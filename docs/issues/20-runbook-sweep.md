# Open items recovered from runbooks/

Source: 2026-08-31 three-way sweep of `runbooks/` (1,299 files, 49 dirs) during OT-025.
An item is OPEN only where evidence names an unmet gate.

---
id: WS10-001
title: Decide and test MASTER_LOGOUT_GROUP_PERSISTENCE group semantics
workstream: WS-10
priority: p1
existing_ot: none
source: runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-analysis-01-package-closure-r1-20260830-223307/IMPLEMENTATION-CONTRACT-ADDENDUM.md
superseded_by: none
body: |
  **Problem:** a persistent bot still leaves a group when a real player logs out.

  **Why:** the roster (commit `3c2b931`) suppresses rotation-driven logout, but does not
  touch `WorldSession.cpp` or `Group/Group.cpp`. Normal logout cleanup still evicts
  machine-driven group members, and a two-member group disbands outright.

  **Status:** deliberately deferred by every roster phase
  (`MASTER_LOGOUT_GROUP_PERSISTENCE=AWAIT_SEPARATE_DECISION_AND_TEST`). Listed in
  OPEN-THREADS.md under "Deliberately separate decisions" with no OT id and no owner.

  **Decide:** keep current cleanup semantics, or add the module-neutral veto hook the
  analysis specifies.

  **If implementing:**
  - Touches `WorldSession.cpp`, `ScriptObjects.h`, `ScriptMgr.h/.cpp`; `Group.cpp` in test scope.
  - Skipping bot eviction alone is NOT enough — the two-member disband still fires.
  - Test surface: two-member groups, offline leader, LFG, instances, raids, server
    shutdown, re-login.
---
id: WS10-002
title: Apply the prepared 50-GUID INITIALIZE request in live Phase C
workstream: WS-10
priority: p0
existing_ot: OT-002
source: runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-implementation-01-phase-c0-20260831-135717/REPORT.md
superseded_by: none
body: |
  **What:** apply the validated 50-bot roster to the live server. Generated and verified,
  never applied.

  **Artifacts Phase C must re-verify byte-for-byte:**
  - Ordered snapshot: 1,169 bytes, SHA-256 `F43E15589953B06D89FA7A81B177736BA5120B52711AF1FD8821D38F5904D6E7`
  - Canonical request: 1,689 bytes, SHA-256 `904A0758CB864EF1C7D32B83643C821F1E8C761247010049A21466CBF1B49E0C`
  - Operation ID: `566f48aa-07e2-49d1-9ddb-e43d63c4e635`

  **State at capture (2026-08-31 15:23 UTC):** 0 active add rows, 0 active RNDBOTs,
  86 expired leases, 4,500 eligible stock characters.

  **Required sequence** (full detail in `planning/PHASE-C-DEPLOYMENT-TEST-ROLLBACK-PLAN.md`):
  1. Non-overwriting EXE and config backups against pinned hashes.
  2. Stopped-server `tw_char` backup, restored into a disposable MariaDB and inventoried —
     an unrestored dump is not rollback evidence.
  3. Apply the B-R2 character migration.
  4. Install the pinned candidate binary.
  5. Config delta only: `PersistentActiveRoster.Enabled=1`, `MaintenanceMode=1`, `AsyncBotLogin=0`.
  6. Local mangosd console only: `rndbot roster apply <abs-path>` — must return exactly
     `APPLIED_RESTART_REQUIRED`.
  7. `MaintenanceMode=0`, two graceful restarts, identical desired/online GUID sets.
  8. Observe grouped bots past all legacy lease deadlines.

  **Blocked on:** WS10-003 (explicit approval of the hashes above).
---
id: WS10-003
title: Record explicit user approval of the 50-GUID roster hashes
workstream: WS-10
priority: p0
existing_ot: OT-002
source: runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-implementation-01-phase-c0-20260831-135717/RESULT.txt
superseded_by: none
body: |
  **A decision, not engineering work.** The only thing between the prepared roster and
  Phase C.

  The user's GUID shortlist authorized *generating* the request. It did not authorize the
  resulting bytes. Phase C0 closes with `USER_ROSTER_APPROVAL_REQUIRED=YES`.

  **Needed:** explicit recorded approval of this exact triple:
  - Snapshot SHA-256 `F43E15589953B06D89FA7A81B177736BA5120B52711AF1FD8821D38F5904D6E7`
  - Request SHA-256 `904A0758CB864EF1C7D32B83643C821F1E8C761247010049A21466CBF1B49E0C`
  - Operation ID `566f48aa-07e2-49d1-9ddb-e43d63c4e635`

  **Two traps:**
  - Eligibility was snapshotted 2026-08-31 15:23 UTC. If approval is late, re-capture
    read-only `tw_logon` eligibility for the 50 and abort on any change.
  - A different GUID set needs a NEW operation ID. Reusing this ID with different content
    fails closed (`OPERATION_ID_REQUEST_MISMATCH`).
---
id: WS40-001
title: Retire or fix the Windows graceful shutdown helper
workstream: WS-40
priority: p2
existing_ot: none
source: runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-implementation-01-phase-c0-20260831-135717/planning/PHASE-C-DEPLOYMENT-TEST-ROLLBACK-PLAN.md
superseded_by: none
body: |
  **The repo contradicts itself about whether the Windows graceful shutdown script works.**

  - Phase C plan (newest operational doc): "Do not use the broken shutdown helper."
  - ADR-0006 (Accepted): lists `ops/windows/server/shutdown-tortoise-servers-gracefully.ps1`
    as passing evidence.
  - `DECISION-REGISTER.md`: "Graceful shutdown helper behavior has passed its controlled
    evidence run."
  - `ops/windows/server/shutdown_all.bat` still calls it.

  **The concrete failure is in LLM-007:** `WriteConsoleInput failed`, exit 1 after 0.598s,
  before `saveall` was ever delivered.

  **Scope reduced by ADR-0028.** Linux + Docker is now the deployment platform and Windows
  gets no quality-of-life work. On Linux this problem is already solved differently:
  `deploy/docker/entrypoint-mangosd.sh` holds a FIFO the server can always read and
  translates SIGTERM into an in-game `saveall` + `server shutdown 0`.

  **So the decision is not "fix it" but "which":**
  - Amend ADR-0006 and DECISION-REGISTER to record the helper as defective and
    unsupported, and rely on the container path; **or**
  - Fix it, only if the live Windows server must keep running until cutover.

  **Do not** leave the accepted ADR contradicting the operational plan. That is the actual
  defect here.
---
id: WS30-001
title: Fix or document the local MariaDB TLS credential gap for tooling
workstream: WS-30
priority: p2
existing_ot: none
source: runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-implementation-01-phase-c0-20260831-135717/evidence/DB-READONLY-ASSESSMENT.md
superseded_by: none
body: |
  **Problem:** every database tooling step silently runs unencrypted.

  - First client connection to the production MariaDB failed during TLS negotiation,
    before authentication or any SQL. stdout was 0 bytes.
  - Recorded cause: the local server does not present usable Windows TLS credentials.
  - Workaround in use: loopback-only retry with TLS disabled, credentials in an
    ACL-restricted temp option file.
  - FG-035 documents the symptom and the workaround, but nothing tracks a fix.

  **Decide one:**
  - Provision a usable server certificate for the local MariaDB (127.0.0.1:3307), or
  - Formally accept loopback-plaintext as policy in an ADR, and pin the exact client
    invocation so tooling stops rediscovering the failure.

  **Constraint:** do not change server TLS policy as a side effect of another task.
---
id: WS20-001
title: Add a unique constraint to ai_playerbot_random_bots (owner,bot,event)
workstream: WS-20
priority: p2
existing_ot: OT-006
source: runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-analysis-01-package-closure-r1-20260830-223307/evidence/TABLE-WRITE-SCAN.txt
superseded_by: REF-018
body: |
  **Superseded by REF-018. Do not add this constraint in place.**

  The original finding is valid: `ai_playerbot_random_bots` has only the non-unique
  `idx_owner_bot_event`, and `SetEventValue` relies on separate asynchronous
  DELETE-then-INSERT operations. The proposed location is no longer valid.

  `tw_char` is upstream-owned and read-only to project migrations under ADR-0021 and
  ADR-0024 invariant 2. Adding another project constraint there would deepen the
  architecture violation. UNIQUE alone is also insufficient while `event` remains
  nullable and the two writes can execute on different database workers.

  REF-018 owns the identity-preserving cutover to the project-owned `cv_bots` schema,
  the non-null unique event key, the atomic write primitive and its disposable-database
  proof. OPS-007 (#29) remains responsible for the deadlock-ordering evidence and the
  separately authorized strict runtime rerun. Never deduplicate or discard an existing
  event row automatically.
---
id: WS10-004
title: Make the real-database roster adapter suite runnable on demand
workstream: WS-10
priority: p2
existing_ot: OT-021
source: runbooks/workstreams/WS-10-ssc-analyse-entwicklung/ot-001-r1-provenance-aware-source-integration-20260831T192201Z/BUILD-IDENTITY.txt
superseded_by: none
body: |
  **Problem:** the strongest test evidence for the roster cannot currently be reproduced
  from this repo.

  `persistent_active_roster_database_tests` proved, against a real MariaDB:
  - `FOR UPDATE` locking and single-winner concurrency (exactly one `CURRENT_VERSION_MISMATCH`)
  - member/audit-insert rollback
  - 50 -> 100 append-only expansion

  **Blockers:**
  - Off by default (`BUILD_PERSISTENT_ROSTER_ADAPTER_TESTS=OFF`).
  - Requires an explicit external OpenSSL dependency runtime.
  - First launch hung because `ACE.dll` was not on the runtime search path.
  - The PowerShell harness that spins up the disposable MariaDB lives outside this repo.

  **Do:** bring a reproducible invocation into the repo — CMake option, required external
  OpenSSL/ACE runtime, and a disposable-MariaDB runner that refuses port 3307.

  **Unblocks:** OT-024 (100 -> 250 and 250 -> 500 expansion proofs). Feeds OT-021 CI scoping.
---
id: WS10-005
title: Resolve dead RandomBotLoginAtStartup and PinnedBots config keys
workstream: WS-10
priority: p2
existing_ot: none
source: runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-analysis-01-package-closure-r1-20260830-223307/evidence/CONFIG-EVIDENCE.txt
superseded_by: none
body: |
  **Problem:** two config keys imply behaviour that does not exist.

  - `AiPlayerbot.RandomBotLoginAtStartup` is loaded but has **no consumer** anywhere in
    the source. The active production config sets it to `1`, so an operator reading the
    config believes a feature is on that has no implementation.
  - `PinnedBots` is name-based and in-memory only (`PINNED_BOTS_ACTIVE=NO`). It was
    evaluated and rejected as a persistence mechanism.

  **Do — per key, pick one:**
  - Wire it to a real consumer, or
  - Remove it from `aiplayerbot.conf.dist.in` and the active config with a note, or
  - Document it as inert.

  **Why it matters:** mistaking either key for evidence of identity persistence is exactly
  the misreading that triggered the whole persistent-roster analysis.
---
id: WS10-006
title: Detect out-of-band SQL mutation of the persistent roster tables
workstream: WS-10
priority: p2
existing_ot: none
source: runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-analysis-01-package-closure-r1-20260830-223307/REPORT.md
superseded_by: none
body: |
  **Problem:** hand-editing the roster tables in SQL is undetectable.

  The design enforces its invariants **only inside the application transaction**:
  - singleton pointer `SELECT ... FOR UPDATE`, CAS on `current_version_id`
  - per-version SHA-256 before/after hashes
  - `member_count`, contiguous ordinal and uniqueness checks, `EMPTY_ROSTER_FORBIDDEN`

  On startup an inconsistent snapshot yields `INVALID_FAIL_CLOSED` with no auto-repair.
  But nothing distinguishes "someone ran UPDATE by hand" from a legitimately corrupt
  state. There is deliberately no FK from roster members to `characters.guid`, so a
  deleted character produces DEGRADED evidence rather than cascading away.

  **Do:**
  - Define the operational contract, e.g. re-hash the current version on startup (or
    periodically) against its stored snapshot digest.
  - Emit a distinct diagnostic for "hash mismatch without a matching audit operation".
  - Treat the alert as operations policy.

  **Constraint:** no automatic repair. There is no path from `INVALID_FAIL_CLOSED` back to
  `LOADING` without an explicitly authorized restart.
---
id: WS00-001
title: Refresh the WS-10 hub README, which still reports Phase B as BLOCKED
workstream: WS-00
priority: p2
existing_ot: OT-019
source: runbooks/workstreams/WS-10-ssc-analyse-entwicklung/README.md
superseded_by: none
body: |
  **Problem:** the routing entry point for roster work is four generations stale and will
  misdirect anyone who starts there.

  **Says:** `PHASE_B_RESULT=BLOCKED` (disposable MariaDB unreachable, WinSock 10061),
  "Phase C: AWAIT_SEPARATE_PACKAGE_AUDIT". Links only the phase-b directory.

  **Reality:**
  - Blocker cleared in B-R1 (24/24 tests) and again in B-R2.
  - Phase C0 passed.
  - OT-001 closed; commit `3c2b931` is on `main`.
  - True gate is now `AWAIT_SEPARATE_USER_APPROVAL_AND_TASK`.
  - None of phase-b-r1, phase-b-r2, phase-c0 or the three ot-001 dirs are referenced.

  **Do:** authorize a dedicated hub-update task (OT-019 — the hub is immutable outside
  one), append the newer directories, correct the stated gate, and regenerate
  `runbooks/workstreams/sha256-manifest.txt` in the same task.

  **Constraint:** append. Do not rewrite the historical phase-b entry.
---
