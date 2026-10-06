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

## Update 2026-10-02 (twow-repo#295)

The riding part of this decision is **superseded in part** by the owner's
decisions of 2026-10-02 (#295), shipped with main train 9. The profession split
above is unchanged.

- **Four stages** instead of two: riding skill 762 = 75/150/225/300, trained from
  level 10/20/40/60 for 50 s / 5 g / 50 g / 500 g (was level 5 for 5 silver and
  level 30 for 1 gold).
- **Mount speed** is chosen by the server, for players and bots only: slow mounts
  (family 1) +60/+100/+100/+100 %, swift mounts (family 2) +60/+100/+140/+180 %.
  NPCs are never affected. Switch `Funserver.Riding.Stages.Enabled`.
- **Mount prices change** by owner decision: the racial vendors sell mount 1 for
  1 g (riding 75, level 10) and mount 2 for 100 g (riding 225, level 40). Special
  vendors (reputation, PvP and others) keep their prices.
- **A client patch is required** now: the new rank spells 61300-61303, their skill
  line rows, SkillRaceClassInfo row 890 (MinLevel 10, a server DBC as well) and the
  riding and mount texts ship with client patch 8 in the same window.
- Existing characters keep 75/150; there is no character migration.
- Still valid: the coordinated rollout (core, bots, config, migration, client) and
  the item changes from a complete mount manifest instead of a broad
  `required_level IN (40,60)` update.
