import test from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { Readable } from 'node:stream';

import { createRequestEnvelope } from '../src/contracts.mjs';
import { loadRuntimeConfiguration, validateConfigObject, validateContextObject } from '../src/configuration.mjs';
import { acquireInstanceLock } from '../src/instance-lock.mjs';
import { strictLines } from '../src/ndjson.mjs';
import { preparePrompt } from '../src/prompt.mjs';
import { parseJsonBytesStrict } from '../src/strict-json.mjs';
import {
  FIXED_NOW_MS,
  TEST_ROOT,
  fixtureBytes,
  fixtureHexBytes,
  fixtureJson,
  makeRequest,
  runtime,
} from './helpers.mjs';

function requestContract(value, config = runtime.config) {
  return createRequestEnvelope(value, { config, nowMs: FIXED_NOW_MS });
}

test('pinned runtime config and versioned file context validate and freeze', () => {
  assert.equal(runtime.config.pinned_model.name, 'qwen2.5:7b');
  assert.equal(runtime.config.pinned_model.digest, '845dbda0ea48ed749caafd9e6037047aa19acfcfd82e704d7ca97d631a0b697e');
  assert.equal(runtime.context.profile_version, 0);
  assert.equal(runtime.context.bot_guid, 18281);
  assert.equal(runtime.context_sha256, 'AB876B90B9DBE006A785C44E272ACEE70671A359DF8B95AB65A9629A117EED10');
  assert.ok(Object.isFrozen(runtime.config));
  assert.ok(Object.isFrozen(runtime.context));
  assert.ok(Object.isFrozen(runtime.context.race));
});

test('strict UTF-8 rejects malformed bytes and BOM', () => {
  assert.throws(
    () => parseJsonBytesStrict(fixtureHexBytes('malformed-utf8.hex'), { label: 'fixture' }),
    (error) => error.code === 'invalid_utf8',
  );
  assert.throws(
    () => parseJsonBytesStrict(fixtureHexBytes('utf8-bom.hex'), { label: 'fixture' }),
    (error) => error.code === 'utf8_bom_forbidden',
  );
});

test('strict JSON rejects duplicate keys, trailing data, depth and lone surrogates', () => {
  assert.throws(
    () => parseJsonBytesStrict(fixtureBytes('duplicate-key-request.json')),
    (error) => error.code === 'duplicate_json_key',
  );
  assert.throws(
    () => parseJsonBytesStrict(Buffer.from('{}x')),
    (error) => error.code === 'json_trailing_content',
  );
  assert.throws(
    () => parseJsonBytesStrict(Buffer.from('[[[[[0]]]]]'), { maxDepth: 3 }),
    (error) => error.code === 'json_depth_exceeded',
  );
  assert.throws(
    () => parseJsonBytesStrict(fixtureBytes('lone-surrogate-request.json')),
    (error) => error.code === 'invalid_unicode_scalar',
  );
});

test('request schema rejects missing, unknown, wrong-version and unsafe integer fields', () => {
  const missing = makeRequest();
  delete missing.message;
  assert.throws(() => requestContract(missing), (error) => error.code === 'schema_missing_field');
  assert.throws(
    () => requestContract(fixtureJson('unknown-field-request.json')),
    (error) => error.code === 'schema_unknown_field',
  );
  const prototypeMember = parseJsonBytesStrict(Buffer.from('{"schema_version":1,"request_id":"11111111-1111-4111-8111-111111111111","bot_guid":18281,"created_utc":"2030-01-01T00:00:00.000Z","expires_utc":"2030-01-01T00:00:30.000Z","message":"Hallo","__proto__":{"polluted":true}}'));
  assert.throws(
    () => requestContract(prototypeMember),
    (error) => error.code === 'schema_unknown_field',
  );
  assert.equal(Object.prototype.polluted, undefined);
  assert.throws(
    () => requestContract(makeRequest(1, { schema_version: 2 })),
    (error) => error.code === 'unsupported_schema_version',
  );
  assert.throws(
    () => requestContract(makeRequest(1, { bot_guid: Number.MAX_SAFE_INTEGER + 1 })),
    (error) => error.code === 'invalid_bot_guid',
  );
});

test('UUID accepts only canonical lowercase RFC 4122 UUIDv4', () => {
  const accepted = requestContract(makeRequest());
  assert.equal(accepted.request_id, '00000000-0000-4000-8000-000000000001');
  for (const requestId of [
    'abcdefab-cdef-4abc-8abc-abcdefabcdef'.toUpperCase(),
    '{00000000-0000-4000-8000-000000000001}',
    '00000000000040008000000000000001',
    '00000000-0000-1000-8000-000000000001',
    '00000000-0000-4000-7000-000000000001',
    '00000000-0000-0000-0000-000000000000',
  ]) {
    assert.throws(
      () => requestContract(makeRequest(1, { request_id: requestId })),
      (error) => error.code === 'invalid_uuid',
      requestId,
    );
  }
});

test('timestamps, clock skew and TTL are finite and canonical', () => {
  assert.throws(
    () => requestContract(makeRequest(1, { created_utc: '2030-01-01T00:00:00Z' })),
    (error) => error.code === 'invalid_timestamp',
  );
  assert.throws(
    () => requestContract(makeRequest(1, { expires_utc: '2030-01-01T00:00:00.000Z' })),
    (error) => error.code === 'invalid_expiry',
  );
  assert.throws(
    () => requestContract(makeRequest(1, {
      created_utc: new Date(FIXED_NOW_MS + runtime.config.max_clock_skew_ms + 1).toISOString(),
      expires_utc: new Date(FIXED_NOW_MS + runtime.config.max_clock_skew_ms + 1000).toISOString(),
    })),
    (error) => error.code === 'created_in_future',
  );
  assert.throws(
    () => requestContract(makeRequest(1, { expires_utc: new Date(FIXED_NOW_MS + runtime.config.request_ttl_max_ms + 1).toISOString() })),
    (error) => error.code === 'ttl_too_large',
  );
});

test('user-message limit is measured in UTF-8 bytes at exact boundary and limit plus one', () => {
  const message = 'ä'.repeat(10);
  assert.equal(Buffer.byteLength(message, 'utf8'), 20);
  const exactConfig = { ...runtime.config, max_user_message_bytes: 20 };
  assert.equal(requestContract(makeRequest(1, { message }), exactConfig).message, message);
  const overConfig = { ...runtime.config, max_user_message_bytes: 19 };
  assert.throws(
    () => requestContract(makeRequest(1, { message }), overConfig),
    (error) => error.code === 'message_too_large',
  );
});

test('assembled prompt is byte-bounded after system, context and user expansion', () => {
  const request = requestContract(makeRequest(1, { message: '€' }));
  const unbounded = preparePrompt(request, runtime.context, { ...runtime.config, max_prompt_bytes: 65536 });
  const exact = preparePrompt(request, runtime.context, { ...runtime.config, max_prompt_bytes: unbounded.prompt_bytes });
  assert.equal(exact.prompt_bytes, unbounded.prompt_bytes);
  assert.throws(
    () => preparePrompt(request, runtime.context, { ...runtime.config, max_prompt_bytes: unbounded.prompt_bytes - 1 }),
    (error) => error.code === 'prompt_too_large',
  );
  assert.equal(exact.messages[1].role, 'user');
  assert.equal(exact.messages[1].content, '€');
  assert.ok(Object.isFrozen(exact.messages));
});

test('model allowlist, digest and loopback endpoint fail closed', () => {
  for (const mutation of [
    (config) => { config.pinned_model.name = 'other:7b'; },
    (config) => { config.pinned_model.digest = '0'.repeat(64); },
    (config) => { config.model_allowlist.push(structuredClone(config.model_allowlist[0])); },
    (config) => { config.ollama_base_url = 'http://localhost:11434'; },
    (config) => { config.verify_model_inventory_on_start = false; },
  ]) {
    const config = structuredClone(runtime.config);
    mutation(config);
    assert.throws(() => validateConfigObject(config));
  }
});

test('context schema and filename profile version must match', () => {
  const context = structuredClone(runtime.context);
  assert.throws(
    () => validateContextObject(context, 1),
    (error) => error.code === 'context_version_mismatch',
  );
  context.race.extra = true;
  assert.throws(
    () => validateContextObject(context, 0),
    (error) => error.code === 'schema_unknown_field',
  );
});

test('immutable request envelope cannot be altered', () => {
  const envelope = requestContract(makeRequest());
  assert.ok(Object.isFrozen(envelope));
  assert.throws(() => { envelope.bot_guid = 1; }, TypeError);
  assert.equal(envelope.bot_guid, 18281);
});

test('personality context byte tampering is detected by its pinned SHA-256', () => {
  const temporaryRoot = mkdtempSync(resolve(tmpdir(), 'ssc-phase1a-context-'));
  try {
    const configDirectory = resolve(temporaryRoot, 'config');
    const contextDirectory = resolve(temporaryRoot, 'context');
    mkdirSync(configDirectory);
    mkdirSync(contextDirectory);
    const configPath = resolve(configDirectory, 'bridge-config-v1.json');
    const contextPath = resolve(contextDirectory, 'personality-context-profile-v0.json');
    copyFileSync(resolve(runtime.context_path, '../..', 'config/bridge-config-v1.json'), configPath);
    copyFileSync(runtime.context_path, contextPath);
    writeFileSync(contextPath, Buffer.concat([readFileSync(contextPath), Buffer.from(' ', 'utf8')]));
    assert.throws(
      () => loadRuntimeConfiguration(configPath),
      (error) => error.code === 'context_hash_mismatch',
    );
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
});

test('exclusive instance lock prevents two bridge processes from owning the inference slot', () => {
  const temporaryRoot = mkdtempSync(resolve(tmpdir(), 'ssc-phase1a-lock-'));
  const lockPath = resolve(temporaryRoot, 'bridge.lock');
  try {
    const first = acquireInstanceLock(lockPath);
    assert.throws(() => acquireInstanceLock(lockPath), (error) => error.code === 'instance_lock_held');
    first.release();
    const second = acquireInstanceLock(lockPath);
    second.release();
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
});

test('published JSON Schema documents are strict UTF-8 JSON', () => {
  const schemaDirectory = resolve(TEST_ROOT, 'schemas');
  const schemaFiles = readdirSync(schemaDirectory).filter((name) => name.endsWith('.schema.json')).sort();
  assert.ok(schemaFiles.length >= 4);
  for (const name of schemaFiles) {
    const schema = parseJsonBytesStrict(readFileSync(resolve(schemaDirectory, name)), {
      label: name,
      maxBytes: 65536,
      maxDepth: 32,
      rejectBom: true,
    });
    assert.equal(schema.additionalProperties, false, name);
  }
});

test('NDJSON wire command is bounded at the exact request byte cap', async () => {
  const maximum = runtime.config.max_request_json_bytes;
  const exact = Buffer.concat([Buffer.alloc(maximum, 0x61), Buffer.from('\n')]);
  const lines = [];
  for await (const line of strictLines(Readable.from([exact]), maximum)) lines.push(line);
  assert.equal(lines.length, 1);
  assert.equal(lines[0].length, maximum);

  const oversized = Buffer.concat([Buffer.alloc(maximum + 1, 0x61), Buffer.from('\n')]);
  await assert.rejects(
    async () => {
      for await (const line of strictLines(Readable.from([oversized]), maximum)) void line;
    },
    (error) => error.code === 'command_too_large',
  );
});
