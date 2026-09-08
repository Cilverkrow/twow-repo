/*
 * mod-bot-brain -- configuration.
 *
 * One key turns the whole thing on: BotBrain.Enable, default 0. Everything
 * below it is tuning that only matters once it is 1 (ADR-0024 invariant 4: the
 * core must run with every project feature disabled).
 *
 * Values are read once at startup and on config reload, not per tick: this is
 * read from bot AI ticks on several map threads at once, and sConfig is not
 * something to hammer from there.
 */

#ifndef MOD_BOT_BRAIN_CONFIG_H
#define MOD_BOT_BRAIN_CONFIG_H

#include <cstdint>
#include <string>

namespace botbrain
{
    // Named Settings, not Config: the core has a class called Config, and its
    // sConfig macro (Config/Config.h:92) expands to Config::Lock -- which, from
    // inside namespace botbrain, resolves to OUR type and fails to compile.
    struct Settings
    {
        bool enabled = false;

        // Scheme + host + port, e.g. "http://127.0.0.1:8085". The service
        // listens on loopback by default and there is no reason for this to
        // point anywhere else without a deliberate decision.
        std::string endpoint = "http://127.0.0.1:8085";

        // How long the worldserver is willing to wait for one batch. Sent as
        // deadline_ms so the brain can shed rather than hang, and used as the
        // socket timeout so a wedged service costs a worker thread, not a bot.
        uint32_t timeoutMs = 750;

        // Minimum gap between plan requests for one bot. This is a tier-2
        // decision loop: seconds, not ticks.
        uint32_t intervalMs = 15000;

        // Backoff after a failed or empty round trip, per bot.
        uint32_t backoffMs = 60000;

        // Ceiling on concurrent HTTP worker threads across all bots. Batching
        // means one worker serves many bots at once, so this now bounds
        // concurrent BATCHES, not concurrent bots -- a much smaller number for
        // the same safety property: a brain that stops answering must cost a
        // bounded number of threads.
        uint32_t maxInFlight = 8;

        // How long a batch may sit accumulating snapshots before it is sent
        // even if it never reaches the negotiated max batch size. Batching is
        // the design (services/bot-brain/contract/wire.go:16-20), but a realm
        // with three bots must not wait for 2045 more of them to show up
        // before anyone gets a plan -- this deadline is what keeps a quiet
        // server responsive.
        uint32_t batchFlushMs = 200;

        // How many POIs one snapshot may carry, nearest first. The whole
        // partition list for a bot can run to hundreds; the brain chooses among
        // what it is offered and does not need all of them.
        uint32_t maxPois = 24;

        // How long a POI table stays resolvable after the snapshot that built
        // it. An intent naming a POI older than this is dropped: the ids are
        // snapshot-scoped by contract, and a stale destination is exactly what
        // that rule exists to prevent.
        uint32_t poiTableTtlMs = 120000;

        // ------------------------------------------------------------------
        // Dialogue (POST /v1/dialogue)
        // ------------------------------------------------------------------
        //
        // A SECOND switch under BotBrain.Enable, defaulting OFF, and that is
        // not belt-and-braces: planning is free and local, while dialogue
        // spends model tokens every time a player types. A realm that wants
        // bots to travel intelligently has not thereby agreed to pay for them
        // to talk, so turning the brain on must not start a meter.
        bool dialogueEnabled = false;

        // How long a dialogue round trip may take. SECONDS, not the plan
        // path's milliseconds-under-a-second, because the thing on the far end
        // is a model: a self-hosted 7B on CPU measured about eight seconds a
        // call (LLM-011). Affordable only because this call is made from the
        // chat path's own async worker -- see BotBrainDialogue.h.
        //
        // Sent as deadline_ms as well as used as the socket timeout, so the
        // service can answer with silence instead of being hung up on.
        uint32_t dialogueTimeoutMs = 8000;

        // Ceiling on concurrent dialogue calls across all bots.
        //
        // Eight, matching DefaultMaxDialogueInFlight on the service side, and
        // the number is bounded by the same thing on both: a model serves a
        // handful of concurrent calls before each gets slower rather than more
        // getting served. The cost this bounds HERE is different and worse
        // though -- each in-flight call is holding a worldserver worker thread
        // that the chat path spawned per message. Over the limit a bot is
        // silent immediately rather than queued: a queue here would accumulate
        // load during exactly the incident where accumulating it is fatal.
        uint32_t dialogueMaxInFlight = 8;

        // Log every applied intent at BASIC level. On by default because the
        // acceptance check for this module is "a bot's travel target is set
        // from an intent", and that is only checkable if it is logged.
        bool logApplied = true;
    };

    // The live configuration. Read-only outside LoadConfig().
    Settings const& GetSettings();

    // Reads every key from sConfig. Called on WORLDHOOK_ON_AFTER_CONFIG_LOAD.
    void LoadConfig();
}

#endif
