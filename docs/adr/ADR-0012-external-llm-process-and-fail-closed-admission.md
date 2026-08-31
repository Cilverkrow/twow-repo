# ADR-0012: External LLM child process with fail-closed admission

- Status: Accepted, deployment pending
- Date: 2026-08-30
- Primary: WS-10

## Context

The existing PlayerBot LLM path contains synchronous HTTP and detached-thread/raw-session patterns that are unsuitable for production ownership, shutdown, and World-thread safety.

## Decision

Integrate the LLM as a disabled-by-default external child process behind a narrow PlayerBot service. The Core owns process and pipe lifecycle but does not call Ollama directly.

Admission is bounded and fail-closed:

- only explicitly permitted bot GUIDs, routes, and non-empty messages may submit;
- queue, message, context, raw response, final text, deadline, and concurrency limits are fixed;
- no database credentials or direct database connection are exposed to the bridge or Ollama;
- World/AI objects and raw pointers never cross the worker boundary;
- completions return as value data and are revalidated in the World thread before at-most-once delivery;
- invalid protocol, timeout, EOF, child failure, model mismatch, or exhausted ledger closes admission for the child instance;
- no automatic retry, resubmit, fallback LLM, or automatic child restart.

Normal non-LLM PlayerBot chat and AI must continue when the external LLM path rejects or fails.

## Consequences

- LLM failure is isolated from the World thread and ordinary bot behavior.
- Delivery cannot target a replaced session or stale route.
- The feature can remain compiled but disabled until deployment and live-test gates pass.
- The old detached-thread/raw-`WorldSession*` delayed-packet path is not reused.

## Evidence

- `runbooks/ssc-source-baseline-01-20260829-193848/stable-source-baseline-report.md`
- `runbooks/ssc-llm-production-bridge-01-phase-a-r2-20260830-170407/REPORT.md`
- `runbooks/ssc-llm-production-bridge-01-phase-b-r1-20260830-194919/REPORT.md`
