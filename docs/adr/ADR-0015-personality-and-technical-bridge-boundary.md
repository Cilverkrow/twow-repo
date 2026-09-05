# ADR-0015: Separate personality policy from the technical LLM bridge

- Status: Accepted
- Date: 2026-08-30
- Primary: WS-10 / WS-70

## Context

Prompts, traits, memory, transport, C++ hooks, configuration, and persistence have different owners and change rates. Combining them in one workstream encourages technical code to embed behavioral policy and personality work to mutate runtime integration.

## Decision

Apply these ownership boundaries:

- WS-10 owns SSC/PlayerBot source analysis, C++ hooks, the external LLM service, wire protocol, process lifecycle, delivery safety, and technical tests.
- WS-70 owns personality traits, prompts, memory rules, dialogue behavior, and content-policy versions.
- WS-30 owns sanitized endpoint/model/limit configuration.
- WS-20 owns migrations needed for persisted profiles or memory.
- WS-40 owns package deployment and process automation.

Interfaces between these areas are narrow, versioned contracts. WS-70 data cannot invoke game actions or bypass the safe response contract. WS-10 transports verified context and does not invent personality rules in C++.

## Consequences

- Personality catalogs can evolve without rewriting process-control code.
- Transport and safety tests remain independent from prompt taste.
- Cross-workstream changes name a primary owner and explicit dependents.

## Evidence

- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/README.md`
- `runbooks/workstreams/WS-70-bot-persoenlichkeiten/README.md`
- `docs/contracts/personality-context-contract-v1.md`
- `docs/MODULARIZATION-ROADMAP.md`
