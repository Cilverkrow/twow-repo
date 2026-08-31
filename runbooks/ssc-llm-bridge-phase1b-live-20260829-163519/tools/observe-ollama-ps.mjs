import { createHash } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { parseJsonBytesStrict } from '../bridge/src/strict-json.mjs';
import { boundedHttpRequest } from '../bridge/src/transport.mjs';

const PINNED_NAME = 'qwen2.5:7b';
const PINNED_DIGEST = '845dbda0ea48ed749caafd9e6037047aa19acfcfd82e704d7ca97d631a0b697e';
const MAX_BYTES = 65536;
const label = process.argv[2];
const artifactRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

if (label !== 'before' && label !== 'after') {
  throw new Error('Usage: node tools/observe-ollama-ps.mjs before|after');
}

const rawPath = resolve(artifactRoot, `evidence/ollama-ps-${label}.json`);
const startedUtc = new Date().toISOString();
const startedMonotonic = performance.now();
const response = await boundedHttpRequest({
  url: 'http://127.0.0.1:11434/api/ps',
  method: 'GET',
  connectTimeoutMs: 3000,
  responseTimeoutMs: 5000,
  maxResponseBytes: MAX_BYTES,
});
const completedMonotonic = performance.now();
const completedUtc = new Date().toISOString();

if (response.statusCode !== 200) {
  throw new Error(`GET /api/ps returned HTTP ${response.statusCode}`);
}
const parsed = parseJsonBytesStrict(response.body, {
  label: 'Ollama running-model observation',
  maxBytes: MAX_BYTES,
  maxDepth: 12,
  rejectBom: true,
});
if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed) || !Array.isArray(parsed.models)) {
  throw new Error('GET /api/ps response must be an object containing a models array');
}

const identityMatches = parsed.models.filter(
  (model) => model !== null && typeof model === 'object' &&
    (model.name === PINNED_NAME || model.model === PINNED_NAME),
);
const exactMatches = identityMatches.filter(
  (model) => model.name === PINNED_NAME && model.model === PINNED_NAME && model.digest === PINNED_DIGEST,
);
if (identityMatches.length !== exactMatches.length || exactMatches.length > 1) {
  throw new Error('GET /api/ps has a mismatched or ambiguous entry for the pinned model');
}

writeFileSync(rawPath, response.body, { flag: 'wx' });
const exact = exactMatches[0] ?? null;
const summary = {
  schema_version: 1,
  label,
  endpoint: 'http://127.0.0.1:11434/api/ps',
  method: 'GET',
  started_utc: startedUtc,
  completed_utc: completedUtc,
  elapsed_ms: Math.round((completedMonotonic - startedMonotonic) * 1000) / 1000,
  http_status: response.statusCode,
  raw_response_bytes: response.body.length,
  raw_response_sha256: createHash('sha256').update(response.body).digest('hex').toUpperCase(),
  running_model_count: parsed.models.length,
  pinned_model_state: exact === null ? 'cold' : 'warm',
  pinned_model_match_count: exactMatches.length,
  pinned_model: {
    name: PINNED_NAME,
    digest: PINNED_DIGEST,
    observed_name: exact?.name ?? null,
    observed_model: exact?.model ?? null,
    observed_digest: exact?.digest ?? null,
    observed_expires_at: typeof exact?.expires_at === 'string' ? exact.expires_at : null,
    observed_size_vram: Number.isSafeInteger(exact?.size_vram) ? exact.size_vram : null,
  },
};
process.stdout.write(`${JSON.stringify(summary)}\n`);
