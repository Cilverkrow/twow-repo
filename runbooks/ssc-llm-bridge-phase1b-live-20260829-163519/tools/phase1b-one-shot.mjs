import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import {
  closeSync,
  existsSync,
  openSync,
  readFileSync,
  writeFileSync,
} from 'node:fs';
import { resolve } from 'node:path';
import readline from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';

import { loadRuntimeConfiguration } from '../bridge/src/configuration.mjs';
import { sanitizeAssistantText } from '../bridge/src/prompt.mjs';

const ROOT = resolve(import.meta.dirname, '..');
const BRIDGE_ROOT = resolve(ROOT, 'bridge');
const EVIDENCE_ROOT = resolve(ROOT, 'evidence');
const CLI_PATH = resolve(BRIDGE_ROOT, 'src/cli.mjs');
const LOCK_PATH = resolve(BRIDGE_ROOT, 'evidence/.phase1a-instance.lock');
const NODE_PATH = 'C:\\Users\\djfav\\.cache\\codex-runtimes\\codex-primary-runtime\\dependencies\\node\\bin\\node.exe';
const GUARD_PATH = resolve(EVIDENCE_ROOT, 'phase1b-one-shot.guard.json');
const PINNED_BOT_GUID = 18281;
const PINNED_MODEL = 'qwen2.5:7b';
const REQUEST_LIFETIME_MS = 45000;
const STARTUP_TIMEOUT_MS = 35000;
const COMMAND_TIMEOUT_MS = 5000;
const SHUTDOWN_RESPONSE_TIMEOUT_MS = 40000;
const PROCESS_CLOSE_TIMEOUT_MS = 10000;
const TERMINAL_WAIT_MS = 46000;
const POLL_INTERVAL_MS = 100;

const runStartedUtc = new Date().toISOString();
const runStartedMonotonic = performance.now();
const transcript = [];
let child = null;
let childClosePromise = null;
let childClosed = false;
let stdoutInterface = null;
let stderrInterface = null;
let stdoutWaiter = null;
const stdoutQueue = [];
let readyObserved = false;
let submitCount = 0;
let statusPollCount = 0;
let consumeCount = 0;
let metricsCount = 0;
let shutdownCount = 0;
let shutdownSent = false;
let request = null;
let inferenceStartedElapsedMs = null;
let inferenceStartedUtc = null;
let terminalObservedElapsedMs = null;
let terminalObservedUtc = null;
let finalResultWritten = false;
let transcriptWritten = false;

createOneShotGuard();

try {
  if (existsSync(LOCK_PATH)) {
    throw new Error(`stale instance lock exists before startup: ${LOCK_PATH}`);
  }

  const runtime = loadRuntimeConfiguration();
  requireCondition(runtime.context.bot_guid === PINNED_BOT_GUID, 'pinned bot_guid changed');
  requireCondition(runtime.config.pinned_model.name === PINNED_MODEL, 'pinned model name changed');
  requireCondition(runtime.config.waiting_capacity === 2, 'waiting capacity changed');
  requireCondition(runtime.config.ledger_capacity === 64, 'ledger capacity changed');

  spawnBridge();
  const startup = await readJsonResponse('startup', STARTUP_TIMEOUT_MS);
  readyObserved = startup.value.code === 'ready';
  assertReady(startup.value);
  requireCondition(existsSync(LOCK_PATH), 'instance lock is absent after ready');
  const lockBytes = readFileSync(LOCK_PATH);
  const lockRecord = JSON.parse(lockBytes.toString('utf8'));
  requireCondition(lockRecord.schema_version === 1, 'instance lock schema version mismatch');
  requireCondition(lockRecord.pid === child.pid, 'instance lock PID does not match the bridge process');
  requireCondition(typeof lockRecord.token === 'string' && lockRecord.token.length > 0, 'instance lock token is missing');
  writeJsonExclusive('instance-lock-present.json', {
    schema_version: 1,
    observed_utc: new Date().toISOString(),
    lock_present: true,
    lock_path: LOCK_PATH,
    bridge_pid: child.pid,
    lock_pid: lockRecord.pid,
    pid_matches: true,
    lock_sha256: createHash('sha256').update(lockBytes).digest('hex').toUpperCase(),
  });

  const requestId = randomUUID();
  requireCondition(
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(requestId),
    'randomUUID did not produce a canonical lowercase UUIDv4',
  );
  const createdMs = Date.now();
  request = {
    schema_version: 1,
    request_id: requestId,
    bot_guid: PINNED_BOT_GUID,
    created_utc: new Date(createdMs).toISOString(),
    expires_utc: new Date(createdMs + REQUEST_LIFETIME_MS).toISOString(),
    message: 'Was hast du heute vor?',
  };
  requireCondition(
    Date.parse(request.expires_utc) - Date.parse(request.created_utc) === REQUEST_LIFETIME_MS,
    'request expiry is not exactly 45 seconds after creation',
  );
  writeJsonExclusive('request-envelope.json', request);

  submitCount += 1;
  const submitEvent = await sendCommand({ command: 'submit', request }, 'submit');
  inferenceStartedElapsedMs = submitEvent.elapsed_ms;
  inferenceStartedUtc = submitEvent.utc;
  const submission = await readJsonResponse('submit', COMMAND_TIMEOUT_MS);
  assertSubmission(submission.value);
  writeJsonExclusive('submit-response.json', submission.value);

  let terminalStatus = null;
  while (performance.now() - runStartedMonotonic - inferenceStartedElapsedMs < TERMINAL_WAIT_MS) {
    await delay(POLL_INTERVAL_MS);
    statusPollCount += 1;
    await sendCommand({
      command: 'status',
      request_id: request.request_id,
      bot_guid: request.bot_guid,
    }, `status-${statusPollCount}`);
    const polled = await readJsonResponse(`status-${statusPollCount}`, COMMAND_TIMEOUT_MS);
    assertStatusResponse(polled.value);
    const state = polled.value.status.state;
    if (state === 'queued' || state === 'running') continue;
    if (state === 'ready') {
      terminalStatus = polled.value.status;
      terminalObservedElapsedMs = polled.event.elapsed_ms;
      terminalObservedUtc = polled.event.utc;
      break;
    }
    if (state === 'failed' || state === 'expired') {
      writeJsonExclusive('terminal-status.json', polled.value.status);
      throw new Error(`inference reached terminal non-ready state: ${state}/${polled.value.status.error_code}`);
    }
    throw new Error(`unexpected status state before consume: ${state}`);
  }
  requireCondition(terminalStatus !== null, 'no terminal ready status was observed before the one-shot deadline');
  writeJsonExclusive('terminal-status.json', terminalStatus);

  consumeCount += 1;
  await sendCommand({
    command: 'consume',
    request_id: request.request_id,
    bot_guid: request.bot_guid,
  }, 'consume-first');
  const firstConsume = await readJsonResponse('consume-first', COMMAND_TIMEOUT_MS);
  assertFirstConsume(firstConsume.value, runtime.config);
  writeJsonExclusive('consume-first-response.json', firstConsume.value);
  writeJsonExclusive('completion-envelope.json', firstConsume.value.completion);

  consumeCount += 1;
  await sendCommand({
    command: 'consume',
    request_id: request.request_id,
    bot_guid: request.bot_guid,
  }, 'consume-second');
  const secondConsume = await readJsonResponse('consume-second', COMMAND_TIMEOUT_MS);
  assertSecondConsume(secondConsume.value);
  writeJsonExclusive('consume-second-response.json', secondConsume.value);

  metricsCount += 1;
  await sendCommand({ command: 'metrics' }, 'metrics');
  const metricsResponse = await readJsonResponse('metrics', COMMAND_TIMEOUT_MS);
  assertMetrics(metricsResponse.value);
  writeJsonExclusive('metrics-before-shutdown.json', metricsResponse.value);

  shutdownCount += 1;
  shutdownSent = true;
  await sendCommand({ command: 'shutdown', drain: true }, 'shutdown');
  child.stdin.end();
  const shutdownResponse = await readJsonResponse('shutdown', SHUTDOWN_RESPONSE_TIMEOUT_MS);
  assertShutdown(shutdownResponse.value);
  writeJsonExclusive('shutdown-response.json', shutdownResponse.value);

  const childExit = await withTimeout(childClosePromise, PROCESS_CLOSE_TIMEOUT_MS, 'bridge process close after shutdown');
  requireCondition(childExit.code === 0, `bridge closed with code ${childExit.code}`);
  requireCondition(childExit.signal === null, `bridge closed from signal ${childExit.signal}`);
  requireCondition(stdoutQueue.length === 0, `unexpected queued stdout lines after shutdown: ${stdoutQueue.length}`);
  requireCondition(
    transcript.filter((event) => event.direction === 'bridge_stderr').length === 0,
    'bridge emitted unexpected stderr output',
  );
  requireCondition(!existsSync(LOCK_PATH), 'instance lock still exists after bridge process exit');
  writeJsonExclusive('instance-lock-removed.json', {
    schema_version: 1,
    observed_utc: new Date().toISOString(),
    lock_path: LOCK_PATH,
    bridge_pid: child.pid,
    bridge_exit_code: childExit.code,
    bridge_exit_signal: childExit.signal,
    lock_present: false,
    result: 'INSTANCE_LOCK_REMOVED=PASS',
  });

  const latency = {
    schema_version: 1,
    measurement: 'submit write to first observed terminal ready status',
    clock: 'Node performance.now monotonic elapsed wall-clock measurement',
    submit_sent_utc: inferenceStartedUtc,
    terminal_ready_observed_utc: terminalObservedUtc,
    latency_ms: roundMilliseconds(terminalObservedElapsedMs - inferenceStartedElapsedMs),
    request_lifetime_ms: REQUEST_LIFETIME_MS,
    status_poll_interval_ms: POLL_INTERVAL_MS,
    status_poll_count: statusPollCount,
    no_second_inference: true,
  };
  writeJsonExclusive('latency.json', latency);

  const result = {
    schema_version: 1,
    result: 'PHASE1B_LIVE_INFERENCE=PASS',
    started_utc: runStartedUtc,
    completed_utc: new Date().toISOString(),
    cli_start_count: 1,
    request_id_count: 1,
    submit_command_count: submitCount,
    status_poll_count: statusPollCount,
    consume_command_count: consumeCount,
    metrics_command_count: metricsCount,
    shutdown_command_count: shutdownCount,
    inferred_required_tags_get_count: 1,
    verified_inference_attempts: metricsResponse.value.metrics.inference_attempts,
    automatic_retry_performed: false,
    resubmission_performed: false,
    live_inference_count: 1,
    request_id: request.request_id,
    bot_guid: request.bot_guid,
    model: firstConsume.value.completion.model,
    outcome: firstConsume.value.completion.outcome,
    raw_response_bytes: firstConsume.value.completion.raw_response_bytes,
    sanitized_text: firstConsume.value.completion.text,
    worker_joined: shutdownResponse.value.metrics.worker_settled,
    instance_lock_removed_after_exit: true,
    process_exit_code: childExit.code,
    process_exit_signal: childExit.signal,
  };
  writeTranscript('PASS');
  writeJsonExclusive('live-run-result.json', result);
  finalResultWritten = true;
  process.stdout.write(`${result.result}\n`);
  process.stdout.write(`request_id=${result.request_id}\n`);
  process.stdout.write(`latency_ms=${latency.latency_ms}\n`);
  process.stdout.write(`raw_response_bytes=${result.raw_response_bytes}\n`);
} catch (error) {
  const failure = normalizeError(error);
  recordEvent('controller', 'failure', JSON.stringify(failure));

  if (readyObserved && child?.exitCode === null && !shutdownSent) {
    try {
      shutdownCount += 1;
      shutdownSent = true;
      await sendCommand({ command: 'shutdown', drain: true }, 'failure-cleanup-shutdown');
      child.stdin.end();
      const cleanup = await readJsonResponse('failure-cleanup-shutdown', SHUTDOWN_RESPONSE_TIMEOUT_MS);
      writeJsonExclusive('failure-cleanup-shutdown-response.json', cleanup.value);
      await withTimeout(childClosePromise, PROCESS_CLOSE_TIMEOUT_MS, 'bridge process close after failure cleanup');
    } catch (cleanupError) {
      recordEvent('controller', 'failure-cleanup-error', JSON.stringify(normalizeError(cleanupError)));
    }
  } else if (child !== null && !childClosed && shutdownSent) {
    try {
      child.stdin.end();
      await withTimeout(childClosePromise, SHUTDOWN_RESPONSE_TIMEOUT_MS, 'bridge process close after sent shutdown');
    } catch (closeError) {
      recordEvent('controller', 'post-shutdown-close-error', JSON.stringify(normalizeError(closeError)));
    }
  } else if (child !== null && !childClosed && !readyObserved) {
    try {
      child.stdin.end();
      await withTimeout(childClosePromise, SHUTDOWN_RESPONSE_TIMEOUT_MS, 'bridge process close after startup failure');
    } catch (closeError) {
      recordEvent('controller', 'startup-failure-close-error', JSON.stringify(normalizeError(closeError)));
    }
  }

  if (!transcriptWritten) writeTranscript('FAIL');
  if (!finalResultWritten) {
    writeJsonExclusive('live-run-result.json', {
      schema_version: 1,
      result: 'PHASE1B_LIVE_INFERENCE=FAIL',
      started_utc: runStartedUtc,
      completed_utc: new Date().toISOString(),
      failure,
      cli_start_count: child === null ? 0 : 1,
      submit_command_count: submitCount,
      status_poll_count: statusPollCount,
      consume_command_count: consumeCount,
      metrics_command_count: metricsCount,
      shutdown_command_count: shutdownCount,
      automatic_retry_performed: false,
      resubmission_performed: false,
      request_id: request?.request_id ?? null,
    });
  }
  process.stderr.write(`PHASE1B_LIVE_INFERENCE=FAIL ${failure.message}\n`);
  process.exitCode = 1;
} finally {
  stdoutInterface?.close();
  stderrInterface?.close();
}

function createOneShotGuard() {
  const fileDescriptor = openSync(GUARD_PATH, 'wx');
  try {
    writeFileSync(fileDescriptor, `${JSON.stringify({
      schema_version: 1,
      purpose: 'prevents any restart, resubmit, or retry of the approved Phase-1B live run',
      created_utc: runStartedUtc,
      controller_pid: process.pid,
    }, null, 2)}\n`, 'utf8');
  } finally {
    closeSync(fileDescriptor);
  }
}

function spawnBridge() {
  child = spawn(NODE_PATH, [CLI_PATH, '--run'], {
    cwd: BRIDGE_ROOT,
    windowsHide: true,
    shell: false,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  recordEvent('controller', 'spawn', JSON.stringify({ executable: NODE_PATH, arguments: [CLI_PATH, '--run'] }));

  stdoutInterface = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
  stderrInterface = readline.createInterface({ input: child.stderr, crlfDelay: Infinity });
  stdoutInterface.on('line', (line) => {
    const event = recordEvent('bridge_stdout', 'line', line);
    if (stdoutWaiter !== null) {
      const waiter = stdoutWaiter;
      stdoutWaiter = null;
      clearTimeout(waiter.timer);
      waiter.resolve({ line, event });
    } else {
      stdoutQueue.push({ line, event });
    }
  });
  stderrInterface.on('line', (line) => recordEvent('bridge_stderr', 'line', line));

  childClosePromise = new Promise((resolveExit, rejectExit) => {
    child.once('error', (error) => {
      if (stdoutWaiter !== null) {
        const waiter = stdoutWaiter;
        stdoutWaiter = null;
        clearTimeout(waiter.timer);
        waiter.reject(error);
      }
      rejectExit(error);
    });
    child.once('close', (code, signal) => {
      childClosed = true;
      recordEvent('controller', 'bridge-close', JSON.stringify({ code, signal }));
      if (stdoutWaiter !== null) {
        const waiter = stdoutWaiter;
        stdoutWaiter = null;
        clearTimeout(waiter.timer);
        waiter.reject(new Error(`bridge exited before the expected line (code=${code}, signal=${signal})`));
      }
      resolveExit({ code, signal });
    });
  });
}

async function sendCommand(command, stage) {
  requireCondition(child !== null && child.exitCode === null, `cannot send ${stage}; bridge is not running`);
  const line = JSON.stringify(command);
  const event = recordEvent('bridge_stdin', stage, line);
  await new Promise((resolveWrite, rejectWrite) => {
    child.stdin.write(`${line}\n`, 'utf8', (error) => {
      if (error) rejectWrite(error);
      else resolveWrite();
    });
  });
  return event;
}

async function readJsonResponse(stage, timeoutMs) {
  const item = await nextStdoutLine(stage, timeoutMs);
  let value;
  try {
    value = JSON.parse(item.line);
  } catch (error) {
    throw new Error(`${stage} returned invalid JSON: ${error.message}`);
  }
  requireCondition(value !== null && typeof value === 'object' && !Array.isArray(value), `${stage} response is not an object`);
  return { value, event: item.event };
}

function nextStdoutLine(stage, timeoutMs) {
  if (stdoutQueue.length > 0) return Promise.resolve(stdoutQueue.shift());
  requireCondition(stdoutWaiter === null, 'concurrent stdout waits are forbidden');
  return new Promise((resolveLine, rejectLine) => {
    const timer = setTimeout(() => {
      if (stdoutWaiter?.timer === timer) stdoutWaiter = null;
      rejectLine(new Error(`${stage} exceeded its ${timeoutMs} ms output deadline`));
    }, timeoutMs);
    stdoutWaiter = { resolve: resolveLine, reject: rejectLine, timer };
  });
}

function assertReady(value) {
  requireCondition(value.code === 'ready', `startup did not return ready: ${value.code}`);
  requireCondition(value.mode === 'server_free_ndjson', 'startup mode mismatch');
  requireCondition(value.active_limit === 1, 'startup active limit mismatch');
  requireCondition(value.waiting_capacity === 2, 'startup waiting capacity mismatch');
  requireCondition(value.ledger_capacity === 64, 'startup ledger capacity mismatch');
  requireCondition(value.bot_guid === PINNED_BOT_GUID, 'startup bot_guid mismatch');
  requireCondition(value.model === PINNED_MODEL, 'startup model mismatch');
}

function assertSubmission(value) {
  requireCondition(value.accepted === true && value.code === 'queued', 'the single submission was not accepted exactly once');
  assertIdentity(value.status, 'submit status');
  requireCondition(value.status.state === 'queued', 'submit state is not queued');
  requireCondition(value.status.attempt_count === 0, 'submit attempt_count is not zero');
}

function assertStatusResponse(value) {
  requireCondition(value.code === 'ok', `status poll returned ${value.code}`);
  assertIdentity(value.status, 'polled status');
  requireCondition(Number.isSafeInteger(value.status.attempt_count), 'status attempt_count is not an integer');
  requireCondition(value.status.attempt_count >= 0 && value.status.attempt_count <= 1, 'status attempt_count exceeds one');
}

function assertFirstConsume(value, config) {
  requireCondition(value.code === 'consumed', `first consume returned ${value.code}`);
  assertIdentity(value.status, 'first consume status');
  requireCondition(value.status.state === 'consumed', 'first consume status is not consumed');
  const completion = value.completion;
  requireCondition(completion !== null && typeof completion === 'object' && !Array.isArray(completion), 'first consume has no completion');
  assertIdentity(completion, 'completion');
  requireCondition(completion.outcome === 'ready', `completion outcome is ${completion.outcome}`);
  requireCondition(completion.model === PINNED_MODEL, `completion model is ${completion.model}`);
  requireCondition(completion.attempt_count === 1, 'completion attempt_count is not one');
  requireCondition(completion.error_code === null, 'ready completion has an error_code');
  requireCondition(
    Number.isSafeInteger(completion.raw_response_bytes) &&
      completion.raw_response_bytes >= 1 &&
      completion.raw_response_bytes <= config.max_raw_response_bytes,
    'completion raw_response_bytes is out of range',
  );
  requireCondition(typeof completion.text === 'string' && completion.text.length > 0, 'completion text is empty or not a string');
  const independentlySanitized = sanitizeAssistantText(completion.text, config);
  requireCondition(independentlySanitized === completion.text, 'completion text is not in canonical sanitized form');
}

function assertSecondConsume(value) {
  requireCondition(value.code === 'already_consumed', `second consume returned ${value.code}`);
  assertIdentity(value.status, 'second consume status');
  requireCondition(value.status.state === 'consumed', 'second consume status is not consumed');
  requireCondition(value.completion === null, 'second consume returned a completion');
  requireCondition(!containsTextMember(value), 'second consume response contains a text member');
}

function assertMetrics(value) {
  requireCondition(value.code === 'metrics', `metrics returned ${value.code}`);
  const metrics = value.metrics;
  requireCondition(metrics.inference_attempts === 1, `inference_attempts is ${metrics.inference_attempts}`);
  requireCondition(metrics.max_active_observed === 1, `max_active_observed is ${metrics.max_active_observed}`);
  requireCondition(metrics.active === 0, `active is ${metrics.active}`);
  requireCondition(metrics.waiting === 0, `waiting is ${metrics.waiting}`);
  requireCondition(metrics.ledger_entries === 1, `ledger_entries is ${metrics.ledger_entries}`);
  requireCondition(metrics.stale_results_discarded === 0, `stale_results_discarded is ${metrics.stale_results_discarded}`);
}

function assertShutdown(value) {
  requireCondition(value.code === 'shutdown', `shutdown returned ${value.code}`);
  const metrics = value.metrics;
  requireCondition(metrics.lifecycle === 'stopped', `shutdown lifecycle is ${metrics.lifecycle}`);
  requireCondition(metrics.accepting === false, 'shutdown still accepts requests');
  requireCondition(metrics.active === 0, `shutdown active is ${metrics.active}`);
  requireCondition(metrics.inference_attempts === 1, `shutdown inference_attempts is ${metrics.inference_attempts}`);
  requireCondition(metrics.max_active_observed === 1, `shutdown max_active_observed is ${metrics.max_active_observed}`);
  requireCondition(metrics.worker_settled === true, 'shutdown worker is not settled');
}

function assertIdentity(value, label) {
  requireCondition(value !== null && typeof value === 'object', `${label} is missing`);
  requireCondition(value.request_id === request.request_id, `${label} request_id mismatch`);
  requireCondition(value.bot_guid === request.bot_guid, `${label} bot_guid mismatch`);
}

function containsTextMember(value) {
  if (value === null || typeof value !== 'object') return false;
  if (Object.hasOwn(value, 'text')) return true;
  if (Array.isArray(value)) return value.some(containsTextMember);
  return Object.values(value).some(containsTextMember);
}

function recordEvent(direction, stage, line) {
  const event = {
    sequence: transcript.length + 1,
    utc: new Date().toISOString(),
    elapsed_ms: roundMilliseconds(performance.now() - runStartedMonotonic),
    direction,
    stage,
    line,
  };
  transcript.push(event);
  return event;
}

function writeTranscript(result) {
  const stdinLines = transcript.filter((event) => event.direction === 'bridge_stdin').map((event) => event.line);
  const stdoutLines = transcript.filter((event) => event.direction === 'bridge_stdout').map((event) => event.line);
  const stderrLines = transcript.filter((event) => event.direction === 'bridge_stderr').map((event) => event.line);
  writeTextExclusive('bridge-stdin.ndjson', stdinLines.length === 0 ? '' : `${stdinLines.join('\n')}\n`);
  writeTextExclusive('bridge-stdout.ndjson', stdoutLines.length === 0 ? '' : `${stdoutLines.join('\n')}\n`);
  writeTextExclusive('bridge-stderr.txt', stderrLines.length === 0 ? '' : `${stderrLines.join('\n')}\n`);
  writeJsonExclusive('bridge-transcript.json', {
    schema_version: 1,
    result,
    controller_started_utc: runStartedUtc,
    events: transcript,
  });
  transcriptWritten = true;
}

function writeJsonExclusive(name, value) {
  const path = resolve(EVIDENCE_ROOT, name);
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
}

function writeTextExclusive(name, value) {
  const path = resolve(EVIDENCE_ROOT, name);
  writeFileSync(path, value, { encoding: 'utf8', flag: 'wx' });
}

function withTimeout(promise, timeoutMs, label) {
  let timer;
  const timeout = new Promise((resolveTimeout, rejectTimeout) => {
    timer = setTimeout(() => rejectTimeout(new Error(`${label} exceeded ${timeoutMs} ms`)), timeoutMs);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function requireCondition(condition, message) {
  if (!condition) throw new Error(message);
}

function normalizeError(error) {
  return {
    name: typeof error?.name === 'string' ? error.name : 'Error',
    code: typeof error?.code === 'string' ? error.code : null,
    message: typeof error?.message === 'string' ? error.message : String(error),
    stack: typeof error?.stack === 'string' ? error.stack : null,
  };
}

function roundMilliseconds(value) {
  return Math.round(value * 1000) / 1000;
}
