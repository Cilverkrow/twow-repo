# Decision register

Operational follow-up is maintained in [Open project threads](../OPEN-THREADS.md). Known implementation and operating hazards are maintained in [Footguns](../FOOTGUNS.md), and non-repository prerequisites are listed in [External requirements](../EXTERNAL-REQUIREMENTS.md).

## Accepted decisions

The accepted durable decisions are recorded by **ADR-0001 through ADR-0030**, minus the
supersessions listed at the bottom of this page.

**ADR-0001 to ADR-0019** cover project governance, evidence authority, chat-history
policy, repository boundaries, provenance, modularization, operational ownership,
database safety, PlayerBot population constraints, persistent roster semantics, the
external LLM bridge, personalities, donation progress, professions, riding, current
runbook-evidence retention, and external Windows build inputs.

**ADR-0020 to ADR-0030** were added on 2026-08-31 and 2026-09-01 and were missing from
this register until 2026-09-02:

| ADR | Decision | Status |
|---|---|---|
| ADR-0020 | Split upstream and project code across two repositories (`twow-core` + `twow-repo`) | Proposed; amended 2026-09-02, and its *module-free core* rationale superseded |
| ADR-0021 | Module boundaries and per-module schema ownership; one module system, `modules/` | Proposed; amended 2026-09-02 |
| ADR-0022 | Test strategy: five levels, all registered with CTest | Proposed; amended 2026-09-02 |
| ADR-0023 | Containerization and the one-command contract (`make up` / `smoke` / `test`) | Proposed; amended 2026-09-02 |
| ADR-0024 | Project invariants 1-6, binding on every module, service, migration and script | Proposed; amended 2026-09-02 |
| ADR-0025 | Repository and project structure; folder structure is module structure | Proposed; amended 2026-09-02 |
| ADR-0026 | **Project lineage and provenance -- the single authority for the fork point, the upstream of record, and which repository may merge from upstream** | **Accepted 2026-09-02** |
| ADR-0027 | MariaDB 11.8 is the database platform | Proposed |
| ADR-0028 | Linux and Docker are the deployment platform; Windows is compile-only | Accepted (amended 2026-09-02: Windows CI disabled) |
| ADR-0029 | Work tracking: reviewable issue manifests in `docs/issues/` drive the GitHub tracker | Proposed |
| ADR-0030 | A narrowly bounded local MariaDB loopback plaintext client transport profile | Accepted |

ADR-0026 is load-bearing for the others: no document may restate the fork point, the
upstream of record or the merge rules. They link to it.

## Implemented but not automatically deployable

- The source-only GitHub repository exists independently from the live workspace.
- The collaboration hub and nine-workstream model are materialized and verified.
- The graceful-shutdown invariant remains accepted. The historical Windows helper passed
  one interactive evidence run but later failed before `saveall` under headless execution;
  it is retired and unsupported. The Linux/Docker console-FIFO path is canonical.
- The donation progress table migration was applied and the feature-specific persistence path passed; an unrelated PlayerBot deadlock kept the broad runtime test's strict overall result at `FAIL`.
- Persistent-roster Phase B-R2 and LLM-bridge Phase B-R1 passed isolated tests and clean builds. Neither result authorizes production deployment.
- The 50-GUID roster shortlist, ordered snapshot, and unapplied `INITIALIZE` request were generated and verified in Phase C0. They were not applied.
- The 28-path persistent-roster integration passed unit tests, two real disposable-database adapter runs, and a clean Windows Release build. Source commit `3c2b931…` is integrated on local `main` without deployment.
- Relevant sanitized text-only runbooks remain in this repository for the upcoming restructuring; a separate evidence repository is deferred.
- Binary Windows resource and library inputs remain external, pinned prerequisites under ADR-0019.
- The legacy local MariaDB endpoint has an explicit loopback-plaintext client profile
  under ADR-0030. It changes no server setting and grants no query or process authority.

## Explicitly open or separately gated

| Topic | Current state | Required next decision |
|---|---|---|
| Persistent roster Phase C | Not deployed | explicit deployment/migration/config/process authorization |
| LLM bridge Phase C | Paused behind roster priority | explicit deployment and live-inference authorization after roster work |
| Master logout/group persistence | Deliberately excluded from minimal roster scope | separate design and test decision |
| 50/100/500/1000 class-race allocation | Weighted models exist; exact 50 cannot evenly cover 52 combinations | approve a concrete allocation before config generation |
| Seven schema-valid but factory-rejected race/class pairs | Verified technical mismatch | decide whether to extend the factory or retain the 52-pair boundary |
| Profession/riding rollout | Target accepted, changes not applied | approve coordinated Core, Config, migration, item manifest, build, and rollback task |
| Mount coverage | No broad migration allowed | complete and approve a spell/skill-derived mount manifest |
| Donation award amount | Runtime-owned configuration policy | do not infer from the table migration; approve separately if changing |
| Trainer money-loss remediation | Initial event was insufficient evidence; controlled normal-account purchase succeeded | no code or data change without a reproducible failure and new approval |
| Historic `manual` migration hashes | Names/order can match while content provenance is absent | retain the limitation; never treat `manual` as a cryptographic file hash |
| Roster expansion to 250/500 | Generic persistence supports it; only 50→100 has named unit and real-adapter proof | add isolated 100→250 and 250→500 persistence tests plus separate capacity measurements |
| Later evidence repository | No split now | reconsider only after restructuring with stable IDs and link/access/retention/sync contracts |

## Superseded or rejected approaches

- Copying or rewriting historical chats: rejected in favor of cross-references.
- Turning the live workspace into the Git repository: rejected in favor of an independent repository copy.
- Deep modularization before the first import: deferred.
- Committing binaries, live configs, database state, large client assets, logs, or credentials: rejected.
- Selecting “the first 50” RNDBOTs by query/login order or random choice: rejected.
- Replacing unavailable roster bots automatically: rejected.
- Reusing detached-thread/raw-`WorldSession*` delayed packet code for LLM completion: rejected.
- Letting the Core parse/extract bridge ZIPs: rejected; deployment tooling owns package verification and extraction.
- Broadly changing every level-40/60 item for early riding: rejected; manifest-driven coverage is required.
- Treating an unproven trainer event as authorization for repair: rejected.

### Lineage corrections, 2026-09-02

Five documents stated the project's lineage independently and two of them disagreed. The
contradiction cost a full day: an agent trusted the wrong one, test-merged a dead branch,
and measured a delta against a stale ref. All of the following are **retracted**, and
[ADR-0026](ADR-0026-project-lineage-and-provenance.md) is now the single authority.

- **A local post-`git-filter-repo` hash quoted as "the effective upstream merge-base"**
  (`docs/PROVENANCE.md` -> ADR-0020 -> ADR-0026): rejected. It exists nowhere upstream.
  ADR-0026 names the real fork point; FG-076 records the class of error.
- **A third GitHub account placed in the chain between Penqle and Shyalya**: rejected as
  unsupported. Penqle forks directly to Shyalya.
- **Shyalya described as a co-developer of this project rather than an upstream, making
  any upstream offer a decision the two of us would take together**: rejected. Shyalya is
  an unrelated third party; the claim came from misreading a commit-count statistic and a
  `Co-Authored-By: Claude` trailer. Offering fixes upstream is an ordinary pull request.
- **The 70 / 27 / 6 "shared heritage" split of the 103-file delta**: rejected. It was
  measured against a stale snapshot ref instead of the live upstream tip; all 103 files
  exist upstream. REF-003's classification deliverable died with it.
- **"`twow-repo` merges upstream periodically"** (root `README.md`): rejected. It never
  has and never can; only `twow-core` can.
- **"Upstream carries a divergent copy of the bot tree at the path we vacated"**: no
  longer true. Upstream commit `8415f1b` moved its bots to `modules/mod-playerbots`, the
  same path this project uses; REF-016 and PROV-02 were closed as moot.
- **ADR-0020's "module-free core", and "the core does not know the platform exists" as
  the acceptance test for the split**: superseded. `twow-core` PR #9 restores `modules/`
  and `cmake/ConfigureModules.cmake`. `cmake/ConfigureModules.cmake` and
  `modules/CMakeLists.txt` are *unmodified upstream files*, so deleting them on our side
  produces **no merge signal** -- every upstream merge would resolve silently to "still
  deleted", upstream's build system quietly gone behind a green tick. The **mergeable**
  core, which is the reason the split exists, is untouched.
- **ADR-0005's "upstream comparison and blame remain useful"**: superseded. There is no
  shared ancestry in `twow-repo`, so there is nothing to compare or blame across.
- **ADR-0008's `42b8a7f7` as the source baseline anchor**: superseded by the fork point.
- **ADR-0013's Windows-pipe / `CreateProcessW` transport**: superseded by the
  out-of-process `services/bot-brain` HTTP service under a Linux/Docker-only platform.
  Its NDJSON discipline and `ledger_full` admission latch survive, as do ADR-0012's
  fail-closed admission, at-most-once World-thread delivery, and no-auto-restart rules.
- **Four ADRs citing a standalone lint workflow file under `.github/workflows/`**: no
  such file exists. The checks are steps of the `lint` job in `.github/workflows/ci.yml`.
- **Eight ADRs citing the pre-promotion `src/modules/` bot-tree path**: it no longer
  exists; the tree is `modules/mod-playerbots`.
