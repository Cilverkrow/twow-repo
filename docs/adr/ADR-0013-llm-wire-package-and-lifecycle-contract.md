# ADR-0013: Strict LLM wire, package, and lifecycle contract

- Status: Accepted, deployment pending
- Date: 2026-08-30
- Primary: WS-10 / WS-40

## Context

An external child adds protocol ambiguity, package-integrity risk, inherited-handle risk, and shutdown deadlocks. The CLI responses have no correlation ID, so concurrent commands cannot be matched safely.

## Decision

Use strict UTF-8 NDJSON over three explicitly inherited Windows pipes. Exactly one CLI command may be outstanding. Ready, submit, status, consume, metrics, shutdown, fatal, and CLI-error envelopes have exact fields, types, nullability, state relationships, and context-bound codes. Unknown or extra data closes admission.

Lifecycle constants are:

- ready timeout: 35,000 ms;
- status poll interval: at least 100 ms;
- total shutdown timeout: 40,000 ms;
- rolling stderr diagnostic cap: 65,536 bytes.

stdout is protocol only; stderr is continuously drained and never interpreted as protocol or model text. On timeout, only the process handle returned by the owned `CreateProcessW` call may be terminated. No name- or PID-search cleanup is allowed.

Package responsibilities are split:

- deployment tooling verifies the outer ZIP, safe paths, root manifest, and extraction into a new directory;
- the Core has no ZIP parser and receives an absolute extracted package root;
- before child start the Core validates reparse-point safety, payload manifest, and pinned Config, personality, and CLI files;
- CLI location is fixed at `PackageRoot/bridge/src/cli.mjs`.

A valid `ledger_full` response creates an irreversible latch for that child instance, reset only by an explicitly authorized manual restart.

## Consequences

- Protocol desynchronization cannot be treated as a partial success.
- Child cleanup cannot affect unrelated Node, Ollama, server, or realm processes.
- Package extraction remains a deployment concern and can be audited independently.
- Isolated Phase B-R1 passed conformance tests and a clean build; it was not deployed.

## Evidence

- `runbooks/ssc-llm-production-bridge-01-phase-a-r2-20260830-170407/bridge-contract-v1.json`
- `runbooks/ssc-llm-production-bridge-01-phase-a-r2-20260830-170407/REPORT.md`
- `runbooks/ssc-llm-production-bridge-01-phase-b-r1-20260830-194919/REPORT.md`
