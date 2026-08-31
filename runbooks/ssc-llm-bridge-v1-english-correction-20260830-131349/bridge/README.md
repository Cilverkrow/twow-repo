# SSC LLM Bridge — V1 English correction

This directory is a separately versioned correction derived from the reviewed Phase-1B bridge. The prior Phase-1B and production-bridge Phase-A packages remain immutable. This copy remains a server-free, external bridge and bounded-queue prototype. It is not linked to `mangosd`, does not expose an HTTP server, and has no database or game-chat adapter.

The correction changes only the dialogue-language contract and the sanitized-output byte bound:

- every system, personality, and dialogue rule requires English output regardless of input language;
- final text remains limited to 240 Unicode code points and is additionally limited to 240 UTF-8 bytes;
- over-limit text is rejected as a whole and is never byte-truncated, so no UTF-8 codepoint is split;
- output remains dialogue text only; no action, emote, command, or additional delivery channel was added.

The verified path is:

```text
strict UTF-8 NDJSON command
  -> immutable request envelope
  -> one admission-derived internal monotonic deadline
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
- Personality: only `context/personality-context-profile-v1.json`, read once at startup, filename/profile-version checked, strict-schema validated, and pinned by SHA-256 `386659245CB8298221465FD8B40339C13A01C7C10CBC58E876CDD264DC64D07E`.
- Profile V1 retains bot GUID 18281, race/class identity, empty traits and professions, and a null race variant. Only English field naming and English dialogue rules were introduced; no memories, professions, relationships, traits, actions, or other personality facts were invented.
- `created_utc` and `expires_utc` remain exact immutable wire evidence. At first admission, their wall-clock remaining lifetime is converted once to a private monotonic deadline. No later lifecycle or transport decision reparses wire UTC against wall time.

## Explicit limits

| Boundary | Limit |
|---|---:|
| Entire NDJSON command line and direct request JSON | 16,384 UTF-8 bytes |
| Personality JSON | 16,384 UTF-8 bytes |
| User message | 2,048 UTF-8 bytes |
| Fully assembled prompt messages | 16,384 UTF-8 bytes |
| Serialized HTTP request | 32,768 bytes |
| Raw HTTP response | 65,536 bytes |
| Final dialogue | 240 Unicode code points, 240 UTF-8 bytes, 2 contiguous terminator runs |
| Connect deadline | 3,000 ms or remaining monotonic lifetime, whichever is shorter |
| Response deadline | 30,000 ms or remaining monotonic lifetime, whichever is shorter |
| Request lifetime | at most 60,000 ms |
| Controlled-shutdown drain deadline | 35,000 ms |

The single absolute monotonic lifetime deadline spans queue wait, running inference, ready-before-consume, connection, and response. Forward or backward wall-clock adjustments after admission cannot shorten or extend it. The CLI wrapper shares the request cap, so its nested request payload has slightly less available space than the direct bridge API. The raw response limit is enforced against declared `Content-Length` before decoding and against streamed bytes at `limit + 1`. UTF-8 decoding is fatal; BOM, malformed sequences, unpaired surrogates, duplicate JSON members, excess depth, trailing content, missing members, unknown members, and wrong types fail closed. Dialogue sentence limits count each maximal contiguous run containing `.`, `!`, `?`, or Unicode ellipsis `…`, whether or not whitespace follows. The 240-byte sanitizer check runs on the complete normalized UTF-8 string and rejects rather than truncates it.

## Contracts and lifecycle

The schemas are under `schemas/`. Request and completion objects are recursively frozen. Lifecycle state is kept separately so consuming a result never mutates its completion envelope. The first successful consume returns the immutable terminal completion and a new `consumed` status; every later consume returns `already_consumed` with no completion or dialogue text.

See `state-and-error-contract.md` for the complete state machine and duplicate/mismatch/stale behavior.

## Reproducible verification

Run `run-tests.ps1` from this directory in PowerShell. The runner uses Node.js 24 or newer already present on the host, installs no packages, and invokes only deterministic unit tests plus temporary loopback mock listeners. It does not query or infer through live Ollama.

```powershell
& '.\run-tests.ps1'
```

Configuration and context can be checked without network activity:

```powershell
& 'C:\Users\djfav\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' '.\src\cli.mjs' --validate-only
```

## Manual external prototype

`src/cli.mjs --run` is the only runtime entry point. It accepts NDJSON commands on standard input and writes NDJSON results to standard output; it opens no server listener. Startup first verifies the exact installed model name and digest using `GET /api/tags`. Each accepted request can cause at most one `POST /api/chat`. A connection error, timeout, malformed response, wrong model, mismatch, or stale result is terminal and is never retried automatically.

Commands are strict objects:

- `{"command":"submit","request":{...request envelope v1...}}`
- `{"command":"status","request_id":"...","bot_guid":18281}`
- `{"command":"consume","request_id":"...","bot_guid":18281}`
- `{"command":"metrics"}`
- `{"command":"shutdown","drain":true}`

The deliverable root outside this payload records the separately authorized one-shot live proof. It starts this entry point once, submits one request, polls only, consumes once plus the required empty second consume, captures metrics, and shuts down with `drain=true`. There is no game-chat adapter.

## Deliberate prototype limitations

- Queue and ledger state are in memory and do not survive restart.
- The fail-closed instance-lock file can remain after an unclean process crash and then requires operator inspection; it is never silently stolen.
- There is no game-source adapter, game object, raw pointer, MariaDB adapter, game-chat output, persistence service, model-management code, or automatic retry.
- No Core source integration is part of this correction; production-bridge Phase B was not started.
