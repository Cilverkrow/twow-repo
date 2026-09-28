# Project documentation map

This repository is a source-controlled project view, not a self-contained server installation. Start here before building, testing, or operating it.

## Current project state

- [Root TODOs](../TODOS.md) — concise checklist of every open work item; never execution authorization.
- [Open threads](OPEN-THREADS.md) — unfinished work, ownership, dependencies, and next gates.
- [Footguns](FOOTGUNS.md) — known ways to produce a wrong result, damage state, or misread the evidence.
- [External requirements](EXTERNAL-REQUIREMENTS.md) — tools, runtime data, services, credentials, and artifacts intentionally absent from Git.
- [Windows build resources](BUILD-RESOURCES.md) — pinned external icon/library prerequisites and their temporary materialization contract.
- [Compiler warning triage](COMPILER-WARNING-TRIAGE.md) — REF-005 classifications, repository ownership, and follow-up gates.
- [Claude Code restructuring handover](HANDOVER-CLAUDE-CODE.md) — verified starting state, constraints, intended module seams, and proposal criteria.

## Decisions and boundaries

- [Architecture Decision Records](adr/README.md)
- [Decision register](adr/DECISION-REGISTER.md)
- [Reconstruction sources](adr/SOURCES.md)
- [Repository boundaries](REPOSITORY-BOUNDARIES.md)
- [Configuration as code and provenance](CONFIGURATION-AS-CODE.md)
- [Repository provenance](PROVENANCE.md)
- [Modularization roadmap](MODULARIZATION-ROADMAP.md)
- [Security policy](SECURITY.md)

## Designs (proposals, not decisions)

- [Rogue as a tank variant](design/rogue-tank.md) — Turtle data analysis and bot design for #367; needs owner decisions before any implementation.
- [Shaman tank: Enhancement rework](design/shaman-tank.md) — phase 1 (bots first) design for #357 based on the owner talent line of 2026-09-27: per-row IDs, route (spell change vs. bot aura), Elemental Weapons values, bot design; owner decisions in section 11; stage 2 (real client talents) in section 12 and `ops/clientpatch/changes/0357-shaman-talents/`.
- [Client patch pipeline](design/client-patch-pipeline.md) — design for #409 (rev. 2): Nostalgia Launcher as the distribution route (assets/mods/addons catalogues over HTTPS on the Radmin host), WoW-Spell-Editor DBC ↔ SQL build with an independent diff check, `patch-X.mpq`, client vs. server DBCs, version check, graphics, staged plan; owner decisions in section 9.
- [Bot-bot groups](design/bot-groups.md) — #365: ad-hoc quest groups (step 2, owner contract), optional leader-driven group quest log (step 3), config keys, diagnostics, acceptance.
- [Map and dungeon tooling](design/map-tooling.md) — research and design for #412/#427: 1.12 vs 3.3.5 map formats, editors/converters (no 1.12 Noggit), extractor limits and silent failure in our core, login guard, pilot path for the Scarlet Citadel on map 45 (reuse vs new terrain, decided at train 10), tools M1–M9 inside the #409 toolchain; decisions in section 8.

## Authority warning

The repository documents and reproduces work, but it does not authorize deployment, database mutation, process control, or rollback. Current verified runtime state outranks these documents. Historical runbooks can contain workstation-specific absolute paths and point-in-time observations; treat them as evidence, not executable instructions.

The long-form root `README.md` is inherited from the source fork and contains historical feature descriptions. Its claims about bot counts, enabled features, and runtime behavior are not a current operations status page. Use `AGENTS.md`, the files above, and fresh runtime evidence instead. The collaboration hub under `runbooks/workstreams` is frozen historical evidence, not a current prerequisite or routing authority.
