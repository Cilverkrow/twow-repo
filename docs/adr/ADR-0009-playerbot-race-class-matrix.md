# ADR-0009: Use the 52-combination effective PlayerBot matrix

- Status: Constraint accepted, allocation pending
- Date: 2026-08-30
- Primary: WS-10 / WS-30

## Context

The world database contains 59 playable race/class rows, while the zero-core RandomPlayerbot factory accepts only 52. Configuration alone cannot enable the other seven combinations.

## Decision

For current RandomBot generation, the effective validity set is the intersection enforced by the factory: 52 combinations. Goblin is race ID 9 and High Elf is race ID 10 in this local server.

The seven database-valid but factory-rejected combinations are Orc Mage, Dwarf Mage, Dwarf Warlock, Undead Hunter, Tauren Priest, Gnome Hunter, and Troll Warlock. They must not be enabled by config unless a separately reviewed source change extends and tests the factory.

Fixed-count configuration must list every intended effective combination explicitly. Omitted entries are zero in the fixed map, and existing bots are not automatically rebalanced. Strict equal allocation across 52 combinations cannot total exactly 50; 52 is the smallest equal one-per-combination allocation.

## Consequences

- A target of 50 requires an explicitly approved weighted allocation, not a claim of exact equality.
- Config generation remains blocked until the desired allocation is approved.
- Extending the seven combinations is a source decision, not a configuration workaround.
- Existing 4,500-stock distribution and online target are separate concerns.

## Evidence

- `runbooks/playerbot-discovery-matrix-preflight-02-20260830-173815/report.md`
- `runbooks/external-evidence/PLAYERBOT-CLASS-RACE-MATRIX-01/matrix-summary.txt`
