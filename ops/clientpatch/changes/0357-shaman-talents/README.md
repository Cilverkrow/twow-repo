# Change 0357: shaman Enhancement talents as real client talents (stage 2)

Refs #357 (design `docs/design/shaman-tank.md`), #409 (pipeline; OB-00 brief
part B, issuecomment-5874183685). Server counterpart: Cilverkrow/twow-core#217.

The owner's Enhancement rework runs server-side since train 7: new talents are
bot auras 90100–90129 (core#187, SpecAura, core#192). Stage 2 gives **all
players** the real talents. The client patch adds the tree slots, the server
`Talent.dbc` gets the same rows, and the bot auras are switched off in the same
release.

**Principle:** the rank spells **are** the phase-1 aura IDs (design #410 §3.4).
The server rows stay, and the client gets `Spell.dbc` rows with the same IDs,
built from `spell_template`.

## Content

| File | Content |
|---|---|
| `Talent.csv` | 10 new rows in tab 263 (Enhancement), talent IDs 9001–9010 |
| `Spell.csv` | 39 `Spell.dbc` rows built from `spell_template` (90100–90139 without 90110), plus the description of Elemental Weapons 16266/29079/29080 (cap 13/27/40 %, CV-1) |
| `SkillRaceClassInfo.csv` | swords for shamans, talent-only (IDs 90043/90055 = core#217 `skill_race_class_info_mod`) |
| `base-cells.csv` | occupied cells of tab 263 in the base client (IDs and positions only; OB-20 read-out, #357 issuecomment-5857352559) |
| `code-values.md` | player-visible values that live in code (CV-1…CV-5) |

`TalentTab`, `SpellIcon`, `SpellDuration` and `SpellCastTimes` do not change:
all icons and indices are existing ones.

## The tree after the patch (tab 263, R = tier + 1, C = column + 1)

| | C1 | C2 | C3 | C4 |
|---|---|---|---|---|
| R1 | **Attack Speed 5** (9001) | Ancestral Knowledge 5 | Shield Specialization 5 | **Earthen Guard 5** (9002, defense) |
| R2 | Totemic Alignment 2 | Thundering Strikes 5 | Stable Shields 3 | Improved Ghost Wolf 2 |
| R3 | Calming Winds 3 | *(arrow Thundering Strikes → Flurry)* | Lightning Strike 1 | Ancestral Guardian 3 |
| R4 | **Imbue Mastery 3** (9003) | Flurry 5 | Spirit Armor 2 | **Retaliation 3** (9004) |
| R5 | Enhancing Totems 2 | Elemental Weapons 3 | Stormstrike 1 | **Charged Stormstrike 1** (9005, ← Stormstrike) |
| R6 | **Storm Wisdom 5** (9006) | *(arrow Elemental Weapons → Bloodlust)* | Element's Grace 5 | **Shield Constitution 3** (9007) |
| R7 | **Chain Storm 1** (9008, ↑ Storm Wisdom 5/5) | Bloodlust 1 | **Ancestral Arms 1** (9010, W) | **Shield Ward 1** (9009, ↑ Charged Stormstrike) |

`talentdelta.py`: layout PASS, one warning. The owner's arrow R5/C4 → R7/C4
passes over Shield Constitution (decision S2-2).

## Switch plan (one coupled release, world stopped)

**Preconditions:**
- core#217 merged and pinned;
- stage-1 tooling (CL-409) merged;
- `talentdelta.py --core core --class 7` PASS on the pin.

1. **Build (owner/OB-15, local):**
   - deltas → client `Talent.dbc`, `Spell.dbc`, `SkillRaceClassInfo.dbc` → `patch-X.mpq` version N, with sha256;
   - from the **same** build, the server's `Talent.dbc` and `SkillRaceClassInfo.dbc` for `data/dbc`;
   - `dbcdiff` `review.csv` lists exactly these rows.
2. **Premade links (OB-10):**
   - `build_premade_specs.py --dbc <patched dbc> --talent-classes 7` → new `PremadeSpecLink.7.*` for **all** shaman paths.
   - Why all paths: the links are position-encoded, and the new rows shift every Enhancement digit.
   - 7.1 gets 14 points and 7.3 gets 21 points in the new talents (what they paid for the auras), plus 1 each for W.
3. **Server (OB-30, release):**
   - core pin with #217 (migration applies itself);
   - patched `data/dbc`;
   - profile `AiPlayerbot.SpecAura.TalentClasses = 7` (SpecAura then no longer grants or removes 90100–90129 for shamans, and the paths pay nothing extra);
   - the new links;
   - all in the same pin/profile.
4. **Bots (OB-40):**
   - `deploy/roster/talent-reset/run-talent-reset.sh --class 7 --spec-nos 1,2,3,4 --dry-run`, then `--apply` with count and hash. This covers every roster shaman on every path, because every link changed.
   - At login `ResetTalents` removes all talent ranks of the patched tree, **including the granted 90100–90129** (now talent ranks). The bot then learns its new link.
5. **Players:**
   - **no reset**: the existing talent IDs and positions stay, and the new slots are free to learn;
   - without the patch the client shows the old tree (fail-closed) and cannot learn the new talents.
6. **Publish** patch N (Nostalgia catalogue, #410 §5).

**Rollback (together):**
- previous pin and previous `data/dbc`;
- `TalentClasses` empty and the old links;
- repeat the reset from step 4;
- republish patch N−1.

## Acceptance

- `review.csv` = exactly the rows of this change.
- **With the patch:**
  - the 10 slots are in the positions shown above with the right rank counts;
  - the tooltips show the server numbers (Elemental Weapons cap 13/27/40 %, CV-1 … CV-5);
  - learning each new talent on a test character gives the right spell server-side;
  - inspect from a second patched client shows the right points.
- **Ancestral Arms:**
  - swords and the sword skill are available, and still there after a relog;
  - a weapon master still refuses swords to a shaman without the talent;
  - extra attack and crit apply only with the matching weapon;
  - a talent reset removes all of it.
- **Bots:**
  - before and after, a 7.1/7.3 bot has each effect **once**: the talent rank, never talent plus aura;
  - no `[SpecAura] state=grant` or `state=remove` for shamans after the switch.
- **Without the patch:** old tree, no crash.

## Open decisions (owner / OB-20)

| # | Question | Recommendation |
|---|---|---|
| S2-1 | Slot of W. Of the free cells only **R7/C3** is clean: R3/C2 and R6/C2 lie on the Flurry and Bloodlust arrows (`talentdelta.py` rejects them). R7 needs 30 points in the tree (level 40+) | R7/C3 |
| S2-2 | Shield Ward's arrow from Charged Stormstrike (R5/C4 → R7/C4) passes over Shield Constitution (R6/C4) | require **Shield Constitution 3/3** instead: a clean arrow in the same column; the owner's intent "tank column builds up" stays |
| S2-3 | Chain Storm needs Storm Wisdom at which rank? | 5/5 (as in the delta) |
| S2-4 | IDs: talents 9001–9010, SkillRaceClassInfo 90043/90055 | OB-20 checks once that they are free in the base DBCs |
| S2-5 | Charged Stormstrike hangs sideways off Stormstrike (R5/C3 → R5/C4) | check in game that the talent frame draws the sideways arrow; otherwise drop the prerequisite |
| S2-6 | Names (Attack Speed, Earthen Guard, Imbue Mastery, Retaliation, Charged Stormstrike, Storm Wisdom, Shield Constitution, Chain Storm, Shield Ward, Ancestral Arms) | the owner may rename; the names are in `spell_template` (core) |
| S2-7 | Bot equipment for swords (`CanEquipWeapon`, `InitSkills`, `RandomItemMgr`) | OB-10 follow-up; without it bots take W but no swords |
