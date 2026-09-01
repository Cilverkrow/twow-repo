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
MariaDB. See `docs/adr/ADR-0026-project-lineage-and-provenance.md` for the upstream chain.

## Platform

- **Linux + Docker is the deployment platform.** All operational tooling targets it.
- **Windows is a compile target only.** No quality-of-life work, no CI full-link job.
  `ops/windows/**` is retained as historical evidence and is not extended.
- A clean clone **builds fully on Linux and cannot on Windows**: `dep/windows/lib` and
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

**Never edit these** — they are shared, and a change here is a request to the core owner,
not a change you make:

| File | Why |
|---|---|
| `src/game/ScriptObjects.h`, `src/game/ScriptMgr.{h,cpp}` | every hook lands here; enum tails conflict textually |
| `src/game/ModuleSlots.h` | slot capacity is core; **claim a slot by name at runtime instead** |
| `modules/CMakeLists.txt`, `cmake/ConfigureModules.cmake` | the framework itself |
| `src/game/World.h` config enums | values are indices into config arrays |
| root `CMakeLists.txt` | every option lands twice, 400 lines apart |

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
