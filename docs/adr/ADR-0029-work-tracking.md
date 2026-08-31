# ADR-0029: Work tracking — ADRs, footguns and generated issues

- Status: Proposed
- Date: 2026-09-01
- Primary: WS-00 / WS-80
- Relates to: ADR-0002 (evidence authority), ADR-0018 (runbook retention), ADR-0025 (structure)

## Context

Open work is currently spread across `docs/OPEN-THREADS.md` (OT-001…OT-026), `TODOS.md`,
the refactor plan, and a large body of runbook evidence. None of it is a tracker: nothing
has a state, an assignee or a closing event, and the same item appears under different
wording in several files.

The repository is otherwise ready for one — GitHub issues are enabled, `gh` is
authenticated, and the tracker started empty, so this is a clean import rather than a
migration.

## Decision

**Three artifacts, three different jobs.**

| Artifact | Job | Lifetime |
|---|---|---|
| `docs/adr/` | decisions of record | permanent, versioned with the code, superseded rather than edited |
| `docs/FOOTGUNS.md` | reference material — known failure modes | permanent |
| GitHub issues | the operational tracker: work items with state | ephemeral |

ADRs are never converted into issues, and issues never carry a decision. `docs/OPEN-THREADS.md`
OT-001…OT-026 map to issues **keeping the OT id cross-referenced**, so existing ADR and
runbook citations still resolve; the file is reduced to a pointer plus the prose that is
genuinely about deliberately separate decisions.

**Issues are generated, never hand-created.** The source of truth is a reviewable manifest
under `docs/issues/*.md` (YAML-ish frontmatter blocks), imported by
`ops/issues/import-issues.sh`. The manifest is committed and reviewed *before* anything is
created; the mapping is therefore diffable, re-runnable and revertible — a botched import
is closed in bulk and re-created from the same file.

**Idempotency is keyed on the manifest `id`, which prefixes the issue title**
(`OT-024: …`). The importer skips an id that already has an issue.

> **Lesson learned, recorded so it is not repeated:** the first importer matched on the
> **full title**. When titles were reworded between runs, every existing issue looked new
> and the re-run created **27 duplicates**. Matching must be on the id prefix alone. A
> title is editable prose; the id is the key.

**Labels** (created by the importer, so they cannot drift from the manifest):

- workstream `ws-00` … `ws-80`, mirroring the collaboration hub so the governance model
  stays addressable by the same key;
- priority `p0` (blocks architecture or release) / `p1` (correctness and scale) /
  `p2` (maintainability and provenance);
- origin `from-runbook` (recovered from runbook evidence), `deferred-architecture`
  (designed, deliberately not in this refactor), `refactor` (part of the OT-025
  restructuring).

**Milestones**: one per phase — `Phase 0 - foundations`, `Phase 1 - one-command run`,
`Phase 2 - upstream split`, `Phase 3 - feature modules` — plus `Deferred`.

**Rate limiting**: GitHub applies secondary rate limits to content creation, and a burst
is throttled or partially rejected — the worst outcome for an import. The importer
therefore creates **serially with a 2-second delay** rather than fanning out. Import
throughput is not a problem worth optimising.

## Consequences

- The tracker can be rebuilt from Git at any time; losing the GitHub state loses nothing
  irreplaceable.
- A reworded title is now free. That was the whole point of the id key.
- The importer writes to a shared repository, so the first run of any manifest happens
  after a human review of that file, with `--apply` withheld until then.
- Runbook-sourced items enter the tracker as `from-runbook` issues while the runbooks stay
  in place under ADR-0018; nothing is deleted from `docs/issues/00-refactor-plan.md` until
  the corresponding issue exists and links back to it.
- **`TODOS.md` and `docs/OPEN-THREADS.md` remain indexes and never authorize execution**
  (FG-074, ADR-0018). Neither does an open issue: mutation still requires the workstream
  preflight and an explicit mutation scope.

## Evidence

- `ops/issues/import-issues.sh` (labels, milestones, `full_title` matching, `sleep 2`)
- `docs/issues/00-refactor-plan.md`, `20-runbook-sweep.md`, `21-runbook-sweep-llm.md`,
  `22-runbook-sweep-ops.md`, `30-deferred-architecture.md`
- `docs/OPEN-THREADS.md` (OT-001…OT-026), `TODOS.md`
- `docs/FOOTGUNS.md` FG-074; `docs/adr/ADR-0018-runbook-evidence-retention-before-restructuring.md`
