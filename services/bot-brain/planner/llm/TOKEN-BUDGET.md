# Lane A2: bounded local token accounting (ARCH-003 / #44)

This is one prerequisite, **not authorization for a metered endpoint**. Money
cost caps and rate-limit handling remain separate work. No tokenizer, database,
durable ledger, cluster coordinator or provider is installed by this change.

## Policy and defaults

| Environment variable | Default | Meaning |
|---|---:|---|
| BOT_BRAIN_LLM_INPUT_TOKEN_BUDGET | 32768 | max estimated input units per HTTP request |
| BOT_BRAIN_LLM_OUTPUT_TOKEN_BUDGET | 1024 | max allowed output reservation per request |
| BOT_BRAIN_LLM_MAX_TOKENS | 1024 | existing provider `max_tokens`, must fit output ceiling |
| BOT_BRAIN_LLM_HOURLY_TOKEN_BUDGET | 262144 | input estimate + output reservations in a 1h window |
| BOT_BRAIN_LLM_DAILY_TOKEN_BUDGET | 1048576 | same sum in a 24h window |

Unset selects these finite defaults. Explicit zero/negative/unparseable or
overflowing environment values fail startup, even if inference is off. Input
plus output policy must fit the hourly limit; hourly must fit daily. Direct
`llm.New` retains its documented zero `MaxTokens` -> 1024 default; negative is
invalid. A manually constructed TokenLimits has **no** implicit zero defaults.

LLM remains off by default. The PoC remains unwired. Deterministic planning is
unchanged. Both LLM paths reserve at the same boundary immediately before HTTP
I/O. Redirect following is disabled, so admission does not silently fund an
additional destination. No retries, fallback model, workers or price handling.

## Counting method and safety limit

**Input estimate = UTF-8 byte length of the complete serialized chat request.**
This includes JSON framing, message roles, model, and parameters. It is a simple
auditable accounting estimate, NOT a model tokenizer and NOT a guaranteed upper
bound on provider tokens. A provider can inject hidden templates/system text,
use another encoding, or charge reasoning/cached tokens differently. There is
no assertion of exact tokenizer/model compatibility or an actual billing cap.
Multi-byte text is counted by bytes, not characters or a bytes/4 guess.

Output reserves the full positive `max_tokens` sent in the existing provider
contract. Providers that do not implement that limit compatibly (or require a
different output/reasoning parameter) are not certified. Real token guarantees
need a separately validated model/tokenizer/chat-template contract.

Under one mutex, validate both per-request limits and both remaining windows,
then charge the full input estimate + max output. Denial performs no provider
I/O. Checked subtraction/addition prevents overflow. No partial reservation.

Reservations are **final, never refunded**. Missing/null usage, lower usage,
timeouts, cancellation after admission, transport/status errors, malformed
responses and unknown execution all retain the full charge. Cancellation before
admission charges nothing. There is deliberately no settlement/refund API.

If `usage` is supplied, the supported projection is an exact nonnegative integer
triple `prompt_tokens`, `completion_tokens`, `total_tokens`, with consistent sum.
Unknown/duplicate fields, wrong types, overflow, mismatched sums or values above
the reservation reject the result and permanently stop that budget. This is a
fail-closed compatibility policy, not support for every provider's usage detail
extensions. Missing usage is unknown, never interpreted as zero actual spend.
The PoC now permits this one optional accounting metadata field; all other
strict proposal and envelope rules stand. Late usage cannot refund a new window.

Reported overage is detected **after** execution, so a latch cannot undo already
incurred provider usage. This is another reason not to claim a metered guarantee.

## Scope, clocks, restart and parallelism

`TokenBudget` is local shared state, with no per-bot identifiers. `config.Load`
creates ONE budget for that loaded service configuration. All planners/PoCs
using that config pointer share it. Direct constructors with a nil budget share
one finite package-default budget. Custom constructors MUST share a single
budget for their desired accounting scope, not create budgets per request.

Windows are fixed half-open intervals [0,1h), [1h,2h), ... and [0,24h), ...
from budget construction, not rolling windows or UTC calendar boundaries. At
an exact boundary the corresponding counter resets atomically; daily does not
reset merely because an hour changed. Charges belong to admission time, even
when completion crosses a boundary. Boundary bursts are possible; this is not
a rate/concurrency limiter. Existing request deadlines remain separate.

Production uses Go's monotonic `time.Now().Sub(epoch)`. Injected clocks support
deterministic tests; a backwards elapsed time is denied without refilling old
buckets. `Stop()` irreversibly closes admission for that object across window
changes, but cannot recall in-flight calls. No automatic re-enable API exists.

**Restart/new budget/new replica resets or duplicates the allowance.** This
provides NO hard restart-wide, account-wide or cluster-wide guarantee. Persistent
accounting needs separately approved infrastructure; none is invented here.
Configuration must not be reloaded per request. Process-local accounting is the
explicit delivery boundary of Lane A2, not a production spending approval.

## Tests

Fake clocks test exact boundaries, hour/day changes and backward movement without
waiting. Parallel goroutines contest one budget. Fake HTTP tests cover both
paths, exact serialized input limits, output parameter, zero I/O on rejection,
shared exhaustion, cancellation, timeout, redirects, malformed/missing/low/invalid
usage, and no refunds. Existing PoC, decoder, default-off and golden fixtures
remain part of `go test ./...`.

```sh
go test -count=1 -timeout=60s ./planner/llm ./config
go vet ./...
go test -count=1 -timeout=60s ./...
# When the existing image includes a C compiler for Go's race runtime:
go test -race -count=1 -timeout=60s ./...
```
