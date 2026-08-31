# RNDBOT Persistent Active Roster – Phase B-R2

Task: `RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R2`  
Mode: isolated correction, test and build  
Result: `PASS`

## Executive result

All six R2 audit findings were corrected in a new isolated local source tree based on commit `42b8a7f742548793910fe8880463aeeb71627fb9` and tree `b2cf4e38fd288a53f61b9f2350f74caa85d606ab`. The exact B-R1 ZIP was verified before reconstruction:

- input ZIP SHA-256: `89E36EFFEB1A53A138E1ABD065A263CCB6BDD7A10478AF91193639FC7242EE7F`
- B-R1 source reconstruction: `25/25 PASS`
- implementation contract SHA-256: `203855E99A7ED2D9B560769E703804CBE4C3AC2594B7C2BFEEED34236452294B`

Two fresh fake/unit runs and two final real C++/MariaDB adapter runs passed. The final Release-only `mangosd` clean build passed; the produced candidate was neither started nor installed.

## Isolation and database boundary

The implementation tree is `C:\TW\rndbot-roster-phase-b-r2-20260831-131938\source`, not the production source tree. The two accepted database runs used fresh datadirs and distinct local ports:

| Run | Port | Datadir | Adapter hash | Result |
| --- | ---: | --- | --- | --- |
| final run 1 | 13329 | `db-r2-run1-attempt4\data` | `2C4729F1713CF8FCEE088C3978DBF99A7A231F340904797DC65ADE99F31144BF` | PASS |
| final run 2 | 13328 | `db-r2-run2-attempt1\data` | `2C4729F1713CF8FCEE088C3978DBF99A7A231F340904797DC65ADE99F31144BF` | PASS |

Both instances used `mariadbd --no-defaults`, `127.0.0.1`, a new datadir, a per-run temporary user/password, no production config, and no Windows service. The runner rejects port 3307. It recorded the full pre-start command line, PID/listener/datadir after start, and complete exit after its own shutdown. The migration was applied twice per accepted run, the real adapter suite was executed, and the rollback migration left zero roster tables.

Initial runner bring-up attempts are retained as diagnostic evidence. A missing `ACE.dll` runtime search path caused the first adapter launch to wait before test execution; the runner was corrected to use the already configured dependency runtime directory. These attempts are not counted as the two accepted runs and did not access production.

## Real C++ adapter closure

The test executable links the delivered production implementations rather than PowerShell replacement SQL:

- `CharacterDatabaseStore`
- `PersistentActiveRosterDatabase.cpp`
- `PersistentActiveRoster.cpp`
- the unchanged `shared` database library, including `Database.cpp` and `DatabaseMysql.cpp`
- required framework, ACE, MariaDB, OpenSSL and Windows dependencies

The PowerShell runner only created/stopped the isolated MariaDB instance, applied/rolled back the supplied migration, and launched the C++ test. All roster reads and commits were made through the real `CharacterDatabaseStore` and core database classes.

The adapter test covers `VerifySchema`, empty `LoadCurrent`, ordered 50-GUID initialization, reload through new database/store/service objects, idempotent replay, operation-ID collision, 50-to-100 append-only expansion, maintenance-mode remove/replace, uppercase SQL `HEX()` values, member count/ordinal/duplicate validation, expected-current mismatch, member-insert rollback, audit-insert rollback, and two complete concurrent commits over separate connections/stores. The concurrency assertion requires exactly one successful commit, exactly one `CURRENT_VERSION_MISMATCH`, and no loser mutation.

`CharacterDatabaseStore::Commit` locks the singleton current row with `SELECT ... FOR UPDATE`, rechecks the operation ID inside the same transaction, derives the next version from the locked current version, requires exactly one affected row for every insert/CAS update, and explicitly reports rollback failure. Schema verification fingerprints tables, column types/collations/defaults, indices/unique rules, foreign keys, and check rules.

## Loading-state contract

`Service::Start` now publishes `LOADING` before schema access and remains in `LOADING` through:

- `VerifySchema`
- `LoadCurrent`, including `LoadVersion` and `LoadMembers`
- canonical snapshot hash validation
- desired-membership construction

Only a completely validated desired roster transitions to `STARTING`. Every error transitions to `INVALID_FAIL_CLOSED`. The fake store records the state observed during both database calls, and both fresh unit runs assert the required sequence.

## Account-lock policy

The baseline realmd path reads `account.locked` and uses its flags for IP/PIN/TOTP authentication decisions (`src/realmd/AuthSocket.cpp`, beginning at lines 463 and 490). Internal RNDBOT sessions do not execute the client authentication handshake, so silently ignoring those flags would create an undocumented bypass.

R2 therefore adopts the conservative policy: before `AddPlayerBot`, a roster GUID must resolve to a character and account, the account must belong to configured RNDBOT stock, must not be banned, must have a login row with `active=1`, must have `locked=0`, and must not already have a registered session. Any nonzero lock value yields deterministic `ACCOUNT_LOCKED`, `DEGRADED`, backoff, and no replacement bot.

## Organic runtime and grouped-bot protection

The B-R1 blanket early return from the persistent `ProcessBot` path was removed. R2 applies a value-based runtime policy:

- suppressed for roster members: lease/`add.validIn` logout, population rotation, random replacement, `RandomizeFirst`, level/gear/skill/progression randomization, change-strategy relocation, random teleport, automatic group removal;
- preserved: `ClearExpiredValues`, ordinary Playerbot AI execution outside this manager, strategy maintenance not tied to random reset, travel/idle AI behavior, revive/session maintenance, login retry with bounded backoff, and safe update scheduling.

Grouped roster bots cannot enter the rotation logout branch and cannot enter the randomize/teleport branch. The change does not alter `WorldSession.cpp`, `Group.cpp`, or general group semantics. `MASTER_LOGOUT_GROUP_PERSISTENCE` remains out of scope.

## Administrative path

The compiled manager handler exposes the roster `status` and `apply` verbs only through the local `mangosd` console context. A session-backed handler is classified as game chat and rejected; a no-session handler with a nonzero account ID is classified as remote administration and rejected.

Apply admission requires the feature/service, `MaintenanceMode=1`, and zero online roster GUIDs, checked both from service state and actual manager-held bot objects. A successful atomic commit returns `APPLIED_RESTART_REQUIRED` and moves admission to `INVALID_FAIL_CLOSED` until an explicitly authorized restart reloads the new snapshot. There is no live partial reconciliation.

The request reader requires an absolute, regular, non-reparse path; checks each existing component; enforces a 1 MiB bound; performs an exact binary read with EOF/size-change checks; and then requires byte-canonical request parsing. Unit tests cover transport, maintenance, online rejection, restart-required closure, a valid canonical file, and invalid file forms. No game-chat command or live console command was executed.

## Tests and build

- fake/unit run 1: `PASS`
- fake/unit run 2: `PASS`
- real adapter/MariaDB final run 1: `PASS`
- real adapter/MariaDB final run 2: `PASS`
- static allowed-scope gate: `PASS`
- `git diff --check`: `PASS` (only Git line-ending notices; no whitespace error)
- clean `Release/mangosd`: `PASS`

Build identity:

- candidate EXE SHA-256: `965CBEA7EDA8CC28EAFD8E9DCEB58187B167563B2644699B23B0C9FD47967679`
- candidate EXE size: `20,460,544` bytes
- candidate PDB SHA-256: `4E5EE6FF1C99012B9282F923249040B1885F43DAA599863338B2A64CB9DC0A80`
- candidate PDB size: `212,553,728` bytes
- CMakeCache SHA-256: `52296309A3F70B4C935CB10D322FB02D2F498C391BEDCBD2E92A9F722EE490A3`
- embedded core revision reported at configure: `42b8a7f742548793910f`

The build used Visual Studio 17 2022 x64, MSVC 19.44.35228, Windows SDK 10.0.26100.0, Boost 1.92.0, `BUILD_PLAYERBOTS=ON`, and the adapter test option disabled for the production candidate. Warnings are the pre-existing G3D narrowing and `httplib` nodiscard warnings; no R2 compile error remained.

## Scope and production preservation

The static gate found exactly 28 allowed source/config-template/migration/test files and no unexpected path. Generated isolated `bin` files are inventoried separately. `WorldSession.cpp` and `Group.cpp` were not changed. No LLM, Ollama, bridge, whisper or Phase-C work was resumed.

The before/after production audit proves:

- production HEAD unchanged;
- the full production `git status --short --untracked-files=all` identical;
- all four pre-existing modified source files and six untracked PDBs identical by size and SHA-256;
- production `mangosd.exe` unchanged at `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC`;
- active `mangosd.conf` unchanged at `C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D`;
- active `aiplayerbot.conf` unchanged at `490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF`.

No production database/config was used, port 3307 was not accessed, no candidate was started, no bot logged in, no game chat was sent, and nothing was deployed.

## Gate

This package authorizes no deployment or Phase C. The next state is:

`PHASE_C_GATE=AWAIT_B_R2_PACKAGE_AUDIT`

