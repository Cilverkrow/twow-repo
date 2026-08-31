# RNDBOT Persistent Active Roster – Phase B

Task: `RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B`

## Decision

`PHASE_B_RESULT=BLOCKED`

The isolated implementation, two reproducible test runs, static scope gate, and clean `Release/mangosd` build passed. The phase cannot receive an overall PASS because the mandatory schema-create/rollback test against a disposable database could not run: the MariaDB client received `ERROR 2002 (HY000)` / WinSock `10061` for `127.0.0.1:3307`. No schema was created, no active schema was named or selected, and no active database was read. Process control was forbidden, so no database service was started.

This is an external evidence blocker, not a build or unit-test failure. Phase C remains closed.

## Immutable inputs and isolation

- Baseline commit: `42b8a7f742548793910fe8880463aeeb71627fb9`
- Baseline tree: `b2cf4e38fd288a53f61b9f2350f74caa85d606ab`
- Isolated detached worktree: `C:\TW\rndbot-roster-phase-b-20260830-230336\source`
- Contract source ZIP SHA-256: `0C4D08163DF56FBBD59B8B9801764990DA9E8F3182319F7CF20A258B710E69BE`
- Contract addendum SHA-256: `203855E99A7ED2D9B560769E703804CBE4C3AC2594B7C2BFEEED34236452294B`
- The production source tree, production EXE, and active configuration hashes were checked against the captured pre-task evidence by `evidence/static-gate-post-build.json` and remained byte-identical.

## Implemented contract

The isolated patch adds a default-disabled `AiPlayerbot.PersistentActiveRoster.Enabled` feature and a Character-DB-backed, ordered, versioned GUID roster.

- Desired identity is loaded only from the current immutable snapshot.
- Runtime states are `DISABLED`, `LOADING`, `STARTING`, `HEALTHY`, `DEGRADED`, `INVALID_FAIL_CLOSED`, `SHUTTING_DOWN`, and `STOPPED`.
- Desired, available, and online counts are tracked separately; diagnostics are deterministically GUID-sorted.
- Missing characters/accounts and login failures produce `DEGRADED` without replacement.
- Async login with the feature enabled fails closed as `ASYNC_LOGIN_UNSUPPORTED`.
- Random factory selection, random top-up, lease/rotation/population logout, `RandomizeFirst`, ordinary remove/reset/disable/delete, and ordinary logout cannot mutate or reap desired roster GUIDs.
- Intentional master/server `LogoutAllBots` semantics are explicitly excluded. `MASTER_LOGOUT_GROUP_PERSISTENCE` remains a separate decision and test gate; no `WorldSession.cpp`, `Group.cpp`, or general group-semantics change was made.
- Expansion appends GUIDs and preserves the previous ordered vector as an exact prefix.
- INITIALIZE requires an explicit ordered GUID list. No random proposal can commit itself, and no real 50-GUID roster was created.
- Canonical admin requests use strict lowercase UUIDv4, UTF-8 NFC, non-empty actor, LF-only framing, fixed ten-digit one-based list ordinals and GUIDs, sorted REMOVE/REPLACE rules, and fail closed on noncanonical input.
- Replace list ordinals describe the canonical list order; replacement targets are resolved by the stated old GUID, not by roster position.
- `operation_id`, raw 32-byte `request_sha256`, before/after snapshot hashes, current pointer, immutable version/member rows, canonical request, and audit row are committed in one Character-DB transaction.
- Same operation ID plus same request hash replays the stored result; same ID plus a different hash returns `OPERATION_ID_REQUEST_MISMATCH`.
- The empty snapshot fixture is exactly 68 bytes and hashes to `BA46C4A526EE8BBE3A640492A1167DE0A449D382FE129891BF38BA89E3DF293E`.

## Tests and gates

Both final test runs compiled independently and returned `persistent_active_roster_tests PASS`:

- `logs/tests-authoritative-run-1.log`
- `logs/tests-authoritative-run-2.log`

The tests cover canonical snapshot/request vectors, Unicode NFC rejection, non-empty actor, remove/replace order, invalid ordinals, duplicate GUIDs, snapshot hash validation, every runtime state name, desired/available/online separation, startup fail-closed cases, idempotency and operation-ID collision, injected transaction failure, restart identity, explicit remove/replace/rollback, GUID-based replace semantics, login failure without replacement, automatic-mutation guards, and append-only 50-to-100 expansion.

`evidence/static-gate-post-build.json` passed after the final build. It confirms baseline commit/tree, `git diff --check`, default-off configuration, prohibited source paths untouched, no LLM/Ollama code, async fail-closed guard, reset/login/logout protections, byte-identical production dirty files, and unchanged production EXE/config hashes.

The database evidence is intentionally negative and complete:

- `evidence/disposable-db-test.json`
- `evidence/disposable-db-test.stdout.txt`
- `evidence/disposable-db-test.stderr.txt`

Only the unique disposable schema name `ssc_rndbot_phaseb_20260830_230336` was targeted. The create-schema connection failed before server-side execution; `active_schema_accessed=false` and `schema_removed=false` mean there was nothing to roll back.

## Clean build provenance

Final build directory: `C:\TW\rndbot-roster-phase-b-20260830-230336\build-clean-5`

- Generator: Visual Studio 17 2022, x64
- CMake: 4.4.2
- MSVC compiler: 19.44.35228.0 / toolset 14.44.35207
- Windows SDK: 10.0.26100.0
- Boost: 1.92.0
- Configuration/target: Release, `mangosd` only
- Candidate EXE SHA-256: `DC51D605EB088A3264666311E2C4C73D96A5FC8AB9D938B0A019A175B6FB09F2`
- Candidate EXE size: `20403712` bytes
- Candidate PDB SHA-256: `CDBAC78E46CD7CB5E2A5D88CE9EBC4D1DC851799718B4312285DA5D7AE7654CD`
- Candidate PDB size: `205533184` bytes
- PE linker timestamp: `2026-08-30T22:23:46Z`
- CodeView GUID: `BA20AA22-3B99-47C4-B312-BEB290D98224`
- CodeView age: `1`
- CMakeCache SHA-256: `6262C1AF96C327EF73A18E60F36909EF2A926DFF3401C6489483845F1978CE4C`
- Embedded revision `42b8a7f742548793910f`: present
- Build errors: `0`
- Warning occurrences: 12 compiler warnings plus one CMake policy-warning block
- Warning families: existing third-party/shared-code `C4834`, `C4838`, and `CMP0167`; no warning originates in the new roster implementation files

The final build started with no isolated `source\bin`, created a fresh CodeView GUID with PDB age 1, and did not start or install the candidate.

## Scope and residual gate

The generated SQL migration and destructive isolated/test rollback script are packaged as source only. Their execution and rollback remain unverified until a separately authorized disposable MariaDB instance is available. That test must be completed before this package can be reconsidered for PASS or used to authorize Phase C.

No production source, production EXE, active config, or database content was changed. No server or other process was controlled. No bot logged in, no game chat was sent, and no LLM bridge, Ollama access, or inference occurred.

## Result block

```text
PHASE_B_RESULT=BLOCKED
BLOCKER=DISPOSABLE_DB_UNAVAILABLE_127.0.0.1_3307_ERROR_2002_WIN32_10061
BASELINE_COMMIT=42b8a7f742548793910fe8880463aeeb71627fb9
BASELINE_TREE=b2cf4e38fd288a53f61b9f2350f74caa85d606ab
CONTRACT_IMPLEMENTATION=PASS
CANONICAL_SERIALIZATION=PASS
RUNTIME_STATE_SEPARATION=PASS
IDEMPOTENCY_AND_COLLISION=PASS
APPEND_ONLY_EXPANSION=PASS
NO_AUTOMATIC_REPLACEMENT=PASS
GROUPED_ROSTER_BOT_ROTATION_PROTECTION=PASS_FAKE_AND_STATIC_ONLY
MASTER_LOGOUT_GROUP_PERSISTENCE=AWAIT_SEPARATE_DECISION_AND_TEST
DISPOSABLE_DB_SCHEMA_TEST=BLOCKED
TWO_REPRODUCIBLE_TEST_RUNS=PASS
STATIC_SCOPE_GATE=PASS
CLEAN_BUILD_RESULT=PASS
CANDIDATE_EXE_SHA256=DC51D605EB088A3264666311E2C4C73D96A5FC8AB9D938B0A019A175B6FB09F2
CANDIDATE_PDB_SHA256=CDBAC78E46CD7CB5E2A5D88CE9EBC4D1DC851799718B4312285DA5D7AE7654CD
PRODUCTION_SOURCE_BYTE_IDENTICAL=YES
PRODUCTION_EXE_CHANGED=NO
ACTIVE_CONFIG_CHANGED=NO
ACTIVE_DATABASE_ACCESSED=NO
DATABASE_CHANGED=NO
PROCESS_CONTROL_PERFORMED=NO
CANDIDATE_STARTED=NO
REAL_ROSTER_VERSION_CREATED=NO
BOT_LOGIN_PERFORMED=NO
GAME_CHAT_SENT=NO
LLM_BRIDGE_STARTED=NO
OLLAMA_ACCESSED=NO
INFERENCE_PERFORMED=NO
DEPLOYMENT_PERFORMED=NO
PHASE_C_STARTED=NO
PHASE_C_GATE=AWAIT_SEPARATE_PACKAGE_AUDIT
```
