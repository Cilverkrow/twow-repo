# SSC LLM Bridge — Phase 1A

This directory contains a server-free, external bridge and bounded-queue prototype. It is not linked to `mangosd`, does not expose an HTTP server, and has no database or game-chat adapter.

The verified path is:

```text
strict UTF-8 NDJSON command
  -> immutable request envelope
  -> bounded duplicate ledger and FIFO waiting queue
  -> one owned inference worker
  -> loopback-only bounded Ollama client
  -> immutable completion envelope
  -> consume-once delivery plus consumed lifecycle receipt
```

## Fixed boundaries

- One active inference per bridge process. The CLI also holds an exclusive fail-closed instance lock, preventing two CLI processes from owning the inference slot.
- Waiting capacity: 2 requests.
- Duplicate ledger capacity: 64 keys, including queue-full tombstones and consumed records. It never evicts during the process lifetime; saturation fails closed with `ledger_full`.
- Model: only `qwen2.5:7b`, digest `845dbda0ea48ed749caafd9e6037047aa19acfcfd82e704d7ca97d631a0b697e`.
- Ollama endpoint: only `http://127.0.0.1:11434`; no redirects, proxy use, decompression, tools, fallback model, pull, or automatic retry.
- Personality: only `context/personality-context-profile-v0.json`, read once at startup, filename/profile-version checked, strict-schema validated, and pinned by SHA-256 `AB876B90B9DBE006A785C44E272ACEE70671A359DF8B95AB65A9629A117EED10`.
- The personality file is byte-identical to the verified Phase-0 context. No traits, professions, variant, memories, or other personality data were invented.

## Explicit limits

| Boundary | Limit |
|---|---:|
| Entire NDJSON command line and direct request JSON | 16,384 UTF-8 bytes |
| Personality JSON | 16,384 UTF-8 bytes |
| User message | 2,048 UTF-8 bytes |
| Fully assembled prompt messages | 16,384 UTF-8 bytes |
| Serialized HTTP request | 32,768 bytes |
| Raw HTTP response | 65,536 bytes |
| Final dialogue | 240 Unicode code points, 2 sentences |
| Connect deadline | 3,000 ms |
| Response deadline | 30,000 ms or remaining request lifetime, whichever is shorter |
| Request lifetime | at most 60,000 ms |
| Controlled-shutdown drain deadline | 35,000 ms |

The CLI wrapper shares the request cap, so its nested request payload has slightly less available space than the direct bridge API. The raw response limit is enforced against declared `Content-Length` before decoding and against streamed bytes at `limit + 1`. UTF-8 decoding is fatal; BOM, malformed sequences, unpaired surrogates, duplicate JSON members, excess depth, trailing content, missing members, unknown members, and wrong types fail closed.

## Contracts and lifecycle

The schemas are under `schemas/`. Request and completion objects are recursively frozen. Lifecycle state is kept separately so consuming a result never mutates its completion envelope. The first successful consume returns the immutable terminal completion and a new `consumed` status; every later consume returns `already_consumed` with no completion or dialogue text.

See `state-and-error-contract.md` for the complete state machine and duplicate/mismatch/stale behavior.

## Reproducible verification

Run from PowerShell:

```powershell
& 'C:\TW\ComTW\runbooks\ssc-llm-bridge-phase1a-20260829-023418\run-tests.ps1'
```

The runner uses Node.js 24 or newer already present on the host, installs no packages, and invokes only deterministic unit tests plus temporary loopback mock listeners. It does not query or infer through live Ollama.

Configuration and context can be checked without network activity:

```powershell
& 'C:\Users\djfav\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' 'C:\TW\ComTW\runbooks\ssc-llm-bridge-phase1a-20260829-023418\src\cli.mjs' --validate-only
```

## Manual external prototype

`src/cli.mjs --run` is the only runtime entry point. It accepts NDJSON commands on standard input and writes NDJSON results to standard output; it opens no server listener. Startup first verifies the exact installed model name and digest using `GET /api/tags`. Each accepted request can cause at most one `POST /api/chat`. A connection error, timeout, malformed response, wrong model, mismatch, or stale result is terminal and is never retried automatically.

Commands are strict objects:

- `{"command":"submit","request":{...request envelope v1...}}`
- `{"command":"status","request_id":"...","bot_guid":18281}`
- `{"command":"consume","request_id":"...","bot_guid":18281}`
- `{"command":"metrics"}`
- `{"command":"shutdown","drain":true}`

The verification performed for this deliverable did not invoke `--run` and performed zero live inference calls.

## Deliberate prototype limitations

- Queue and ledger state are in memory and do not survive restart.
- The fail-closed instance-lock file can remain after an unclean process crash and then requires operator inspection; it is never silently stolen.
- There is no game-source adapter, game object, raw pointer, MariaDB adapter, game-chat output, persistence service, model-management code, or automatic retry.
- Source integration is blocked by the separate gate in `future-source-integration-gate.md`.
