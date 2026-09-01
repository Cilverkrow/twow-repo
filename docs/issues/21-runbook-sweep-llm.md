# Open items: LLM bridge, source baseline, inference

Authoritative generations — later supersede earlier, never rebase from a superseded copy:

| Concern | Path |
|---|---|
| Bridge payload (Node) | `runbooks/ssc-llm-bridge-v1-english-correction-20260830-131349` |
| Bridge contract | `runbooks/ssc-llm-production-bridge-01-phase-a-r2-20260830-170407` |
| C++ adapter | `runbooks/ssc-llm-production-bridge-01-phase-b-r1-20260830-194919` |
| Runtime proof | `runbooks/ssc-source-baseline-02c-r1-20260830-004551` |
| Migration provenance | `runbooks/ssc-source-baseline-02a3-20260829-215858` |

---
id: LLM-001
title: Integrate the LLM bridge adapter from the B-R1 (683-test) generation
workstream: WS-10
priority: p0
existing_ot: OT-003
source: runbooks/ssc-llm-production-bridge-01-phase-b-r1-20260830-194919/REPORT.md
superseded_by: none
body: |
  **Context:** bots can talk to a local LLM. The adapter that does it safely was written,
  tested and never merged — it lives only under `runbooks/`, not in `src/`.

  **Use the right copy.** Authoritative:
  `ssc-llm-production-bridge-01-phase-b-r1-20260830-194919/source-copies/`.
  The earlier `phase-b-20260830-173121` copy is the 107-test generation — superseded.

  **Nine files:**
  - New: `ExternalLLMBridgeService.{h,cpp}`
  - Modified: `PlayerbotAIConfig.{h,cpp}`, `aiplayerbot.conf.dist.in`,
    `PlayerbotScripts.cpp`, `PlayerbotAI.{h,cpp}`, `strategy/actions/SayAction.cpp`
  - the bot tree's CMake file needs no change; its GLOB picks up the new files.

  **Evidence it works:** 683/683 fake-child tests, passed twice with identical results;
  27-check static forbidden-path gate; clean Release build.

  **Do:**
  1. Rebase onto current `main` — it has moved; the roster landed at `3c2b931`.
  2. Re-run `tests/run-tests.ps1` (683 cases) and `tests/static-forbidden-paths.ps1`.
  3. Clean build. Commit. **Do not deploy.**

  **Re-target the transport while integrating.** The adapter currently uses Windows named
  pipes + `CreateProcessW`. Per ADR-0028 the deployment platform is Linux containers, so
  replace the transport with a network one. Keep everything the ADRs got right: fail-closed
  admission, world-thread re-validation of session fingerprints before delivery,
  at-most-once, no retry, no fallback.

  **Build trap:** re-adding the legacy `PREFIX` CMake definition collides with the CMake
  4.4 compiler-ID macro and fails configure. Use only `CMAKE_INSTALL_PREFIX`.

  **See also:** LLM-012 (unsafe legacy code paths that must not be reused).
---
id: LLM-002
title: Build the deployment tool that verifies and extracts the bridge package
workstream: WS-70
priority: p1
existing_ot: none
source: runbooks/ssc-llm-production-bridge-01-phase-a-r2-20260830-170407/REPORT.md
superseded_by: none
body: |
  **Blocker:** the LLM adapter can never be enabled, because nothing produces the package
  it requires.

  **Why:** the contract deliberately forbids the game server from parsing archives
  (`CORE_ZIP_PARSER=NO`). The server only accepts an already-extracted absolute
  `PackageRoot` and re-verifies a payload manifest before every child start. The tool that
  does the extraction does not exist.

  **The tool must:**
  - Verify the outer ZIP hash `36485E40...7434` (112,411 bytes, 78 entries) and the root
    manifest `522D3358...353C` (77 entries).
  - Reject duplicate, absolute and escaping paths, and symlink/reparse targets.
  - Extract only into a new, previously non-existent `PackageRoot`.

  **Pins the server re-checks itself:** payload manifest `814A8988...171B` (50 files),
  config `D2925AA8...3902`, personality `38665924...4D07E`, CLI `C5D2C01D...CA611`.

  **Layout is load-bearing:** the CLI path is fixed at `PackageRoot/bridge/src/cli.mjs`.
  There is deliberately no config option to move it. Only three keys exist: `Enabled`,
  `NodeExecutable`, `PackageRoot`.

  **Relationship:** narrower than, and prerequisite to, OT-005 (deployment contract).
  Prerequisite for OT-004 (live LLM). Should be built for containers per ADR-0028.
---
id: LLM-003
title: Active aiplayerbot.conf points at raw Ollama and bypasses the bridge
workstream: WS-70
priority: p1
existing_ot: none
source: runbooks/ssc-ollama-manual-scaling-01-phase1-20260829-210352/phase1-preflight-report.md
superseded_by: none
body: |
  **Live config defect. Currently harmless only because `LLMEnabled=0`.**

  If anyone sets `LLMEnabled=1` today:
  - Endpoint is `http://127.0.0.1:11434/v1/chat/completions` — **direct Ollama**, bypassing
    the bridge, its ledger, its 240-char output sanitizer and its whisper-only routing.
  - `LLMDefaultPromptsFile=llm_character_card.txt` points at a file that **does not exist**.
  - The blocked-channel list is **empty**, so generated text would go straight to public
    channels via the legacy path.
  - API key is empty; bot-to-bot and RPG chances are 0.

  **Do — but not yet:**
  1. Wait for LLM-001 (adapter integrated) and LLM-002 (deployment tool).
  2. Then rewrite endpoint, prompt file and channel settings against the three-key schema.
  3. Apply the blocklist from LLM-004.
  4. Hash-record the change; this file is a pinned production artifact in every runbook.
---
id: LLM-004
title: Set the whisper-only channel blocklist using source-exact tokens
workstream: WS-70
priority: p2
existing_ot: none
source: runbooks/ssc-ollama-manual-scaling-01-phase1-20260829-210352/phase1-preflight-report.md
superseded_by: none
body: |
  **v1 delivery is whisper-only.** To enforce that on the legacy config side, the block
  list must be exactly:

  ```
  guild,world,general,trade,lfg,ldefence,wdefence,grecruitement,say,emote,temote,yell,party,raid
  ```

  (every recognised token except `whisper`)

  **Do not correct the spelling.** `ldefence`, `wdefence` and `grecruitement` are what the
  core actually parses. "Fixing" them silently disables those blocks.

  **Related trap for any future test:** `RandomBotSayWithoutMaster=1` means legacy non-LLM
  bot speech continues independently. Any evidence claiming "no public LLM output" must
  positively distinguish legacy chatter from LLM output, or it proves nothing.

  **Do:** land this as part of the LLM-003 config rewrite, and define the observation
  method that separates the two before any live test.
---
id: LLM-005
title: Unblock the single-bot live LLM test
workstream: WS-10
priority: p2
existing_ot: OT-004
source: runbooks/ssc-ollama-manual-scaling-01-phase1-20260829-210352/phase1-preflight-report.md
superseded_by: none
body: |
  **Status: ABORT.** The deployed binary cannot do LLM inference at all — the string
  "LLM generation disabled in this build" was found inside the running `mangosd.exe`.
  `PlayerbotLLMInterface::Generate` is a stub returning empty. A test would prove nothing.

  **Blocked on:** LLM-001 (integrate adapter) + LLM-002 (deployment tool).

  **Preserved setup, so nobody redoes this work:**
  - Test subject already chosen: bot `Meladu`, GUID 23143, account 75 (`RNDBOT79`),
    Human Priest level 2, offline, no persistent group.
  - To run one manual bot with automatic population off, use `MinRandomBots=0` +
    `MaxRandomBots=0` + `RandomBotAutologin=**1**`. Setting `RandomBotAutologin=0` returns
    early from `UpdateAIInternal` and breaks the manual bot.
  - The 53 existing `owner=0,event=add` rows need no deletion.
  - DB at capture: 500 RNDBOT accounts, 4,500 characters, 11 group members in 5 groups.

  **Re-check before testing:** the `AddOfflineGroupBots()` bypass. All 5 group leaders were
  themselves RNDBOTs; a real player leader changes the assessment.
---
id: LLM-006
title: Add monitoring for the irreversible ledger_exhausted latch
workstream: WS-70
priority: p2
existing_ot: none
source: runbooks/ssc-llm-production-bridge-01-phase-a-r2-20260830-170407/REPORT.md
superseded_by: none
body: |
  **Hazard: LLM dialogue can die permanently after a single log line.**

  By design, the first valid `ledger_full` response latches the adapter into
  `ledger_exhausted` for that child instance:
  - The triggering route is retired; no further requests are ever sent.
  - New requests are rejected locally before any ID or route is created.
  - **Exactly one** warning is emitted per child instance; repeats are suppressed.
  - Reset requires a manual restart. No auto-restart, retry, resubmit or fallback.

  Non-LLM bot chat is unaffected by design and must not be suppressed.

  **Capacities:** ledger 64, active 1, waiting 2, core outstanding max 3.

  **Do before any live use:**
  - Alert on that single warning — otherwise the first exhaustion in production is
    invisible.
  - Document the manual restart procedure.

  **Note:** a *malformed* `ledger_full` does not latch; it triggers `protocol_failed`,
  which closes admission permanently and more aggressively.
---
id: LLM-007
title: Windows shutdown helper fails with WriteConsoleInput failed
workstream: WS-50
priority: p2
existing_ot: none
source: runbooks/ssc-source-baseline-02c-20260829-233607/source-baseline-02c-blocked-report.md
superseded_by: none
body: |
  **Concrete defect** (the evidence behind WS40-001).

  `shutdown-tortoise-servers-gracefully.ps1` fails after 0.598s with exit 1:
  `Ausnahme beim Aufrufen von "WriteCommand" ... "WriteConsoleInput failed"`.

  From the source it is provable that process, path, PID and console-title validation all
  passed, and the failure hit the **first** `WriteCommand`. So `saveall` was never
  delivered and `server shutdown 0` was never attempted.

  **Impact:** blocked an entire runtime test (`SOURCE_BASELINE_02C_RESULT=BLOCKED`) leaving
  mangosd PID 13808 and realmd PID 32260 running. The retry only passed because a human
  typed the commands into the console by hand.

  **Scope reduced by ADR-0028:** Windows gets no quality-of-life work. Likely resolution is
  to mark it unsupported (see WS40-001) rather than debug it, since
  `deploy/docker/entrypoint-mangosd.sh` solves the same problem on Linux.

  **If it is fixed anyway:** the cause is likely console-attach, handle, or session
  isolation. Keep the no-force-kill design.
---
id: LLM-008
title: Decide whether to promote the reproducible build candidate
workstream: WS-50
priority: p2
existing_ot: OT-014
source: runbooks/ssc-source-baseline-02c-r1-20260830-004551/REPORT.md
superseded_by: none
body: |
  **Problem: nobody can prove what source the running production binary was built from.**

  - The deployed `mangosd.exe` (`FB722BAA...E45FC`) has no build log or signed manifest
    binding it to a clean commit, toolchain and dependency set.
  - A reproducible candidate (`2C24707C...D10AE`) **was** built and runtime-verified:
    started with production configs against the live DB, accepted the schema, listened on
    0.0.0.0:8090, stable 227.9s (requirement 180s), graceful shutdown, production binary
    restored and hash-verified afterwards.
  - That proves the candidate runs. It does not give the deployed binary provenance.

  **Decide one:**
  - Deploy the reproducible candidate and retire the unprovenanced binary, or
  - Record a signed acceptance of the provenance gap.

  **Note:** ADR-0020's submodule SHA + `UPSTREAM.lock` + CI build manifest is the
  structural fix for this class of problem going forward.
---
id: LLM-009
title: Decide retention for runbook evidence that exists only outside Git
workstream: WS-50
priority: p2
existing_ot: OT-020
source: runbooks/ssc-llm-production-bridge-01-phase-b-r1-20260830-194919/SHA256SUMS.txt
superseded_by: none
body: |
  **Problem: several `SHA256SUMS.txt` manifests declare files that are not in the repo, so
  they cannot be verified from a clone.** A future reader cannot tell "intentionally
  excluded" from "tampered with".

  **Missing but declared:**
  - `phase-b-r1`: `artifacts/mangosd.exe` (`1231B38B...3718C`), `evidence/CMakeCache.txt`,
    all six `logs/*.log`
  - `02c-r1`: `artifacts/mangosd.candidate-tested.exe` (`2C24707C...D10AE`), server log

  **Deliverable ZIPs, external only:** phase-b `510C3E36...` (8.0 MB), phase-b-r1
  `A0154CE3...` (8.1 MB), english-correction `36485E40...` (112 KB), 02B `FD937CF7...`
  (62.9 MB). They exist only on the live workstation.

  **Decide one:**
  - Archive the ZIPs/binaries somewhere durable and record the location, or
  - Mark the affected manifest lines as intentionally external.

  **Urgency:** do this before that workstation is rebuilt. Those hashes are the only link
  between every report and its build.
---
id: LLM-010
title: Answer the seven open questions blocking DB-backed bot personalities
workstream: WS-30
priority: p2
existing_ot: none
source: runbooks/personality-context-contract-v1.md
superseded_by: none
body: |
  **State:** the personality contract is a complete design with **no real IDs in it**, and
  deliberately so. Only Stage A shipped: one hand-written JSON profile for a single bot
  (GUID 18281), with empty traits and professions.

  **Seven questions needing a read-only DB enumeration (contract section 14):**
  1. Real race/class IDs and names
  2. Whether race variants are representable and detectable
  3. Tables and skill IDs for primary/secondary professions
  4. Actual status of Survival, Gardening, Jewelcrafting
  5. Source of the bot GUID and its safe separation from player characters
  6. Available quest/guild/group/inventory/recipe views
  7. Actual chat lengths, channel types, character encoding

  **Not started (Stage B):** migrating real IDs, binding profile+version durably to the bot
  GUID, exposing a personality view to the bridge, incremental profession updates.

  **Fixed composition rules (already decided):** 3-of-6 race traits, 2-of-5 class, 1-of-3
  per profession; strengths clamped 20-80; max 3 traits per reply; max 2 profession traits.

  **Acceptance criteria to check afterwards (section 16):** same seed + version yields the
  same profile; restarts do not change personality; two same-race/class bots stay
  distinguishable; an inference outage does not affect the game server; the model never
  holds DB credentials.

  **See also:** ARCH-002 (the full persona/memory/canon design), OPS-017 (data gaps).
---
id: LLM-011
title: Record measured LLM latency limits before planning live rollout
workstream: WS-10
priority: p1
existing_ot: OT-004
source: runbooks/ssc-llm-bridge-v1-english-correction-20260830-131349/REPORT.md
superseded_by: none
body: |
  **Measured capacity envelope.** Only two live inferences have ever run, both bridge-only,
  never through the game:
  - Phase 1B: 8,104 ms submit-to-ready
  - V1 English correction: 7,802 ms, 96 codepoints out, 1 attempt, `max_active_observed=1`

  **~8 s per reply, with active=1 and waiting=2.** That is the number any rollout plan must
  start from, and the strongest argument for a batching-capable backend (see ARCH-003).

  **Hard output limits:** 240 codepoints AND 240 UTF-8 bytes; over-limit **rejects the
  whole reply**, no truncation; max 2 terminator runs. Verified at the boundary: 240 ASCII
  ok, 241 rejected; 120 x "é" (240 bytes) ok, 121 rejected.

  **Model pin:** `qwen2.5:7b`, digest `845dbda0...b697e`. Test suite 75/75 on Node 24.

  **Every phase closed with:** `REAL_BRIDGE_STARTED=NO`, `OLLAMA_ACCESSED=NO`,
  `INFERENCE_PERFORMED=NO`, `GAME_CHAT_SENT=NO`, `PHASE_C_STARTED=NO`.

  **First live test must be bounded to:** a single whisper, to one real player, from bot
  GUID 18281, with the protocol language derived from the bot's team. English text is not
  the same as `LANG_COMMON`.
---
id: LLM-012
title: Do not reuse the detached-thread packet path for LLM completion
workstream: WS-10
priority: p1
existing_ot: OT-003
source: runbooks/ssc-source-baseline-01-20260829-193848/stable-source-baseline-report.md
superseded_by: none
body: |
  **Standing hazard to re-check at every LLM integration.**

  `PlayerbotAI.cpp:7978-8006` (`SendDelayedPacket` / `ReceiveDelayedPacket`) spawns
  **detached threads** carrying a raw `WorldSession*` across the thread boundary. This
  directly contradicts the bridge safety boundary and must never become the queue or
  completion mechanism. `SayAction.cpp:653` uses `std::async` with it.
  `DebugAction.cpp:1243` is a debug path explicitly marked not for reuse.

  **The rule (integration gate item 6):** any worker may carry only copied scalar IDs and
  immutable bytes — never `Player*`, `PlayerbotAI*`, `WorldSession*`, map/channel objects,
  or any other raw game pointer.

  The B-R1 adapter satisfies this internally. The gate is about the **surrounding legacy
  code**, which does not.

  **Also:** `BroadcastHelper` must not be used for replies — it applies randomized
  broad-channel selection.

  **Integration points to re-read from the approved commit, not a working tree:**
  `PlayerbotLLMInterface.cpp:376`, `SayAction.cpp:421,598-600`,
  `RpgTriggers.cpp:629/635/638`, `PlayerbotAI.cpp:260,1222,3619,3777-3790`,
  `PlayerbotMgr.cpp:1229,1244`, `RpgSubActions.cpp:422-433`,
  `World.cpp:2628,2671,3654`, `WorldSession.h:137,266`, `PlayerbotAIConfig.cpp:706,717,718`.

  **Do:** fold this checklist into the LLM-001 review and record the result against the
  actual commit integrated. The unapproved debug LLM changes on the live workstation must
  not become the base.
---
