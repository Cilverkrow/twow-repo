# ADR-0013: Strict LLM wire, package, and lifecycle contract

- Status: **Transport half superseded 2026-09-02** by the `services/bot-brain` HTTP
  service (see ADR-0012 amendment, ADR-0028). The protocol discipline half stands.
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

## Superseded 2026-09-02: the transport half only

This ADR specifies **three explicitly inherited Windows pipes** and terminating "only the
process handle returned by the owned `CreateProcessW` call". ADR-0028 makes Linux and
Docker the deployment platform and Windows a compile target only, so those mechanics
describe a runtime the project does not deploy on. They are superseded by the
out-of-process HTTP service `services/bot-brain` (Go), called over loopback.

**Superseded, in full:**

- Windows pipes as the wire; `CreateProcessW`; owned-handle termination; the
  inherited-handle risk model.
- The child lifecycle constants as *process* constants -- ready timeout 35,000 ms,
  shutdown timeout 40,000 ms -- and the ZIP-package split (deployment tooling verifies
  and extracts, the Core receives an extracted root, CLI fixed at
  `PackageRoot/bridge/src/cli.mjs`). A container image replaces the package; its identity
  is pinned by digest under ADR-0023, not by a payload manifest the Core validates at
  start.

**Not superseded. These carry over to the HTTP transport unchanged:**

- **Strict UTF-8 NDJSON discipline**: exact fields, types, nullability, state
  relationships and context-bound codes; **unknown or extra data closes admission**.
  Protocol desynchronization is never a partial success.
- **The `ledger_full` latch.** A valid `ledger_full` response creates an irreversible
  latch for that service instance, reset only by an explicitly authorized manual
  restart. This is the admission latch, and it is the reason the fail-closed rule cannot
  be defeated by reconnecting.
- **At most one outstanding command** while the protocol carries no correlation ID
  (FG-057); a transport that adds one must add it explicitly, not assume it.
- **Diagnostics are never protocol.** Response bodies are protocol only; diagnostic
  output is drained separately, bounded, and never interpreted as protocol or model text
  (FG-058).
- **Cleanup never touches unrelated processes** (FG-060).

`services/bot-brain` is on `wip/bot-brain` and is not merged. Until it lands, nothing
implements either transport.
