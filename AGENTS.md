# AGENTS.md

Read this before doing anything in this repository. It has two halves:

- **Engineering** — how to build, test and run the project. Start here for code work.
- **Governance** — the canonical collaboration-hub policy. Mandatory before any analysis,
  planning, mutation or execution task.

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
  `src/mangosd/mangosd.ico` are deliberately not in Git (`docs/adr/ADR-0019-*`).
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
| `src/` | Server source: `game/`, `shared/`, `framework/`, `mangosd/`, `realmd/` |
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

Issues are a **projection of `docs/issues/*.md`**, not the source of truth. Edit the
manifest and re-run the importer; do not hand-edit an issue body, because the next
import will overwrite it.

```bash
ops/issues/import-issues.sh                    # dry run (default)
ops/issues/import-issues.sh --apply            # create anything missing
ops/issues/import-issues.sh --apply --update   # push manifest edits into existing issues
ops/issues/import-issues.sh --apply --only REF-002
```

**Filing new work.** Add a block to the right manifest, then import:

| Manifest | For |
|---|---|
| `10-refactor-tasks.md` | restructuring work (`REF-*`) |
| `20/21/22-runbook-sweep*.md` | items recovered from `runbooks/` |
| `30-deferred-architecture.md` | designed but deliberately out of scope (`ARCH-*`) |

The `id` is the stable key and prefixes the issue title. **The importer matches on that
id prefix, never on the title** — matching on titles once created 27 duplicate issues the
moment titles were reworded.

It matches against issues in **every state**, open and closed. Deduplicating against open
issues only was the first attempted fix for those 27 duplicates, and it aimed at the wrong
cause: with the id as the key, ignoring closed issues means finishing a task and closing
its issue makes the next run file it again. REF-001 and REF-002 came back as #85 and #86
that way.

**Priorities are `p0`, `p1` or `p2`.** There is no `p3` label, and the importer creates
the issue anyway when it cannot apply a label — so a typo here costs you a
correctly-titled issue with no priority on it.

**Reading comments.** Check periodically:

```bash
gh issue list --repo Cilverkrow/twow-repo --state open --limit 100 --json number --jq '.[].number' \
  | while read n; do
      c=$(gh issue view "$n" --repo Cilverkrow/twow-repo --json comments --jq '.comments|length')
      [ "$c" -gt 0 ] && echo "#$n has $c comment(s)"
    done
```

A comment saying something is fixed is a lead, not a verdict. **Verify against the source
before closing** — a fix may live in the live workspace and never have been committed
here, and the repo is what CI and the container build from. Say which it is.

**Updating and closing.** Close with evidence: the commit, the file and line, or the CI
run. If a claim turns out to be stale, comment with what you actually found rather than
silently editing the body. If new work falls out of an issue, file it as its own manifest
entry instead of growing the original.

### Ownership when several agents work in parallel

An agent owns **`modules/<name>/**` and nothing else.**

**Work in your own git worktree.** This is the rule that actually protects you, and it
supersedes the one below:

```bash
git worktree add ../twow-<task> <your-branch> origin/refactor/modular-platform
```

Committing by path is not enough on its own. Several agents share one checkout, and a
concurrent `git checkout` moves the *branch* under you — so a correctly-scoped
`git commit -- <paths>` still lands on somebody else's branch. That happened: one agent's
two commits went onto another's branch and had to be cherry-picked out and force-pushed
back, with the other agent's branch pointer restored by hand.

Never run `git checkout`, `git switch`, `git stash` or `git reset` in the shared checkout
while others are working. Uncommitted changes have no reflog.

**Remove your worktree when your PR merges.** `git worktree remove --force ../twow-<task>`,
then `git worktree prune`. Nineteen worktrees accumulated across `twow-repo` and `twow-core`
in a single day because every agent created one and none removed it. A worktree shares the
object store, so it does not duplicate history -- but it is a full checkout of the working
tree, and the owner's `git/` directory holds ~75 other projects. Leaving yours behind is
clutter in somebody else's workspace.

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
| `core/src/game/ModuleSlots.h` | slot capacity is core; **claim a slot by name at runtime instead** |
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

The canonical collaboration hub policy follows. It is mandatory and unchanged. The
byte-identical local snapshot is preserved at `docs/history/AGENTS.local-snapshot.md`.

BEGIN_CANONICAL_COLLAB_HUB_POLICY_V1

## 3.1 Kanonischer Hub

Der verbindliche Collaboration Hub für alle Arbeiten in dieser Repository-Kopie liegt unter:
`runbooks\workstreams` relativ zum Repository-Root.

Die technische Workstream-ID `WS-00` bis `WS-80` ist der dauerhafte Primärschlüssel.
Sichtbare Chat-Titel sind keine technischen Identitäten.

## 3.2 Pflicht-Preflight für jeden Auftrag

Vor jeder Analyse, Planung, Mutation oder Ausführung prüft der lokale Agent:

1. `canonical-workstream-registry-v1.json` vollständig lesen.
2. `runbooks\workstreams\README.md` vollständig lesen.
3. Den zuständigen Workstream anhand der Registry und des Auftragsziels bestimmen.
4. Die zugehörige Workstream-`README.md` vollständig lesen.
5. Für den Auftrag relevante, dort referenzierte Artefakte direkt verifizieren.
6. Den Hub-Manifeststatus (`runbooks\workstreams\sha256-manifest.txt`) prüfen.
7. Widersprüche oder fehlende Informationen feststellen und dokumentieren.

Kein Chatgedächtnis oder frühere Zusammenfassung darf eine aktuelle lokale Datei,
einen Hash oder eine reproduzierbare Verifikation ersetzen.

## 3.3 Prioritätsordnung

Bei widersprüchlichen Informationen gilt in dieser Reihenfolge:

1. aktuell und reproduzierbar verifizierter Produktionszustand  
2. ausdrücklich freigegebene aktuelle technische Baseline  
3. `canonical-workstream-registry-v1.json`  
4. Hub-`README.md` des zuständigen Workstreams  
5. direkt referenzierte Reports, Handoffs und Manifeste  
6. übrige lokale Dokumentation  
7. Chatverlauf und Projektgedächtnis  

Ein niedriger priorisierter Eintrag darf einen höher priorisierten Befund nicht stillschweigend ersetzen.

## 3.4 Stop-Regel

Vor jeder Mutation wird mit `HUB_PREFLIGHT_RESULT=BLOCKED` sofort gestoppt, wenn:

- der zuständige Workstream nicht eindeutig bestimmbar ist;
- eine erforderliche Datei fehlt oder nicht lesbar ist;
- ein vorgeschriebener Hash nicht stimmt;
- Registry, Workstream-README und überprüfter Ist-Zustand widersprüchlich sind;
- eine benötigte Referenz nur im Chatgedächtnis behauptet wird;
- eine Mutation mehrere Workstreams betrifft ohne eindeutigen primären Eigentümer;
- Berechtigungen für die beabsichtigte Mutation fehlen.

Keine eigenmächtige Reparatur oder Erweiterung des Auftrags.

## 3.5 Schreibregeln

Der Collaboration Hub ist kein allgemeiner Ort für ungeprüfte Zwischenstände.
Neue Ergebnisse müssen zuerst als eigenständige, reproduzierbare Artefakte im vorgesehenen
Runbook- oder Workstream-Kontext abgelegt werden.

Änderungen an folgenden Hub-Dateien sind nur durch ausdrücklich autorisierte Hub-Aktualisierungsaufträge zulässig:

- `canonical-workstream-registry-v1.json`
- globale Hub-`README.md`
- Workstream-`README.md`
- Hub-`sha256-manifest.txt`

Bestehende Artefakte dürfen nicht kopiert, verschoben, gelöscht oder physisch zusammengeführt werden, sofern dies nicht gesondert autorisiert wurde.

## 3.6 Abschlussnachweis

Jeder lokale Abschlussbericht enthält mindestens:

- `HUB_PREFLIGHT_RESULT=PASS|BLOCKED`
- `CANONICAL_REGISTRY_READ=YES|NO`
- `GLOBAL_HUB_README_READ=YES|NO`
- `WORKSTREAM_ID=...`
- `WORKSTREAM_README_READ=YES|NO`
- `HUB_MANIFEST_VERIFIED=YES|NO`
- `REFERENCED_ARTIFACTS_VERIFIED_COUNT=...`
- `SOURCE_OF_TRUTH_CONFLICT_COUNT=...`
- `UNRESOLVED_REFERENCE_COUNT=...`
- `HUB_MUTATIONS_PERFORMED=...`
- `NEXT_TASK_AUTHORIZED=NO`

Bei mehreren beteiligten Workstreams zusätzlich:

- `PRIMARY_WORKSTREAM_ID=...`
- `DEPENDENT_WORKSTREAM_IDS=...`

END_CANONICAL_COLLAB_HUB_POLICY_V1
