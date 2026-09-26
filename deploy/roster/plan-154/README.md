# Base roster 154, twow-repo#366 part 5

**Planning data only.** Owner decision 2026-09-26: base roster **154 now** (with train 6 and
the level-1 reset; more than 154 only after the 7-day measurement). Per faction
77 = **10 tanks / 20 healers / 47 DPS**.

| File | Content |
|---|---|
| `v4-154-roster-plan.csv` | 154 rows; 1–136 = plan v3 (`../expand-272/v4-272-roster-plan.csv`) byte for byte, 137–154 = 18 new |
| `select_roster_v4_154.py` | deterministic generator (stdlib only) |
| `new-18-names.tsv` | names for 137–154 from the owner-approved list (`run-rename-roster.sh` format) |
| `expand-request-v3-to-154.txt` | canonical EXPAND request (A2) for `rndbot roster apply` |

## The 18 new bots

Alliance +5 healers, Horde +5 healers and +8 DPS. Owner requirement: spread over class, race
and gender, no clusters. Each slot takes the (race, gender) that does not repeat a class +
race + gender among the new bots and is rarest in the faction's role, then race, then class.
Only one repeat is unavoidable: Horde druids exist only as tauren (2 genders) and the plan has
three new Horde druids (restoration, balance, feral).

Result over 154: tanks 20, healers 40, DPS 94; 4 bears (specNo 4); professions
HA 31, TE 28, SL 28, MB 18, ME 15, MJ 12, pair 7 22 (the owner shares, rounded).

## EXPAND request (for the owner's go)

- `operation_id` = `62e0df47-6a5a-4a72-9684-5225005fb606`
- `request_sha256` = `bc07653732c51d1c199e604a9f356f3df7ead9a67c304d0b4170abc5bf2f726b`
- `expected_current_version_id=3`, `requested_target_count=154`, 18 `add` rows = ordinals 137–154.

## Reproduction

```sh
python3 select_roster_v4_154.py --base ../expand-272/v4-272-roster-plan.csv \
    --pool free-pool-snapshot.tsv --out v4-154-roster-plan.csv
```

Pool snapshot as for plan v3 (SHA-256 `8EB3F994…8183`, `evidence\ws-60\ob40-366-roster-272-selection\`).
Same inputs, same output. The 272 plan remains the basis for a later expansion (308).

## Rollback guard (train 6)

**Stage 1, roster only (no progress loss):** `rollback-request-v4-to-v3.txt`, a canonical
ROLLBACK request built by `../expand-272/make_rollback_request.py`:
`operation_id = f5476697-5ec8-4619-8356-807f85f66a14`,
`request_sha256 = b31512ba6120108fc7e9e5b704eeb6346919a6b0611977f0e63b44bbed4071a9`,
`expected_current_version_id = 4`, `rollback_version_id = 3`, `requested_target_count = 136`.
The core creates a new version with exactly the members of version 3 (ordinals 1–136);
bots 137–154 stay offline, and every character keeps its progress. Same path as the EXPAND:
`AiPlayerbot.PersistentActiveRoster.MaintenanceMode = 1`, world start without bots, local
console `rndbot roster apply <absolute path>`, stop, normal start. About 6–8 min.

**Stage 2, last resort only (failed apply):** restore the cold backup taken before the
maintenance. It resets the whole database to that moment, including player progress.
