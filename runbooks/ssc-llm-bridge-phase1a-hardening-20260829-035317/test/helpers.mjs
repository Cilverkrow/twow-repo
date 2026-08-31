import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { loadRuntimeConfiguration, validateConfigObject } from '../src/configuration.mjs';

export const TEST_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const FIXTURE_ROOT = resolve(TEST_ROOT, 'test/fixtures');
export const FIXED_NOW_MS = Date.parse('2030-01-01T00:00:00.000Z');
export const runtime = loadRuntimeConfiguration();

export class ManualClock {
  constructor(wallNowMs = FIXED_NOW_MS, monotonicNowMs = 0) {
    this.wallValue = wallNowMs;
    this.monotonicValue = monotonicNowMs;
  }

  wallNow = () => this.wallValue;

  monotonicNow = () => this.monotonicValue;

  advance(milliseconds) {
    this.wallValue += milliseconds;
    this.monotonicValue += milliseconds;
  }

  jumpWall(milliseconds) {
    this.wallValue += milliseconds;
  }

  advanceMonotonic(milliseconds) {
    this.monotonicValue += milliseconds;
  }
}

export class ControlledTransport {
  constructor(handler = undefined, verificationError = undefined) {
    this.handler = handler;
    this.verificationError = verificationError;
    this.verifyCalls = 0;
    this.calls = [];
    this.active = 0;
    this.maxActive = 0;
  }

  async verifyPinnedModel() {
    this.verifyCalls += 1;
    if (this.verificationError) throw this.verificationError;
    return runtime.config.pinned_model;
  }

  async infer(args) {
    this.calls.push(args.request.request_id);
    this.active += 1;
    this.maxActive = Math.max(this.maxActive, this.active);
    try {
      if (this.handler) return await this.handler(args, this.calls.length - 1);
      return successfulTransportResult(args.request);
    } finally {
      this.active -= 1;
    }
  }
}

export function successfulTransportResult(request, overrides = {}) {
  return {
    request_id: request.request_id,
    bot_guid: request.bot_guid,
    model: runtime.config.pinned_model.name,
    text: 'Ich halte heute die Augen offen.',
    raw_response_bytes: 128,
    ...overrides,
  };
}

export function makeRequest(sequence = 1, overrides = {}) {
  const suffix = sequence.toString(16).padStart(12, '0').slice(-12);
  return {
    schema_version: 1,
    request_id: `00000000-0000-4000-8000-${suffix}`,
    bot_guid: runtime.context.bot_guid,
    created_utc: new Date(FIXED_NOW_MS).toISOString(),
    expires_utc: new Date(FIXED_NOW_MS + 30000).toISOString(),
    message: 'Grüße, was hast du heute vor?',
    ...overrides,
  };
}

export function requestBytes(sequence = 1, overrides = {}) {
  return Buffer.from(JSON.stringify(makeRequest(sequence, overrides)), 'utf8');
}

export function fixtureBytes(name) {
  return readFileSync(resolve(FIXTURE_ROOT, name));
}

export function fixtureJson(name) {
  return JSON.parse(fixtureBytes(name).toString('utf8'));
}

export function fixtureHexBytes(name) {
  return Buffer.from(fixtureBytes(name).toString('ascii').trim(), 'hex');
}

export function clonedConfig(changes = {}) {
  const clone = structuredClone(runtime.config);
  Object.assign(clone, changes);
  return validateConfigObject(clone);
}

export function deferred() {
  let resolvePromise;
  let rejectPromise;
  const promise = new Promise((resolve, reject) => {
    resolvePromise = resolve;
    rejectPromise = reject;
  });
  return { promise, resolve: resolvePromise, reject: rejectPromise };
}

export async function eventually(predicate, message = 'condition was not met', timeoutMs = 2000) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const value = predicate();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
  throw new Error(message);
}

export function abortableGate(signal, gate, resultFactory) {
  return new Promise((resolve, reject) => {
    const onAbort = () => reject(Object.assign(new Error('cancelled'), { code: 'request_cancelled' }));
    if (signal.aborted) {
      onAbort();
      return;
    }
    signal.addEventListener('abort', onAbort, { once: true });
    gate.promise.then(
      () => {
        signal.removeEventListener('abort', onAbort);
        resolve(resultFactory());
      },
      (error) => {
        signal.removeEventListener('abort', onAbort);
        reject(error);
      },
    );
  });
}
