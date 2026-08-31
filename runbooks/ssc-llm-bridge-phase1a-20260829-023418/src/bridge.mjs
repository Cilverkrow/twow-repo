import { randomUUID } from 'node:crypto';

import { BridgeError, asBridgeError } from './errors.mjs';
import {
  assertBotGuid,
  assertCanonicalUuidV4,
  createCompletionEnvelope,
  createRequestEnvelope,
  createStatusEnvelope,
  frozenResult,
  requestKey,
} from './contracts.mjs';
import { parseJsonBytesStrict } from './strict-json.mjs';
import { preparePrompt, sanitizeAssistantText } from './prompt.mjs';

export class BoundedBridge {
  constructor({ config, context, transport, clock = () => Date.now() }) {
    this.config = config;
    this.context = context;
    this.transport = transport;
    this.clock = clock;

    this.lifecycle = 'new';
    this.accepting = false;
    this.stopping = false;
    this.queue = [];
    this.jobs = new Map();
    this.requestIndex = new Map();
    this.waiter = null;
    this.workerTask = null;
    this.startTask = null;
    this.startupController = null;
    this.shutdownTask = null;
    this.activeKey = null;
    this.activeController = null;
    this.activeCount = 0;
    this.maxActiveObserved = 0;
    this.inferenceAttempts = 0;
    this.staleResultsDiscarded = 0;
  }

  start() {
    if (this.lifecycle !== 'new') {
      throw new BridgeError('invalid_bridge_lifecycle', 'bridge can only be started once');
    }
    this.lifecycle = 'starting';
    this.startupController = new AbortController();
    this.startTask = this.startInternal();
    return this.startTask;
  }

  async startInternal() {
    try {
      if (this.config.verify_model_inventory_on_start) {
        await this.transport.verifyPinnedModel(this.startupController.signal);
      }
      if (this.stopping || this.startupController.signal.aborted) {
        throw new BridgeError('startup_cancelled', 'bridge startup was cancelled');
      }
      this.lifecycle = 'running';
      this.accepting = true;
      this.workerTask = this.workerLoop();
    } catch (error) {
      if (this.stopping) {
        this.lifecycle = 'stopping';
        throw new BridgeError('startup_cancelled', 'bridge startup was cancelled', error);
      }
      this.lifecycle = 'failed';
      throw error;
    } finally {
      this.startupController = null;
    }
  }

  submitBytes(bytes) {
    if (!this.accepting || this.lifecycle !== 'running') {
      throw new BridgeError('admission_closed', 'bridge is not accepting requests');
    }
    const parsed = parseJsonBytesStrict(bytes, {
      label: 'request envelope',
      maxBytes: this.config.max_request_json_bytes,
      maxDepth: 8,
      rejectBom: true,
    });
    const nowMs = this.clock();
    const request = createRequestEnvelope(parsed, {
      config: this.config,
      nowMs,
    });
    const key = requestKey(request.request_id, request.bot_guid);

    const indexedGuid = this.requestIndex.get(request.request_id);
    if (indexedGuid !== undefined) {
      if (indexedGuid !== request.bot_guid) {
        return frozenResult({ accepted: false, code: 'identity_mismatch', status: null });
      }
      const existingJob = this.jobs.get(key);
      this.expireIfDue(existingJob);
      return frozenResult({ accepted: false, code: 'duplicate', status: existingJob.status });
    }

    if (request.bot_guid !== this.context.bot_guid) {
      throw new BridgeError('personality_guid_mismatch', 'request bot_guid does not match the pinned personality context');
    }
    const prompt = preparePrompt(request, this.context, this.config);

    if (this.jobs.size >= this.config.ledger_capacity) {
      return frozenResult({ accepted: false, code: 'ledger_full', status: null });
    }

    const queuedUtc = new Date(nowMs).toISOString();
    const job = {
      request,
      prompt,
      queuedUtc,
      startedUtc: null,
      attemptCount: 0,
      attemptToken: null,
      state: 'queued',
      status: createStatusEnvelope({
        request,
        state: 'queued',
        queuedUtc,
        updatedUtc: queuedUtc,
        attemptCount: 0,
      }),
      completion: null,
    };
    this.jobs.set(key, job);
    this.requestIndex.set(request.request_id, request.bot_guid);

    if (nowMs >= Date.parse(request.expires_utc)) {
      this.setTerminal(job, {
        outcome: 'expired',
        errorCode: 'expired_before_run',
        model: null,
        rawResponseBytes: null,
        nowMs,
      });
      return frozenResult({ accepted: false, code: 'expired', status: job.status });
    }

    this.sweepQueuedExpiry();
    if (this.queue.length >= this.config.waiting_capacity) {
      this.setTerminal(job, {
        outcome: 'failed',
        errorCode: 'queue_full',
        model: null,
        rawResponseBytes: null,
        nowMs,
      });
      return frozenResult({ accepted: false, code: 'queue_full', status: job.status });
    }

    this.queue.push(key);
    this.notifyWorker();
    return frozenResult({ accepted: true, code: 'queued', status: job.status });
  }

  getStatus(requestId, botGuid) {
    const lookup = this.lookup(requestId, botGuid);
    if (lookup.code !== 'ok') return frozenResult({ code: lookup.code, status: null });
    this.expireIfDue(lookup.job);
    return frozenResult({ code: 'ok', status: lookup.job.status });
  }

  consume(requestId, botGuid) {
    const lookup = this.lookup(requestId, botGuid);
    if (lookup.code !== 'ok') return frozenResult({ code: lookup.code, status: null, completion: null });
    const job = lookup.job;
    this.expireIfDue(job);

    if (job.state === 'queued' || job.state === 'running') {
      return frozenResult({ code: 'not_ready', status: job.status, completion: null });
    }
    if (job.state === 'consumed') {
      return frozenResult({ code: 'already_consumed', status: job.status, completion: null });
    }
    if (!job.completion) {
      throw new BridgeError('missing_completion', 'terminal job has no immutable completion envelope');
    }

    const completion = job.completion;
    job.completion = null;
    job.state = 'consumed';
    job.status = createStatusEnvelope({
      request: job.request,
      state: 'consumed',
      queuedUtc: job.queuedUtc,
      updatedUtc: new Date(this.clock()).toISOString(),
      attemptCount: job.attemptCount,
      errorCode: completion.error_code,
    });
    return frozenResult({ code: 'consumed', status: job.status, completion });
  }

  shutdown(options = {}) {
    if (this.shutdownTask) return this.shutdownTask;
    const drain = options.drain ?? true;
    const timeoutMs = options.timeoutMs ?? this.config.shutdown_timeout_ms;
    if (typeof drain !== 'boolean') {
      throw new BridgeError('invalid_shutdown_mode', 'shutdown drain must be boolean');
    }
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 180000) {
      throw new BridgeError('invalid_shutdown_timeout', 'shutdown timeout is out of range');
    }
    this.shutdownTask = this.shutdownInternal(drain, timeoutMs);
    return this.shutdownTask;
  }

  metrics() {
    this.sweepQueuedExpiry();
    return frozenResult({
      lifecycle: this.lifecycle,
      accepting: this.accepting,
      waiting: this.queue.filter((key) => this.jobs.get(key)?.state === 'queued').length,
      ledger_entries: this.jobs.size,
      active: this.activeCount,
      max_active_observed: this.maxActiveObserved,
      inference_attempts: this.inferenceAttempts,
      stale_results_discarded: this.staleResultsDiscarded,
      worker_owned: this.workerTask !== null,
      worker_settled: this.lifecycle === 'stopped' || this.lifecycle === 'failed',
    });
  }

  lookup(requestId, botGuid) {
    try {
      assertCanonicalUuidV4(requestId);
      assertBotGuid(botGuid);
    } catch (error) {
      return { code: asBridgeError(error).code, job: null };
    }
    const indexedGuid = this.requestIndex.get(requestId);
    if (indexedGuid === undefined) return { code: 'not_found', job: null };
    if (indexedGuid !== botGuid) return { code: 'identity_mismatch', job: null };
    return { code: 'ok', job: this.jobs.get(requestKey(requestId, botGuid)) };
  }

  async workerLoop() {
    while (true) {
      if (this.queue.length === 0) {
        if (this.stopping) return;
        await new Promise((resolve) => {
          this.waiter = resolve;
        });
        this.waiter = null;
        continue;
      }

      const key = this.queue.shift();
      const job = this.jobs.get(key);
      if (!job || job.state !== 'queued') continue;
      if (this.expireIfDue(job)) continue;
      await this.processJob(key, job);
    }
  }

  async processJob(key, job) {
    const startedMs = this.clock();
    if (startedMs >= Date.parse(job.request.expires_utc)) {
      this.setTerminal(job, {
        outcome: 'expired',
        errorCode: 'expired_before_run',
        model: null,
        rawResponseBytes: null,
        nowMs: startedMs,
      });
      return;
    }

    job.state = 'running';
    job.startedUtc = new Date(startedMs).toISOString();
    job.attemptCount = 1;
    job.attemptToken = randomUUID();
    const attemptToken = job.attemptToken;
    job.status = createStatusEnvelope({
      request: job.request,
      state: 'running',
      queuedUtc: job.queuedUtc,
      updatedUtc: job.startedUtc,
      attemptCount: 1,
    });

    this.activeKey = key;
    this.activeController = new AbortController();
    this.activeCount += 1;
    this.inferenceAttempts += 1;
    this.maxActiveObserved = Math.max(this.maxActiveObserved, this.activeCount);

    try {
      const result = await this.transport.infer({
        request: job.request,
        prompt: job.prompt,
        signal: this.activeController.signal,
      });
      if (job.state !== 'running' || job.attemptToken !== attemptToken) {
        this.staleResultsDiscarded += 1;
        return;
      }
      const nowMs = this.clock();
      if (nowMs >= Date.parse(job.request.expires_utc)) {
        this.setTerminal(job, {
          outcome: 'expired',
          errorCode: 'stale_result',
          model: this.config.pinned_model.name,
          rawResponseBytes: boundedRawByteCountOrNull(result.raw_response_bytes, this.config.max_raw_response_bytes),
          nowMs,
        });
        return;
      }
      if (result.request_id !== job.request.request_id || result.bot_guid !== job.request.bot_guid) {
        this.setTerminal(job, {
          outcome: 'failed',
          errorCode: 'completion_mismatch',
          model: null,
          rawResponseBytes: boundedRawByteCountOrNull(result.raw_response_bytes, this.config.max_raw_response_bytes),
          nowMs,
        });
        return;
      }
      if (result.model !== this.config.pinned_model.name) {
        this.setTerminal(job, {
          outcome: 'failed',
          errorCode: 'response_model_mismatch',
          model: null,
          rawResponseBytes: boundedRawByteCountOrNull(result.raw_response_bytes, this.config.max_raw_response_bytes),
          nowMs,
        });
        return;
      }
      if (!Number.isSafeInteger(result.raw_response_bytes) || result.raw_response_bytes < 0 || result.raw_response_bytes > this.config.max_raw_response_bytes) {
        throw new BridgeError('invalid_raw_response_bytes', 'transport returned an invalid raw response byte count');
      }
      const text = sanitizeAssistantText(result.text, this.config);
      this.setTerminal(job, {
        outcome: 'ready',
        errorCode: null,
        model: result.model,
        rawResponseBytes: result.raw_response_bytes,
        text,
        nowMs,
      });
    } catch (error) {
      if (job.state !== 'running' || job.attemptToken !== attemptToken) {
        this.staleResultsDiscarded += 1;
        return;
      }
      const nowMs = this.clock();
      if (nowMs >= Date.parse(job.request.expires_utc)) {
        this.setTerminal(job, {
          outcome: 'expired',
          errorCode: 'stale_result',
          model: this.config.pinned_model.name,
          rawResponseBytes: null,
          nowMs,
        });
      } else {
        const bridgeError = asBridgeError(error, 'inference_failed');
        const errorCode = bridgeError.code === 'request_cancelled' && this.stopping ? 'shutdown_cancelled' : bridgeError.code;
        this.setTerminal(job, {
          outcome: 'failed',
          errorCode,
          model: this.config.pinned_model.name,
          rawResponseBytes: null,
          nowMs,
        });
      }
    } finally {
      this.activeCount -= 1;
      this.activeKey = null;
      this.activeController = null;
      job.attemptToken = null;
    }
  }

  expireIfDue(job) {
    const nowMs = this.clock();
    if (nowMs < Date.parse(job.request.expires_utc)) {
      return false;
    }
    if (job.state === 'ready') {
      const readyCompletion = job.completion;
      job.state = 'expired';
      job.completion = createCompletionEnvelope({
        request: job.request,
        outcome: 'expired',
        model: readyCompletion.model,
        attemptCount: job.attemptCount,
        startedUtc: job.startedUtc,
        completedUtc: new Date(nowMs).toISOString(),
        text: null,
        errorCode: 'expired_before_consume',
        rawResponseBytes: readyCompletion.raw_response_bytes,
      });
      job.status = createStatusEnvelope({
        request: job.request,
        state: 'expired',
        queuedUtc: job.queuedUtc,
        updatedUtc: new Date(nowMs).toISOString(),
        attemptCount: job.attemptCount,
        errorCode: 'expired_before_consume',
      });
      return true;
    }
    if (job.state !== 'queued' && job.state !== 'running') {
      return false;
    }
    const wasRunning = job.state === 'running';
    this.setTerminal(job, {
      outcome: 'expired',
      errorCode: wasRunning ? 'stale_result' : 'expired_before_run',
      model: wasRunning ? this.config.pinned_model.name : null,
      rawResponseBytes: null,
      nowMs,
    });
    if (wasRunning && this.activeKey === requestKey(job.request.request_id, job.request.bot_guid)) {
      this.activeController?.abort();
    }
    return true;
  }

  setTerminal(job, { outcome, errorCode, model, rawResponseBytes, text = null, nowMs }) {
    if (job.state === 'ready' || job.state === 'failed' || job.state === 'expired' || job.state === 'consumed') {
      this.staleResultsDiscarded += 1;
      return false;
    }
    job.state = outcome;
    const completedUtc = new Date(nowMs).toISOString();
    job.completion = createCompletionEnvelope({
      request: job.request,
      outcome,
      model,
      attemptCount: job.attemptCount,
      startedUtc: job.startedUtc,
      completedUtc,
      text: outcome === 'ready' ? text : null,
      errorCode: outcome === 'ready' ? null : errorCode,
      rawResponseBytes,
    });
    job.status = createStatusEnvelope({
      request: job.request,
      state: outcome,
      queuedUtc: job.queuedUtc,
      updatedUtc: completedUtc,
      attemptCount: job.attemptCount,
      errorCode: outcome === 'ready' ? null : errorCode,
    });
    return true;
  }

  async shutdownInternal(drain, timeoutMs) {
    if (this.lifecycle === 'new') {
      this.lifecycle = 'stopped';
      return this.metrics();
    }
    if (this.lifecycle === 'failed' || this.lifecycle === 'stopped') return this.metrics();
    if (this.lifecycle === 'starting') {
      this.accepting = false;
      this.stopping = true;
      this.lifecycle = 'stopping';
      this.startupController?.abort();
      try {
        await this.startTask;
      } catch {
        // Startup failure/cancellation is fully joined by this shutdown path.
      }
      this.lifecycle = 'stopped';
      return this.metrics();
    }

    this.accepting = false;
    this.stopping = true;
    this.lifecycle = 'stopping';
    if (!drain) this.cancelOutstanding('shutdown_cancelled');
    this.notifyWorker();

    const outcome = await joinWithTimeout(this.workerTask, timeoutMs);
    if (outcome === 'timeout') {
      this.cancelOutstanding('shutdown_timeout');
      this.notifyWorker();
      await this.workerTask;
    }
    this.lifecycle = 'stopped';
    return this.metrics();
  }

  cancelOutstanding(errorCode) {
    const nowMs = this.clock();
    for (const key of this.queue) {
      const job = this.jobs.get(key);
      if (job?.state === 'queued') {
        this.setTerminal(job, {
          outcome: 'failed',
          errorCode,
          model: null,
          rawResponseBytes: null,
          nowMs,
        });
      }
    }
    this.queue = [];
    if (this.activeKey) {
      const job = this.jobs.get(this.activeKey);
      if (job?.state === 'running') {
        this.setTerminal(job, {
          outcome: 'failed',
          errorCode,
          model: this.config.pinned_model.name,
          rawResponseBytes: null,
          nowMs,
        });
      }
      this.activeController?.abort();
    }
  }

  notifyWorker() {
    const waiter = this.waiter;
    this.waiter = null;
    waiter?.();
  }

  sweepQueuedExpiry() {
    for (const queuedKey of this.queue) {
      const queuedJob = this.jobs.get(queuedKey);
      if (queuedJob?.state === 'queued') this.expireIfDue(queuedJob);
    }
    this.queue = this.queue.filter((queuedKey) => this.jobs.get(queuedKey)?.state === 'queued');
  }
}

function boundedRawByteCountOrNull(value, maximum) {
  return Number.isSafeInteger(value) && value >= 0 && value <= maximum ? value : null;
}

function joinWithTimeout(workerTask, milliseconds) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => resolve('timeout'), milliseconds);
    workerTask.then(
      () => {
        clearTimeout(timer);
        resolve('joined');
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}
