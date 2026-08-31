# ADR-0014: Deterministic, persisted, fact-bounded bot personalities

- Status: Accepted, integration pending
- Date: 2026-08-29
- Primary: WS-70

## Context

Bot personality must survive restarts and model changes without inventing game facts or stereotypes. Local race variants and professions cannot be inferred safely from appearance or chat.

## Decision

Build a versioned personality profile from verified structured inputs: bot GUID, base race, optional proven race variant, class, learned professions, profile version, and stable seed.

Trait selection is deterministic using SHA-256 ranking over profile version, seed, source type/key, and trait key. Existing profiles are persisted and do not silently change when a trait catalog changes. Deliberate regeneration increments the profile version or uses an audited rebuild state. Profession changes recalculate only profession-derived traits.

Traits influence tone and priorities, never game facts, skills, items, recipes, relationships, or actions. A response activates only a small relevant subset. Real game information comes only from supplied context. Race variants remain absent unless local evidence distinguishes them reliably.

Ollama receives no database connection or credentials. Prompts and responses do not reveal internal GUIDs, trait keys, schema, model pins, or database details. The safe response contract constrains channels, length, language, and disallowed command/action forms.

## Consequences

- A bot keeps a recognizable personality across restarts.
- Catalog evolution is explicit and auditable.
- Unproven cosmetic variants remain null rather than guessed.
- Personality data can later become a versioned data-only package independent of C++ transport.

## Evidence

- `runbooks/personality-context-contract-v1.md`
- `runbooks/bot-personality-discovery-20260828-224032/bot-personality-discovery-report.md`
- `runbooks/ssc-llm-bridge-v1-english-correction-20260830-131349/REPORT.md`
