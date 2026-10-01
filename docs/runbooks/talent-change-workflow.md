# Runbook: change talents (new talents, new spells, trainer spells)

Status: 2026-10-01, from trains 8, 8b and patch v4 (#357, #367, #409, #455).
Owner decision 2026-10-01 (#409): talent trees will keep growing; this is the
fixed workflow. Server part: OB-10; client part: OB-15; data/roster: OB-40;
deploy: OB-30; release and approvals: OB-00.

Every rule below exists because breaking it has already cost us a release:
the reason is given next to it.

## 1. Rules

| # | Rule | Why (incident) |
|---|---|---|
| R1 | **Every spell a player can learn, see or cast has an ID < 65536.** New custom spells come from the free block behind the Turtle spells (section 2). | The 1.12 protocol sends spell IDs as uint16 in `SMSG_INITIAL_SPELLS`, `SMSG_SUPERCEDED_SPELL`, `SMSG_REMOVED_SPELL`. 90xxx arrived as `id − 65536` after a relog: wrong spells in the spellbook, talent frame out of step (#455, train 8). |
| R2 | **A new ID is checked against the client `Spell.dbc` (base, dbc → patch-9) and `spell_template`** before it is used, by OB-50. | A reused ID makes the client show the other spell's text and icon. |
| R3 | **Talent.dbc is one file for server and client.** The server copy is the `server-dbc/` output of the same clientpatch build; both change in the same window. | Server and client disagree on ranks and positions otherwise (#409). |
| R4 | **At most 30 talents per tree** (talent frame buttons, patch v4). The build enforces it. More needs a new `[ui] talent_buttons` and a new patch. | Turtle's frame had 20 buttons; 26 talents showed an incomplete tree (#455). |
| R5 | **Trainer teach spells: visual 107, target 0, interruptFlags 0** (the trainer casts), like every class teach spell. Never clone Turtle's 47312. Profession recipe teach spells that the player casts need visual 222 **and** target 1 (self) **and** a cast time. | 47312 clones (visual 222, target 0) hung the player in a crafting cast, "Another action is in progress", money taken (#455, 61213–61220). |
| R6 | **`skill_line_ability.id` < 65536** (smallint unsigned). Row ID convention: spell − 60000 was used for 90xxx; for the new block use a free range below 65536 and check it. | IDs 90140+ were silently clamped by `INSERT IGNORE` (#219). |
| R7 | **DB and client changes go with a main train** (Ä15). Hotfix trains carry no migration. A client-only change (UI, tooltips with identical DBC data) may go with a hotfix train. | Release pattern Ä15. |
| R8 | **Nothing client-derived goes into Git** (DBCs, MPQs, Turtle interface files). The pipeline extracts them from the client at build time. | Both repos are public. |

## 2. ID registry (keep this table current, in the same PR as the new IDs)

| Kind | Range | Used | Free from |
|---|---|---|---|
| Custom spells (player-facing and server-only) | 61002–65535 (behind Turtle's last spell 61001) | 61002–61007 Alterac item spells; 61101–61131 shaman stage 2 (61111 = old 90110, intentionally empty); 61141–61220 rogue kit, talents, helpers, poison ranks, recipes, trainer spells | **61221** |
| Enchantments (SpellItemEnchantment) | behind Turtle's last 3059 | 3060–3063 Agitating Poison I–IV | **3064** |
| Talent IDs (Talent.dbc) | free IDs < 65536 | 9001–9010 shaman, 9150–9188 rogue | **9200** (check Talent.dbc) |
| SkillLineAbility row IDs | < 65536 | 30140–30211 rogue P-1/P-2 | check the client DBC and `skill_line_ability` |
| Talent tree size | ≤ 30 per TabID | Combat 26, Enhancement 26, Assassination 23, Subtlety 23 | — |

The old 90001–90219 numbering is history (train 8b moved it by −28999,
`ops/clientpatch/tools/inputs/455-spell-renumber-8b.csv`).

## 3. Workflow

### 3.1 Design (owner + OB-10/OB-20)
- Talent list with tree, tier, column, ranks, prerequisites, tooltip numbers
  (design doc in `docs/design/`). Arrows only straight down or sideways.
- Count per tree after the change (R4).
- IDs from the registry (section 2), checked by OB-50 (R2), entered in the
  registry table in the same PR.

### 3.2 Server (OB-10, twow-core)
- **Migration** in `sql/database_updates/`: `spell_template` rows (clone a
  fitting donor, overwrite what differs), `spell_proc_event`, `spell_chain`,
  `skill_line_ability`, `npc_trainer` rows with R5 teach spells,
  `item_template` where items are involved. IDs per R1/R6.
- **Contracts:** custom spell IDs < 65536 (core contract), teach spells per R5,
  scripts/C++ constants (`spell_*.cpp`, `FunserverRogueTalents.h`, SpecAura
  tables).
- **Premade generator:** `AURA_FIRST_SPELL` / `EXTRA_REAL_TALENTS` in
  `modules/mod-playerbots/tools/build_premade_specs.py`; regenerate the links
  with `--talent-classes <class>` against the **new server Talent.dbc**; only
  that class block in `aiplayerbot.conf.dist.in` may change.
- **Dry run:** OB-40 clones the throwaway DB (current ledger + the new
  migration) and grants read access; never the live DB (no heavy queries live).

### 3.3 Client (OB-15, `ops/clientpatch`)
- Spell rows: `tools/inputs/<issue>-spells.csv` → `tools/gen_spell_mirror.py`
  (every value `sql:spell_template.*`; the server is the source of truth).
- Talents: `tools/inputs/<issue>-talents.csv` → `tools/talentdelta.py`
  (`--check`, and `--core <core checkout> --class <id>` against the core PR).
- SkillLineAbility / SpellItemEnchantment deltas by hand, values `sql:`.
- `export-sql` from the dry-run clone, then
  `clientpatch build --server-dbc <server data/dbc> --version <N>` twice
  (a/b byte-identical). The build stops on spell IDs > 65535, trees above the
  button count, changed Turtle interface files and consistency findings.
- Check like `builds\ob15-clientpatch-v3\verify_v3.py`: 0 changed foreign
  records, all references in `spell_template` and the client, server DBCs ==
  client. Hashes of `patch-X-v<N>.mpq` and `server-dbc/*` to OB-30.

### 3.4 Release (main train, OB-00 approves)
1. Merge core PR and clientpatch PR; pin.
2. Window (world stopped): migration; server DBC mount (OB-30); profile key
   `AiPlayerbot.SpecAura.TalentClasses` for talent classes.
3. **Talent reset** for the affected classes, bots **and** players
   (`deploy/roster/talent-reset --class <id> --spec-nos …`, first `--dry-run`,
   then `--apply`; OB-40). Players with changed spell IDs also need their
   `character_spell` / `character_aura` migrated (OB-40).
4. Smoke, then OB-30 switches the Nostalgia catalogue to `patch-X-v<N>`
   **in the same window** (client and server must match), previous version kept
   as rollback.
5. Rollback = previous pin, previous server DBCs, previous catalogue, talent
   reset again.

### 3.5 Acceptance (owner, non-GM character)
1. Launcher: ⟳ in the Assets banner, restart the launcher (catalogue cache 7
   days), install version N, **restart the game fully** (not `/reload`).
2. Talent frame: every tree complete (base + new talents), no "Too many
   talents in talent frame!" popup.
3. Learn one new talent; buy one new spell at the trainer (no cast animation,
   no "Another action is in progress", money only on success).
4. **Log out and in again (relog):** talent rank and points unchanged, no
   foreign spells in the spellbook, the bought spell has the right name and
   can be cast from the action bar.
5. Talent reset at the trainer, relog: new talents gone, nothing foreign left.
6. Bots: a roster bot of each changed path has its talents as talents, none
   twice; `[SpecAura]` logs no grant/remove for the class.
