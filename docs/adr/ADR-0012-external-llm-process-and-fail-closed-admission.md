# ADR-0012: External LLM child process with fail-closed admission

- Status: Accepted; **amended 2026-09-02** -- the admission contract survives, the
  child-process/Ollama transport does not. The replacement transport is ADR-0039.
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

## Amendment 2026-09-02: the transport is replaced, the admission contract is not

ADR-0028 makes Linux and Docker the deployment platform. A Windows child process that
the Core spawns and owns is not a thing that platform has, and the replacement is an
out-of-process HTTP service, `services/bot-brain` (Go), which the Core calls over
loopback instead of spawning.

**What this amendment replaces -- and only this:**

- "external child process" and "the Core owns process and pipe lifecycle". The Core owns
  no process. It owns a client, a deadline and a circuit breaker.
- the direct Ollama relationship. The service, not the Core, decides whether a request
  is answered by a rule planner or by a model.
- ADR-0013's Windows pipe and `CreateProcessW` mechanics, superseded there.

**What survives unchanged and binds the new transport exactly as written above:**

- **Fail-closed, bounded admission.** Only explicitly permitted bot GUIDs, routes and
  non-empty messages may submit; queue, message, context, response, deadline and
  concurrency limits stay fixed.
- **At-most-once delivery on the World thread.** Completions return as value data and are
  revalidated in the World thread before delivery. World/AI objects and raw pointers
  never cross the boundary. FG-055 stands.
- **No automatic retry, resubmit, fallback model, or automatic restart.** Invalid
  protocol, timeout, EOF, service failure, model mismatch or an exhausted ledger closes
  admission; reopening it is an explicit authorized act.
- **No database credentials or connection reach the bridge**, and normal non-LLM
  PlayerBot chat and AI continue when the LLM path rejects or fails (ADR-0024 invariant
  6).

The service is on `wip/bot-brain` and is not merged; until it is, neither transport is
live. The admission rules above are binding on whatever transport lands.
