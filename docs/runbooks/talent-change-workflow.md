# Runbook: change talents (new talents, new spells, trainer spells)

Status: 2026-10-02, from trains 8, 8b, 9 and patches v4/v5/v7 (#295, #357, #367, #409, #455).
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
| R3 | **Talent.dbc has the same content on server and client** (same IDs, all fields equal); the byte order of the records may differ, because the server loads by ID. The server copy comes from the `server-dbc/` output of a clientpatch build; a content change goes to both in the same window. A pure reorder (R9) is client-only. Check: same ID set and fields, as `builds\ob15-clientpatch-v5\verify_v5.py`. | Server and client disagree on ranks and positions otherwise (#409). Patch v5 (#455) reordered the client file only; the 8b server copy `7072ee1e` stayed. |
| R4 | **At most 30 talents per tree** (talent frame buttons, patch v4). The build enforces it. More needs a new `[ui] talent_buttons` and a new patch. | Turtle's frame had 20 buttons; 26 talents showed an incomplete tree (#455). |
| R5 | **Trainer teach spells: visual 107, target 0, interruptFlags 0** (the trainer casts), like every class teach spell. Never clone Turtle's 47312. Teach spells the player casts on themselves (profession recipes) need visual 222 **and** target 1 (self); a cast time is optional (Turtle's 47200–47341 are instant self-casts that work). Since hotfix 8.3 the server routes 222 + target 0 to the trainer cast, so a wrong clone no longer hangs, but R5 stays the rule for the data. | 47312 clones (visual 222, target 0) hung the player in a crafting cast, "Another action is in progress", money taken (#455, 61213–61220). |
| R6 | **`skill_line_ability.id` < 65536** (smallint unsigned; core contract `skill_line_ability_id_range_contract`, no `INSERT IGNORE`). New rows from the free value in section 2 (30300–30399 reserved for #295), checked before use. The old "spell − 60000" convention does **not** work for 61xxx spells (61221 − 60000 = 1221 collides with the base rows 1–7210). | IDs 90140+ were silently clamped by `INSERT IGNORE` (#219). |
| R7 | **DB and client changes go with a main train** (Ä15). Hotfix trains carry no migration. A client-only change (UI, tooltips with identical DBC data) may go with a hotfix train. | Release pattern Ä15. |
| R8 | **Nothing client-derived goes into Git** (DBCs, MPQs, Turtle interface files). The pipeline extracts them from the client at build time. | Both repos are public. |
| R9 | **Every talent tree is one contiguous record block in the client Talent.dbc.** `[record_order] Talent = "TabID"` makes the build put new rows directly behind their tree and stop if a tree is still split. Talent IDs need not be contiguous. | The client keeps one record range per tree: new rows at the end of the file hid the base talents of their tree (`GetNumTalents(Combat)` = 8 instead of 26, #455, fixed in patch v5). |

## 2. ID registry (keep this table current, in the same PR as the new IDs)

| Kind | Range | Used | Free from |
|---|---|---|---|
| Custom spells (player-facing and server-only) | 61002–65535 (behind Turtle's last spell 61001) | 61002–61007 Alterac item spells; 61101–61131 shaman stage 2 (61111 = old 90110, intentionally empty); 61141–61220 rogue kit, talents, helpers, poison ranks, recipes, trainer spells; 61221–61222 planned for #367 (Riposte Flow display MH/OH, train 9); **61300–61399 reserved for #295**: 61300–61303 riding ranks 225/300 and their teach spells, 61310 Blink cooldown passive | **61223** (up to 61299), then **61400** |
| Enchantments (SpellItemEnchantment) | behind Turtle's last 3059 | 3060–3063 Agitating Poison I–IV | **3064** |
| Talent IDs (Talent.dbc) | free IDs < 65536 (base max 476; 9011–9149 also free) | 9001–9010 shaman, 9150–9188 rogue | **9200** (check Talent.dbc) |
| SkillLineAbility row IDs | < 65536 (base rows 1–7210) | 30140–30211 rogue P-1/P-2; **30300–30399 reserved for #295**: 30300–30301 riding ranks | **30400** (check the client DBC and `skill_line_ability`) |
| Talent tree size | ≤ 30 per TabID | Combat 26, Enhancement 26, Assassination 23, Subtlety 23 | — |

The old 90001–90219 numbering is history (train 8b moved it by −28999,
`ops/clientpatch/tools/inputs/455-spell-renumber-8b.csv`). **Never reuse
90001–90219** (or any ID ≥ 65536) for spells (R1). The current free block is
confirmed by OB-50's ID range list (#455 issuecomment-5926452548).

## 3. Workflow

### 3.1 Design (owner + OB-10/OB-20)
- Talent list with tree, tier, column, ranks, prerequisites, tooltip numbers
  (design doc in `docs/design/`). Arrows only straight down or sideways.
- Count per tree after the change (R4).
- IDs from the registry (section 2), checked by OB-50 (R2), entered in the
  registry table in the same PR.

### 3.2 Server (OB-10, twow-core)
- **Migration** in `sql/database_updates/`: `spell_template` rows (clone a
  fitting donor, overwrite what differs), `spell_proc_event`,
  `skill_line_ability`, `npc_trainer` rows with R5 teach spells. IDs per R1/R6.
  - Tooltip variables in `description` / `auraDescription` (`$<spellid>s1`)
    must point at our own new IDs.
  - Scripts bind by `spell_template.script_name` (AuraScripts/SpellScripts are
    registered by name, not by ID).
  - `spell_chain` is empty for us so far (chains come from SLA and the DBC);
    only touch it when needed.
  - Items: `item_template.spellid_1..5`; poisons: enchantment IDs in
    `effectMiscValue1` (range from section 2).
- **Contracts:** `custom_spell_id_range_contract` (spell IDs < 65536, also C++
  constants and later migrations), `skill_line_ability_id_range_contract`,
  `trainer_teach_cast_contract` (R5, hotfix 8.3), plus scripts/C++ constants
  (`spell_*.cpp`, `FunserverRogueTalents.h`, SpecAura tables).
- **Premade generator:** `AURA_FIRST_SPELL` / `EXTRA_REAL_TALENTS` in
  `modules/mod-playerbots/tools/build_premade_specs.py`; regenerate the links
  with `--talent-classes <class>` against the **new server Talent.dbc**; only
  that class block in `aiplayerbot.conf.dist.in` may change.
  - Cross-check **before** the client build: simulate the old DBCs with the
    planned changes; the links must come out byte-identical where nothing was
    meant to change (8b: 390/390, simulated Talent.dbc byte-identical to the
    real v3). Then run `premade_specs_rate2`.
- **Dry run:** OB-40 clones the throwaway DB (current ledger + the new
  migration) and grants read access; never the live DB (no heavy queries live).
  - Apply the migration **twice** (replay safety).
  - Check: 0 spells ≥ 65536; every reference uses the new IDs (triggers,
    tooltips, trainer, SLA, procs, items).

### 3.3 Client (OB-15, `ops/clientpatch`)
- Spell rows: `tools/inputs/<issue>-spells.csv` → `tools/gen_spell_mirror.py`
  (every value `sql:spell_template.*`; the server is the source of truth).
- Mount spells (#295): `tools/inputs/295-mount-spells.csv` →
  `tools/gen_mount_spells.py` → `changes/Spell/0295_mount_spells.csv`
  (aura-32 value and buff text by mount family, values `sql:`; `--out`
  writes, `--check` compares). Change the input list and regenerate; never
  edit the delta by hand.
- Talents: `tools/inputs/<issue>-talents.csv` → `tools/talentdelta.py`
  (`--check`, and `--core <core checkout> --class <id>` against the core PR).
- SkillLineAbility / SpellItemEnchantment deltas by hand, values `sql:`.
- **v7 (#295), before building:** diff the key set of
  `changes/Spell/0295_mount_spells.csv` against the W2b IN list of the core
  migration `sql/database_updates/20261002212000_world.sql` (core commit of
  the dry-run clone and the train-9 pin, mounted read-only into the tools
  container):
  `python3 tools/gen_mount_spells.py --spells tools/inputs/295-mount-spells.csv --check changes/Spell/0295_mount_spells.csv --core <core checkout>`
  must print `MOUNTSPELLS=PASS` with `core=checked` (465 spells, 11 aura-32
  values, every buff text in the family the migration gives it). A spell the
  migration changes but the delta lacks keeps its old buff text in the client;
  fix the input list, regenerate, then build.
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
   `character_spell` / `character_aura` migrated, and changed enchantment IDs
   their `item_instance.enchantments` (OB-40, as in 8b). After the reset OB-10
   checks the talents against the expected prefix with the **new** server
   Talent.dbc (sample as in 8b, `tank_exact.py`).
4. Smoke, then OB-30 switches the Nostalgia catalogue to `patch-X-v<N>`
   **in the same window** (client and server must match), previous version kept
   as rollback.
5. Rollback = previous pin, previous server DBCs, previous catalogue, talent
   reset again.

### 3.5 Acceptance (owner, non-GM character)
1. Launcher: ⟳ in the Assets banner, restart the launcher (catalogue cache 7
   days), install version N, **restart the game fully** (not `/reload`).
2. Talent frame: every tree complete (base + new talents), no "Too many
   talents in talent frame!" popup. Count check in chat (open the frame once;
   tab 1–3 by OrderIndex):
   `/script DEFAULT_CHAT_FRAME:AddMessage("MAX="..tostring(MAX_NUM_TALENTS).." N="..GetNumTalents(2))`
   must show the expected number of talents of that tree (R4, R9). Lua errors
   are hidden by default: `/console scriptErrors 1` while testing.
3. Learn one new talent; buy one new spell at the trainer (no cast animation,
   no "Another action is in progress", money only on success).
4. **Log out and in again (relog):** talent rank and points unchanged, no
   foreign spells in the spellbook, the bought spell has the right name and
   can be cast from the action bar.
5. Talent reset at the trainer, relog: new talents gone, nothing foreign left.
6. Bots: a roster bot of each changed path has its talents as talents, none
   twice; `[SpecAura]` logs no grant/remove for the class.
