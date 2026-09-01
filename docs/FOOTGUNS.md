# Known footguns

These are verified or strongly evidenced hazards, not generic cautions. A footgun entry does not authorize its repair.

## Repository and provenance

| ID | Footgun | Failure mode | Guardrail |
|---|---|---|---|
| FG-001 | Treating this clone as the live server | Scripts, relative paths, and apparent configs can be mistaken for deployed state. | Keep repository and live workspace separate; deploy only through an explicitly reviewed task. |
| FG-002 | Assuming a clone is runnable | Binaries, DLLs, PDBs, game data, databases, live configs, and credentials are intentionally absent. | Use [external requirements](EXTERNAL-REQUIREMENTS.md); never “fix” the clone by committing runtime assets. |
| FG-003 | Executing historical absolute paths | Runbooks retain workstation-specific paths as evidence. They may target the wrong host or stale files. | Resolve repository-relative sources and explicitly select the current environment. |
| FG-004 | Trusting the inherited root README as live status | It contains upstream/history claims, including bot counts and features, that do not describe the current verified runtime. | Use `docs/`, ADRs, the hub, and fresh runtime evidence. |
| FG-005 | Confusing `origin` and `upstream` | `origin` is the private project repository; `upstream` is `Shyalya/tortoise-wow`. An accidental push can publish private work. A *merge* from upstream is not merely risky here, it is impossible: `twow-repo` shares no ancestry with upstream, so a proposed "upstream merge" in this repository is always a mistake or a mislabelled import ([ADR-0026](adr/ADR-0026-project-lineage-and-provenance.md)). | Inspect remotes before fetch/push; never push private work to `upstream`; treat any upstream merge into `twow-repo` as a stop condition, and do it in `twow-core` instead. |
| FG-006 | Rewriting published filtered history | The initial history was rewritten to remove binaries. Another rewrite changes every descendant identity and can invalidate provenance. | Do not force-push or rerun history filtering without a separately approved migration plan. |
| FG-007 | Reintroducing binaries through an upstream merge **in `twow-core`** | A normal merge brings back the 146 warden `.cr`/`.key` blobs and anything else upstream carries that the `twow-repo` filter removed. **This risk is `twow-core`'s alone**: `twow-repo` has no shared ancestry and cannot merge from upstream at all, so an "upstream merge" proposed here is FG-005, not this. | In `twow-core`: run binary-size/type and full-history secret scans before push, and decide deliberately which upstream blobs the fork keeps. In `twow-repo`: refuse the merge. |
| FG-008 | Treating runbook source copies as integrated code | Roster and production-LLM candidate source exists under `runbooks/.../source-copies`, but not in main `src/`. | Integrate through reviewed commits; never build production directly from a runbook directory or copy files blindly. |
| FG-009 | Overwriting the dirty live tree | The live source contains pre-existing custom changes and generated artifacts. | Snapshot status and hashes; integrate in an independent worktree; never reset or checkout away user changes. |
| FG-010 | Short Git revision as binary provenance | The EXE embeds only a shortened commit and omits dirty state, toolchain, options, and dependencies. | Require full commit/tree, clean status, build manifest, toolchain, EXE/PDB identity, and logs. |
| FG-011 | Raw-byte hashes plus line-ending conversion | Migration hashing uses raw checkout bytes. `core.autocrlf`, BOM changes, or CRLF/LF conversion changes identity. | Pin encoding and line endings; hash the exact bytes consumed by the tool. |
| FG-012 | Broad secret-scan suppression | `.gitleaksignore` has one narrow audited HTTP-header false positive. | Do not add broad rule exemptions; audit each new finding. |
| FG-076 | Treating a local hash as an upstream hash | Every commit identity in `twow-repo` was rewritten by `git-filter-repo`, so none of them exists upstream. A hash that resolves in this clone proves nothing about upstream. This one cost a full day: a post-filter local hash was recorded in `docs/PROVENANCE.md` and then quoted by ADR-0020 and ADR-0026 as "the upstream merge-base", so an agent test-merged a dead branch and measured a whole delta against a stale ref. Its two siblings: a *branch* that exists upstream can still be an ancestor of the fork point and therefore dead, and a snapshot ref (`upstream-tracking`) is not the live tip. | Resolve every asserted upstream hash **on the upstream remote** (`git cat-file -e <hash>` after fetching `upstream`, or the GitHub API) before writing it down. Measure only against `upstream/playerbots-integration-gh`. Cite [ADR-0026](adr/ADR-0026-project-lineage-and-provenance.md) rather than restating a hash. |

## Hub, evidence, and task control

| ID | Footgun | Failure mode | Guardrail |
|---|---|---|---|
| FG-013 | Treating chat memory as proof | Chats can be compacted, stale, or contradicted by current files and databases. | Apply ADR-0002 evidence precedence and stop on conflict. |
| FG-014 | Treating a phase `PASS` as authorization for the next phase | Isolated tests/builds can be mistaken for deployment approval. | Read the exact gate fields; require a new explicit authorization for every production mutation. |
| FG-015 | Naively parsing the hub manifest as a standard checksum file | It contains hash, byte count, and historical absolute path columns. | Parse all three fields and map the historical project prefix to the repository root for repository verification. |
| FG-016 | Self-referential manifests | Storing a manifest's own final hash inside itself creates an impossible fixed-point requirement. | Cover payloads only; report the manifest hash externally. |
| FG-017 | Editing immutable historical evidence | “Fixing” old reports destroys the audit trail. | Add a correction or closure revision; do not overwrite prior evidence. |
| FG-018 | Using runbooks as deployment input by default | Evidence packages may include proposed, rejected, superseded, or unapplied artifacts. | Require an approved deployment manifest that selects exact payload hashes. |
| FG-019 | Playing during a supposedly static snapshot | Normal gameplay mutates character, event, group, and log data even without manual SQL. | Coordinate snapshot windows; label concurrent gameplay and recapture affected evidence. |
| FG-020 | Assuming logs only append | Logs can rotate, truncate, or be replaced, making append-offset analysis invalid. | Verify prefix identity and size before reading deltas; return `INDETERMINATE` on drift. |

## Build, process, and deployment

| ID | Footgun | Failure mode | Guardrail |
|---|---|---|---|
| FG-021 | Building in the live source tree | Generated files and local edits can contaminate both agents and provenance. | Use a clean isolated worktree/build directory. |
| FG-022 | Reconstructing the legacy CMake `PREFIX` definition | It collided with CMake 4.4 compiler-ID macros in the verified build attempt. | Use `CMAKE_INSTALL_PREFIX`; preserve exact known-good options. |
| FG-023 | Candidate build equals deployable production | A clean build can still lack live config, schema, runtime, and rollback proof. | Keep build, install, migration, enablement, and live validation as separate gates. |
| FG-024 | EXE/PDB mismatch | Similar timestamps or filenames do not prove that symbols belong to an executable. | Verify CodeView GUID and Age plus file hashes. |
| FG-025 | Process control by name alone | Multiple processes or unrelated Node/MariaDB/server instances can be killed. | Verify PID, full path, listener, owned handle, and expected console identity. |
| FG-026 | Forced shutdown as fallback | `taskkill` can skip save/flush and damage state. | Stop Worldserver, Realmd, then MariaDB through graceful reviewed paths; fail closed on ambiguity. |
| FG-027 | Console-title assumptions | Batch launchers can alter titles and cause helpers to stop midway. | Accept only documented titles after PID/path checks and test title compatibility. |
| FG-028 | Duplicate listeners/processes | A test can connect to an old instance and validate the wrong binary or database. | Capture process start time, full path, PID, and port ownership before and after. |
| FG-029 | Running without elevated rights when the task requires them | Backup, ACL, service, or process-control steps can abort after partial preparation. | Check privilege in preflight; never work around UAC silently. |

## Database and migrations

| ID | Footgun | Failure mode | Guardrail |
|---|---|---|---|
| FG-030 | Wrong schema selected | A valid SQL statement can mutate the wrong database. | Verify `SELECT DATABASE()` and exact schema identity before applying anything. |
| FG-031 | `CREATE IF NOT EXISTS` treated as schema verification | It silently accepts an incompatible existing table. | Compare exact columns, types, indexes, engine, and charset; block on a third state. |
| FG-032 | Editing base SQL or old migrations | It destroys provenance and does not safely update an existing database. | Add a new forward migration with pre/post-state and rollback evidence. |
| FG-033 | Treating tracker value `manual` as a digest | Names can match while file bytes do not. | Record new SHA-1/SHA-256 evidence; retain the historical provenance limitation. |
| FG-034 | Credentials in command lines or reports | Shell history, process listings, logs, and Git can expose them. | Use protected ephemeral option files or approved secret injection; delete temporary material immediately. |
| FG-035 | Assuming TLS client defaults work locally | One verified Windows MariaDB client path failed Schannel negotiation before authentication. | Use ADR-0030's explicit `127.0.0.1:3307` profile or fail closed; never retry silently or change server policy incidentally. |
| FG-036 | No verified backup before DDL | Rollback becomes guesswork. | Create, hash, inspect, and where required restore-test the backup before mutation. |
| FG-037 | Full database equality during normal gameplay | Runtime legitimately changes many tables, creating false alarms. | Define the affected data set and compare only controlled invariants plus unexpected errors. |
| FG-038 | Missing donation progress table | The source performs a first-seen `SELECT`; the database assertion path can terminate the server. | Apply and verify the approved `tw_logon` migration before enabling that source path. |
| FG-039 | Donation configuration integer hazards | Negative text can become a huge unsigned amount; zero is accepted; range checks are incomplete. | Validate bounds in source/config before changing policy. |
| FG-040 | Donation grant and progress update treated as atomic | Current async outcomes and separate statements can diverge. | Design and test atomicity/error handling before claiming financial correctness. |
| FG-041 | Ignoring the PlayerBot deadlock | The donation feature passed, but an unrelated error 1213 still occurred in `ai_playerbot_random_bots`. | Keep the defect open and diagnose separately. |

## PlayerBot roster and population

| ID | Footgun | Failure mode | Guardrail |
|---|---|---|---|
| FG-042 | Equating stock, stored `add` rows, active leases, and online bots | The same database can show 4,500 stock characters, stale historical rows, and zero active bots. | Report every population definition and timestamp separately. |
| FG-043 | Selecting “the first 50” | Query order, login order, or random order is not stable identity. | Require an explicit ordered GUID set and canonical snapshot hash. |
| FG-044 | Automatic replacement of a missing roster member | Relationships and progression silently move to another bot identity. | Enter `DEGRADED`; never fill or substitute automatically. |
| FG-045 | Applying a roster while bots are online | Partial reconciliation can log out, replace, or split groups. | Local console only, maintenance mode, offline-roster gate, transaction, and required restart. |
| FG-046 | Timer values treated as membership | `validIn` and lease expiration control legacy rotation, not desired persistent membership. | Store membership in a versioned ordered roster independent of timers. |
| FG-047 | Suppressing the entire normal bot update path | A broad early return also disables safe AI cleanup, travel, revive, strategy, and session maintenance. | Disable only identity rotation/logout effects and test organic behavior. |
| FG-048 | Assuming DB-valid means factory-generatable | Seven of 59 schema pairs are rejected by the current factory. | Use the verified 52-pair effective set unless source support is added. |
| FG-049 | Claiming exact equality at target 50 | Fifty slots cannot evenly cover 52 combinations. | Approve a weighted 50 allocation or use at least 52 for one each. |
| FG-050 | Fixed counts treated as weights or rebalance instructions | They are absolute creation counts and do not rebalance 4,500 existing characters. | Separate creation policy, active-online target, and existing-stock remediation. |
| FG-051 | Omitting fixed-map entries or enabling Async login later | Missing entries read as zero in one path; the dormant Async path reads the wrong probability structure. | List all effective pairs explicitly and re-audit before enabling `AsyncBotLogin`. |
| FG-052 | Explicit zero in the generation path | The discovered fixed-count path has an unsigned-underflow hazard around zero. | Do not use zero entries as a casual exclusion mechanism; fix and test the path first. |
| FG-053 | Folding master-logout group semantics into roster work | It broadens scope and can alter deliberate player logout behavior. | Keep `MASTER_LOGOUT_GROUP_PERSISTENCE` as a separate decision and test. |

## LLM bridge and personalities

| ID | Footgun | Failure mode | Guardrail |
|---|---|---|---|
| FG-054 | Assuming the tested LLM adapter is in main source | The validated Phase B-R1 files live in runbook source copies; main source has the earlier debug path. | Integrate and retest explicitly before any build/deploy claim. |
| FG-055 | Reusing detached-thread/raw-session delayed packets | A raw `WorldSession*` can outlive its owner and deliver on the wrong thread/session. | Pass value data only and revalidate in the World thread before at-most-once delivery. |
| FG-056 | Core parsing or extracting the bridge ZIP | It expands attack surface and mixes deployment with runtime. | Deployment tooling verifies/extracts; Core receives a pinned extracted package root. |
| FG-057 | Concurrent CLI commands | The protocol has no correlation ID, so responses can be misassigned. | Permit exactly one outstanding command and validate every envelope by context. |
| FG-058 | stderr treated as protocol or model output | Diagnostics can corrupt NDJSON state or leak into chat. | stdout is protocol only; drain bounded stderr separately. |
| FG-059 | Automatic retry/restart/fallback | It can duplicate submissions, violate ledger semantics, or silently switch models. | Fail closed; no retry, resubmit, fallback, or automatic child restart. |
| FG-060 | Killing by Node/Ollama process name | It can terminate unrelated applications. | Terminate only the owned child handle after the shutdown deadline. |
| FG-061 | Model tag without digest | A tag can point to different bytes later. | Pin model name and digest; verify inventory before inference. |
| FG-062 | Personality as a source of game facts | Traits can hallucinate skills, items, quests, relationships, or race variants. | Supply facts from verified context only; traits affect tone and priorities. |
| FG-063 | Personality before stable bot identity | Profiles and memory can attach to bots that disappear from the active population. | Complete the persistent GUID roster before live personality continuity claims. |
| FG-064 | Inferring cosmetic race variants | Persisted appearance bytes do not retain reliable token provenance. | Keep `race_variant` null unless a verified source distinguishes it. |

## Gameplay configuration

| ID | Footgun | Failure mode | Guardrail |
|---|---|---|---|
| FG-065 | Raising the global profession limit before the RNDBOT cap | Bots could acquire up to six primary professions. | Ship and test the bot-specific cap first; then change config. |
| FG-066 | Enforcing the bot cap only at trainers | Factory, spell, item, quest, script, GM, and direct `SetSkill` paths can bypass it. | Centralize and test every acquisition path without deleting persisted skills. |
| FG-067 | Trainer-only early-riding migration | Bots still use hard-coded thresholds and mount items still require old levels. | Coordinate Core, Config, trainer rows, and item manifest. |
| FG-068 | Updating every level-40/60 item | Ordinary items and intentionally gated special mounts can be damaged. | Derive a complete mount manifest from spells, skills, and sources; classify each item. |
| FG-069 | Changing mount training price and assuming item price changed | Trainer cost and item purchase price are independent fields. | Treat purchase-price policy as a separate explicit decision. |
| FG-070 | Repairing the trainer path from one unproven event | The controlled normal-account purchase succeeded and persisted correctly. | Require a reproducible failure before code, data, refund, or spell-grant action. |

## Repository restructuring and evidence

| ID | Footgun | Failure mode | Guardrail |
|---|---|---|---|
| FG-071 | Ignoring required build resources as “just binaries” | `mangosd.rc` requires `mangosd.ico`; the linker requires external compiled libraries. A text-only checkout can configure and compile most targets but still fail late. | Follow `docs/BUILD-RESOURCES.md`: verify pinned external inputs, expose them only temporarily, and keep them out of Git. |
| FG-072 | Refactoring while a feature worktree is the only integrated copy | A reset, rebase, broad move, or cleanup can orphan a reviewed source delta before it is secured in Git. | Inventory worktrees and branches, pin the exact parent and diff, produce a tested feature commit first, and preserve it until `main` integration is verified. |
| FG-073 | Copying whole evidence directories into Git | Raw packages can contain executables, symbols, logs, credentials, account data, oversized files, or licensed assets. | Import only allowlisted sanitized text after secret, binary, size, and path review; record excluded payloads by hash. |
| FG-074 | Treating `TODOS.md` as permission | A checklist can be mistaken for an approved deployment or database task. | Every checklist remains non-authorizing; require the workstream preflight and explicit mutation scope for execution. |
| FG-075 | Treating one interactive Windows console-helper pass as a universal contract | The same helper later failed at `WriteConsoleInput` before `saveall` when launched headlessly with redirected handles. | Keep the Windows helper historical and unsupported; use the Docker console FIFO and its shutdown smoke contract. |
| FG-076 | A non-recursive checkout of this repository | The server core is the `core/` submodule and the core carries the Eluna engine as a submodule of *its* own. One level short and the build dies in the core's `FATAL_ERROR` about a missing Eluna; zero levels and it dies in the root one about an empty `core/`. Both read as a broken build rather than a shallow checkout. | Always `--recurse-submodules` / `submodules: recursive`. Both `FATAL_ERROR`s name the command to run. |
| FG-077 | Reading `core/` as ordinary source | It is a pinned submodule of another repository. Editing a file there produces a change no commit here can carry, and `git status` in this repository reports only a moved gitlink. | A core change is a `twow-core` pull request plus a deliberate pin bump recorded in `UPSTREAM.lock`. |
| FG-078 | `git submodule add` inside an unrelated commit | It **pre-stages** `.gitmodules` and the gitlink before you write a single line. This has already shipped a submodule declaration inside a bug-fix commit and broken CI. | Run `git diff --cached --stat` before every commit, and stage with `git commit -- <paths>` rather than `git add -A`. |
| FG-079 | Enabling an inline core feature that also exists as a module | `twow-core` took AutoWorldBuff, AutoDonationPoints, Leech and SoloDungeonRepop back inline from upstream, and this repository still ships each as a module. All four inline paths default off, so the effect only doubles when somebody switches one on. | Leave `Leech.Enable`, `AutoWorldBuff.Enable`, `AutoDonationPoints.Enable` and `SoloDungeonRepopAlive.Enable` off, and drive the behaviour from the module. |
| FG-080 | Editing a generated runtime `.conf` or preserving it across renders | The runtime copy becomes an unreviewed source of truth; a few bytes can change without attribution or a reproducible rollback point. | Change the complete template/reviewed overlay in Git, render from a clean approved revision, and verify the secret-free provenance record. |
