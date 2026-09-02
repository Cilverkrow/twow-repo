# PR #131 interaction matrix

## Pinned read-only reference

- Pull request: `Cilverkrow/twow-repo#131`
- Inspected head: `d9d805debcf74118727a7eb01af883b2440f2ee6`
- Source branch mutation: none

| Area | PR #131 behavior | Issue #119 disposition | Integration action |
| --- | --- | --- | --- |
| Bootstrap failures | Makes database bootstrap failures visible | Retain | Preserve the general fail-fast behavior when rebasing or resolving overlap. |
| Migration hashing | Uses real migration content hashes and apply-before-register ordering | Retain | Keep strict content identity and registration after successful application. |
| Migration streams | Processes migration directories chronologically and reports missing inputs | Retain | Preserve the general stream handling; keep the PlayerBot module stream strict. |
| Legacy event index | Adds/checks nonunique `idx_owner_bot_event` on `tw_char.ai_playerbot_random_bots` | Retarget/discard as final architecture | Do not treat the legacy nonunique index as the post-cutover target. The target has unique BTREE `cv_bots.ai_playerbot_random_bots.uq_owner_bot_event`. |
| Smoke schema effect | Checks the old character-schema event table | Retarget | Final smoke assertions must validate the qualified `cv_bots` table, eight-column contract, `event NOT NULL`, and unique key. |
| Compose bootstrap | Changes `deploy/compose/db-init.sh` | Overlap | Preserve general PR #131 safety fixes, then retain #119 schema/grant creation and strict module-migration execution. |
| ADR and smoke documentation | Describes the legacy index behavior | Update after integration | State that the legacy index is transitional only and not the durable target architecture. |

## Overlapping paths observed at the pinned head

- `deploy/compose/db-init.sh`
- `docs/adr/ADR-0024-project-invariants.md`
- `modules/mod-playerbots/data/sql/characters/ai_playerbot_random_bots_index.sql`
- `sql/character_updates/20260708055500_ai_playerbot_random_bots_index.sql`
- `test/smoke/10-migrations.sh`
- `test/smoke/15-schema-effects.sh`
- `test/smoke/README.md`

## Safe integration order

1. Rebase or resolve PR #131's general fail-fast, hashing, registration, and directory-handling fixes without copying its branch wholesale.
2. Resolve `deploy/compose/db-init.sh` so `cv_bots` schema/grants and strict PlayerBot module migrations remain intact.
3. Remove or explicitly classify the legacy nonunique-index assertion as transitional.
4. Retarget final schema-effect smoke checks to `cv_bots.ai_playerbot_random_bots`.
5. Re-run the fresh, replay, negative, contention, and legacy-write-guard suites.

No change was made to PR #131, and no commit from it was cherry-picked.
