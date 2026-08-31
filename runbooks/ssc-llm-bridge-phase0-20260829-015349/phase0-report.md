# SSC LLM Bridge — Phase 0 console proof of concept

## Result

`PHASE0_RESULT=PASS`

Phase 0 proved one isolated console-only request/response flow. Nothing was sent to game chat, and Phase 1 was not started.

Output directory:

`C:\TW\ComTW\runbooks\ssc-llm-bridge-phase0-20260829-015349`

## Discovery package verification

- Package: `C:\TW\ComTW\runbooks\bot-personality-discovery-20260828-224032.zip`
- Size: 84,494 bytes (expected and actual)
- SHA-256: `8287DAF2124B08863A43FE2A4C03EAB2FFA8FFD7DCC64A527ADA1D928BBEA290` (expected and actual)
- ZIP entries: 26
- Manifested payload entries: 25
- All ZIP paths passed traversal/rooted-path checks.
- Every ZIP payload matched `sha256-manifest.txt` before extraction.
- Every extracted payload matched the same manifest after extraction.

No SQL was executed. The mapping was read only from the verified extracted package.

## Deterministic Bot fixture

Selection rule: numerically smallest `bot_guid` in `active_random_rotation` whose race and class keys both occur in their mapping dictionaries.

- `bot_guid`: 18281
- Population: `active_random_rotation`
- Race: ID 5, `undead`, mapping name `Undead`, German presentation label `Untoter`
- Class: ID 4, `rogue`, mapping name `Rogue`, German presentation label `Schurke`
- Race variant: `null`
- Professions: `[]`
- Traits: `[]`

The selected GUID occurs exactly once. Its active race count is 9 in both the Bot list and race summary; its active class count is 22 in both the Bot list and class summary. Mapping totals reconcile to 4,500 unique normalized GUIDs: 100 active rotation and 4,400 inactive reserve, range 17,930–22,429. All exported profession arrays are empty and no race variant is mapped.

The fixture classification comes from the immutable discovery capture. This report does not claim that Bot 18281 is currently spawned or online. The German labels are deterministic localizations of the verified race/class identities, not new Bot attributes.

## Personality context and request

`personality-context-phase0.json` follows schema version 1 and profile version 0. Its status is `phase0_unprovisioned`; professions and traits remain empty.

Synthetic request:

- `request_id`: `72e080a9-225b-49cc-92cc-012c352109d3`
- Channel: `phase0_console`
- Speaker: `synthetic_phase0_user`
- `bot_guid`: 18281
- Message: `Was hast du heute vor?`

The user message remained a separate untrusted `user` message. The system instruction prohibited tools, commands, database/external actions, technical self-reference, invented history/professions/relationships and explicit race/class/trait listing.

## Ollama inventory and model decision

Only `http://127.0.0.1:11434` was used.

- Ollama version: 0.33.2
- Installed models: exactly one
- Selected model: `qwen2.5:7b`
- Digest: `845dbda0ea48ed749caafd9e6037047aa19acfcfd82e704d7ca97d631a0b697e`
- Parameter size: 7.6B
- Quantization: Q4_K_M
- Installed size: 4,683,087,332 bytes
- Format/family: GGUF / qwen2
- Installed context length reported by `/api/tags`: 32,768
- Loaded before inference: no
- Loaded context length reported by `/api/ps` after inference: 4,096

Exact decision: one installed suitable local text/chat model existed and none was already loaded, so `qwen2.5:7b` was selected. No model was downloaded, copied, created, deleted, updated or explicitly loaded/unloaded through a model-management operation.

Sanitized results from `GET /api/version`, `GET /api/tags` and `GET /api/ps` are preserved in `ollama-inventory.json`.

## Harness behavior

`phase0-console-harness.ps1` uses only the installed PowerShell runtime and standard .NET classes. It:

- reads context and request JSON;
- validates schema versions, positive GUIDs, exact GUID equality, request ID, channel and non-empty message;
- keeps the user text in a separate user message;
- permits only the HTTP loopback host `127.0.0.1`;
- posts to `/api/chat` with `stream: false` and no tools;
- uses finite connect/response timeouts and a named single-request mutex;
- limits the HTTP client to one connection;
- converts validation, HTTP and model-response failures into JSON error envelopes;
- rejects tool calls, missing assistant role/content, invalid response JSON and empty output;
- extracts only `message.content`;
- removes control characters, converts line breaks to spaces, collapses whitespace, keeps at most two sentences and at most 240 visible text elements;
- preserves `request_id` and `bot_guid`;
- restricts optional output paths to its Phase-0 directory;
- prints the final envelope to the console.

It contains no database/game file access and no game-chat call.

## Test results

All eight server-free tests passed before the real inference:

1. Valid context and request — pass (`status=ok`).
2. Missing `bot_guid` — pass (`error_validation`).
3. Request/context GUID mismatch — pass (`error_validation`).
4. Invalid JSON — pass (`error_validation`).
5. Empty user message — pass (`error_validation`).
6. Unreachable temporary loopback port 61244 — pass (`error_http`); Ollama was not stopped.
7. Oversized mocked response — pass; output reduced to 177 visible characters and two sentence terminators.
8. Mocked control characters and multiple lines — pass; no controls remained and output was `Erste Zeile. Zweite Zeile.`

Machine-readable details are in `harness-test-results.json`.

## Single real inference

Exactly one real `POST /api/chat` request was made, after the final test run passed.

Response envelope:

```json
{
  "schema_version": 1,
  "request_id": "72e080a9-225b-49cc-92cc-012c352109d3",
  "bot_guid": 18281,
  "status": "ok",
  "model": "qwen2.5:7b",
  "latency_ms": 8487,
  "text": "Heute werde ich die Stadt abspähen und eventuelle Gefahren auskundschaften."
}
```

Metrics:

- Wall-clock latency: 8,487 ms
- Ollama `total_duration`: 8,341,960,600 ns (8,341.961 ms)
- Ollama `load_duration`: 7,968,958,000 ns (7,968.958 ms)
- Prompt tokens: 273
- Output tokens: 22
- Sanitized output: 75 visible characters, one sentence, no control characters
- Exact request ID preserved: yes
- Exact Bot GUID preserved: yes

No hidden reasoning or tool calls were copied into the response.

## Server/resource observation

Immediately before and after the single inference, the required process identities and listener identities were unchanged.

| Component | PID | Start time UTC | Listener after inference |
|---|---:|---|---|
| `mangosd` | 9628 | 2026-08-28T22:12:48.2884890Z | `0.0.0.0:8090` |
| MariaDB (`mysqld`) | 14776 | 2026-08-28T22:12:37.9655841Z | `127.0.0.1:3307` |
| `realmd` | 24080 | 2026-08-28T22:12:45.2939531Z | `0.0.0.0:3724` |
| Ollama | 5528 | 2026-08-28T21:21:58.8358817Z | `127.0.0.1:11434` |

`mangosd` observation:

- Before: 96.88% of one core during the one-second sample; working set 1,697,124,352 bytes; private memory 4,305,076,224 bytes.
- After: 84.38% of one core during the one-second sample; working set 1,697,341,440 bytes; private memory 4,305,076,224 bytes.
- Working-set delta: +217,088 bytes; private-memory delta: 0 bytes.

No matching MariaDB/mangosd/realmd/Ollama Windows service registrations were present; these components were observed as running processes. No instability or excessive resource change attributable to the single inference was observed.

## Read-only future integration result

The detailed call map is in `future-integration-map.md`.

Summary:

- Incoming chat is validated in `WorldSession::HandleMessagechatOpcode`, then offered to `PlayerbotPlayerScript::OnChatCommand`.
- Command handling proceeds through `PlayerbotMgr::HandleCommand`, `PlayerbotAI::HandleCommand`, `chatCommands`, `ReactionEngine` and `ExternalEventHelper`.
- Observed chat reaches Bot AI through `PlayerbotServerScript::CanPacketSend` and `PlayerbotAI::HandleBotOutgoingPacket`; eligible dialogue enters the mutex-protected `chatReplies` queue and `ChatReplyAction::ChatReplyDo`.
- The addressed Bot is already an authoritative live `Player*`; copy `bot->GetGUIDLow()` into an immutable request before leaving the owning thread.
- The pinned `PlayerbotLLMInterface::Generate` is a disabled stub. Existing `std::async`/detached-thread code retains a raw `WorldSession*` and is not a sufficient production boundary.
- A later bridge should use one bounded worker, immutable GUID/request envelopes, a completion queue, and world/AI-thread re-resolution before speech.
- Existing `PlayerbotAI::Whisper`, `Say`, `Yell` and `SayTo*` methods can be reused after revalidation. `BroadcastHelper` itself should not be used for replies because it applies randomized broad-channel selection.

## Operational-boundary confirmation

During this Phase 0 run:

- no server or service was stopped or restarted;
- no launcher or shutdown helper was invoked;
- no database connection or SQL statement was made;
- no database, character, Bot or personality table was created or changed;
- no server source file was edited or compiled;
- no game chat message was sent;
- no model was pulled, created, copied, deleted or updated;
- Ollama remained bound to loopback;
- no migration, audit, historical runbook or trainer-defect operation was invoked;
- Phase 1 was not started.

## Sanitized package entry list

The deliverable ZIP contains exactly these entries:

1. `phase0-report.md`
2. `ollama-inventory.json`
3. `selected-bot-evidence.json`
4. `personality-context-phase0.json`
5. `phase0-request.json`
6. `phase0-response.json`
7. `phase0-console-harness.ps1`
8. `harness-test-results.json`
9. `future-integration-map.md`
10. `sha256-manifest.txt`

`sha256-manifest.txt` covers the nine payload files other than the manifest itself. The final ZIP byte count, ZIP SHA-256 and verified entry list are returned alongside the package.
