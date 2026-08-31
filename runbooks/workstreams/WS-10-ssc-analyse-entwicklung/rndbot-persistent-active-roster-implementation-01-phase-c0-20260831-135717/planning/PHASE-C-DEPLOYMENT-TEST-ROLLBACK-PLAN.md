# Phase C deployment, verification and rollback plan

Status: planning only. Nothing in this document authorizes Phase C, a migration, a config edit, a process action, a bot login or a deployment.

## Preconditions and immutable pins

Phase C may start only after a separate authorization and explicit approval of the exact 50 sorted Character GUIDs, roster snapshot SHA-256, canonical INITIALIZE request bytes and request SHA-256. Reverify the B-R2 ZIP, candidate EXE/PDB, production EXE and both active config hashes. Confirm the installed executable and config paths are ordinary files, the backup names do not exist, `realmd` is stopped, `mangosd` is stopped, MariaDB remains at `127.0.0.1:3307`, and the LLM bridge/Ollama are outside the procedure.

## Backup gate

1. With `mangosd` and `realmd` stopped, create new, non-overwriting backups of the production `mangosd.exe`, `mangosd.conf` and `aiplayerbot.conf`; hash every source and backup and require equality with the pinned values.
2. Create a full pre-C logical backup of `tw_char` with tables, triggers, routines, events and binary data preserved. Record tool version, exact redacted command, size and SHA-256. Do not use a live mutable snapshot.
3. Restore that backup into a fresh disposable MariaDB instance and verify table counts plus a deterministic schema/data inventory before accepting it as rollback evidence.
4. Capture read-only `tw_logon` eligibility evidence for the approved 50, but do not mutate Login DB. Abort if any account has changed eligibility.

## Migration and bootstrap gate

1. Apply only the audited B-R2 Character-DB migration. Verify its expected schema fingerprint and record every statement/result. No unrelated migration is allowed.
2. Install only the pinned candidate EXE after preserving the production EXE under the verified unused backup name. Hash the installed candidate.
3. Make the smallest audited config delta: `AiPlayerbot.PersistentActiveRoster.Enabled = 1`, `AiPlayerbot.PersistentActiveRoster.MaintenanceMode = 1`, and require `AiPlayerbot.AsyncBotLogin = 0`. Preserve a byte-exact pre-change copy and a reviewed patch. No other value changes.
4. Start only `mangosd`. In the no-current state require `INVALID_FAIL_CLOSED`; the factory/top-up path must remain closed. Keep `realmd` stopped, perform no player login and verify no bot has been admitted.

## Canonical INITIALIZE apply

1. Rehash the pre-approved request file and require its pinned request SHA-256. Revalidate lowercase canonical UUIDv4, operation type `INITIALIZE`, `expected_current_version_id=null`, target/add counts 50, sorted explicit GUID list, zero remove/replace and `rollback_version_id=null`.
2. From the local original `mangosd` console only, run `rndbot roster status`, then `rndbot roster apply <absolute-request-file>`. Do not use RA or game chat.
3. Require exactly `APPLIED_RESTART_REQUIRED`. A replay with the same operation ID/hash is not part of live Phase C unless separately authorized. Admission must remain closed until restart.
4. Read-only verify Current pointer, version, 50 contiguous ordinals, unique GUIDs, member_count, before/after hashes and one matching audit operation. Abort on any deviation.
5. Gracefully stop `mangosd` from its original console. Do not use the broken shutdown helper.

## Normal-mode start and acceptance

1. Change only MaintenanceMode from `1` to `0`; keep Enabled `1` and AsyncBotLogin `0`. Hash and record the final candidate config.
2. Start only `mangosd`; keep `realmd` stopped until the initial status is stable. Require the audited candidate revision, accepted Character schema, full World initialization and listener `0.0.0.0:8090`.
3. Require desired=50 and the exact approved ordered GUID vector. Inventory available and online separately. A missing/failed member must yield `DEGRADED`, never a replacement.
4. After the approved login window, require online GUID set equals the approved 50, with no foreign GUID. Only then may a separately controlled login window be considered.
5. Gracefully stop and start a second time. Require exactly the same desired set, snapshot SHA-256 and online GUID set. No new roster operation may appear.
6. Keep one explicitly approved roster bot in a real-player group during normal play. Observe beyond all relevant legacy rotation/lease deadlines. Require no lease/population logout, no group removal, no randomization and no automatic group teleport. Intentional real-player master logout semantics remain out of scope.
7. Throughout observation, periodically compare desired, available and online sets. Any missing GUID yields `DEGRADED`; no foreign GUID or automatic replacement is permitted. LLM bridge, Ollama, whisper tests and game-chat administration remain excluded.

## Failure handling and full rollback

At any gate failure: stop the candidate gracefully if it is running; keep `realmd` stopped; collect logs without troubleshooting in scope. Restore the exact pre-C `tw_char` backup, not merely a table-drop migration, so the Current pointer, roster tables and all runtime data return to the captured point. Restore the original `mangosd.exe` and both config files from verified backups, then rehash against the production pins. Verify the pre-C schema/data inventory and that no roster tables remain if they were absent before C. Leave services stopped and require a separate decision before starting the restored production server.

The migration rollback script is a secondary schema-only option; it is not a substitute for the verified full Character-DB restore. Login DB is never written. LLM artifacts are never deployed or invoked.

