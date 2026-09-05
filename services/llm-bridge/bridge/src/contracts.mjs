import { BridgeError } from './errors.mjs';

export const REQUEST_SCHEMA_VERSION = 1;
export const COMPLETION_SCHEMA_VERSION = 1;
export const STATUS_SCHEMA_VERSION = 1;
export const LIFECYCLE_STATES = Object.freeze([
  'queued',
  'running',
  'ready',
  'failed',
  'expired',
  'consumed',
]);
export const TERMINAL_OUTCOMES = Object.freeze(['ready', 'failed', 'expired']);

const UUID_V4_CANONICAL = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const ISO_UTC_MILLISECONDS = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

export function deepFreeze(value) {
  if (value !== null && typeof value === 'object' && !Object.isFrozen(value)) {
    for (const child of Object.values(value)) {
      deepFreeze(child);
    }
    Object.freeze(value);
  }
  return value;
}

export function assertPlainObject(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new BridgeError('schema_type_mismatch', `${label} must be a JSON object`);
  }
}

export function assertExactKeys(value, requiredKeys, label) {
  assertPlainObject(value, label);
  const actual = Object.keys(value).sort();
  const required = [...requiredKeys].sort();
  const missing = required.filter((key) => !actual.includes(key));
  const unknown = actual.filter((key) => !required.includes(key));
  if (missing.length > 0) {
    throw new BridgeError('schema_missing_field', `${label} is missing: ${missing.join(', ')}`);
  }
  if (unknown.length > 0) {
    throw new BridgeError('schema_unknown_field', `${label} has unknown fields: ${unknown.join(', ')}`);
  }
}

export function assertCanonicalUuidV4(value, label = 'request_id') {
  if (typeof value !== 'string' || !UUID_V4_CANONICAL.test(value)) {
    throw new BridgeError('invalid_uuid', `${label} must be a canonical lowercase RFC 4122 UUIDv4`);
  }
}

export function assertBotGuid(value, label = 'bot_guid') {
  if (!Number.isSafeInteger(value) || value < 1 || value > 4_294_967_295) {
    throw new BridgeError('invalid_bot_guid', `${label} must be an integer in 1..4294967295`);
  }
}

export function parseCanonicalUtc(value, label) {
  if (typeof value !== 'string' || !ISO_UTC_MILLISECONDS.test(value)) {
    throw new BridgeError('invalid_timestamp', `${label} must use canonical UTC millisecond format`);
  }
  const date = new Date(value);
  if (!Number.isFinite(date.getTime()) || date.toISOString() !== value) {
    throw new BridgeError('invalid_timestamp', `${label} is not a real canonical UTC timestamp`);
  }
  return date.getTime();
}

export function createRequestEnvelope(value, { config, nowMs }) {
  assertExactKeys(
    value,
    ['schema_version', 'request_id', 'bot_guid', 'created_utc', 'expires_utc', 'message'],
    'request envelope',
  );
  if (value.schema_version !== REQUEST_SCHEMA_VERSION) {
    throw new BridgeError('unsupported_schema_version', 'request schema_version must be 1');
  }
  assertCanonicalUuidV4(value.request_id);
  assertBotGuid(value.bot_guid);

  const createdMs = parseCanonicalUtc(value.created_utc, 'created_utc');
  const expiresMs = parseCanonicalUtc(value.expires_utc, 'expires_utc');
  if (expiresMs <= createdMs) {
    throw new BridgeError('invalid_expiry', 'expires_utc must be after created_utc');
  }
  if (expiresMs - createdMs > config.request_ttl_max_ms) {
    throw new BridgeError('ttl_too_large', 'request lifetime exceeds request_ttl_max_ms');
  }
  if (createdMs > nowMs + config.max_clock_skew_ms) {
    throw new BridgeError('created_in_future', 'created_utc exceeds the permitted clock skew');
  }

  if (typeof value.message !== 'string' || value.message.trim().length === 0) {
    throw new BridgeError('invalid_message', 'message must be a non-empty string');
  }
  if (/[\u0000-\u001f\u007f]/u.test(value.message)) {
    throw new BridgeError('forbidden_message_control', 'message contains a forbidden control character');
  }
  if (Buffer.byteLength(value.message, 'utf8') > config.max_user_message_bytes) {
    throw new BridgeError('message_too_large', 'message exceeds max_user_message_bytes');
  }

  return deepFreeze({
    schema_version: REQUEST_SCHEMA_VERSION,
    request_id: value.request_id,
    bot_guid: value.bot_guid,
    created_utc: value.created_utc,
    expires_utc: value.expires_utc,
    message: value.message,
  });
}

export function createStatusEnvelope({ request, state, queuedUtc, updatedUtc, attemptCount, errorCode = null }) {
  if (!LIFECYCLE_STATES.includes(state)) {
    throw new BridgeError('invalid_state', `Unsupported lifecycle state: ${state}`);
  }
  if (!Number.isInteger(attemptCount) || attemptCount < 0 || attemptCount > 1) {
    throw new BridgeError('invalid_attempt_count', 'attempt_count must be 0 or 1');
  }
  parseCanonicalUtc(queuedUtc, 'queued_utc');
  parseCanonicalUtc(updatedUtc, 'updated_utc');
  if (!(errorCode === null || typeof errorCode === 'string')) {
    throw new BridgeError('invalid_error_code', 'error_code must be a string or null');
  }
  return deepFreeze({
    schema_version: STATUS_SCHEMA_VERSION,
    request_id: request.request_id,
    bot_guid: request.bot_guid,
    state,
    queued_utc: queuedUtc,
    updated_utc: updatedUtc,
    attempt_count: attemptCount,
    error_code: errorCode,
  });
}

export function createCompletionEnvelope({
  request,
  outcome,
  model,
  attemptCount,
  startedUtc,
  completedUtc,
  text,
  errorCode,
  rawResponseBytes,
}) {
  if (!TERMINAL_OUTCOMES.includes(outcome)) {
    throw new BridgeError('invalid_outcome', `Unsupported completion outcome: ${outcome}`);
  }
  if (!Number.isInteger(attemptCount) || attemptCount < 0 || attemptCount > 1) {
    throw new BridgeError('invalid_attempt_count', 'attempt_count must be 0 or 1');
  }
  if (!(model === null || typeof model === 'string')) {
    throw new BridgeError('invalid_completion_model', 'model must be a string or null');
  }
  if (startedUtc !== null) parseCanonicalUtc(startedUtc, 'started_utc');
  parseCanonicalUtc(completedUtc, 'completed_utc');
  if (!(rawResponseBytes === null || (Number.isSafeInteger(rawResponseBytes) && rawResponseBytes >= 0))) {
    throw new BridgeError('invalid_raw_response_bytes', 'raw_response_bytes must be a non-negative integer or null');
  }

  if (outcome === 'ready') {
    if (typeof text !== 'string' || text.length === 0 || errorCode !== null || attemptCount !== 1) {
      throw new BridgeError('invalid_ready_completion', 'ready requires text, one attempt and no error_code');
    }
  } else if (text !== null || typeof errorCode !== 'string' || errorCode.length === 0) {
    throw new BridgeError('invalid_nonready_completion', 'failed/expired require null text and a non-empty error_code');
  }

  return deepFreeze({
    schema_version: COMPLETION_SCHEMA_VERSION,
    request_id: request.request_id,
    bot_guid: request.bot_guid,
    outcome,
    model,
    attempt_count: attemptCount,
    started_utc: startedUtc,
    completed_utc: completedUtc,
    text,
    error_code: errorCode,
    raw_response_bytes: rawResponseBytes,
  });
}

export function requestKey(requestId, botGuid) {
  return `${requestId}:${botGuid}`;
}

export function frozenResult(value) {
  return deepFreeze(value);
}
