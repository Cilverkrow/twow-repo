# Phase 1A state and error contract

## Immutable identity

Every accepted request is keyed by the exact pair `(request_id, bot_guid)`.

- `request_id` is canonical lowercase RFC 4122 UUIDv4 only.
- `bot_guid` is a JSON integer in `1..4294967295` and must match the single pinned personality context.
- A frozen request envelope is never modified after validation.
- A terminal frozen completion envelope contains the identical key and one outcome: `ready`, `failed`, or `expired`.
- Lifecycle status is a separate frozen snapshot. This permits `consumed` to be recorded without mutating or redelivering the completion.

## State machine

```text
validated -> queued
validated -> failed(queue_full)
validated -> expired(expired_before_run)

queued -> running
queued -> expired(expired_before_run)
queued -> failed(shutdown_cancelled | shutdown_timeout)

running -> ready
running -> failed
running -> expired(stale_result)

ready -> consumed
ready -> expired(expired_before_consume)
failed -> consumed
expired -> consumed

consumed -> no transition
```

At every deadline boundary, `now >= expires_utc` means expired. Text from an inference that completes late, or from a ready result that is not consumed before expiry, is discarded and cannot be returned by `consume`.

## Admission and identity results

| Result | Behavior |
|---|---|
| `queued` | Frozen request and prompt snapshot admitted to FIFO queue. |
| `duplicate` | Exact pair already exists; current status returned, no enqueue and no new attempt. |
| `identity_mismatch` | Existing `request_id` belongs to another GUID; neither record is changed. |
| `queue_full` | Valid key receives a stored keyed `failed` completion with `attempt_count=0`; later identical submission is `duplicate`. |
| `expired` | Valid but already-expired key receives a stored keyed `expired` completion with `attempt_count=0`; it is never queued. |
| `ledger_full` | Bounded duplicate ledger is saturated; request is not stored and no attempt occurs. |
| validation error | Request is rejected before admission and makes zero transport attempts. |

## Completion rules

- The worker owns a unique internal attempt token and commits only while the matching job remains `running`.
- Completion `request_id` and `bot_guid` must exactly match the request; otherwise `completion_mismatch`.
- Response model must exactly match the pin; otherwise `response_model_mismatch`.
- A result arriving after expiry, cancellation, failure, or another terminal transition is stale and discarded without state regression.
- The first consume atomically removes the completion from the registry and returns it with a `consumed` status. A second consume returns `already_consumed` and no completion.

## Single-attempt invariant

`attempt_count` is always 0 or 1. It becomes 1 immediately before the sole transport call. There is no retry loop, retry middleware, redirect handling, model fallback, or resubmission path inside the bridge. Queue-full, ledger-full, validation, mismatch-before-admission, queued expiry, and queued shutdown use zero attempts.

## Shutdown ownership

Shutdown first closes admission. It can drain within a finite deadline or cancel immediately. At drain timeout, queued jobs become failed, the active request's owned `AbortController` is cancelled, and the single worker task is awaited before shutdown reports `stopped`. The implementation creates no worker thread, detached thread, game pointer, or callback holding game state.
