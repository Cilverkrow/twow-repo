#!/bin/sh
# Proves: a message addressed to a bot produces that bot's spoken reply, carried
# the whole way by the real dialogue service running in the real stack, with the
# reply's exact bytes originating outside the server.
#
# ============================ WHAT THIS DOES NOT PROVE =======================
#
# It does NOT prove that a player can type in the game and get an answer in a
# chat channel. It cannot, and neither can anything else in this repository
# today. Read this section before quoting a green run as evidence of
# conversation, because the gap is larger than it looks.
#
# 1. THERE IS NO GAME CLIENT IN CI, AND THERE WILL NOT BE ONE. ARCH-005 records
#    that a headless protocol client is a separate product - SRP6 through
#    realmd, an encrypted world socket, a client-side world model rebuilt from
#    SMSG_UPDATE_OBJECT, its own navmesh and DBC - not a refactor. So nobody can
#    log in and whisper a bot here. The speaker below is an HTTP request, not a
#    person.
#
# 2. THE WORLDSERVER IS NOT IN THE LOOP AT ALL. The C++ half that will call this
#    endpoint from the in-world chat path is still in flight. What runs here is
#    the service half: contract decoding, trait resolution, prompt construction,
#    the token budget, the circuit breaker, the outbound HTTP call, response
#    parsing, the filter and the silence rules. Everything from "a bot heard
#    something" to "call the endpoint", and everything from "a reply arrived" to
#    "a bot says it", is untested by this file.
#
# 3. THE WORLDSERVER'S OWN LLM CHAT PATH IS DEAD CODE IN THIS TREE, so there is
#    no second route worth pointing at a model. Two facts, both checked against
#    the pinned core rather than assumed:
#
#      * `PlayerbotLLMInterface::Generate` - the single function every in-world
#        bot-speech route funnels through, and the only caller is
#        `ChatReplyAction::GenerateResponsePackets` in SayAction.cpp - has had
#        its network client removed and unconditionally returns an empty string
#        ("LLM gateway network client removed", PlayerbotLLMInterface.cpp). So
#        `AiPlayerbot.LLMEnabled` and `AiPlayerbot.LLMApiEndpoint` cannot make a
#        bot say a generated line no matter what they are set to. Pointing them
#        at the stub server would be theatre, so this check does not, and the
#        rendered config is left exactly as it is.
#
#      * The one live LLM HTTP surface that remains, `DebugAction::HandleLLM`
#        (reachable as `.rndbot debug <bot> llm <prompt>`, and `.rndbot` IS the
#        one bot command the console accepts), refuses unless
#        `requester->GetSession()->GetSecurity() >= SEC_MODERATOR`. Driven from
#        the console there is no requester but the bot itself, and every bot
#        session in the tree is constructed with a hardcoded `SEC_PLAYER`
#        (PlayerbotMgr.cpp twice, RandomPlayerbotFactory.cpp once) - it is not
#        read from the account, so no amount of `.account set gmlevel` reaches
#        it. That path therefore requires a logged-in moderator, i.e. a client.
#
#    A console-driven test of a bot actually speaking an LLM line is not
#    available. That is a finding, not an omission.
#
# 4. NOTHING A BOT SAYS IS WRITTEN TO A DATABASE TABLE, so there is no
#    persistent artefact to assert on either. `World::LogChat` is called only
#    from `WorldSession::HandleMessagechatOpcode`, so direct `Player::Say` calls
#    - which is how bots speak - never reach chat.log; and the only live
#    LogsDatabase writer in the whole core is an INSERT into `character_loot`.
#
# So: this is the furthest-reaching honest check available today. It is a real
# service, in the real stack, over real HTTP, with a real reply - and it stops
# at the service boundary. The day the C++ half lands, this file is the thing
# that will be extended past that boundary, not replaced.
#
# ============================== WHAT IT DOES PROVE ==========================
#
#   A. The worldserver container can reach bot-brain by service name on the
#      project network. That is the exact seam the C++ half will use, and it is
#      the one worldserver-side fact that is provable now. Checked only when
#      there is client data, because otherwise there is no world container.
#
#   B. A structured utterance addressed to a bot comes back as `spoke: true`
#      with a reply whose bytes are EXACTLY the sentence the stub model server
#      is holding - read back out of the stub itself rather than hardcoded here,
#      so a pass means the sentence travelled rather than that two constants
#      agree. The stub's own call counter must also have advanced, which is what
#      rules out a canned reply that never left the process.
#
#   C. A dead model is silence, not an outage. With the stub stopped, the same
#      call still returns HTTP 200 with `spoke: false` and a named reason. This
#      is the property that matters most in a live realm: the thing that makes
#      bots talk must never be able to make the game fail. It is asserted by
#      actually stopping the container, and the stub is put back afterwards.
#
# ================================ ON SKIPPING ===============================
#
# Every precondition below skips with the specific thing that is missing, and
# never fails for it - the distinction 30-bot-persistence.sh and
# 50-bot-initialisation.sh both draw deliberately. A feature that is absent is
# not a feature that is broken. But once the endpoint answers, a wrong answer is
# a FAILURE: at that point the question was asked and the wrong thing came back.
#
# On a checkout where `POST /v1/dialogue` does not exist yet (twow-repo#265),
# this skips saying so. That is the honest report, and it is why the file is
# worth landing before the endpoint is: the stub, the compose overlay and the CI
# wiring are the parts that take a day to get right, and they are ready when the
# endpoint arrives.
set -eu
# shellcheck source=test/smoke/lib.sh
. "$(dirname "$0")/lib.sh"

here=$(cd "$(dirname "$0")" && pwd)

# bot-brain and the stub each live in their own compose file, and deliberately
# so: docker-compose.yml must keep starting and playing with both absent (ADR-
# 0024 invariant 4), and the cleanest guarantee of that is that it does not
# mention either. All three declare `name: twow`, so composing them together
# lands them in one project on one network.
: "${TWOW_BOT_BRAIN_FILE:=deploy/compose/bot-brain.yml}"
: "${TWOW_LLM_STUB_FILE:=deploy/compose/llm-stub.yml}"
: "${TWOW_BOT_BRAIN_SERVICE:=bot-brain}"
: "${TWOW_LLM_STUB_SERVICE:=llm-stub}"
: "${TWOW_BOT_BRAIN_URL:=http://bot-brain:8085}"
: "${TWOW_LLM_STUB_URL:=http://llm-stub:8099}"
# The speaker's name. Two to twelve letters, nothing else: bot-brain validates
# it as a character name and rejects digits and punctuation outright.
: "${TWOW_DIALOGUE_SPEAKER:=Smoketester}"
: "${TWOW_DIALOGUE_MESSAGE:=Well met. Which way to the inn from here?}"

require_stack

[ -f "$TWOW_BOT_BRAIN_FILE" ] \
    || skip "no $TWOW_BOT_BRAIN_FILE - the dialogue service is not part of this checkout"
[ -f "$TWOW_LLM_STUB_FILE" ] \
    || skip "no $TWOW_LLM_STUB_FILE - there is no stub model, and CI has no real one"
[ -f "$here/dialogue-probe.py" ] \
    || fail "test/smoke/dialogue-probe.py is missing; this check has no HTTP client"

# Every compose call in this file needs all three files, so lib.sh's `dc` (which
# is pinned to the main stack alone) cannot be used for them.
dcx() {
    if [ -f "$TWOW_ENV_FILE" ]; then
        docker compose -f "$TWOW_COMPOSE_FILE" -f "$TWOW_BOT_BRAIN_FILE" \
            -f "$TWOW_LLM_STUB_FILE" --env-file "$TWOW_ENV_FILE" "$@"
    else
        docker compose -f "$TWOW_COMPOSE_FILE" -f "$TWOW_BOT_BRAIN_FILE" \
            -f "$TWOW_LLM_STUB_FILE" "$@"
    fi
}

running() {
    dcx ps --format '{{.Service}} {{.State}}' 2>/dev/null \
        | awk -v s="$1" '$1 == s && $2 == "running" { found = 1 } END { exit !found }'
}

running "$TWOW_LLM_STUB_SERVICE" \
    || skip "the $TWOW_LLM_STUB_SERVICE service is not running; bring it up with -f $TWOW_LLM_STUB_FILE (there is no model in CI, so without it nothing can answer)"
running "$TWOW_BOT_BRAIN_SERVICE" \
    || skip "the $TWOW_BOT_BRAIN_SERVICE service is not running; bring it up with -f $TWOW_BOT_BRAIN_FILE"

# A THROWAWAY container from the stub's image, not `exec` into the running stub.
#
# Two reasons, and the second is the load-bearing one. The stub is the only
# image in this project with an HTTP client - bot-brain is `scratch` with no
# shell, the worldserver image has neither curl nor python - and it is on the
# project network, so it can address the services by name with no published
# port. And proof C below STOPS the stub: a client that dies with the server it
# is interrogating could not make that assertion at all.
#
# `run` publishes no ports (that needs --service-ports), so this never collides
# with the running stub. --no-deps because nothing here needs the rest of the
# graph started on its account.
#
# The script is handed over with `python3 -c`, NOT piped on stdin. Piping is the
# obvious form and it HANGS: `docker compose run -T` with redirected stdin does
# not deliver EOF on a Docker Desktop host, so `python3 -` waits forever and the
# check times out rather than failing - observed while writing this. Under `-c`,
# argv[0] is "-c" and the mode is still argv[1], so the probe is unchanged.
probe_src=$(cat "$here/dialogue-probe.py")
probe() {
    dcx run --rm -T --no-deps "$TWOW_LLM_STUB_SERVICE" \
        python3 -c "$probe_src" "$@" 2>/dev/null
}

work=$(mktemp -d)
# shellcheck disable=SC2064  # expand $work now: it is gone by the time this runs
trap "rm -rf '$work'" EXIT INT TERM

# Read one emitted field. Empty when absent, which the probe guarantees is
# indistinguishable from "present but empty" on purpose.
val() { sed -n "s/^$1=//p" "$2" | head -n 1; }

# ---------------------------------------------------------------- proof A
#
# The worldserver's reach to the planner. Not a dialogue fact, but it is the
# seam the C++ half will call across, and a broken network here would otherwise
# only be discovered by that half failing for a reason that looks like its own.
#
# bash's /dev/tcp because the runtime image has no curl, no nc and no python -
# the same reason the compose healthchecks are written that way.
#
# Only while the world container is actually running. Without client data it
# cannot start at all, and `docker compose exec` cannot attach to a Restarting
# container - so anything else here would report a world that is down as a
# network fault, which is the mistake lib.sh's have_client_data carries a long
# comment about.
if have_client_data && [ "$(world_container_state)" = "running" ]; then
    if dc exec -T "$TWOW_WORLD_SERVICE" bash -c \
        "exec 3<>/dev/tcp/$TWOW_BOT_BRAIN_SERVICE/8085" >/dev/null 2>&1; then
        info "the world server can reach $TWOW_BOT_BRAIN_SERVICE:8085 on the project network"
    else
        fail "the world server cannot reach $TWOW_BOT_BRAIN_SERVICE:8085 - the seam the in-world chat path will use is broken"
    fi
else
    info "the world server is not running here, so its reach to $TWOW_BOT_BRAIN_SERVICE is unproven"
fi

# ---------------------------------------------------------------- preconditions
probe stub-stats "$TWOW_LLM_STUB_URL" > "$work/stub0" \
    || fail "could not run the probe container"
[ "$(val http_status "$work/stub0")" = "200" ] \
    || fail "the stub model server is running but did not answer on $TWOW_LLM_STUB_URL/_stub/stats"

expected_reply=$(val reply "$work/stub0")
calls_before=$(val count "$work/stub0")
[ -n "$expected_reply" ] \
    || fail "the stub model server reports no reply sentence; it cannot be used as an oracle"

probe health "$TWOW_BOT_BRAIN_URL" > "$work/health" \
    || fail "could not run the probe container"
[ "$(val http_status "$work/health")" = "200" ] \
    || fail "$TWOW_BOT_BRAIN_SERVICE is running but /healthz did not answer 200"
contract=$(val contract_version "$work/health")
[ -n "$contract" ] \
    || fail "$TWOW_BOT_BRAIN_SERVICE answered /healthz without a contract_version; the request below could not be versioned"
info "bot-brain contract $contract, stub has served $calls_before call(s)"

# ---------------------------------------------------------------- proof B
probe dialogue "$TWOW_BOT_BRAIN_URL" "$contract" \
    "$TWOW_DIALOGUE_SPEAKER" "$TWOW_DIALOGUE_MESSAGE" > "$work/say" \
    || fail "could not run the probe container"

status=$(val http_status "$work/say")
case "$status" in
    404)
        skip "this build of bot-brain has no POST /v1/dialogue (contract $contract); the endpoint is not merged yet (twow-repo#265), so dialogue is unproven here rather than broken"
        ;;
    409)
        fail "bot-brain refused contract $contract as version skew, and $contract is what its own /healthz announced"
        ;;
    200) : ;;
    0)
        fail "no answer at all from $TWOW_BOT_BRAIN_URL/v1/dialogue: $(val raw "$work/say")"
        ;;
    *)
        fail "POST /v1/dialogue answered HTTP $status ($(val code "$work/say"): $(val message "$work/say")) - a dialogue call may only ever be 200, 400, 409 or 413"
        ;;
esac

spoke=$(val spoke "$work/say")
reason=$(val reason "$work/say")

if [ "$spoke" != "true" ]; then
    case "$reason" in
        dialogue_disabled)
            skip "bot-brain answered but dialogue is switched off (BOT_BRAIN_DIALOGUE_ENABLED); the path is present and deliberately not running"
            ;;
        "")
            fail "bot-brain returned spoke=false with no reason; the response contract requires one"
            ;;
        *)
            fail "bot-brain stayed silent with reason '$reason' while the stub model was up and reachable - the reply path is broken, not quiet"
            ;;
    esac
fi

reply=$(val reply "$work/say")
[ "$reply" = "$expected_reply" ] || {
    printf '     %-20s stub holds : %s\n' "$smoke_name" "$expected_reply"
    printf '     %-20s bot replied: %s\n' "$smoke_name" "$reply"
    fail "the reply is not the sentence the model produced; something between the model and the endpoint changed it"
}

probe stub-stats "$TWOW_LLM_STUB_URL" > "$work/stub1" || fail "could not run the probe container"
calls_after=$(val count "$work/stub1")
[ "${calls_after:-0}" -gt "${calls_before:-0}" ] || {
    fail "the reply matched but the stub served no new call ($calls_before -> $calls_after); it did not come over the wire"
}
info "reply travelled from the model: $reply"

# ---------------------------------------------------------------- proof C
#
# A dead model must be silence, not an outage. Asserted by stopping the stub for
# real: a request that cannot reach a model is the single most likely thing to
# happen to a live realm, and the endpoint's whole contract is that it degrades
# to `spoke: false` rather than handing the game an error.
#
# The stub goes back up whatever happens, including on an interrupt, or every
# later run against this stack would inherit a broken model.
restore_stub() {
    dcx start "$TWOW_LLM_STUB_SERVICE" >/dev/null 2>&1 || true
}
# shellcheck disable=SC2064
trap "restore_stub; rm -rf '$work'" EXIT INT TERM

info "stopping the stub model to prove a dead model is silence, not an outage"
dcx stop -t 10 "$TWOW_LLM_STUB_SERVICE" >/dev/null 2>&1 \
    || fail "could not stop $TWOW_LLM_STUB_SERVICE"

probe dialogue "$TWOW_BOT_BRAIN_URL" "$contract" \
    "$TWOW_DIALOGUE_SPEAKER" "$TWOW_DIALOGUE_MESSAGE" > "$work/quiet" \
    || fail "could not run the probe container with the stub stopped"

qstatus=$(val http_status "$work/quiet")
[ "$qstatus" = "200" ] \
    || fail "with the model unreachable, /v1/dialogue answered HTTP $qstatus; a game path must never be handed an error because a model is down"
[ "$(val spoke "$work/quiet")" = "false" ] \
    || fail "with the model unreachable, bot-brain still claimed to have spoken"
qreason=$(val reason "$work/quiet")
[ -n "$qreason" ] \
    || fail "with the model unreachable, bot-brain went silent without naming a reason"
info "model down: HTTP 200, spoke=false, reason=$qreason"

restore_stub

pass "a message to a bot produced its reply from the model over real HTTP, and a dead model is silence (reason=$qreason) - service half only; no player and no worldserver were involved (see the header)"
