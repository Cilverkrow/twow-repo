import http from 'node:http';

import { BridgeError, asBridgeError } from './errors.mjs';
import { assertExactKeys, deepFreeze } from './contracts.mjs';
import { parseJsonBytesStrict } from './strict-json.mjs';
import { sanitizeAssistantText } from './prompt.mjs';

export function boundedHttpRequest({
  url,
  method,
  headers = {},
  body = null,
  connectTimeoutMs,
  responseTimeoutMs,
  maxResponseBytes,
  signal,
  requestFunction = http.request,
}) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let connected = false;
    let response;
    let connectTimer;
    let responseTimer;
    let abortListener;

    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(connectTimer);
      clearTimeout(responseTimer);
      if (signal && abortListener) signal.removeEventListener('abort', abortListener);
      if (error) reject(error);
      else resolve(result);
    };

    const request = requestFunction(
      url,
      {
        method,
        headers: {
          Accept: 'application/json',
          'Accept-Encoding': 'identity',
          Connection: 'close',
          ...headers,
        },
        agent: false,
      },
      (incoming) => {
        response = incoming;
        const rawLength = incoming.headers['content-length'];
        if (rawLength !== undefined) {
          if (!/^\d+$/.test(rawLength)) {
            const error = new BridgeError('invalid_content_length', 'response Content-Length is invalid');
            finish(error);
            incoming.destroy(error);
            request.destroy(error);
            return;
          }
          if (Number(rawLength) > maxResponseBytes) {
            const error = new BridgeError('raw_response_too_large', 'declared response exceeds max_raw_response_bytes');
            finish(error);
            incoming.destroy(error);
            request.destroy(error);
            return;
          }
        }

        const chunks = [];
        let byteCount = 0;
        incoming.on('data', (chunk) => {
          if (settled) return;
          byteCount += chunk.length;
          if (byteCount > maxResponseBytes) {
            const error = new BridgeError('raw_response_too_large', 'streamed response exceeds max_raw_response_bytes');
            finish(error);
            incoming.destroy(error);
            request.destroy(error);
            return;
          }
          chunks.push(chunk);
        });
        incoming.on('aborted', () => {
          finish(new BridgeError('response_aborted', 'HTTP response was aborted'));
        });
        incoming.on('error', (error) => {
          finish(asBridgeError(error, 'http_response_error'));
        });
        incoming.on('end', () => {
          finish(null, {
            statusCode: incoming.statusCode ?? 0,
            headers: incoming.headers,
            body: Buffer.concat(chunks, byteCount),
          });
        });
      },
    );

    request.once('socket', (socket) => {
      const startResponseDeadline = () => {
        if (connected || settled) return;
        connected = true;
        clearTimeout(connectTimer);
        responseTimer = setTimeout(() => {
          const error = new BridgeError('response_deadline', `response exceeded ${responseTimeoutMs} ms`);
          response?.destroy(error);
          request.destroy(error);
          finish(error);
        }, responseTimeoutMs);
      };

      if (socket.connecting) {
        connectTimer = setTimeout(() => {
          const error = new BridgeError('connect_deadline', `connection exceeded ${connectTimeoutMs} ms`);
          socket.destroy(error);
          request.destroy(error);
          finish(error);
        }, connectTimeoutMs);
        socket.once('connect', startResponseDeadline);
      } else {
        startResponseDeadline();
      }
    });

    request.once('error', (error) => {
      if (error instanceof BridgeError) {
        finish(error);
      } else {
        finish(new BridgeError(connected ? 'http_transport_error' : 'connect_failed', error.message, error));
      }
    });

    if (signal) {
      abortListener = () => {
        const error = new BridgeError('request_cancelled', 'HTTP request was cancelled');
        response?.destroy(error);
        request.destroy(error);
        finish(error);
      };
      if (signal.aborted) {
        abortListener();
        return;
      }
      signal.addEventListener('abort', abortListener, { once: true });
    }

    if (body !== null) request.write(body);
    request.end();
  });
}

export class OllamaTransport {
  constructor(config, clock = () => Date.now()) {
    this.config = config;
    this.clock = clock;
    this.postAttempts = 0;
  }

  async verifyPinnedModel(signal) {
    const response = await boundedHttpRequest({
      url: `${this.config.ollama_base_url}${this.config.ollama_tags_path}`,
      method: 'GET',
      connectTimeoutMs: this.config.connect_timeout_ms,
      responseTimeoutMs: this.config.response_timeout_ms,
      maxResponseBytes: this.config.max_raw_response_bytes,
      signal,
    });
    if (response.statusCode !== 200) {
      throw new BridgeError('model_inventory_http_error', `Ollama inventory returned HTTP ${response.statusCode}`);
    }
    const inventory = parseJsonBytesStrict(response.body, {
      label: 'Ollama model inventory',
      maxBytes: this.config.max_raw_response_bytes,
      maxDepth: 12,
      rejectBom: true,
    });
    assertExactKeys(inventory, ['models'], 'Ollama model inventory');
    if (!Array.isArray(inventory.models)) {
      throw new BridgeError('invalid_model_inventory', 'Ollama inventory models must be an array');
    }
    inventory.models.forEach((model, index) => validateInventoryModel(model, index));
    const exact = inventory.models.filter(
      (model) =>
        model.name === this.config.pinned_model.name && model.model === this.config.pinned_model.name,
    );
    if (exact.length !== 1) {
      throw new BridgeError('pinned_model_unavailable', 'the pinned model is absent or ambiguous');
    }
    if (exact[0].digest !== this.config.pinned_model.digest) {
      throw new BridgeError('model_digest_mismatch', 'the installed model digest differs from the pin');
    }
    return deepFreeze({
      name: this.config.pinned_model.name,
      digest: this.config.pinned_model.digest,
    });
  }

  async infer({ request, prompt, signal }) {
    const remainingMs = Date.parse(request.expires_utc) - this.clock();
    if (remainingMs <= 0) {
      throw new BridgeError('request_expired', 'request expired before the HTTP attempt');
    }
    const responseTimeoutMs = Math.max(1, Math.min(this.config.response_timeout_ms, remainingMs));
    const payload = {
      model: this.config.pinned_model.name,
      stream: false,
      messages: prompt.messages,
      options: {
        temperature: 0.2,
        num_predict: 96,
      },
    };
    const body = Buffer.from(JSON.stringify(payload), 'utf8');
    if (body.length > this.config.max_http_request_bytes) {
      throw new BridgeError('http_request_too_large', 'serialized Ollama request exceeds max_http_request_bytes');
    }

    this.postAttempts += 1;
    const response = await boundedHttpRequest({
      url: `${this.config.ollama_base_url}${this.config.ollama_chat_path}`,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': String(body.length),
      },
      body,
      connectTimeoutMs: Math.min(this.config.connect_timeout_ms, remainingMs),
      responseTimeoutMs,
      maxResponseBytes: this.config.max_raw_response_bytes,
      signal,
    });
    if (response.statusCode !== 200) {
      throw new BridgeError('inference_http_error', `Ollama inference returned HTTP ${response.statusCode}`);
    }

    const parsed = parseJsonBytesStrict(response.body, {
      label: 'Ollama inference response',
      maxBytes: this.config.max_raw_response_bytes,
      maxDepth: 12,
      rejectBom: true,
    });
    validateOllamaResponse(parsed, this.config);
    const text = sanitizeAssistantText(parsed.message.content, this.config);
    return deepFreeze({
      request_id: request.request_id,
      bot_guid: request.bot_guid,
      model: parsed.model,
      text,
      raw_response_bytes: response.body.length,
    });
  }
}

function validateInventoryModel(model, index) {
  const label = `Ollama inventory model[${index}]`;
  assertAllowedKeys(
    model,
    ['name', 'model', 'modified_at', 'size', 'digest', 'details', 'capabilities'],
    ['name', 'model', 'digest'],
    label,
  );
  for (const field of ['name', 'model']) {
    if (typeof model[field] !== 'string' || model[field].length === 0) {
      throw new BridgeError('invalid_model_inventory', `${label}.${field} must be a non-empty string`);
    }
  }
  if (typeof model.digest !== 'string' || !/^[0-9a-f]{64}$/.test(model.digest)) {
    throw new BridgeError('invalid_model_inventory', `${label}.digest must be lowercase SHA-256`);
  }
  if (Object.hasOwn(model, 'modified_at') && typeof model.modified_at !== 'string') {
    throw new BridgeError('invalid_model_inventory', `${label}.modified_at must be a string`);
  }
  if (Object.hasOwn(model, 'size') && (!Number.isSafeInteger(model.size) || model.size < 0)) {
    throw new BridgeError('invalid_model_inventory', `${label}.size must be a non-negative safe integer`);
  }
  if (Object.hasOwn(model, 'capabilities')) {
    if (!Array.isArray(model.capabilities) || model.capabilities.some((capability) => typeof capability !== 'string')) {
      throw new BridgeError('invalid_model_inventory', `${label}.capabilities must be an array of strings`);
    }
  }
  if (Object.hasOwn(model, 'details')) validateInventoryDetails(model.details, `${label}.details`);
}

function validateInventoryDetails(details, label) {
  assertAllowedKeys(
    details,
    [
      'parent_model',
      'format',
      'family',
      'families',
      'parameter_size',
      'quantization_level',
      'context_length',
      'embedding_length',
    ],
    [],
    label,
  );
  for (const field of ['parent_model', 'format', 'family', 'parameter_size', 'quantization_level']) {
    if (Object.hasOwn(details, field) && typeof details[field] !== 'string') {
      throw new BridgeError('invalid_model_inventory', `${label}.${field} must be a string`);
    }
  }
  if (Object.hasOwn(details, 'families')) {
    if (!Array.isArray(details.families) || details.families.some((family) => typeof family !== 'string')) {
      throw new BridgeError('invalid_model_inventory', `${label}.families must be an array of strings`);
    }
  }
  for (const field of ['context_length', 'embedding_length']) {
    if (Object.hasOwn(details, field) && (!Number.isSafeInteger(details[field]) || details[field] < 0)) {
      throw new BridgeError('invalid_model_inventory', `${label}.${field} must be a non-negative safe integer`);
    }
  }
}

function assertAllowedKeys(value, allowedKeys, requiredKeys, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new BridgeError('invalid_model_inventory', `${label} must be an object`);
  }
  const actual = Object.keys(value);
  const unknown = actual.filter((key) => !allowedKeys.includes(key));
  const missing = requiredKeys.filter((key) => !Object.hasOwn(value, key));
  if (unknown.length > 0 || missing.length > 0) {
    throw new BridgeError(
      'invalid_model_inventory',
      `${label} fields invalid; missing=[${missing.join(', ')}] unknown=[${unknown.join(', ')}]`,
    );
  }
}

function validateOllamaResponse(value, config) {
  const allowedRoot = [
    'model',
    'created_at',
    'message',
    'done',
    'done_reason',
    'total_duration',
    'load_duration',
    'prompt_eval_count',
    'prompt_eval_duration',
    'eval_count',
    'eval_duration',
  ];
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new BridgeError('invalid_inference_schema', 'inference response must be an object');
  }
  const unknown = Object.keys(value).filter((key) => !allowedRoot.includes(key));
  if (unknown.length > 0) {
    throw new BridgeError('invalid_inference_schema', `unknown inference fields: ${unknown.join(', ')}`);
  }
  for (const required of ['model', 'message', 'done']) {
    if (!Object.hasOwn(value, required)) {
      throw new BridgeError('invalid_inference_schema', `missing inference field: ${required}`);
    }
  }
  if (value.model !== config.pinned_model.name) {
    throw new BridgeError('response_model_mismatch', 'response model differs from the pin');
  }
  if (value.done !== true) {
    throw new BridgeError('incomplete_inference_response', 'Ollama response is not complete');
  }
  for (const field of ['created_at', 'done_reason']) {
    if (Object.hasOwn(value, field) && typeof value[field] !== 'string') {
      throw new BridgeError('invalid_inference_schema', `${field} must be a string when present`);
    }
  }
  for (const field of [
    'total_duration',
    'load_duration',
    'prompt_eval_count',
    'prompt_eval_duration',
    'eval_count',
    'eval_duration',
  ]) {
    if (Object.hasOwn(value, field) && (!Number.isSafeInteger(value[field]) || value[field] < 0)) {
      throw new BridgeError('invalid_inference_schema', `${field} must be a non-negative safe integer when present`);
    }
  }
  assertExactKeys(value.message, ['role', 'content'], 'assistant message');
  if (value.message.role !== 'assistant') {
    throw new BridgeError('invalid_assistant_role', 'response role must be assistant');
  }
  if (typeof value.message.content !== 'string') {
    throw new BridgeError('invalid_assistant_text', 'assistant content must be a string');
  }
}
