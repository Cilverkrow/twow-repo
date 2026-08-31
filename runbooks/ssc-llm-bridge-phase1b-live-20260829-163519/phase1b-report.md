# SSC LLM Bridge — Phase 1B live proof report

`PHASE1B_RESULT=PASS`

Phase 1B executed exactly one isolated live Ollama inference through the independently reviewed server-free Phase-1A hardening bridge. No retry, resubmission, second inference, game/database integration, or model-management action occurred.

## Verified source and preflight

The original Phase-1A hardening directory and ZIP were treated as immutable. The source ZIP was copied into this separate Phase-1B directory and authenticated before extraction or live execution:

- ZIP size: 71,689 bytes;
- ZIP SHA-256: `BADE583E726F5177D2BA9AF753962D6DC74BC3297B6C610A3CB91FF5251DDF11`;
- ZIP entries: 50 unique, safe relative paths;
- embedded manifest: 49 entries, self-excluded, 0 hash failures;
- embedded manifest SHA-256: `7494F26C2CBA47084691D57ED7DEA372B5E895C90F58FF86304101B48305FA8E`;
- extracted payload before execution: 50 files, exact entry-list match, 49/49 manifest hashes valid;
- pre-start instance lock: absent.

The original Phase-1A directory remained byte-for-byte and metadata unchanged after Phase 1B: 52 files, 297,947 bytes, fingerprint `D458FA595A776DF36A586BB240D3B3F0271853DF8CAAD431620ABCBEA59710FA`, and 0 path/size/hash/last-write differences. The original Phase-1A ZIP was not edited or repackaged.

Before the bridge started, a read-only listener observation confirmed Ollama PID 5528 had exactly the TCP listener `127.0.0.1:11434`. One bounded `GET /api/ps` observed the pinned model as cold (`models=[]`). No manual `GET /api/tags` was made; the bridge performed its required startup inventory verification once and emitted `ready` for bot 18281 and model `qwen2.5:7b`, proving the verified code accepted the exact pinned name/digest inventory.

## Exact live request

The controller generated the request only after startup returned `ready`:

```json
{
  "schema_version": 1,
  "request_id": "2b7dce77-a3e7-4a1c-b268-0c85e088fa51",
  "bot_guid": 18281,
  "created_utc": "2026-08-29T14:50:19.295Z",
  "expires_utc": "2026-08-29T14:51:04.295Z",
  "message": "Was hast du heute vor?"
}
```

The UUID is canonical lowercase RFC 4122 UUIDv4. The timestamps are canonical UTC with exactly 45,000 ms between creation and expiry. There was one `submit` command. It returned `accepted=true`, `code=queued`, the exact identity, and `attempt_count=0`.

## Inference and completion

After submission, the controller issued only status commands until `ready`: 74 serialized polls, with one response awaited before the next. Polling invoked no transport path. The submit-to-first-observed-ready latency was **8,104.44 ms**, measured with Node's monotonic `performance.now()` and accompanied by UTC endpoints.

The first and only completion was:

```json
{
  "request_id": "2b7dce77-a3e7-4a1c-b268-0c85e088fa51",
  "bot_guid": 18281,
  "outcome": "ready",
  "model": "qwen2.5:7b",
  "attempt_count": 1,
  "raw_response_bytes": 384,
  "text": "Heute werde ich die Gassen der Stadt beobachten und eventuelle Gelegenheiten ausnutzen."
}
```

The completion has the exact request identity, pinned model, ready outcome, one attempt, null error, and 384 bounded raw-response bytes. The delivered text is already in canonical sanitized form, contains 87 Unicode code points and one terminator run, and passes the verified Phase-1A output limits.

The first consume returned `consumed` and the immutable completion. The second consume returned `already_consumed`, `completion=null`, a consumed status, and no dialogue-text member.

## Metrics and controlled shutdown

Metrics after completion and both consumes were:

- `inference_attempts=1`;
- `max_active_observed=1`;
- `active=0`;
- `waiting=0`;
- `ledger_entries=1`;
- `stale_results_discarded=0`.

Exactly one `shutdown` command used `drain=true`. Its metrics reported `lifecycle=stopped`, `accepting=false`, `active=0`, `inference_attempts=1`, and `worker_settled=true`. The controller waited for process close with exit code 0 and no signal. The lock was observed present after `ready` with PID 26928 matching the bridge, then absent after process close. Bridge stderr was empty and no unexpected stdout remained.

The complete command accounting is 79 stdin commands and 80 stdout records including the unsolicited startup `ready`: one submit, 74 status polls, two consumes, one metrics command, and one drain shutdown. The correlated transcript contains 161 timestamped events, one controller spawn, one clean close, no resubmit, and no retry.

## Cold/warm and external boundaries

The single post-shutdown `GET /api/ps` observed exactly one loaded entry for `qwen2.5:7b` with digest `845dbda0ea48ed749caafd9e6037047aa19acfcfd82e704d7ca97d631a0b697e`; state was therefore cold before and warm after. No second inference was performed. No model was pulled, updated, copied, deleted, explicitly loaded, or unloaded. The warm transition resulted solely from the approved inference.

Read-only before/after presence/listener observations were identical:

- `mangosd`: absent;
- `realmd`: PID 7316, listener `0.0.0.0:3724`;
- MariaDB (`mysqld`): PID 30480, listener `127.0.0.1:3307`;
- Ollama: PID 5528, only listener `127.0.0.1:11434`.

No process-control action targeted `mangosd`, `realmd`, MariaDB, Ollama, or a model process. No database connection/query, game-source read/write/compile, game-chat action, or existing game LLM-path action occurred. Only the required external bridge child was started and joined through its own `drain=true` command.

## Post-run verification and evidence

`PHASE1B_OFFLINE_VERIFICATION=PASS` independently cross-checked the request, ordered transcript, submit/status/consume responses, sanitized completion, exact command counts, metrics, shutdown, lock lifecycle, raw `/api/ps` hashes, cold/warm classification, listener snapshots, full Phase-1A before/after snapshots, and the extracted bridge manifest. The extracted bridge returned to exactly 50 packaged files with 49/49 hashes valid and no lock.

The outer Phase-1B deliverable includes the original verified ZIP, pristine extracted bridge payload, controller, raw streams, correlated transcript, request, completion, consumes, metrics, shutdown, latency, before/after observations, action audit, integrity snapshots, verification scripts, report, entry list, and SHA-256 manifest. Final outer ZIP size and SHA-256 are stored externally in `evidence/phase1b-package-evidence.json` because an archive cannot contain its own digest without circularity.

This isolated live proof does not approve game-source integration. The separate stable-source-revision approval and integration-point revalidation gate from Phase 1A remains blocked.
