# SSC RNDBOT persistent roster – Phase C0

`PHASE_C0_RESULT=PASS`

The immutable package and production pins passed. After the dated SELECT-only snapshot found zero active leases, the user supplied an explicit, ordered 50-GUID shortlist through `evidence/ROSTER-CANDIDATES-SHORTLIST-50-from-expired.txt` and instructed C0 to continue with exactly those values. Every GUID matches the dated candidate inventory and the historical expired-add inventory with `base_eligible=1`.

## Verified inputs

The B-R2 ZIP has SHA-256 `D32453BE1F3283EFB3306E76F47E984CFB3228FB24AE814D04012C4B16C82088`, contains 109 ZIP entries, and its internal `SHA256SUMS.txt` has 107 records with zero missing or mismatched payloads. Candidate EXE and PDB match their pins. Production `mangosd.exe`, `mangosd.conf` and `aiplayerbot.conf` also match all supplied pins.

The first preflight at `2026-08-31T13:57:17Z` found `mangosd`, `realmd` and MariaDB stopped. After `MARIADB_READY=YES`, MariaDB was observed as user-started `mysqld` PID 46980 with the only port-3307 listener at `127.0.0.1:3307`; `mangosd` and `realmd` remained stopped. Ollama was not contacted. No production process was started, stopped or signalled by C0.

The active playerbot config still describes the legacy population: min/max 50, RNDBOT prefix, automatic creation and startup login enabled, Async login disabled. Because the timed-login keys are commented, the pinned source defaults are effective: timed logout true, timed offline false, and add leases from 1,800 through 21,600 seconds. The persistent-roster keys are absent and therefore remain at their source defaults of false. These facts were read only; no active config was changed.

## Exact selection interpretation

The legacy implementation loads current rotation members from `ai_playerbot_random_bots` rows where `owner=0` and `event='add'`. The event is active only while its nonzero value has not expired under `elapsed < validIn`. C0 therefore does not equate a stale add row, `characters.online`, account order or login order with membership.

The exact-50 gate requires 50 active add rows, 50 distinct GUIDs, all 50 mapped to existing non-deleted active characters and existing accounts whose username satisfies the configured `RNDBOT` stock prefix, `active=1`, `locked=0`, the legacy account banned flag clear, and no current/permanent active `account_banned` row. The last condition exactly matches the ban set loaded by the baseline `AccountMgr`; checking the legacy flag as well is a stricter C0 exclusion. Because `mangosd` must remain stopped for the snapshot, registered session status is deterministically absent. Duplicate add rows, foreign accounts, missing characters, deleted/inactive characters, inactive/locked/banned accounts and expired leases fail the gate. There is no trimming, filling or replacement.

If and only if all four counts are exactly 50, the GUIDs are sorted numerically and serialized using the R1 ordered-snapshot contract. A new lowercase canonical UUIDv4 is then used to form an unapplied `INITIALIZE` request with exact target/add count 50, no remove/replace rows, null expected/current rollback versions, UTF-8 without BOM and LF including the last line. Both SHA-256 values are reported in uppercase. Even then, user approval remains required.

## Read-only database result

`queries/READONLY-ROSTER-INVENTORY.sql` is the fixed SELECT-only inventory. Its SHA-256 is `B9CA0D9359EC4339D8DE9222DA64CEEAF6F4ADE8801B6CD217B409E3012A93CC`. The successful raw output is 702,698 bytes with SHA-256 `B7368DC8B39C1667B149EA3DCAC266A63149B8D7D134B54B1F701663F7B98530`; stderr is empty. The database timestamp is `2026-08-31 15:23:05.007923` UTC.

The exact counts are: zero active add rows, zero distinct active add GUIDs, zero active RNDBOTs, and zero eligible active RNDBOTs. There are 86 distinct historical add rows, all eligible as RNDBOT stock but all expired; their leases expired between `2026-08-30 21:30:11` and `2026-08-31 02:59:16` server time. The complete RNDBOT stock contains 4,500 characters, all passing the base account/character eligibility checks at this stopped-server snapshot.

The first client connection attempt failed during TLS negotiation before authentication or SQL execution: stdout was zero bytes and the error was preserved. A deliberate corrected loopback-only attempt disabled TLS, used a temporary ACL-restricted option file that was removed immediately, ran the identical query under a read-only session, and succeeded. There was no automatic query retry and no first-attempt database access.

`evidence/ROSTER-CANDIDATES.tsv` contains all 4,500 fully inventoried RNDBOT candidates. `evidence/EXPIRED-ADD-CANDIDATES.tsv` contains the 86 recently leased historical GUIDs with names, accounts, character facts, lease times, group state and eligibility. Neither list is a proposal; every row is marked as requiring explicit user selection.

## Deployment and rollback readiness

The complete planning-only sequence is in `planning/PHASE-C-DEPLOYMENT-TEST-ROLLBACK-PLAN.md`. It includes verified non-overwriting EXE/config backups, a stopped-server full Character-DB backup plus disposable restore proof, migration/schema gate, MaintenanceMode bootstrap, local-console-only apply, required `APPLIED_RESTART_REQUIRED`, normal restart, exact set comparison, graceful second restart, grouped-bot lease protection, foreign-GUID/replacement exclusion and full restoration of production EXE, configs and Character DB.

No Phase C action is authorized. In particular, the candidate was not installed or started, no migration or config delta was applied, no bot or game chat was used, and the LLM workstream remained paused.

## Explicit 50-GUID continuation

The adopted shortlist is 350 bytes with SHA-256 `A552DE67342DF7406213A040C68E801C20977BA8561173685CBD98B4B709004D`. It contains exactly 50 positive decimal GUIDs, strict numeric ascending order, no duplicate and a final CRLF. All 50 are present in both source inventories and remain base-eligible in the dated snapshot. No additional GUID was inferred, ranked or substituted.

The byte-exact ordered snapshot is 1,169 bytes with SHA-256 `F43E15589953B06D89FA7A81B177736BA5120B52711AF1FD8821D38F5904D6E7`. The canonical unapplied INITIALIZE request is 1,689 bytes with SHA-256 `904A0758CB864EF1C7D32B83643C821F1E8C761247010049A21466CBF1B49E0C`; its new operation ID is `566f48aa-07e2-49d1-9ddb-e43d63c4e635`. Independent reconstruction proved exact UTF-8-no-BOM, LF-only final newline, field order, 10-digit ordinals/GUIDs, UUIDv4, counts and hashes.

The generator outputs were not regenerated after creation. A post-generation orchestration check initially reported a false failure because it inspected a stale native `$LASTEXITCODE` after a successful PowerShell invocation; the reusable check now reads the immediate PowerShell success flag, and independent byte validation passed.

C0 is complete, but user roster approval remains required. The request has not been applied, the migration has not run, and Phase C/deployment remains gated by a separate task.
