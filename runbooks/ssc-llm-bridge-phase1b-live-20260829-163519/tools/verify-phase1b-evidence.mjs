import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import {
  existsSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { relative, resolve } from 'node:path';

const ROOT = resolve(import.meta.dirname, '..');
const EVIDENCE = resolve(ROOT, 'evidence');
const BRIDGE = resolve(ROOT, 'bridge');
const OUTPUT = resolve(EVIDENCE, 'offline-verification.json');
const PINNED_MODEL = 'qwen2.5:7b';
const PINNED_DIGEST = '845dbda0ea48ed749caafd9e6037047aa19acfcfd82e704d7ca97d631a0b697e';
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const CANONICAL_UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

if (existsSync(OUTPUT)) throw new Error(`Refusing to overwrite: ${OUTPUT}`);

const bridgeFiles = listFiles(BRIDGE);
const packagedEntries = readLinesAt(resolve(BRIDGE, 'package-entry-list.txt')).sort();
assert.equal(bridgeFiles.length, 50);
assert.deepEqual(bridgeFiles, packagedEntries);
const manifestPath = resolve(BRIDGE, 'sha256-manifest.txt');
assert.equal(sha256(readFileSync(manifestPath)), '7494F26C2CBA47084691D57ED7DEA372B5E895C90F58FF86304101B48305FA8E');
let manifestEntries = 0;
for (const line of readLinesAt(manifestPath)) {
  const match = /^([0-9A-F]{64}) \*(.+)$/.exec(line);
  assert.ok(match, `invalid bridge manifest line: ${line}`);
  manifestEntries += 1;
  assert.equal(sha256(readFileSync(resolve(BRIDGE, match[2]))), match[1], match[2]);
}
assert.equal(manifestEntries, 49);

const { sanitizeAssistantText } = await import('../bridge/src/prompt.mjs');
const { loadRuntimeConfiguration } = await import('../bridge/src/configuration.mjs');
const runtime = loadRuntimeConfiguration();
const request = readJson('request-envelope.json');
const submitResponse = readJson('submit-response.json');
const terminalStatus = readJson('terminal-status.json');
const completion = readJson('completion-envelope.json');
const firstConsume = readJson('consume-first-response.json');
const secondConsume = readJson('consume-second-response.json');
const metricsResponse = readJson('metrics-before-shutdown.json');
const shutdownResponse = readJson('shutdown-response.json');
const latency = readJson('latency.json');
const liveResult = readJson('live-run-result.json');
const transcript = readJson('bridge-transcript.json');
const beforeBoundary = readJson('boundary-observation-before.json');
const afterBoundary = readJson('boundary-observation-after.json');
const lockPresent = readJson('instance-lock-present.json');
const lockRemoved = readJson('instance-lock-removed.json');
const sourceVerification = readJson('source-package-verification.json');
const extractedVerification = readJson('extracted-payload-verification.json');
const phase1aComparison = readJson('phase1a-integrity-comparison.json');
const phase1aBefore = readJson('phase1a-integrity-before.json');
const phase1aAfter = readJson('phase1a-integrity-after.json');

assert.equal(liveResult.result, 'PHASE1B_LIVE_INFERENCE=PASS');
assert.equal(transcript.result, 'PASS');
assert.match(request.request_id, UUID_V4);
assert.equal(request.bot_guid, 18281);
assert.equal(request.message, 'Was hast du heute vor?');
assert.match(request.created_utc, CANONICAL_UTC);
assert.match(request.expires_utc, CANONICAL_UTC);
assert.equal(Date.parse(request.expires_utc) - Date.parse(request.created_utc), 45000);
assert.equal(new Date(request.created_utc).toISOString(), request.created_utc);
assert.equal(new Date(request.expires_utc).toISOString(), request.expires_utc);
assert.equal(submitResponse.accepted, true);
assert.equal(submitResponse.code, 'queued');
assert.equal(submitResponse.status.request_id, request.request_id);
assert.equal(submitResponse.status.bot_guid, request.bot_guid);
assert.equal(submitResponse.status.state, 'queued');
assert.equal(submitResponse.status.attempt_count, 0);
assert.equal(terminalStatus.request_id, request.request_id);
assert.equal(terminalStatus.bot_guid, request.bot_guid);
assert.equal(terminalStatus.state, 'ready');
assert.equal(terminalStatus.attempt_count, 1);

assert.equal(completion.request_id, request.request_id);
assert.equal(completion.bot_guid, request.bot_guid);
assert.equal(completion.model, PINNED_MODEL);
assert.equal(completion.outcome, 'ready');
assert.equal(completion.attempt_count, 1);
assert.equal(completion.error_code, null);
assert.ok(Number.isSafeInteger(completion.raw_response_bytes));
assert.ok(completion.raw_response_bytes >= 1 && completion.raw_response_bytes <= runtime.config.max_raw_response_bytes);
assert.equal(sanitizeAssistantText(completion.text, runtime.config), completion.text);
assert.ok(Array.from(completion.text).length <= runtime.config.max_output_characters);
const terminatorRuns = completion.text.match(/[.!?…]+/gu)?.length ?? 0;
assert.ok(terminatorRuns <= runtime.config.max_output_sentences);
assert.deepEqual(firstConsume.completion, completion);
assert.equal(firstConsume.code, 'consumed');
assert.equal(firstConsume.status.state, 'consumed');

assert.equal(secondConsume.code, 'already_consumed');
assert.equal(secondConsume.status.state, 'consumed');
assert.equal(secondConsume.completion, null);
assert.equal(containsTextMember(secondConsume), false);

assert.equal(metricsResponse.code, 'metrics');
assert.equal(metricsResponse.metrics.inference_attempts, 1);
assert.equal(metricsResponse.metrics.max_active_observed, 1);
assert.equal(metricsResponse.metrics.active, 0);
assert.equal(metricsResponse.metrics.waiting, 0);
assert.equal(metricsResponse.metrics.ledger_entries, 1);
assert.equal(metricsResponse.metrics.stale_results_discarded, 0);
assert.equal(shutdownResponse.code, 'shutdown');
assert.equal(shutdownResponse.metrics.lifecycle, 'stopped');
assert.equal(shutdownResponse.metrics.accepting, false);
assert.equal(shutdownResponse.metrics.active, 0);
assert.equal(shutdownResponse.metrics.inference_attempts, 1);
assert.equal(shutdownResponse.metrics.max_active_observed, 1);
assert.equal(shutdownResponse.metrics.worker_settled, true);

assert.equal(liveResult.cli_start_count, 1);
assert.equal(liveResult.request_id_count, 1);
assert.equal(liveResult.submit_command_count, 1);
assert.equal(liveResult.consume_command_count, 2);
assert.equal(liveResult.metrics_command_count, 1);
assert.equal(liveResult.shutdown_command_count, 1);
assert.equal(liveResult.verified_inference_attempts, 1);
assert.equal(liveResult.live_inference_count, 1);
assert.equal(liveResult.automatic_retry_performed, false);
assert.equal(liveResult.resubmission_performed, false);
assert.equal(liveResult.worker_joined, true);
assert.equal(liveResult.instance_lock_removed_after_exit, true);
assert.equal(liveResult.process_exit_code, 0);
assert.equal(liveResult.process_exit_signal, null);

const stdinEvents = transcript.events.filter((event) => event.direction === 'bridge_stdin');
const stdoutEvents = transcript.events.filter((event) => event.direction === 'bridge_stdout');
const stderrEvents = transcript.events.filter((event) => event.direction === 'bridge_stderr');
const commands = stdinEvents.map((event) => JSON.parse(event.line));
const responses = stdoutEvents.map((event) => JSON.parse(event.line));
assert.equal(commands.length, 79);
assert.equal(stdoutEvents.length, 80);
assert.equal(stderrEvents.length, 0);
assert.equal(commands.filter((command) => command.command === 'submit').length, 1);
assert.equal(commands.filter((command) => command.command === 'status').length, liveResult.status_poll_count);
assert.equal(commands.filter((command) => command.command === 'consume').length, 2);
assert.equal(commands.filter((command) => command.command === 'metrics').length, 1);
assert.equal(commands.filter((command) => command.command === 'shutdown').length, 1);
assert.equal(commands[0].command, 'submit');
assert.deepEqual(commands[0].request, request);
assert.ok(commands.slice(1, 1 + liveResult.status_poll_count).every((command) => command.command === 'status'));
assert.deepEqual(
  commands.slice(1 + liveResult.status_poll_count).map((command) => command.command),
  ['consume', 'consume', 'metrics', 'shutdown'],
);
assert.equal(commands.at(-1).drain, true);
assert.equal(new Set(commands.filter((command) => command.request_id).map((command) => command.request_id)).size, 1);
assert.equal(JSON.parse(stdoutEvents[0].line).code, 'ready');
assert.equal(JSON.parse(stdoutEvents.at(-1).line).code, 'shutdown');
assert.equal(transcript.events.filter((event) => event.direction === 'controller' && event.stage === 'spawn').length, 1);
assert.deepEqual(responses[1], submitResponse);
const statusResponses = responses.slice(2, 2 + liveResult.status_poll_count);
assert.ok(statusResponses.every((response) => response.code === 'ok'));
assert.deepEqual(statusResponses.at(-1).status, terminalStatus);
const postStatusResponses = responses.slice(2 + liveResult.status_poll_count);
assert.deepEqual(postStatusResponses, [firstConsume, secondConsume, metricsResponse, shutdownResponse]);
assert.deepEqual(readLines('bridge-stdin.ndjson'), stdinEvents.map((event) => event.line));
assert.deepEqual(readLines('bridge-stdout.ndjson'), stdoutEvents.map((event) => event.line));
assert.equal(readFileSync(resolve(EVIDENCE, 'bridge-stderr.txt')).length, 0);

assert.equal(latency.measurement, 'submit write to first observed terminal ready status');
assert.ok(typeof latency.latency_ms === 'number' && latency.latency_ms > 0 && latency.latency_ms < 45000);
assert.equal(latency.request_lifetime_ms, 45000);
assert.equal(latency.status_poll_count, liveResult.status_poll_count);
assert.equal(latency.no_second_inference, true);

assert.equal(lockPresent.lock_present, true);
assert.equal(lockPresent.pid_matches, true);
assert.equal(lockRemoved.lock_present, false);
assert.equal(lockRemoved.result, 'INSTANCE_LOCK_REMOVED=PASS');
assert.equal(lockPresent.bridge_pid, lockRemoved.bridge_pid);
assert.equal(existsSync(resolve(BRIDGE, 'evidence/.phase1a-instance.lock')), false);

assert.equal(beforeBoundary.ollama_binding_verified, true);
assert.equal(afterBoundary.ollama_binding_verified, true);
for (const boundary of [beforeBoundary, afterBoundary]) {
  assert.ok(boundary.ollama_listeners.length >= 1);
  assert.ok(boundary.ollama_listeners.every(
    (listener) => listener.name === 'ollama' && listener.local_address === '127.0.0.1' && listener.local_port === 11434,
  ));
  assert.equal(boundary.actions.process_control_actions, 0);
  assert.equal(boundary.actions.game_process_start_stop_actions, 0);
  assert.equal(boundary.actions.database_connections_or_queries, 0);
  assert.equal(boundary.actions.game_source_reads_or_writes, 0);
  assert.equal(boundary.actions.game_chat_actions, 0);
  assert.equal(boundary.actions.model_pull_update_copy_delete_actions, 0);
  assert.equal(boundary.actions.model_explicit_load_unload_actions, 0);
  assert.equal(boundary.actions.manual_tags_requests, 0);
  assert.equal(boundary.actions.ps_observation_requests, 1);
}
assert.equal(beforeBoundary.ollama_running_model_observation.pinned_model_state, 'cold');
assert.equal(afterBoundary.ollama_running_model_observation.pinned_model_state, 'warm');
assert.equal(afterBoundary.ollama_running_model_observation.pinned_model.observed_name, PINNED_MODEL);
assert.equal(afterBoundary.ollama_running_model_observation.pinned_model.observed_digest, PINNED_DIGEST);
assert.deepEqual(beforeBoundary.game_database_processes, afterBoundary.game_database_processes);
assert.deepEqual(beforeBoundary.game_database_listeners, afterBoundary.game_database_listeners);
const psBeforeBytes = readFileSync(resolve(EVIDENCE, 'ollama-ps-before.json'));
const psAfterBytes = readFileSync(resolve(EVIDENCE, 'ollama-ps-after.json'));
const psBefore = JSON.parse(psBeforeBytes.toString('utf8'));
const psAfter = JSON.parse(psAfterBytes.toString('utf8'));
assert.equal(sha256(psBeforeBytes), beforeBoundary.ollama_running_model_observation.raw_response_sha256);
assert.equal(sha256(psAfterBytes), afterBoundary.ollama_running_model_observation.raw_response_sha256);
assert.equal(psBeforeBytes.length, beforeBoundary.ollama_running_model_observation.raw_response_bytes);
assert.equal(psAfterBytes.length, afterBoundary.ollama_running_model_observation.raw_response_bytes);
assert.deepEqual(psBefore.models, []);
assert.equal(psAfter.models.filter(
  (model) => model.name === PINNED_MODEL && model.model === PINNED_MODEL && model.digest === PINNED_DIGEST,
).length, 1);

assert.equal(sourceVerification.result, 'PHASE1B_SOURCE_PACKAGE_VERIFICATION=PASS');
assert.equal(sourceVerification.zip_sha256, 'BADE583E726F5177D2BA9AF753962D6DC74BC3297B6C610A3CB91FF5251DDF11');
assert.equal(sourceVerification.manifest_hash_failures, 0);
assert.equal(extractedVerification.result, 'PHASE1B_EXTRACTED_PAYLOAD_VERIFICATION=PASS');
assert.equal(phase1aComparison.result, 'PHASE1A_HARDENING_INTEGRITY=UNCHANGED');
assert.equal(phase1aComparison.difference_count, 0);
assert.equal(phase1aBefore.file_count, phase1aAfter.file_count);
assert.equal(phase1aBefore.total_bytes, phase1aAfter.total_bytes);
assert.equal(phase1aBefore.content_fingerprint_sha256, phase1aAfter.content_fingerprint_sha256);
assert.deepEqual(phase1aBefore.files, phase1aAfter.files);

const result = {
  schema_version: 1,
  result: 'PHASE1B_OFFLINE_VERIFICATION=PASS',
  verified_utc: new Date().toISOString(),
  request_id: request.request_id,
  bot_guid: request.bot_guid,
  model: completion.model,
  model_digest: PINNED_DIGEST,
  outcome: completion.outcome,
  raw_response_bytes: completion.raw_response_bytes,
  sanitized_text: completion.text,
  sanitized_text_code_points: Array.from(completion.text).length,
  sentence_terminator_runs: terminatorRuns,
  latency_ms: latency.latency_ms,
  cold_warm_transition: `${beforeBoundary.ollama_running_model_observation.pinned_model_state}->${afterBoundary.ollama_running_model_observation.pinned_model_state}`,
  cli_start_count: 1,
  submit_command_count: 1,
  status_command_count: liveResult.status_poll_count,
  consume_command_count: 2,
  metrics_command_count: 1,
  shutdown_command_count: 1,
  stdin_command_count: commands.length,
  stdout_response_count: stdoutEvents.length,
  stderr_line_count: stderrEvents.length,
  inference_attempts: metricsResponse.metrics.inference_attempts,
  max_active_observed: metricsResponse.metrics.max_active_observed,
  active_after_completion: metricsResponse.metrics.active,
  worker_joined: shutdownResponse.metrics.worker_settled,
  instance_lock_removed: true,
  phase1a_hardening_unchanged: true,
  extracted_bridge_files: bridgeFiles.length,
  extracted_manifest_entries: manifestEntries,
  extracted_manifest_hash_failures: 0,
  game_database_observation_unchanged: true,
  ollama_loopback_binding_before_after: true,
  live_inference_count: 1,
  automatic_retry_performed: false,
  second_inference_performed: false,
};
writeFileSync(OUTPUT, `${JSON.stringify(result, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
process.stdout.write(`${result.result}\n`);
process.stdout.write(`commands=${commands.length} submit=1 status=${liveResult.status_poll_count} consume=2 metrics=1 shutdown=1\n`);
process.stdout.write(`bridge_files=${bridgeFiles.length} manifest_entries=${manifestEntries} hash_failures=0\n`);

function readJson(name) {
  return JSON.parse(readFileSync(resolve(EVIDENCE, name), 'utf8'));
}

function readLines(name) {
  return readLinesAt(resolve(EVIDENCE, name));
}

function readLinesAt(path) {
  const text = readFileSync(path, 'utf8');
  return text.split(/\r?\n/u).filter((line) => line.length > 0);
}

function listFiles(root) {
  const results = [];
  walk(root, results);
  return results.map((path) => relative(root, path).replaceAll('\\', '/')).sort();
}

function walk(directory, results) {
  for (const entry of readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) walk(path, results);
    else if (entry.isFile()) results.push(path);
  }
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex').toUpperCase();
}

function containsTextMember(value) {
  if (value === null || typeof value !== 'object') return false;
  if (Object.hasOwn(value, 'text')) return true;
  if (Array.isArray(value)) return value.some(containsTextMember);
  return Object.values(value).some(containsTextMember);
}
