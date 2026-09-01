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

**3. Migrations are forward-only and replay-safe.**
No editing an applied migration, no down-migrations, real content hashes, never the
literal `manual` (FG-032, FG-033).
*Enforcement:* migration lint in CI.

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
- Enforcement work is real and belongs to Phase 0, not to a later cleanup.

## Evidence

- `docs/adr/ADR-0010-persistent-rndbot-roster.md`, `ADR-0011`, `ADR-0012`, `ADR-0004`
- `docs/FOOTGUNS.md` FG-032, FG-033, FG-044, FG-047
- `PLAYERBOTS_QUICKSTART.md`
- `modules/mod-playerbots/src/playerbot/PersistentActiveRoster.h`
