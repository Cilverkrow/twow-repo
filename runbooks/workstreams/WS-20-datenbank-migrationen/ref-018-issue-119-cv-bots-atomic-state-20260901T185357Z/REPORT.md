# REF-018 Issue 119 implementation evidence

## Scope

This evidence records the local implementation and disposable-database verification for issue #119. It covers only the PlayerBot event store, its `cv_bots` schema foundation, its forward-only copy migration, and its atomic runtime write path.

The implementation does not access or change the production database, does not connect to port 3307, does not change active configuration or executables, and does not start `mangosd` or `realmd`. The source snapshot is dated evidence and is not treated as proof of current production state.

## Provenance

- Repository: `Cilverkrow/twow-repo`
- Pinned base: `a82415e7e21143a75e7527f9b4767dec9e156375`
- Feature branch: `fix/issue-119-cv-bots-atomic-state`
- Phase A commit: `7795858a514827a91c134d8ddacb779756f3da94`
- Data-quality gate commit: `283edad5f7aaec88b333c853032b49acdab9346e`
- Data-quality manifest SHA-256: `5C930F18DCE577ABAF83AC75FCB01AAF4AE67E0FDD047043F0E384922AC4D285`
- Verified dated source dump SHA-256: `97E509C87B40CE44DCA0D0EF11CC665A4329DBF9070DAFD902EB952B22BADE22`
- Source snapshot rows: `178`
- Source logical rowset SHA-256: `9501380861D30849F034CF8910F79580601FE5DFFDCB938C50ED0BB69CE094B3`
- PR #131 reference head, inspected read-only: `d9d805debcf74118727a7eb01af883b2440f2ee6`

## Implementation

The bootstrap foundation creates `cv_bots`, grants the existing application database user least-privilege access to it, and runs PlayerBot module migrations as a strict migration stream. The runtime continues to use `CharacterDatabase`; the cross-schema target is fully qualified and supported by the explicit grant, so no core seam or second global database object is required.

The forward migration creates `cv_bots.ai_playerbot_random_bots` with eight validated columns, InnoDB storage, `event NOT NULL`, and a unique BTREE key on `(owner,bot,event)`. It rejects invalid source values, duplicate source keys, target-only rows, and conflicting target payloads. It copies all eight payload columns and then validates equal counts, bidirectional anti-joins, ordered fingerprints, and logical rowset hashes. It never updates, deletes, truncates, renames, or drops the source table.

The runtime event-store target is defined once in `PlayerbotDatabaseContract.h`. A nonzero event value uses one prepared `INSERT ... ON DUPLICATE KEY UPDATE`; deletion uses one prepared `DELETE WHERE owner=? AND bot=? AND event=?`. `SetEventValue` owns the serialized transaction lane derived from the full event key. No `REPLACE` operation or unbounded retry is used. Database failures remain visible through server logging.

The maintained reset and delete helper SQL files now target the same qualified table and preserve the same upsert/delete semantics. A static test scans module source and the maintained helper SQL files for new writes to the legacy table.

## Disposable verification

The final evidence source was `C:\TW\disposable-evidence\ref018-issue119-final-20260901T185357Z`. Raw logs, fixture rows, credentials, database files, and dump content are deliberately not included here.

The isolated MariaDB instance used port 33319 with `--no-defaults` and a private data directory. Two complete positive suites passed. Each suite performed a fresh migration, exact schema verification, 178-row copy verification, migration replay, a second exact verification, same-key and different-key adapter contention, precise deletion, cleanup of only test rows, and final source/target equality verification.

Both suites reported:

- same-key writes: `4000`, failures: `0`
- different-key writes: `6400`, failures: `0`
- deadlock 1213 count: `0`
- duplicate 1062 count: `0`
- precise delete: `PASS`
- source and target rows: `178`
- source and target logical SHA-256: `9501380861D30849F034CF8910F79580601FE5DFFDCB938C50ED0BB69CE094B3`
- source-to-target anti-join count: `0`
- target-to-source anti-join count: `0`
- unique key: `uq_owner_bot_event|0|BTREE|owner,bot,event`

The NULL event, empty event, duplicate source key, and conflicting target payload cases each failed closed with a nonzero database-client result. The disposable instance shut down cleanly, the disposable port closed, and the private data directory containing temporary credentials was removed.

## Build and static verification

- Generator: Visual Studio 2022 Build Tools 17.14.39, MSVC 19.44.35228
- Configuration: Release
- Module target: `mod_mod_playerbots`
- Contract test target: `playerbot_event_store_contract_tests`
- Database adapter target: `playerbot_event_store_database_tests`
- Module output: `C:\TW\builds\issue-119-event-store-clean3\modules\Release\mod_mod_playerbots.lib`
- Core seam: not required

The Release targets built successfully. Warnings were pre-existing C4838 conversions in `dep/src/g3dlite/System.cpp`, pre-existing C4834 discarded `nodiscard` results originating from `src/shared/httplib.h`, and CMake's CMP0167 Boost policy warning. No compiler warning or error originated in the new files.

The contract test and legacy-write guard passed twice. The database adapter integration ran twice in each disposable suite. PowerShell 5.1 parsed the disposable runner without errors. The modified Compose shell passed `bash -n`; the Helm embedded shell was extracted and passed `bash -n`. No new standalone shell script was added, and ShellCheck was not installed locally. `git diff --check`, targeted secret scanning, binary/size scanning, scope scanning, and the legacy-write guard passed.

## Scope boundaries

The source-to-target inventory contains 15 independently defined PlayerBot objects. Only `ai_playerbot_random_bots` is moved now. Ten older name, strategy, store, and cache objects are excluded because issue #119's accepted implementation scope is the event state and moving them would create unrelated runtime cutovers. The four persistent-roster tables are fully mapped but remain out of scope because Roster Phase C is explicitly not authorized.

ADR-0036 could not be found in any fetched local or remote repository ref. Consequently, this branch contains no profession assignment, skill learning, gathering, crafting, self-equipment, trading, or profession dialogue change. The missing repository artifact is recorded in `ADR-0036-BOUNDARY.md` and does not block the event-store work.

## Cutover prerequisites

A production cutover remains unauthorized. It requires a separately approved fresh production snapshot, a repeated fail-closed data-quality gate, a final decision and migration plan for all four roster objects, verified final target DDL, exact copy equality, an approved backup and rollback procedure, explicit apply authorization, and a new deployment review. The dated 178-row snapshot must not be used as proof of production freshness.
