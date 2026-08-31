# RNDBOT Persistent Active Roster – Phase B-R1

Task: `RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R1`  
Mode: isolated correction, test and build  
Result: `PASS`

## Decision

The requested Phase B-R1 implementation, database hardening, isolated tests, static scope gate and clean `Release/mangosd` build passed. The candidate was not started, installed or deployed. No production source, executable, active configuration or production database was changed or accessed.

`PHASE_C_GATE=AWAIT_B_R1_PACKAGE_AUDIT`

## Fixed baseline and preserved input

- Baseline commit: `42b8a7f742548793910fe8880463aeeb71627fb9`
- Baseline tree: `b2cf4e38fd288a53f61b9f2350f74caa85d606ab`
- Isolated source: `C:\TW\rndbot-roster-phase-b-r1-20260831-005014\source`
- State: detached HEAD, independent local Git objects, no submodules
- Input Phase-B ZIP SHA-256: `C25B254ED780EB02254E40E2D2C161528906D96717850B6A92DAD4E1B7D13C94`
- The input ZIP was verified again at final-gate time and was not modified.

## Implemented corrections

### Transaction and schema adapter

- The current pointer is locked with `SELECT ... FOR UPDATE` inside the same direct transaction that checks operation replay/collision, assigns the next version, writes the version/members/audit row and performs the current-pointer CAS.
- Every query/execute result is checked. The CAS must affect exactly one row. Any failure returns false to the direct transaction and triggers an explicit rollback; commit failure also triggers rollback.
- The operation UUID is re-read with `FOR UPDATE` in the transaction. Same UUID plus same request hash returns the stored result idempotently; a different request hash fails closed.
- Hex parsing accepts upper- and lowercase; persisted/evidence output is canonical uppercase.
- `member_count` is loaded and checked against actual member rows, contiguous one-based ordinals and duplicate GUID constraints.
- Version allocation occurs only while holding the singleton current-pointer lock. The two-operation DB test proves one winner and one deterministic `CURRENT_VERSION_MISMATCH` loser with zero loser mutations.
- Empty after-state is canonically forbidden. The database CHECK requires `member_count > 0`, and the adapter returns `EMPTY_ROSTER_FORBIDDEN` before persistence.
- The verified 52-line schema fingerprint covers table engines/collations, columns/types/null/default/charset/collation/extra, indexes/uniqueness, foreign keys/actions and CHECK rules. SHA-256: `32A9C149DBEB9C06EFF6DBBA31A4A6F938E4E6AFB665B91F566595DE46EE9220`.
- Applying the migration twice is idempotent; the rollback removes all four roster tables.

Primary locations: `PersistentActiveRosterDatabase.cpp:17-307`, `Database.cpp:572`, `Database.h:242`, `DatabaseMysql.cpp:363`, and the migration/rollback files listed in `SOURCE-MATRIX.tsv`.

### GUID, login and runtime validation

- Availability starts unknown, not implicitly available.
- Before login, the implementation validates character existence, account existence/ownership, RNDBOT account membership/name, ban state and absence of a real registered session.
- A non-roster or non-RNDBOT GUID cannot reach `AddPlayerBot`; the final boundary is revalidated in `PlayerbotHolder::AddPlayerBot`.
- A missing session removes the GUID from the online set before a new attempt.
- Login errors move the desired GUID to `DEGRADED` and use bounded exponential backoff capped at 60 seconds. No replacement or random top-up occurs.
- `INVALID_FAIL_CLOSED` also blocks ordinary destructive mutation paths.
- Desired roster members bypass lease, rotation, population, `RandomizeFirst`, factory/delete/reset and ordinary logout removal. Grouped roster bots therefore are not lease-/rotation-/population-logged out during normal play.
- `MASTER_LOGOUT_GROUP_PERSISTENCE` remains explicitly outside this phase; no `WorldSession.cpp`, `Group.cpp`, LLM or Debug path was changed.

### Administrative contract

- The actual administrative interfaces are local server-console commands only: `rndbot roster status` and `rndbot roster apply <absolute-request-file>`.
- Client and remote-administration contexts are rejected; no game-chat command exists.
- Apply requires the explicit canonical ordered GUID request, maintenance mode, zero tracked/actual online desired bots, and a safe absolute regular request file. Reparse/symlink path components, traversal, oversize input and non-exact reads fail closed.
- V1 does not attempt partial live reconciliation. A successful atomic operation returns `APPLIED_RESTART_REQUIRED`, closes admission and requires a deliberate restart. Removed/replaced GUIDs therefore cannot remain online unmanaged.
- `INITIALIZE` never chooses GUIDs. Expansion preserves the prior ordered vector as an exact prefix.
- Feature and maintenance options both default to `0` in `aiplayerbot.conf.dist.in`; disabled behavior retains the legacy path.

## Isolated disposable MariaDB evidence

- Executable: `C:\TW\ComTW\DB\bin\mariadbd.exe`
- Server command includes mandatory `--no-defaults`.
- Bind/port: `127.0.0.1:13317` (never port 3307)
- Fresh datadir per run below the isolated R1 directory
- Temporary user: `ssc_roster_r1_user@127.0.0.1`; only its password SHA-256 is retained
- No Windows service, production config, production credential or production datadir was used.
- The initialization utility itself does not accept `--no-defaults`; that non-server initialization limitation is recorded. Every actual MariaDB server start used `--no-defaults`.
- Two complete successful runs were preserved: attempt 10 and authoritative attempt 11.
- Authoritative result: `24/24 PASS`; server exited gracefully and port 13317 had no listener afterward.

The authoritative run covers migration twice, complete schema fingerprint, uppercase-HEX `LoadCurrent`/`LoadVersion`, 50-member initialize/reload, idempotency/collision, concurrent operations, injected member/audit failure with full rollback, false-old-version CAS, empty-roster rejection, 50→100 append-only expansion, maintenance remove/replace, and rollback to zero tables.

## Unit, static and build results

- Fresh unit/fake run 1: `PASS`
- Fresh unit/fake run 2: `PASS`
- Static scope/prohibition gate: `PASS`
- `git diff --check`: `PASS`
- Final clean `Release/mangosd` build: `PASS`
- Compiler errors: `0`
- Compiler warning occurrences: `12` (`C4838` ×4 in existing g3dlite, `C4834` ×8 in existing httplib call sites)
- CMake warning blocks: `1` (existing CMP0167 policy warning)
- CMakeCache SHA-256: `5E50DD1A1EF0931BBFB316FA5692442CDD2DE6E2F636CD21984C991651ECDBC1`

Candidate artifacts:

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `mangosd.exe` | 20,457,984 | `91FC789A7AB949C95C3FD7433B2D27414C10E13EB0EEEF17534BDFA0EDCC974A` |
| `mangosd.pdb` | 205,934,592 | `4704E5EA78D75059DC91BD7580B58D86CA218827D7C4C98FAD449F40F5BD623F` |

Embedded revision: `42b8a7f742548793910f`  
PE timestamp: `2026-08-30T23:57:17Z`  
CodeView GUID/age: `BCE90ECA-F227-4A77-B4D8-7BA8232AE1C5 / 1`

## Production protection

The production Git status remained the same ten-entry dirty tree. Each of those ten files was compared by relative path, byte length and SHA-256 and is identical to the before snapshot.

- Production `mangosd.exe`: unchanged, SHA-256 `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC`
- Active `mangosd.conf`: unchanged, SHA-256 `C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D`
- Active `aiplayerbot.conf`: unchanged, SHA-256 `490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF`
- Production database accessed: `NO`
- Endpoint `127.0.0.1:3307` accessed: `NO`
- Candidate started: `NO`
- Deployment performed: `NO`
- Bot login/game chat: `NO`
- LLM/Ollama/inference: `NO`

## Evidence map and limits

- `evidence/final-evidence.json`: machine-readable build, candidate and prohibition summary
- `evidence/static-gate-final.json`: all final gate predicates
- `evidence/disposable-db-test-result.json`: authoritative 24-test DB matrix
- `evidence/production-before.json` and `production-after.json`: byte-level production comparison
- `SOURCE-MATRIX.tsv`: exact 25-file implementation scope and hashes
- `TEST-MATRIX.tsv`: unit, DB, static and build test index
- `source-copies/`: complete delivered implementation source set
- `logs/`: configure, build, unit and DB evidence

No live server, bot-login, group, shutdown or gameplay claim is made. Runtime deployment and any real roster creation remain blocked pending the separate B-R1 package audit and a later explicit Phase-C authorization.
