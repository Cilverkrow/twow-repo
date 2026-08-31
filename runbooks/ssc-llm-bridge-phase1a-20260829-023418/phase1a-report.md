# SSC LLM Bridge — Phase 1A report

`PHASE1A_RESULT=PASS`

This result is limited to the server-free external bridge and bounded-queue prototype. It is not approval for game-source integration or live game dialogue.

## Delivered result

The prototype provides:

- recursively frozen request and completion envelopes keyed by canonical UUIDv4 `request_id` plus validated `bot_guid`;
- separate frozen lifecycle snapshots for `queued`, `running`, `ready`, `failed`, `expired`, and `consumed`;
- one owned asynchronous worker, one active inference maximum, an explicit two-entry FIFO waiting queue, and a bounded 64-key duplicate/completion ledger;
- an exclusive fail-closed CLI instance lock so two external bridge CLI processes cannot own independent active slots;
- strict raw-byte UTF-8 decoding without BOM, a duplicate-safe JSON parser, exact field schemas, depth/trailing-content checks, canonical timestamps, safe integer bounds, and canonical lowercase UUIDv4 validation;
- byte limits on the entire NDJSON command, request, context, user message, assembled prompt, serialized HTTP request, and raw HTTP response;
- independent 3-second connect and 30-second response deadlines, with the response deadline shortened to the request's remaining lifetime;
- duplicate, request-ID/GUID mismatch, context mismatch, queue-full, ledger-full, completion mismatch, model mismatch, stale-result, ready-before-consume expiry, and consume-once handling;
- controlled drain or immediate shutdown, startup cancellation, active HTTP cancellation, and joining of the owned worker without detached threads or raw game pointers;
- exactly one allowlisted model: `qwen2.5:7b` with digest `845dbda0ea48ed749caafd9e6037047aa19acfcfd82e704d7ca97d631a0b697e`;
- one versioned, file-only context `personality-context-profile-v0.json`, pinned to SHA-256 `AB876B90B9DBE006A785C44E272ACEE70671A359DF8B95AB65A9629A117EED10`;
- a strict NDJSON console interface with no inbound server listener;
- no retry loop, retry middleware, redirect following, fallback model, or other automatic path capable of generating duplicate dialogue.

The Phase-1A context is byte-identical to the reviewed Phase-0 context. Its `profile_version` remains 0 and its empty traits, professions, and null race variant remain unchanged; Phase 1A invented no personality data.

## Automated verification

The final reproducible run returned:

```text
PHASE1A_TEST_RESULT=PASS
tests=60 passed=60 failed=0
node=v24.19.0
```

The official runner is `run-tests.ps1`. It resolves an already-installed Node runtime, installs no package, validates configuration/context without network access, and executes three test files serially. HTTP cases use temporary listeners on `127.0.0.1` and close them after each fixture.

Coverage includes:

- exact and over-limit command, message, prompt, declared response, and chunked response boundaries;
- malformed UTF-8, BOM, unpaired surrogate, duplicate key including `__proto__`, trailing JSON, excess depth, missing/unknown members, wrong types, schema versions, timestamps, integer bounds, and UUID variants;
- context filename/version/hash/GUID and hard model/system-instruction pins;
- exact inventory name/model/digest, ambiguity/mismatch/type failures, wrong response role/model, tool calls, malformed response JSON/UTF-8, and empty/oversized output;
- one-worker concurrency, FIFO order, exact waiting capacity, bounded ledger, queue-full tombstones, duplicate/mismatch admission, unobserved queued expiry, and zero-attempt rejection paths;
- queued expiry, running stale result, ready-before-consume expiry, completion mismatch, consume race, transport failure, response/connect deadline behavior, and an exact `attempt_count <= 1` invariant;
- immediate shutdown, drain shutdown, drain timeout, invalid shutdown options, shutdown during startup verification, worker join, instance-lock exclusion, and closed admission.

An independent read-only code audit reran the suite and ended with no unresolved requirement-level or medium/high-severity findings.

## Phase-0 preservation

The original directory `C:\TW\ComTW\runbooks\ssc-llm-bridge-phase0-20260829-015349` was treated as immutable. Full recursive snapshots were captured outside that directory before and after Phase 1A:

- files before/after: 48 / 48;
- bytes before/after: 1,381,525 / 1,381,525;
- sorted path/size/hash fingerprint before/after: `1968C9B4B4C1874A7709EE1101ED7E2A8BDD8644D487E75C925359CD27E11009`;
- per-file path, size, SHA-256, and last-write differences: 0;
- result: `PHASE0_INTEGRITY=UNCHANGED`.

The original Phase-0 runbook and deliverable ZIP were not edited or repackaged.

## Operational boundary

Phase 1A performed:

- zero live Ollama inference calls and zero live Ollama inventory requests;
- zero MariaDB connections, queries, schema actions, or file access through a database client;
- zero game-chat messages;
- zero `mangosd` or game-source modification/compilation;
- zero game launch, stop, restart, shutdown-helper, model-management, or existing in-source LLM-path actions;
- zero external-network requests.

The final read-only OS observation saw Ollama PID 5528 responding and listening only on `127.0.0.1:11434`. At that final observation, `mangosd`, `mysqld`, and `realmd` were not present in the accessible process table and their prior ports were not listening. Phase 1A issued no process-control command and made no attempt to restart or alter them; this external runtime-state observation does not affect the isolated mock-test result and is preserved in `evidence/operational-boundary-final.json`.

## Source integration remains blocked

`SOURCE_INTEGRATION_GATE=BLOCKED_PENDING_APPROVED_STABLE_REVISION`

Phase 0 historically inspected commit `42b8a7f742548793910fe8880463aeeb71627fb9`, but Phase 1A does not treat it as the separately approved stable integration revision. `future-source-integration-gate.md` requires a new approval record and a full read-only revalidation of every cited integration point against the exact approved commit before any later source patch is considered.

## Evidence and packaging

- `evidence/automated-test-result.json`: machine-readable test result and scope declarations.
- `evidence/automated-tests.tap`: complete TAP output.
- `evidence/config-validation.jsonl`: offline configuration/context validation.
- `evidence/phase0-integrity-before.json` and `phase0-integrity-after.json`: complete recursive snapshots.
- `evidence/phase0-integrity-comparison.json`: zero-difference comparison.
- `evidence/operational-boundary-final.json`: sanitized final process/listener observation and action boundary.
- `sha256-manifest.txt`: SHA-256 manifest for packaged payload files (self-excluded).
- `package-entry-list.txt`: exact ZIP entry list.
- `evidence/package-evidence.json`: external ZIP path, byte count, SHA-256, and entries.

No live dialogue output exists in this Phase-1A package because live inference was intentionally not part of this verification run.
