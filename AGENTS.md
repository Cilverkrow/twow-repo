# AGENTS.md

Read this before doing anything in this repository. It has two halves:

- **Engineering** — how to build, test and run the project. Start here for code work.
- **Governance** — current evidence precedence and authorization boundaries. Mandatory
  before any analysis, planning, mutation or execution task; the historical collaboration
  hub is no longer a preflight.

Paths are relative to the repository root and use forward slashes. Historical runbooks may
retain absolute `C:\TW\ComTW` paths as evidence; those do not authorize access to or
mutation of that workspace.

---

# Engineering

## What this is

A WoW 1.12 / Turtle-WoW 1.18.1 private server (mangos-zero / VMaNGOS lineage) whose
defining feature is playerbots. Two daemons — `mangosd` (world) and `realmd` (auth) — plus
MariaDB. See `docs/adr/ADR-0026-project-lineage-and-provenance.md` for the upstream chain
-- it is the only document that states it, so read it there and never restate it here.

Four rules follow from it, and getting them wrong has already cost a day:

- **`twow-repo` never merges from upstream.** Its history was rewritten at creation, so
  it shares no ancestry: `git merge-base` returns nothing and no merge is possible, at
  any path. A proposed upstream merge here is always a mistake.
- **`twow-core` is the only place upstream merges happen.**
- **Upstream's live branch is `playerbots-integration-gh`.** Measure, diff and test-merge
  against that and nothing else.
- **Upstream's `main`, `dev`, `1181dev`, `challenges`, `shop` and `1181-rogue-fixes` are
  all ancestors of our fork point** -- dead branches. Measuring against them produces
  nonsense.

## Platform

- **Linux + Docker is the deployment platform.** All operational tooling targets it.
- **Windows is a compile target only.** No quality-of-life work, no CI full-link job.
  `ops/windows/**` is retained as historical evidence and is not extended.
- A clean clone **builds fully on Linux and cannot on Windows**: `core/dep/windows/lib` and
  `core/src/mangosd/mangosd.ico` are committed in twow-core, which builds and links on
  Windows in its own CI. twow-repo does not build for Windows at all.
- See `docs/adr/ADR-0028-platform-and-ci-strategy.md`.

## Build and run

```bash
# One command. Requires client data mounted and deploy/compose/.env present.
make up            # db + migrations + realmd + worldserver
make smoke         # is it alive
make test          # unit + integration
make console CMD='server info'
make down
```

Native Linux build:

```bash
sudo apt install build-essential cmake ninja-build ccache libace-dev \
  default-libmysqlclient-dev libssl-dev zlib1g-dev libbz2-dev \
  libboost-dev libboost-thread-dev libboost-filesystem-dev \
  libboost-system-dev libboost-stacktrace-dev
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/opt/turtle
cmake --build build --parallel "$(nproc)"
```

## Fast-feedback build and runtime workflow

Before any command that may compile C++, build an image, bootstrap a database, or start a
service, write a short plan in the task log. Documentation-only work still records
`BUILD_REQUIRED=NO`; it does not run a build merely to prove that no code changed.

```text
BUILD_PLAN
CHANGE_CLASS=<docs-only|script-or-image-layer|C++|migration|runtime-acceptance>
SMALLEST_SUFFICIENT_TARGET=<exact target and test>
BUILD_REQUIRED=<YES|NO>
REUSE_CANDIDATE=<image/build tree/server/snapshot or NONE>
COMPATIBILITY=<source+core pins; toolchain; generator; flags; arch; linkage; schema/cache>
REUSE_DECISION=<REUSE|REJECT|NOT_APPLICABLE>: <reason>
FULL_BUILD_REQUIRED=<YES|NO>
FULL_BUILD_REASON=<why the smaller target is insufficient, or NOT_APPLICABLE>
EXPENSIVE_LANE=<single task-owned build/run lane, or NONE>
```

Classify first, then use the smallest gate that can falsify the change:

- A script- or image-layer-only change reuses a verified server binary/image and tests
  only the changed layer in a task-isolated environment. Record the reused artifact's
  digest and source provenance. Do not rebuild C++ without a demonstrated dependency.
- A C++ change prefers a compatible incremental build tree and rebuilds only the changed
  target plus its actual compile/link dependencies. Compatibility means the source and
  core pins, toolchain, generator, CMake options, architecture, linkage mode, install
  prefix, and relevant generated inputs agree. `ccache` can reuse compiler output; it is
  not an incremental build tree and does not preserve configured or linked state. Do not
  rebuild unchanged upstream more than once after establishing a compatible artifact.
- Start with a deterministic reproduction and a focused regression. Broaden to component
  integration only after those pass. A full release image and end-to-end runtime proof
  belong at the integration/acceptance gate, not after every edit.
- For container work, try the repository's standard Dockerfile with a verified compatible
  cache before inventing another build path. Run at most one expensive build or runtime
  lane for a task at a time. Before replacing or abandoning it, prove that both the client
  command and its task-owned container/Ninja process have ended. Failed, timed-out, or
  interrupted work is never a passing or reusable baseline.

Measure elapsed time for build, database bootstrap, cache construction, readiness, and
tests separately. Report measured values only; do not claim time saved without comparable
before/after measurements. Inventory candidate build trees, images, caches, worktrees, and
snapshots with bounded, named queries. Record both storage cost and restore/rebuild value;
neither implies the other. Never make a full worktree backup or run a global prune as part
of ordinary iteration.

Readiness is an instance-scoped latch, not a transient log tail. Start observation before
the service, bind it to the container/process identity and start time, and retain the first
valid ready marker for that instance. A fixed last-N-lines query is diagnostic only: noisy
SQL startup output can evict the marker and manufacture a timeout. Keep collected logs
bounded and sanitized; never export unrestricted SQL logs as evidence.

Treat a fresh bootstrap and a warm functional test as different gates. Fresh bootstrap
proves schema creation and the migration ledger. Warm testing proves behaviour against an
existing compatible state. Reuse a warm database snapshot only when source, schema,
migration ledger, and generated cache compatibility are verified, the test receives its
own isolated copy, and snapshot creation/retention has explicit approval. Never infer a
retention decision from test authorization.

Do not use `libboost-all-dev`: it pulls ~230 packages including OpenMPI. Only `thread`,
`filesystem` and `system` are linked.

## Build traps

| Trap | Consequence |
|---|---|
| `CMAKE_INSTALL_PREFIX` is compiled in (`SYSCONFDIR`) | Building under one prefix and copying to another silently ships a server that cannot find its configs. Build where you will run. |
| `TW_ARCH` defaults to `x86-64-v2` | `native` bakes in the build host's CPU. Fine for a hand-built server, fatal for an image. |
| `mangosd` exits on stdin EOF | The container entrypoint holds a FIFO open at `${PREFIX}/run/mangosd.in`. |
| Client data is not in Git | maps/dbc/vmaps/mmaps come from a game client. mmaps generation takes an hour or more. |
| `revision.h` is written into the source tree | A read-only source mount fails to configure. |

## Structure

| Path | Contents |
|---|---|
| `core/` | The server, as a submodule: `core/src/game`, `core/src/shared`, `core/sql`. Not ours to edit here - changes go to twow-core and come back as a pin bump. |
| `modules/` | Every module (`mod-*`), each with its own `src/`, `conf/`, `data/sql/`, `t/`. The vendored bot tree is one of them: `mod-playerbots`. |
| `sql/` | Schema and migrations |
| `deploy/` | `docker/`, `compose/`, `helm/` |
| `test/` | `smoke/`, and unit/integration targets registered with ctest |
| `docs/` | ADRs, footguns, external requirements, issue manifests |
| `ops/` | Helper scripts. `ops/issues/` drives the GitHub tracker. |
| `runbooks/` | Immutable text evidence. Never a deployment input. |

Full rules: `docs/adr/ADR-0025-repository-and-project-structure.md`.

## Invariants

Binding on every module, service, migration and script. Full text in
`docs/adr/ADR-0024-project-invariants.md`.

1. **Bots are persistent — a bot must never be lost.** No code path may silently delete,
   replace, substitute or re-roll a bot identity. Unresolvable member ⇒ `DEGRADED`, never
   a substitution.
2. **Upstream schemas are read-only to us** (`tw_world`, `tw_char`, `tw_logon`, `tw_logs`).
3. **Migrations are forward-only and replay-safe.** Never the literal hash `manual`.
4. **The core must run with every project feature disabled.**
5. **No secrets, binaries or client data in Git.**
6. **Fail closed** — degrade to core behaviour, never to wrong behaviour.

## Work tracking

- **ADRs** (`docs/adr/`) are permanent decisions of record.
- **`docs/FOOTGUNS.md`** is reference material — read it before operating anything.
- **GitHub issues** are the operational tracker.
- **`TODOS.md` and `docs/OPEN-THREADS.md` are indexes, never execution authorization**
  (FG-074).

### Working with issues

**The backlog serves the project, not the other way round.** An issue records that
something *was* worth doing when it was written. It is not authorization, and it is not
evidence that the problem still exists.

**Verify the premise before doing the work.** Manifest bodies are written in the present
tense and are often months old, so they read as statements of current fact when they are
not. REF-001 still opens "the repo has 196 test assertions and runs none of them ... no
`enable_testing()`, no `add_test()`, no CTest registration anywhere" - `ctest` runs six
suites today. Re-check the claim against the tree as it is now. **If the premise is false,
the issue is finished**: say what you actually found and close it.

**Check `core/` first.** twow-core absorbed a large amount of what this tracker still
describes. If core already does it, the issue is done here no matter what the body says.

**ADRs outrank issues.** `docs/adr/` holds the decisions of record. An issue that re-opens
a settled decision is invalid on its face - close it citing the ADR, do not "evaluate" it.
Eluna is the standing example: it is decided, and it ships in core. A title beginning
**Decide**, **Evaluate** or **Restate** is the tell; check it against the tree before
touching it.

**Closing as no-longer-wanted is a normal outcome**, equal in standing to closing as done.
Record which it was and why. Removing work from the plan is progress, not failure.

**Do not file work you are not going to do.** Prefer growing an existing issue over adding
a manifest entry.

#### The mechanics

Issues are a **projection of `docs/issues/*.md`**, not the source of truth. Edit the
manifest and re-run the importer; do not hand-edit an issue body, because the next import
overwrites it.

```bash
ops/issues/import-issues.sh                    # dry run (default)
ops/issues/import-issues.sh --apply            # create anything missing
ops/issues/import-issues.sh --apply --update   # push manifest edits into existing issues
ops/issues/import-issues.sh --apply --only REF-002
```

**`status:` is how an entry retires.** `open` (default) | `done` | `obsolete`. A non-`open`
entry is never created, and `--apply --update` closes an existing issue with the recorded
reason. Without this the tracker cannot represent "we decided not to" and every triage
decision evaporates on the next import - which is exactly how solved work keeps coming
back. `superseded_by:` is prose for humans; it has no effect on the importer.

**Filing new work.** Add a block to the right manifest, then import:

| Manifest | For |
|---|---|
| `10-refactor-tasks.md` | restructuring work (`REF-*`) |
| `20/21/22-runbook-sweep*.md` | items recovered from `runbooks/` |
| `30-deferred-architecture.md` | designed but deliberately out of scope (`ARCH-*`) |

The `id` is the stable key and prefixes the issue title. **The importer matches on that id
prefix, never on the title** - matching on titles once created 27 duplicate issues the
moment titles were reworded.

It matches against issues in **every state**, open and closed. Deduplicating against open
issues only was the first attempted fix for those 27 duplicates and aimed at the wrong
cause: with the id as the key, ignoring closed issues means finishing a task and closing
its issue makes the next run file it again. REF-001 and REF-002 came back as #85 and #86
that way.

**Priorities are `p0`, `p1` or `p2`.** There is no `p3` label, and the importer creates the
issue anyway when it cannot apply a label - so a typo costs you a correctly-titled issue
with no priority on it.

**Closing.** Close with evidence: the commit, the file and line, or the CI run. A comment
saying something is fixed is a lead, not a verdict - verify against the source. If a claim
turns out to be stale, say what you found rather than silently editing the body.
### Ownership when several agents work in parallel

An agent owns **`modules/<name>/**` and nothing else.**

**Work in your own git worktree.** This is the rule that actually protects you, and it
supersedes the one below:

```bash
# Branch from the default branch, whatever it currently is - do not hardcode it.
base=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
git worktree add ../twow-<task> <your-branch> "$base"
```

Committing by path is not enough on its own. Several agents share one checkout, and a
concurrent `git checkout` moves the *branch* under you — so a correctly-scoped
`git commit -- <paths>` still lands on somebody else's branch. That happened: one agent's
two commits went onto another's branch and had to be cherry-picked out and force-pushed
back, with the other agent's branch pointer restored by hand.

Never run `git checkout`, `git switch`, `git stash` or `git reset` in the shared checkout
while others are working. Uncommitted changes have no reflog.

**Do not remove a worktree automatically.** After its PR merges or the task is explicitly
superseded, report the exact worktree path and exact `git worktree remove <path>` command.
Recommend removal only after proving that the tree is clean, a commit exists, the branch is
pushed, the PR is merged/superseded, and untracked evidence is preserved. Removal still
requires explicit authorization; then run the exact remove command without `--force`,
followed by `git worktree prune`. A worktree shares the object store, so it does not
duplicate history, but it is a full checkout and abandoned trees still consume storage.

Note that a squash-merged branch is **not** an ancestor of the target, so
`git merge-base --is-ancestor` will say "not merged" for work that is merged. Check the PR
state instead.

## Where you may write

**This is somebody's daily-use machine, not a dev box for this project.** The owner's
`git/` directory holds ~75 unrelated repositories, and `C:\` root sits next to the Windows
system folders. Treat everything outside the list below as off limits.

**You may write to exactly three places:**

| | |
|---|---|
| your own git worktree | code, commits, build output that belongs to the repo |
| the session scratchpad | anything transient -- archives, extracted data, scratch scripts, logs |
| Docker volumes / containers | services, databases, build trees |

The scratchpad path is given in your environment. Everything temporary goes **under one
directory inside it**, not scattered.

**Never:**
- create directories at `C:\` root, or any other drive root
- write to `V:`, `X:`, `Y:`, `Z:` -- these are network shares
- install software on the host: no MariaDB, no toolchains, no services, no PATH changes
- touch `C:\temp`, `C:\tmp`, `C:\xampp` or anything else you did not create

**Run services in containers.** `deploy/compose/docker-compose.yml` already defines
`mariadb:11.8` with a `db-data` volume and a `db-init` bootstrap. A native database on the
host is not just untidy -- it is a *second, divergent* database, and every later test
becomes ambiguous about which one it hit.

This happened: one agent created `C:\mariadb` (442 MB, a full native install), plus
`C:\wow-build`, `C:\wow-data`, `C:\wow-dbstate`, `C:\wow-extract` (9.2 GB) and `C:\wow-work`
at the drive root. The instruction it was given said "extract to local disk, C: has 241 GB
free" and never named a path -- so **whoever writes the task prompt owns this too**: name
the directory, do not just name the drive.

**If a step genuinely requires something on the host, stop and ask**, and say why. It
almost certainly does not: the stack is containerised, and the extractors are C++ programs
under `core/tools/` that build and run in Docker like everything else.

## When the environment is broken, say so -- do not build a substitute

If a tool, service or endpoint you were told to use is unreachable, **stop and report it**.
Do not quietly assemble a replacement.

This is the rule that would have prevented the worst incident of 2026-09-02, and the
"where you may write" rule above would not have. An agent found the Docker workspace
unreachable:

```
cannot reach the workspace: wstunnel: dialling wss://docker.lhns.de/:
expected handshake response status code 101 but got 404
```

Instead of reporting that, it built a native substitute for the whole containerised stack:
MariaDB installed on the host, vcpkg with ACE and Boost (3.6 GB, 86,805 files), MSVC builds
of the extractors. Hours of work, none of it usable, all of it on the owner's daily-use
machine. Its own assessment afterwards was correct: *"I should have told you this the moment
I found it instead of quietly routing around it -- that is the real error here."*

**A blocked task reported in five minutes is worth more than a workaround delivered in
three hours.** The person who gave you the task can often clear the blocker in one message;
they cannot un-install software from their machine as easily.

Note that "Docker is down" is rarely a single fact. On 2026-09-02 the **local** tunnel to
the workspace daemon was 404ing while the **CI runner's** Docker worked perfectly -- builds
ran there the whole time. Say which one you mean and test the other before concluding you
are blocked.

Two things that make this failure mode easy to fall into, so watch for them:

- **A partial workaround feels like progress.** Extracting client data natively genuinely
  produced usable `dbc/` and `maps/`. It still did not advance the actual goal, which needed
  a running server.
- **The blocker is often outside your reach but inside someone else's.** Provisioning,
  credentials, a tunnel, an admin install -- all one message away for the owner, all
  impossible for you.

**Vendoring another repository: prefer `git subtree` over `git submodule`.** Owner's
standing preference, recorded 2026-09-02.

`core/` is currently a **submodule** pointing at `Cilverkrow/twow-core`. That was chosen
because `twow-repo`'s history was rewritten by `git-filter-repo` at creation and so shares
no ancestry with upstream, making `git merge` impossible -- and the conclusion drawn was
"therefore a second repository is needed". **That conclusion was not fully examined.**
`git subtree pull` does not require shared ancestry; merging an unrelated history into a
subdirectory is exactly what it is for, so a subtree would have avoided the second
repository, the submodule pin, and `--recurse-submodules` entirely.

The submodule stays for now -- it is built, verified and green, and `twow-core` has its own
CI which caught real defects. But **new vendoring uses subtree**, and if the two-repo shape
becomes painful in practice, migrating `core/` to a subtree is the direction to move, not
further submodules.

**Commit by path, never by index.** Inside your worktree this still matters:

```bash
git commit -- path/one path/two      # right
git add -A && git commit             # wrong
git add some/dir/ && git commit      # also wrong: commits the WHOLE index
```

`git commit` commits the index, not the paths of the `git add` that preceded it. Three
separate commits in one session picked up another agent's in-progress work this way:
once through `git add -A`, once through `git add ops/audit/` sweeping a file being
rewritten, and once because `git submodule add` had already staged `.gitmodules` and a
gitlink — which then shipped a submodule declaration inside a commit of unrelated bug
fixes, and broke CI.

Cheap habit that catches all three: run `git diff --cached --stat` and read it before
every commit. If a path you did not touch appears, stop.

**Never edit these** — they are shared, and a change here is a request to the core owner,
not a change you make:

| File | Why |
|---|---|
| `core/src/game/ScriptObjects.h`, `core/src/game/ScriptMgr.{h,cpp}` | every hook lands here; enum tails conflict textually |
| `core/src/game/ModuleSlots.h` | upstream owns this file; a slot is a line in it, so it is a `twow-core` PR plus a pin bump, and it rebuilds ~1060 of 1171 TUs. Read ADR-0021 "Update 2026-09-02" first |
| `modules/CMakeLists.txt`, `core/cmake/ConfigureModules.cmake` | the framework itself |
| `core/src/game/World.h` config enums | values are indices into config arrays |
| anything under `core/` | it is a submodule: a change there is a twow-core pull request, not a commit here |

**In `modules/<name>/<name>.cmake`, only ever touch `mod_<sanitized_name>`.** Never
`target_link_libraries(modules ...)` or `target_include_directories(modules ...)` — that
target is shared, so a `PUBLIC` addition lands on every other module's compile line. CI
rejects it.

Other rules:
- **Namespace config keys** as `<ModuleName>.<Key>`. The ACE config namespace is flat and
  shared; two modules using `Enable` collide silently.
- **Own your schema.** A module writes only its own tables. CI rejects a module migration
  naming `tw_world`/`tw_char`/`tw_logon`/`tw_logs` (ADR-0024 invariant 2).
- **Use `-DMODULES=dynamic` while developing.** Every module has its own target in both
  linkage modes, so compile flags are isolated either way; what dynamic adds is that an
  edit rebuilds one file with no `mangosd` relink. Release builds are static.

## Before changing anything

1. Read `docs/FOOTGUNS.md`. It is verified failure modes, not generic caution.
2. Read `docs/EXTERNAL-REQUIREMENTS.md` if you intend to build or run.
3. Work on a branch. Never refactor the live workspace.
4. Commit `3c2b931` is the tested persistent-roster baseline — do not rewrite it (FG-072).

---

# Governance

## `runbooks/` is frozen evidence, not an input

`runbooks/` holds 976 files of historical evidence from before the core split. It is
kept so decisions can be traced, and it is **never a prerequisite for current work**.
Do not read it to start a task, do not gate a task on it, and do not report against it.

This replaces a mandatory pre-task ceremony (`3.1`-`3.6` of the collaboration hub
policy) that required reading a registry JSON, a hub README, a workstream README and a
SHA-256 manifest **before any analysis, planning, mutation or execution**, and stopping
with `HUB_PREFLIGHT_RESULT=BLOCKED` if the responsible workstream could not be
determined. It made 976 files of dead evidence a blocking gate on every task, and it
outranked reading the code. The full policy is preserved byte-identically at
`docs/history/AGENTS.local-snapshot.md`; nothing is lost, it is simply no longer
mandatory.

## When sources disagree

This ordering is worth keeping, and it survives from that policy unchanged:

1. current, reproducibly verified state of the running system
2. an explicitly approved current technical baseline
3. the repository as it is on disk - files, hashes, `git` output
4. project documentation
5. chat history and session memory

**A lower-ranked source never silently overrides a higher-ranked finding.** In
particular: no chat memory and no earlier summary may stand in for a current local
file, a hash, or a reproducible verification. If documentation and the tree disagree,
the tree wins and the documentation is wrong - say so and fix it.
