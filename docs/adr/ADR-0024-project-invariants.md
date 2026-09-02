# ADR-0024: Project invariants

- Status: Proposed; amended 2026-09-02 (stale bot-tree path corrected)
- Date: 2026-08-31
- Primary: WS-00

## Context

The project has accumulated many correct decisions in individual ADRs, but some of them
express a rule that binds *everything*, not just the subsystem that motivated it. When
such a rule is recorded only inside a subsystem decision, the next subsystem does not
inherit it.

The clearest case is bot persistence. ADR-0010 and ADR-0011 decide that persistent
roster members are never automatically replaced, and FG-044 records the failure mode.
But that binds the roster implementation, not a future planning service, a future
personality store, or a module written next year.

The urgency is not theoretical. `PLAYERBOTS_QUICKSTART.md:93-97` documents that
`AiPlayerbot.DeleteRandomBotAccounts = 1` is a one-shot reset which "will wipe and
recreate the cohort on every subsequent restart" if it is not set back to `0`. One stale
config value silently destroys every bot identity, and nothing objects.

## Decision

The following invariants bind every module, service, migration and script in the
project. A change that violates one is rejected regardless of which subsystem it lives
in. Each is enforced by a test or a CI check wherever enforcement is possible.

**1. Bots are persistent. A bot must never be lost.**
A bot keeps its character, GUID, items, progression, relationships and history across
restarts, migrations, rotations, deployments and refactors. No code path may silently
delete, replace, substitute or re-roll a bot identity. If a roster member cannot be
resolved, the system enters `DEGRADED` and reports it; it never fills the gap with a
different bot.
*Enforcement:* a persistence conformance test in the smoke suite — record the roster,
restart the stack, assert identical GUIDs, item counts and progression — plus a CI guard
rejecting `DELETE` or `TRUNCATE` against character or roster tables outside an
explicitly authorized migration, and a config check that flags
`DeleteRandomBotAccounts = 1`.

**2. Upstream schemas are read-only to us.**
`tw_world`, `tw_char`, `tw_logon` and `tw_logs` are upstream-owned. Project tables live
in project-owned schemas.
*Enforcement:* a CI check on migration file targets.

**3. Migrations are forward-only and replay-safe, and the ledger is evidence.**
No editing an applied migration, no down-migrations, real content hashes, never the
literal `manual` (FG-032, FG-033). A row in a `migrations` table means the file it
names ran to completion — it is a record of what happened, not a list of the files
that were on disk when the bootstrap ran.

That second sentence is new, and it is here because the invariant was asserted for
months without being enforced anywhere. `deploy/compose/db-init.sh` applied every
migration with `--force` and `|| true`, then wrote a ledger row per filename in a
later stage, unconditionally, hashed `manual`. Replay-safety was therefore never
tested: a migration could fail on every single bootstrap and still be marked done,
which is what `20260708055500_ai_playerbot_random_bots_index.sql` did. It ran one
stage before the table it indexes was created, failed with `ERROR 1146`, and was
recorded as applied every time (OPS-020, #123). Four world migrations failed the
same way, on a column added by a migration the bootstrap applied after them. The
same unconditional insert is where the 146 unverifiable `manual` rows of OPS-012
came from.

*Enforcement:*
- `deploy/compose/db-init.sh` applies one file per client invocation with no
  `--force` and no `|| true`, so a failing migration aborts the bootstrap and the
  stack never comes up on a half-migrated database. A ledger row is written only
  after that client exits 0, and carries the uppercase SHA-1 of the file's bytes —
  the digest `AutoUpdater::CalculateFileHash` computes, so the ledger and the files
  on disk can finally be compared.
- CI rejects the literal `manual` in any newly added `.sql`
  (`.github/workflows/ci.yml`, "Reject 'manual' migration hashes"), and
  `test/smoke/10-migrations.sh` fails on a `manual` row in a live database. Those
  two now agree; while the bootstrap was writing `manual` on purpose, the smoke
  check could only warn.
- `test/smoke/15-schema-effects.sh` asserts the *effects* rather than the ledger:
  the composite `idx_owner_bot_event` on `ai_playerbot_random_bots`, and
  `spell_template.script_name` populated. Counting ledger rows cannot catch a row
  that lies, and both of these were silently absent from every fresh bootstrap.
- CI applies the roster migration twice against a clean schema
  (`.github/workflows/ci.yml`, "Apply the roster schema (twice, to prove replay
  safety)"), which is the only place replay-safety is exercised directly.

Still unenforced: nothing checks that an *already applied* migration file has not
been edited afterwards. Recording real hashes makes that checkable for the first
time — a stored hash can now be compared against the file — but no check does it
yet. Nor is replay-safety *within* a file enforced: several world migrations are a
sequence of plain `INSERT`s with no `IGNORE`, so a file that dies halfway leaves
its earlier statements committed and cannot be re-run. Failing loudly at the first
error is what makes that visible; it does not make it safe.

**4. The core must run with every project feature disabled.**
Each module and service is individually switchable off, and the server still starts and
plays.
*Enforcement:* a CI job that builds and smoke-tests with all modules off.

**5. No secrets, binaries or client data in Git.**
Existing policy (ADR-0004, ADR-0019).
*Enforcement:* gitleaks plus a file size and type gate.

**6. Fail closed.**
Project paths degrade to core behaviour rather than to wrong behaviour. An unavailable
dependency never blocks or crashes the world thread. This generalises ADR-0012's
admission rules beyond the LLM bridge.

## Consequences

- These are quotable in review: "this violates invariant 1" is a complete objection.
- Invariant 1 makes the persistent roster (`3c2b931`) load-bearing rather than optional,
  and makes the unpersisted LLM conversation context a defect rather than a limitation:
  it is stored under `manual string`, not `manual saved string`, so it is lost on every
  logout (see ARCH-002).
- Invariant 4 constrains how modules may hook the core: a feature that cannot be
  compiled out is not acceptable.
- Enforcement work is real and belongs to Phase 0, not to a later cleanup. OPS-020
  is what that costs when it is deferred: invariant 3 was quotable in review for
  months while the shipped bootstrap contradicted it on every run.
- Recording real content hashes changes what `Database.AutoUpdate.Enabled = 1`
  would do. `manual` matched nothing on disk, so the updater would have replayed
  every file; a real SHA-1 keyed as `Module + ":" + hash` matches, so the ledger is
  now something the updater can act on rather than a tombstone that only works
  while the updater is switched off.

## Evidence

- `docs/adr/ADR-0010-persistent-rndbot-roster.md`, `ADR-0011`, `ADR-0012`, `ADR-0004`
- `docs/FOOTGUNS.md` FG-032, FG-033, FG-044, FG-047
- `PLAYERBOTS_QUICKSTART.md`
- `modules/mod-playerbots/src/playerbot/PersistentActiveRoster.h`
- `deploy/compose/db-init.sh`, `test/smoke/10-migrations.sh`,
  `test/smoke/15-schema-effects.sh`
- `docs/issues/40-divergence-findings.md` (OPS-020), and `AutoUpdater.cpp`, which
  now lives in the `twow-core` submodule at `core/src/shared/Database/AutoUpdater.cpp`
