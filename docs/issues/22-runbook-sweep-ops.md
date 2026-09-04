# Open items: bot population, donation, professions, operations

---
id: OPS-001
title: Run a read-only DB capture to unblock the bot population matrix
workstream: WS-30
priority: p1
existing_ot: none
source: runbooks/playerbot-discovery-matrix-preflight-02-20260830-173815/report.md
superseded_by: none
body: |
  **Blocker for four other issues.** The bot population analysis is complete except for
  two fields, and no production bot config can be generated until they exist.

  **Already proven:** source/config identity, the 59-vs-52 race/class pair matrix, 4,500
  RNDBOT stock, level histogram, professions, role mapping, and weighted allocation
  matrices for 50/100/500/1000.

  **Missing:**
  - `CURRENT_GROUP_LOGIN_CANDIDATE_COUNT` — the last group query is stale (all four group
    data/index files were written after it), so group candidates must **not** be assumed 0.
  - `STORED_SPECNO_DISTRIBUTION`

  **Capture (read-only, MariaDB only — do not start mangosd or realmd):**
  1. Current `owner=0, event IN ('add','login','specNo')` rows
  2. Current RNDBOT group members and leader account type
  3. Current `characters.online` flags (consistency evidence)
  4. Stored `specNo` distribution

  **Unblocks:** OT-007, OPS-004, OPS-006.
---
id: OPS-002
title: Fix two source defects before enabling fixed class/race bot counts
workstream: WS-10
priority: p1
existing_ot: none
source: runbooks/playerbot-discovery-matrix-preflight-02-20260830-173815/report.md
superseded_by: none
body: |
  **`ClassRace.UseFixedClassRaceCounts=1` is unsafe today.** Two bugs, independent of the
  allocation decision in OT-007.

  **Bug 1 — fixed mode reads the wrong array.**
  `PlayerbotLoginMgr::GetClassRaceBucketSize()` (`PlayerbotLoginMgr.cpp:732-742`) returns
  `classRaceProbability` even in fixed mode, instead of `fixedClassRaceCounts`. Any pair
  omitted from config then falls back to the implicit default probability 100.
  Currently inert only because `AsyncBotLogin=0` selects the legacy manager.

  **Bug 2 — unsigned underflow on zero.**
  `RandomPlayerbotFactory` (`RandomPlayerbotFactory.cpp:879-953`) copies every fixed-map
  entry into `remaining` and decrements only after creation. A valid entry with value 0
  can underflow the unsigned counter if a free character slot exists.

  **Consequences for any candidate config:**
  - Never encode explicit zero entries.
  - Give every effective valid pair an exact entry, so no inherited default survives if
    async login is later enabled.

  **Current numbers:** effective probability total across the 52 supported pairs is 2,483;
  at target 50 the legacy formula produces aggregate allowances of 83 while the global
  target still caps selection at 50 — a probabilistic cap, not an exact matrix.

  **Do:** a narrowly scoped source change with its own rollback point, before any
  fixed-count config is written.
---
id: OPS-003
title: Define how a stable bot cohort maps to class/race targets
workstream: WS-10
priority: p1
existing_ot: OT-002
source: runbooks/playerbot-discovery-matrix-preflight-02-20260830-173815/report.md
superseded_by: none
body: |
  **The "cohort" question — this is the one place it is written down.**

  The four planning matrices (`matrix-50/100/500/1000.csv`) assign per-pair target counts
  and an `add_deficit`, but explicitly **do not select GUIDs**. Nothing binds a stable set
  of characters to those targets.

  **Why the legacy system cannot do it:**
  - The manager shuffles candidate account order on every pass, so fixed counts control
    pair totals only, never identity.
  - Every login assigns a fresh `add` timer (1800–21600s default); expiry logs the bot out
    and the manager refills the target from a different bot. Grouped bots get a 120s
    deferral.
  - Level cap does not trigger replacement; `DisableRandomLevels=1`.

  **Current stock:** 4,500 characters across exactly 500 accounts (`RNDBOT0`..`RNDBOT499`,
  9 each), 53 stored `add` rows, 0 unexpired timers at capture, 0 online.

  **Partly answered already:** the persistent roster (commit `3c2b931`) solves *membership
  and identity*. It does not solve the *per-pair distribution* these matrices describe.

  **Do:** specify how a persistent cohort (50, then 100/250/500) is chosen, pinned and
  re-established across restarts without relying on rotation timers, then feed that into
  OT-002.

  **Constraint:** accounts are already full at 4,500/4,500 slots, so the factory cannot
  rebalance the existing pool by creating more characters.
---
id: OPS-004
title: Model bot tank/healer/DPS split once bots pass level 10
workstream: WS-10
priority: p2
existing_ot: none
source: runbooks/playerbot-discovery-matrix-preflight-02-20260830-173815/report.md
superseded_by: none
body: |
  **The current role split is a low-level fallback, not the real distribution.**

  All 4,500 bots are level 1–9 (4,382 of them level 1), so `AiFactory::GetPlayerSpecTab()`
  uses its deterministic low-level fallback rather than learned talents.

  **Resulting roles:** Tank 719, Healer 362, DPS 3,419.
  Spec mapping confidence is HIGH **only for this fallback**.

  **What changes at level 10+:** `AiFactory::GetPlayerSpecTabs()` walks Talent/TalentTab
  DBC rows, sums ranks for spells matched via `Player::HasSpell()`, and picks the
  highest-point tab. Note there is no `character_talent` table in this build; learned
  talent spells live in `character_spell`.

  **Do:**
  1. Get the stored `specNo` distribution from OPS-001.
  2. Model what the role split becomes past level 10.
  3. Decide whether premade spec selection should be steered rather than left to the
     fallback.

  **Blocked on:** OPS-001.
---
id: OPS-005
title: Decide bot profession pairing (gathering vs manufacturing)
workstream: WS-10
priority: p2
existing_ot: OT-009
source: runbooks/playerbot-discovery-matrix-preflight-02-20260830-173815/report.md
superseded_by: none
body: |
  **Separate from the 2-vs-6 profession cap in OT-009.** This is *which* professions bots
  get, and whether crafting professions are paired with the gathering profession that
  feeds them.

  **Current state across 4,500 bots — essentially empty:**
  - 4,491 have zero primary professions; 5 have one; 4 have two.
  - Totals: Blacksmithing 1, Leatherworking 1, Alchemy 2, Herbalism 5, Mining 3, Skinning 1.
  - Secondary: First Aid 5, Cooking 3, Fishing 4, Survival 4.
  - Exactly **one** bot has a complete pair (Alchemy + Herbalism).
  - Three orphans: Alchemy without Herbalism, Blacksmithing without Mining, Leatherworking
    without Skinning.
  - Engineering, Jewelcrafting, Enchanting, Tailoring: learned by nobody.

  **Two traps:**
  - The classic factory branch substitutes Herbalism/Skinning where other builds pick
    Jewelcrafting/Mining — so Jewelcrafting is player-available but never bot-selected.
  - `PlayerbotFactory.cpp:4119-4125` **removes** factory-listed skills whose value is
    exactly 1 on refresh. Naive provisioning will be silently undone.

  **Do:** decide the pairing policy, implement it in the factory (not by direct SQL), and
  design the test around that value-1 refresh cleanup.
---
id: OPS-006
title: Bound bot grouping lifecycle and offline group-bot admission
workstream: WS-10
priority: p2
existing_ot: none
source: runbooks/playerbot-discovery-matrix-preflight-02-20260830-173815/report.md
superseded_by: none
body: |
  **Two unbounded behaviours around groups.**

  - `AddOfflineGroupBots()` can add 1–5 offline bots for an online real-player group
    leader, **outside** the normal target-filling loop. So the online bot count can exceed
    the configured `Min/MaxRandomBots` target.
  - Grouped bots get a 120-second deferral instead of immediate logout when their timer
    expires.

  Neither is bounded, measured or configurable.

  **Also stale/misleading:**
  - `CURRENT_GROUP_LOGIN_CANDIDATE_COUNT=UNPROVEN` — the group snapshot is superseded and
    must not be treated as current.
  - `LogInGroupOnly` defaults to 1 but the name is wrong: it gates Engine diagnostic
    logging, not bot login.
  - `RandomBotLoginAtStartup=1` has no consumer (see WS10-005).

  **Do:** after OPS-001, define max concurrent group-admitted bots, how that interacts
  with the global target, and the deferral policy. Decide whether exceeding the target is
  acceptable.

  **Blocked on:** OPS-001.
---
id: OPS-007
title: Re-run the donation runtime test to a strict PASS
workstream: WS-20
priority: p1
existing_ot: OT-006
source: runbooks/donation-runtime-test-01-20260829-184426/final-report.md
superseded_by: none
body: |
  **The donation feature works; the test still failed.**

  - Functional result: **PASS** — every AutoDonationPoints check passed.
  - Overall result: **FAIL** — one MariaDB error 1213 (deadlock) on a DELETE against
    `ai_playerbot_random_bots` at 19:09:19, violating the no-SQL-errors criterion.

  **Functional evidence to reproduce after the fix:** account 505 persisted at 298,887 ms,
  598,900 ms (delta 300,013 ms, just over the 300,000 ms flush interval), then 898,929 ms.
  After controlled shutdown and clean restart with no login, exactly one row remained:
  `505|898929`. No `shop_coins` write — the 1-hour award interval was never reached.

  **Do:**
  1. Instrument or reproduce the 1213 deadlock; prove transaction ordering.
  2. Then re-run this test to a strict PASS.

  **See also:** WS20-001 (missing unique constraint on that table — candidate cause),
  WS30-001 (the TLS workaround these probes needed).
---
id: OPS-008
title: Harden AutoDonationPoints before trusting it with real balances
workstream: WS-20
priority: p1
existing_ot: OT-012
source: runbooks/autodonationpoints-preflight-20260829-034455/activation-and-rollback-plan.md
superseded_by: none
body: |
  **Feature is live and granting 100 points per online hour, with six known weaknesses.**

  1. No flush on logout or shutdown — progress since the last flush is lost on stop.
  2. Grant and progress-reset are **not atomic**; async outcomes are ignored.
  3. A synchronous first-seen query can stall the World thread.
  4. Bot exclusion relies on account **naming**, not an actual bot type check.
  5. GM and AFK sessions accrue points (AFK is deliberate; GM probably is not).
  6. Integer inputs are inadequately validated, with unsigned conversion hazards.

  **Live config:** `Enable=1`, `IntervalMs=3600000`, `Amount=100`, `FlushIntervalMs=300000`.
  The preflight recommended `Amount=1`; that was never applied.

  **Do, in order:**
  1. **Policy first** — decide award amount and eligibility (bots / GM / AFK).
  2. Then implement: flush on logout+shutdown, atomic grant+reset, async first-seen query.

  The controlled activation and rollback procedure already exists in the source document —
  reuse it rather than rewriting.

  **Restructuring note:** this feature is spliced into `World::Update()` with no file of
  its own; it is a target for extraction into `modules/mod-donation`.
---
id: OPS-009
title: Explain the unattributed mangosd.conf change during a migration
workstream: WS-30
priority: p1
existing_ot: none
source: runbooks/donation-point-progress-migration-20260829-173126/external-state-drift.txt
superseded_by: none
body: |
  **A production config changed mid-task and nobody knows why.**

  - Before: 69,531 bytes, SHA-256 `90D6D7AE...618FF`
  - After: 69,515 bytes, SHA-256 `C552BA61...9297D` (written 2026-08-29T15:38:43Z)
  - 16 bytes removed.
  - The migration harness had **no config write capability**; 0 processes referenced the
    file. Cause was never determined.

  **Why it matters:** the post-drift hash `C552BA61...` is now the identity every later
  package pins as "approved" (donation runtime test, profession/riding discovery). If that
  16-byte deletion was unintentional, every downstream "approved configuration" claim
  inherits an unverified baseline.

  A follow-up retry aborted because intentional-save confirmation was never supplied, and
  it was never recorded afterwards either.

  **Do:**
  1. Recover the pre-drift 69,531-byte config from backup.
  2. Diff it; record what the 16 bytes were.
  3. Confirm the save as intentional, or restore.
  4. Adopt a config-change provenance rule (archive-before-write + hash) so this cannot
     recur silently.
---
id: OPS-010
title: Add bot-aware profession cap before raising the player limit to 6
workstream: WS-10
priority: p1
existing_ot: OT-009
source: runbooks/db-profession-riding-discovery-01-20260830-010856/report.md
superseded_by: none
body: |
  **Goal: players get 6 primary professions, bots keep 2. Not currently possible.**

  The limit is a single global config key `MaxPrimaryTradeSkill=2` (`mangosd.conf:833`,
  loaded at `World.cpp:1135`), copied into every `Player`'s free-slot counter at
  `Player.cpp:21193-21195`. There is no per-account-type column, so raising it to 6 gives
  **every bot 6 as well**.

  **Four paths already bypass the counter entirely:**
  - RNDBOT factory calls `SetSkill` directly (`PlayerbotFactory.cpp:3928-3997, 4275-4294`)
  - GM `.learn` calls `LearnSpell` with no cap check (`Commands.cpp:892-945`)
  - Quest/item/script learning spells (`SpellEffects.cpp:2239-2255`)
  - Direct skill-step effects (`SpellEffects.cpp:2748-2762`)

  Only the normal trainer path is gated.

  **Rollback is asymmetric** (record this in the ADR): lowering 6 back to 2 sets future
  free slots to zero but does **not** remove already-learned skills. A 6→2 rollback cannot
  restore the prior state.

  **Current exposure is nil:** 0 bots and 0 players over 2; 0 players over 6.

  **Do:** implement bot-aware enforcement in the core and the PlayerBots module, verify
  across all six acquisition paths, and only then change the config value. SQL cannot
  enforce a runtime spell-learning policy.
---
id: OPS-011
title: Decide early-riding level and approve a mount-item allowlist
workstream: WS-30
priority: p1
existing_ot: OT-010
source: runbooks/db-profession-riding-discovery-01-20260830-010856/report.md
superseded_by: none
body: |
  **Two operator decisions block the early-riding rollout (OT-010, OT-011).**

  **Current values:**
  - Apprentice Riding (spell 33389): level 40, 90g
  - Journeyman Riding (spell 33392): level 60, skill 762, 900g
  - Both from `npc_trainer_template` entry 1, used by 10 trainers (one per race), no
    faction or level variation.

  **Decision 1:** advanced riding at level **30** (Variant A) or level **20** (Variant B).
  Both at 10,000 copper.

  **Decision 2:** which mount items to include. Only 31 item rows apply mounted aura 78,
  and they include deprecated and test objects. Usable generic groups:
  - 9 items: level 40, rank 75, +60% speed, 10g
  - 2 items: level 60, rank 150, +100% speed, 100g

  No `npc_vendor` link exists for any of the 31 rows — do not infer a merchant from item
  names.

  **Critical:** without lowering item levels, a character at level 5/20/30 learns the skill
  but **cannot use any generic mount**.

  **Bot paths needing matching changes:** `PlayerbotFactory.cpp:4133-4161` (grants skill 75
  at 40, 150 at 60), `MountValues.cpp:356-368` (rejects buying below 40),
  `BudgetValues.cpp:251-285` (budgets 40g/1000g), `RandomPlayerbotMgr.cpp:4437-4445`
  (inactive below 20).

  **Ready to use:** `proposed-migration-plan.md` in the same directory has preconditions,
  post-validation, rollback values and repeat-execution hazards.
---
id: OPS-012
title: Stop using 'manual' as a migration hash; adopt content hashes
workstream: WS-20
priority: p2
existing_ot: OT-015
source: runbooks/db-profession-riding-discovery-01-20260830-010856/report.md
superseded_by: none
body: |
  **The world database cannot prove which migrations were applied.**

  - `tw_world.migrations`: **146 rows, every one with `Hash='manual'`** (latest
    `20260821203635_world`). A literal string, not a digest — it matches nothing on disk.
  - `tw_logon.migrations`: 0 rows, and **no `Module` column at all**.
  - `tw_char.migrations`: 4 rows with real cryptographic hashes (the good case).

  **Concrete example of the limit:** the live riding trainer rows exactly match
  `sql/base/tw_world_npc_trainer_template.sql`, and no committed migration references those
  values. That proves current-state parity — it cannot prove how or when they were imported.

  **Do:**
  - All new world migrations: forward-only, immutable, content-hashed, state-preconditioned,
    verified before registration, never retrofitted into base files.
  - Decide whether the 146 legacy `manual` rows are backfilled or permanently accepted as
    unverifiable.
  - Resolve the missing `Module` column in `tw_logon.migrations`.
---
id: OPS-013
title: Verify a trainer spell was actually learned before charging for it
workstream: WS-20
priority: p1
existing_ot: OT-013
source: runbooks/trainer-purchase-money-loss-20260829-004949-873/diagnosis.md
superseded_by: none
body: |
  **Any player can be charged for a trainer spell they did not receive.**

  This is the source defect, separable from the unproven incident report in OT-013. The
  diagnosis is explicit that it "is shared by normal-player trainer purchases generally".

  **The gap:**
  - The handler stores the result of `Spell::prepare()`, then calls the **void**
    `spell->update(1)`.
  - Execution can still fail inside `Spell::cast()` or return before the learning effect.
  - `EffectLearnSpell` calls a **void** `LearnSpell`, which does not propagate `AddSpell`
    failure.
  - The handler then checks only the earlier prepare result, deducts money, and reports
    success — **without ever verifying the spell is in the player's spell map**.
  - No transactional coupling, no refund path.

  **It is also invisible:** the handler calls `ModifyMoney` instead of the security-aware
  `LogModifyMoney`, so this class of loss produces no trade-log record at all. The reported
  incident had 0 trainer-buy records, 0 success/failure records, 0 learned-spell records —
  partly *because* of this.

  **Do (independent of reproduction):**
  1. Verify the taught spell is present before `ModifyMoney`.
  2. Switch the handler to `LogModifyMoney` so the failure mode becomes observable.

  A seven-step controlled reproduction proposal exists if wanted; it needs separate
  authorization per state-changing step.
---
id: OPS-014
title: Make the live smoke harness rotation-aware and triage 1,602 errors
workstream: WS-50
priority: p1
existing_ot: none
source: runbooks/post-completion-live-smoke-20260829-000920-697/smoke-result.md
superseded_by: none
body: |
  **The smoke test cannot produce a verdict.** Result: INDETERMINATE. No failures were
  demonstrated, but nothing was proven either.

  **Why:** the harness baselines logs by byte offset, which breaks whenever a log rotates,
  truncates or is replaced.
  - `bot_events.csv`, `deaths.csv`: "indeterminate-shorter" (file shrank below baseline)
  - `Realmd.log`: "indeterminate-replaced-or-modified"

  **Second problem:** 1,602 generic error markers were found in newly appended log ranges
  and merely classified as non-fatal. Nobody has triaged them. The 18.5 MB log holding them
  is excluded from the repo, so that evidence exists only on the live machine.

  **Worth preserving — what did pass:** over 30.951 s, mysqld PID 14776, mangosd PID 9628
  and realmd PID 24080 were stable; ports 3307/3724/8090 each had a single correct owner
  PID; `CHARACTER_ONLINE` was received; no duplicate processes or listeners.

  **Do:**
  1. Track inode/creation time so shrink and replacement are handled, not reported as
     indeterminate.
  2. Re-run to a definite result.
  3. Separately triage the 1,602 markers into fatal / known / benign.

  **Note:** the container smoke suite (ADR-0028) is the forward-looking replacement; this
  issue is about the current live server.
---
id: OPS-015
title: Execute the 13 approved workstream chat renames and creations
workstream: WS-00
priority: p2
existing_ot: none
source: runbooks/project-structure-alignment-20260830T163408Z/project-structure-alignment-handoff-v1.md
superseded_by: none
body: |
  **Planned, approved in analysis, never executed.** `UI_MUTATIONS_PERFORMED=0`.

  The canonical nine-workstream matrix (WS-00..WS-80) is agreed and supported by both
  accepted inventories. The action plan specifies exactly **13 manual UI actions: 8 renames
  + 5 creations**.

  - Online: 9 chats -> 9 canonical + 2 retained legacy references (7 renames, 2 creates)
  - Local: 6 -> 9 canonical (1 rename, 3 creates)
  - Missing locally: WS-30, WS-70, WS-80. Missing online: WS-50, WS-60.

  **Nothing is destroyed:** 0 deletes, 0 physical merges, 0 historical content copies.
  Legacy chats stay in place and are routed by cross-reference only.

  **Do:** get explicit approval, execute the 13 actions exactly as listed, verify.

  Reports are in German.
---
id: OPS-016
title: Point the proven ACL backup harness at the real backups
workstream: WS-60
priority: p2
existing_ot: OT-017
source: runbooks/semantic-acl-e2e-lab-3/run-2/test-results.json
superseded_by: none
body: |
  **Half of the restore proof OT-017 needs already exists — but only in a lab.**

  `semantic-acl-e2e-lab-3/run-2` passes over a 3-file / 7-object tree: cold-backup content,
  backup content, raw and semantic ACLs, reparse points; and on restore-staging, coverage,
  owner, group, protection, SACL presence, semantic DACL/SACL, inheritance and reparse.
  Negative cases (missing path, changed type, extra/duplicate ACL entries) correctly reject
  with the ACL left unchanged.

  **It has never been run against the real backup set.**

  **Warning from an earlier run:** the first lab-3 attempt failed against the real
  migration-backups volume with a root DACL SID count mismatch (expected 7, actual 4). That
  discrepancy may recur outside the lab tree.

  **Do:**
  1. Inventory the actual backups read-only.
  2. Run the harness against them.
  3. Define retention.
  4. Prove a full restore into a disposable target.
---
id: OPS-017
title: Resolve the data gaps blocking bot personality assignment
workstream: WS-70
priority: p2
existing_ot: none
source: runbooks/bot-personality-discovery-20260828-224032/bot-personality-discovery-report.md
superseded_by: none
body: |
  **No bot has a personality, and two of the five trait inputs have no data.**

  A 37,690-byte trait vocabulary and behaviour contract exists, but there is no schema, no
  assignment mechanism, and nothing binding the two.

  **Populations at capture:** 4,500 stock, 100 in active rotation, 4,400 reserve, 0
  player-owned always-online. All 10 races and 9 classes occur (incl. 1,088 High Elves,
  928 Goblins).

  **Four blockers:**
  1. **Drifting rotation set** — 100 add-marked characters existed while the configured
     target was 50; a later capture saw 53. The cause cannot be proven read-only.
  2. **Race variants unprovable** — there is no standalone Blood Elf race ID (race 10 is
     locally High Elf), and the `characters` row does not retain which token produced a
     given skin, so every `race_variant_key` is null.
  3. **Player-owned bots indistinguishable** from normal player characters in an offline
     capture, without an ACTIVE `always` marker.
  4. **Zero learned professions** across all 4,500 bots, so profession-derived traits are
     empty.

  **Validated:** appearance encoding — `CharSections.dbc` has 6,617 records and 0 unmatched
  bot appearance tuples. No bot-specific display override exists.

  **Do:** decide whether personality keys on stable character GUID (depends on the
  persistent roster) or on account slot, then design the table and assignment path before
  writing any trait.

  **See also:** ARCH-002 (full design), LLM-010 (the seven contract questions).
---
id: OPS-018
title: Automate evidence import and triage nine secret-flagged files
workstream: WS-80
priority: p2
existing_ot: OT-020
source: runbooks/IMPORT-NOTES.md
superseded_by: none
body: |
  **`runbooks/` is a manual, deliberately incomplete copy — and two gaps are real problems.**

  **Problem 1: nine JSON evidence files were flagged by Gitleaks and excluded, and never
  triaged.** Nobody has confirmed whether they hold real secrets or false positives, and no
  redacted substitute was imported.

  **Problem 2: a committed report cites a file this repo does not contain.**
  `playerbot-discovery-matrix-preflight-02-.../active-config-relevant-lines.csv` is
  referenced as primary evidence but was excluded for connection-string context.

  **Also excluded (expected):** executables, libraries, symbols, archives, database files,
  client assets, PID files, build output, and a 17 MB appended server log.

  **Do:**
  1. Build the allowlisted text-only import with secret, binary, size, link and manifest
     checks (this is OT-020).
  2. As part of it, triage the nine flagged files and produce redacted replacements for any
     evidence a committed report cites.
---
id: OPS-019
title: Deduplicate and pin the loose runbook harness scripts
workstream: WS-00
priority: p2
existing_ot: OT-026
source: runbooks/
superseded_by: none
body: |
  **14 loose PowerShell harnesses sit at `runbooks/` root with no index of which is
  canonical, and 5 are exact byte duplicates under two names each.**

  **Verified duplicate pairs (identical SHA-256):**
  - `tw-char-migration-1B9D3F82.ps1` = `...-module-metadata-candidate.ps1` (93,150 B)
  - `tw-char-migration-3904689F.ps1` = `...-semantic-acl-candidate.ps1` (88,894 B)
  - `tw-char-migration-89C6C934.ps1` = `...-normalize-candidate.ps1` (93,173 B)
  - `tw-char-migration-F92F86D6.ps1` = `...-db-ready-candidate.ps1` (92,898 B)

  The hash-named files are named after their own content hash, so the `-candidate` names
  are aliases.

  **Two are load-bearing elsewhere:**
  - `tw-world-shutdown-smoke-35C08FAF.ps1` — produced the failed shutdown smoke evidence
  - `tw-world-shutdown-smoke-count-fix-candidate.ps1` — its successor, pinned by
    `shutdown-helper-console-lab/title-compatibility-static-final`

  **Separate open question:** `tw-char-migration-20260827-205920-completion.md` is identical
  to `-completion-candidate.md` but differs from `-completion-revised-candidate.md`. Nothing
  records whether the revision was rejected or just never adopted.

  **Do:** pin one canonical version per harness with its hash, mark aliases superseded, and
  decide the fate of the revised completion note.

  **Prerequisite for:** OT-026 (evidence repository decision).
---
id: OPS-021
title: Prove the full local Linux Compose runtime with extracted client data
workstream: WS-50
priority: p1
existing_ot: none
source: docs/adr/ADR-0023-containerization-and-one-command-contract.md
superseded_by: none
body: |
  **Goal:** reproduce the complete modular Linux runtime locally on Docker Desktop
  from the proven platform and core revisions, using externally held extracted
  client data as a read-only mount.

  **Pinned starting point:**
  - Platform merge: `a31dce250f2e585c6729cc613b3d1153bf96fba0`
  - Core pin: `e3ab7b0d7e77fc32009c664618d7ec7e58c511de`
  - PR #173 CI run 131: capacity, lint, empty bootstrap, build/test and Compose
    smoke passed.

  **What remains unproven:** CI intentionally does not start `mangosd` because it
  has no client data. The local test must prove MariaDB, db-init, realmd and
  mangosd together with existing `dbc`, `maps`, `vmaps` and `mmaps`.

  **Required execution contract:**
  1. Work from an isolated Y: worktree and Y: build directory.
  2. Verify Docker and physical host capacity before building.
  3. Discover only already extracted client-data directories. Do not scan or copy
     large MPQs and do not commit client data.
  4. Bind client data read-only.
  5. Use a task-specific Compose project, network, configuration directory and
     disposable database volume.
  6. Do not use or mutate the pre-existing Docker volume `TwWoW`.
  7. Observe existing Windows server processes and listeners but never stop,
     reconfigure or replace them. Use non-conflicting task-local host ports.
  8. Build or retrieve an image only if its exact platform/core provenance is
     verified.
  9. Start db, db-init, realmd and mangosd; verify revisions, schemas, health,
     listeners and at least ten minutes of stability.
  10. Perform one controlled graceful restart and verify successful recovery.
  11. Stop only task-owned containers. Do not broadly prune images, volumes or
      caches.
  12. Do not apply the persistent roster, run Phase C, enable the LLM bridge or
      access the production database.

  **Acceptance:**
  - exact platform/core revisions verified;
  - PlayerBots and Dungeon Clear present;
  - config render and provenance verification pass;
  - db-init, realmd and mangosd start successfully;
  - realm and world listeners respond on task-local ports;
  - client data stays external and read-only;
  - stability observation and graceful restart pass;
  - Windows server and production database remain unchanged.

  **Dependencies:** ADR-0023, ADR-0024, PR #173, and the completed standalone
  twow-core Docker reproduction.
---
