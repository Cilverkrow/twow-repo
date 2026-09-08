#!/usr/bin/env bash
# Report whether the external LLM bridge has latched shut on this worldserver.
#
# WHAT THIS CATCHES. The bridge closes admission permanently in two ways, and
# both are designed to be irreversible until someone restarts the process:
#
#   1. ledger_exhausted -- the child instance's bounded duplicate ledger (64
#      keys, never evicted) saturated and returned a valid `ledger_full`.
#      ExternalLLMBridgeService::LatchLedger drops every pending route, closes
#      admission and disables retry. Per ADR-0013 this is by design.
#   2. admission_closed -- any other terminal protocol failure, which closes
#      admission more aggressively still.
#
# Neither auto-restarts, retries, resubmits or falls back. Non-LLM bot chat is
# unaffected by design, so from the outside the server looks entirely healthy:
# bots still talk, they just never say anything the model wrote. There is no
# error rate to watch, no queue to back up, and no metric -- the service exposes
# none for this.
#
# WHY A LOG SCAN AND NOT A METRIC. The latch lives in the worldserver process,
# in C++, and the only signal it emits is one sLog.outError line. It is emitted
# EXACTLY ONCE per child instance -- repeats are suppressed deliberately -- so
# there is nothing to poll and nothing that recurs. That single line is the whole
# observable.
#
# WHICH MEANS RETENTION IS PART OF THE CHECK, and it is the trap worth knowing
# about. deploy/compose/docker-compose.yml caps container logs at 20m x 3 files.
# A busy realm rotates through that in well under a process lifetime, and this
# project has already lost startup lines to exactly that rotation. Once the line
# rotates away the latch is UNDETECTABLE by any means: the state is in process
# memory, admission is closed, and nothing will ever mention it again.
#
# So: run this on a schedule short enough to see the line before it rotates, not
# once after someone notices bots have gone quiet. It exits 1 while the latch is
# present in the window it can see, which is what a monitor should alert on.
#
# Usage:
#   ops/monitoring/check-llm-bridge-latch.sh [container]
#   ops/monitoring/check-llm-bridge-latch.sh --file /path/to/Server.log
#
# Exit codes:
#   0  no latch found in the window examined  (NOT proof there is none -- see above)
#   1  the bridge has latched; admission is closed until a restart
#   2  could not examine anything, so the answer is unknown
set -euo pipefail

container=${1:-mangosd}
source_desc=""
log_cmd=()

if [[ ${1:-} == "--file" ]]; then
    file=${2:?--file needs a path}
    [[ -r $file ]] || { echo "cannot read $file" >&2; exit 2; }
    log_cmd=(cat -- "$file")
    source_desc="file $file"
else
    command -v docker >/dev/null 2>&1 || { echo "docker not found and no --file given" >&2; exit 2; }
    docker inspect "$container" >/dev/null 2>&1 || {
        echo "no such container: $container" >&2; exit 2; }
    # MSYS2 on Windows rewrites anything that looks like a path in a container
    # argument, which mangles container names and paths alike.
    export MSYS2_ARG_CONV_EXCL='*'
    log_cmd=(docker logs "$container")
    source_desc="container $container"
fi

# Both terminal states, not just the ledger one. A check that greps only for the
# latch it was named after stays silent through the other way admission closes.
pattern='external_llm_bridge (state=ledger_exhausted|admission_closed)'

if hit=$("${log_cmd[@]}" 2>&1 | grep -E -- "$pattern" | tail -5) && [[ -n $hit ]]; then
    echo "LATCHED: the external LLM bridge has closed admission on $source_desc"
    echo
    echo "$hit"
    echo
    echo "Admission does not reopen. See docs/runbooks/llm-bridge-ledger-latch.md for"
    echo "confirmation steps and the restart procedure."
    exit 1
fi

echo "no latch found in $source_desc"
echo "note: this only proves the line is not in the retained log window."
exit 0
