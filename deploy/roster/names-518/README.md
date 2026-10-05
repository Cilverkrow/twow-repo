# RP names for the roster bots (twow-repo#518)

Owner approval of list v2.2 on 2026-10-04 ("okay so ist witzig", relayed by OB-00 in #518).
Planning data: nothing here changes a database by itself.

| File | Content |
|---|---|
| `rp-names-810.tsv` | the approved list for all stages up to 810: ordinal, guid (planned), race, class, gender, role, current name, **first name**, **surname (addon only)**, surname source, status (KEEP/NEW) |
| `rename-train9-v6-180.tsv` | **A5 mapping for train 9**: the 132 existing roster bots (v6, ordinals 1–180) whose name changes; format `ordinal guid old_name race class gender new_name`, no header; sha256 `f67e003519c9ceb190fb61e74a0def0c43f7a6990562fab01791b8667ed88cf9` |
| `addon-surnames-810.tsv` | first name → surname for the BotMenu addon (OB-15); the surname never goes into `characters.name` |
| `make_rp_names2.py` | generator of the list (deterministic) |
| `npc_surnames.py` | surname candidates from NPC names of each race (race via the NPC display in the client DBCs) |
| `origin_places.py` | "of <place>" origins from AreaTable.dbc (English client names) |
| `ob50-names-*.md`, `syllables.tsv` | OB-50's name patterns and syllables (self-formed, no copied texts) |
| `npc-surnames.tsv`, `origins-clean.tsv`, `blocklist.txt`, `reserve-first.tsv`, `keep-all.txt` | the inputs used for v2.2 |

**Rules:**
- First name = character name: `^[A-Z][a-z]{1,11}$`, no letter three times in a row, unique, not a character name or `ai_playerbot_names` entry, not on the lore block list.
- Surname: every surname exactly once over all 810.
- 48 current names are kept (KEEP): our earlier race-style names + Gwendolyn.
- Re-checked on 2026-10-04 11:27Z against a live read-only snapshot of all character names + `ai_playerbot_names`: 0 collisions.

**Not in Git:**
- client DBC files (CreatureDisplayInfo, -Extra, AreaTable; read-only copies under the OB-40 evidence);
- the taken-names snapshot (contains player names);
- the live roster snapshot.

They live in `evidence\ws-60\ob40-518-roster-800\` on Y:.

**Train 9 window:** with the world stopped, after the cold backup, the existing bots are renamed:
```bash
deploy/roster/rename/run-rename-roster.sh --container <db> --map deploy/roster/names-518/rename-train9-v6-180.tsv \
    --expect-map-sha256 f67e003519c9ceb190fb61e74a0def0c43f7a6990562fab01791b8667ed88cf9 --expected 132 --conf <mangosd.conf> --apply
```

**The 90 new bots (181–270):** their names are fixed per ordinal in `rp-names-810.tsv`. The A5 mapping for them is built in the window after the factory run, from the real GUIDs and pool names, with its own hash.

**Rollback:** cold backup (A5 refuses reverse mappings by design, since the old pool names are in `ai_playerbot_names`).

**Train 10 (#379, new race/class pairs):** names come as an extension **before** the factory run, under the same rules (unique against all first and last names here, English "of <place>"). The owner gets the extension list first.
