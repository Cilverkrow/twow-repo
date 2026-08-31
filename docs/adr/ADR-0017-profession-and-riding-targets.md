# ADR-0017: Player/bot profession split and early-riding target

- Status: Accepted, implementation pending
- Date: 2026-08-30
- Primary: WS-10 / WS-20 / WS-30

## Context

The current global primary-profession limit is two. The desired server design gives players more freedom while keeping RNDBOT behavior bounded. Riding trainer levels, item restrictions, and hard-coded PlayerBot thresholds are distributed across Config, Core, and database data.

## Decision

Target rules are:

- normal players: at most six primary professions;
- RNDBOTs: at most two primary professions;
- secondary professions, including Survival, do not count toward the primary limit;
- basic riding: level 5, training price 5 silver;
- advanced riding: level 30, training price 1 gold;
- corresponding mount item requirements and PlayerBot riding thresholds must be made consistent;
- mount purchase prices remain unchanged unless separately approved;
- no client patch is required for the server-side trainer and item requirements.

The bot-specific hard cap must exist in the new executable before `MaxPrimaryTradeSkill` is raised to six. The cap covers every acquisition path and does not delete already learned skills.

Riding is a coordinated change: trainer rows use a new forward migration, PlayerBot hard-coded 40/60 behavior is updated in source, and usable mount items are selected through a complete spell/skill-derived manifest. A broad `required_level IN (40,60)` update is forbidden. Special, event, quest, PvP, profession, class, faction, and custom mounts require explicit classification and unresolved candidates block migration.

## Consequences

- No partial rollout may temporarily allow RNDBOTs six professions.
- Trainer-only changes cannot claim early riding is usable.
- Existing profession skills, riding skills, and acquired items are not removed during rollback.
- Implementation requires coordinated build, config, migration, validation, and rollback authorization.

## Evidence

- `runbooks/db-profession-riding-discovery-01-20260830-010856/report.md`
- `runbooks/db-profession-riding-discovery-01-20260830-010856/proposed-migration-plan.md`
- online decision history in `Bot-Persönlichkeiten`, cataloged in `SOURCES.md`
