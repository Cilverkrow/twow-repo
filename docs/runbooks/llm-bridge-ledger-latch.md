# The LLM bridge has latched shut

Detection and recovery for the two states in which `ExternalLLMBridgeService`
closes admission permanently. Answers LLM-006 (issue #16).

## What has happened

The bridge closes admission for good in two ways, both deliberate (ADR-0013):

| state | cause | log line |
|---|---|---|
| `ledger_exhausted` | the child instance's duplicate ledger (64 keys, never evicted) saturated and returned a valid `ledger_full` | `external_llm_bridge state=ledger_exhausted admission=closed retry=disabled` |
| `admission_closed` | any other terminal protocol failure — malformed NDJSON, a contract mismatch, an oversized line | `external_llm_bridge admission_closed reason=<reason>` |

Neither auto-restarts, retries, resubmits, or falls back. The triggering route is
retired, new requests are rejected locally before an ID is even created, and
recovery requires restarting the worldserver process.

## Why nothing looks wrong

**Non-LLM bot chat is unaffected by design and must not be suppressed.** Bots
carry on talking; they simply never say anything the model wrote. There is no
error rate, no growing queue, no failed health check. A latched deployment is
indistinguishable from a healthy rules-only one unless you look for it.

The warning is emitted **exactly once** per child instance — repeats are
suppressed on purpose — so there is nothing that recurs and nothing to poll.

## The retention trap

`deploy/compose/docker-compose.yml` caps container logs at 20 MB × 3 files. A
busy realm rotates through that in well under a process lifetime, and this
project has already lost startup lines to exactly that rotation.

**Once the line rotates away, the latch cannot be detected at all.** The state
lives in process memory, admission is closed, and nothing will mention it again.

That is why the check below belongs on a schedule, not in an incident response.
Run it often enough to see the line inside the retained window.

## Confirming it

```sh
ops/monitoring/check-llm-bridge-latch.sh              # the mangosd container
ops/monitoring/check-llm-bridge-latch.sh <container>
ops/monitoring/check-llm-bridge-latch.sh --file .../Server.log
```

Exit `1` means latched, `0` means not found **in the window it could see** — which
is not the same as "not latched", per the trap above. Exit `2` means it could not
look at anything, and should be treated as unknown rather than healthy.

A healthy process logs `external_llm_bridge state=ready admission=open` once at
startup. If neither that line nor an error line is present in the window, the
bridge is not running at all — a third state that used to look identical to the
other two.

## Recovery

There is no runtime reset: no command reopens admission, and `reload config` does
not touch it. The child is spawned during service start and the latch is cleared
only by a new process.

**Compose deployment**

```sh
docker compose -f deploy/compose/docker-compose.yml restart mangosd
docker compose -f deploy/compose/docker-compose.yml logs --since 5m mangosd \
  | grep external_llm_bridge
```

**Windows deployment**

```powershell
ops\windows\server\shutdown-tortoise-servers-gracefully.ps1
ops\windows\server\start-mangosd.bat
```

Use the graceful shutdown script rather than killing the process: the bridge's
`Shutdown()` closes the child's pipes and reaps it, and a hard kill can leave the
child process behind.

**Then confirm recovery** by looking for `state=ready admission=open` in the new
process's log. Absence of an error line on its own is not confirmation.

## If it was `ledger_exhausted`, expect it again

The ledger holds 64 keys and **never evicts for the life of the process**, so
exhaustion is a function of how many distinct requests that process has handled,
not of load at any moment. A restart resets the count; it does not raise the
ceiling. A realm that exhausts the ledger once will exhaust it again on the same
schedule, and the fix is a capacity change, not a restart loop.

A *malformed* `ledger_full` behaves differently: it does not latch the ledger, it
triggers `protocol_failed`, which closes admission more aggressively still.

## Related

- ADR-0013 — the wire package and lifecycle contract
- Issue #16 (LLM-006) — the monitoring requirement this answers
- `services/llm-bridge/bridge/state-and-error-contract.md` — the full error vocabulary
