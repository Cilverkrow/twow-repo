/*
 * mod-bot-brain -- the per-bot planning pipeline.
 *
 * ---------------------------------------------------------------------------
 * Why there are four phases and not one blocking call
 * ---------------------------------------------------------------------------
 * Two things this needs are slow, and neither may happen on a map thread:
 *
 *  1. sTravelMgr.GetPartitions() takes a five-permit semaphore
 *     (TravelMgr::GetPartitionsLock) and BLOCKS until one is free. Upstream
 *     only ever calls it from a std::async worker for exactly that reason
 *     (ChooseTravelTargetAction.cpp:742). Calling it from a map thread would
 *     park that thread behind up to five destination workers.
 *  2. the HTTP round trip to the brain.
 *
 * So:
 *   A (worker)      GetPartitions for this bot -> PartitionedTravelList
 *   B (map thread)  build the POI table and the snapshot JSON, bot alive
 *   C (worker)      POST /v1/plan, JSON in, JSON out
 *   D (map thread)  parse, keep the intent until the travel chooser asks
 *
 * ---------------------------------------------------------------------------
 * What crosses the worker boundary
 * ---------------------------------------------------------------------------
 * Phase A crosses a PlayerTravelInfo *by value* and returns a
 * PartitionedTravelList of pointers into sTravelMgr, which are
 * process-lifetime objects -- byte for byte what upstream's own travel future
 * already does.
 *
 * Phase C crosses a std::string and nothing else. No Player, no PlayerbotAI,
 * no WorldSession, no ObjectGuid, no TravelDestination. That is ADR-0012's
 * "World/AI objects and raw pointers never cross the worker boundary", and it
 * is enforced by the signature of BotBrainClient rather than by care.
 *
 * The failure this avoids is not hypothetical: PlayerbotAI.cpp:7986
 * (SendDelayedPacket) detaches a thread holding a raw WorldSession*, sleeps,
 * and then calls QueuePacket -- a use-after-free the moment the bot logs out
 * (LLM-012). A worker here cannot express that bug.
 *
 * Bot state is keyed by ObjectGuid and re-resolved on the map thread; the
 * workers hold a shared_ptr to a plain data exchange, so a bot logging out
 * mid-flight costs a discarded result, never a dangling pointer.
 *
 * EVERY failure is silent and falls through to the stock chooser: no brain, a
 * slow brain, a skewed brain, a malformed intent and an unknown POI all end
 * with the bot travelling exactly as it does today.
 */

#ifndef MOD_BOT_BRAIN_PIPELINE_H
#define MOD_BOT_BRAIN_PIPELINE_H

#include "BotBrainWire.h"

#include "ObjectGuid.h"

#include <memory>
#include <string>

class Player;
class PlayerbotAI;

namespace ai
{
    class TravelDestination;
    class WorldPosition;
}

namespace botbrain
{
    // The strategy name a bot must carry for the brain to plan for it. Enable
    // it in config with ",+bot brain" appended to
    // AiPlayerbot.RandomBotNonCombatStrategies, or per bot with
    // ChangeStrategy("+bot brain", BOT_STATE_NON_COMBAT).
    extern char const* const kStrategyName;

    // One resolved destination handed back to the applier. The pointers are
    // sTravelMgr's and are only ever read on a map thread.
    struct ResolvedPoi
    {
        std::string id;
        ai::TravelDestination* destination = nullptr;
        ai::WorldPosition* position = nullptr;
    };

    // Drives one bot one step. Called from PLAYERHOOK_ON_UPDATE, which fires
    // from Player::Update -- i.e. on the map thread that owns this bot, the
    // same thread its AI ticks on. That is the same choice mod-dungeon-clear
    // made for its strategy gate, and for the same reason: doing this from the
    // world thread while the bot's map thread is inside its AI tick tears the
    // trigger list apart underneath it.
    void Tick(Player* bot, PlayerbotAI* ai);

    // Called by the travel-target applier. Returns true and fills `intent` and
    // `poi` when a fresh, unexpired, POI-directed intent is waiting for this
    // bot and its POI still resolves. Consumes it either way: an intent is
    // offered once.
    bool TakeTravelIntent(Player* bot, Intent& intent, ResolvedPoi& poi);

    // Records what happened to the last intent so the next snapshot can carry
    // it as last_outcome. This is how the loop closes without the brain
    // holding any state: the server remembers, and the brain is told.
    void RecordOutcome(Player* bot, std::string const& intentId, std::string const& kind,
        std::string const& result, std::string const& reason);

    // Drop everything remembered for a bot. Called on logout.
    void Forget(ObjectGuid guid);

    // The startup handshake: GET /v1/contract, compare majors, log. Returns
    // false when the module must stay inert (skew, or no service). Runs on the
    // world thread at WORLDHOOK_ON_STARTUP so version skew is a boot-time log
    // line rather than a silent stream of dropped intents in production.
    bool Handshake();

    // True once Handshake() has confirmed a compatible peer. Until then the
    // pipeline does nothing: fail closed.
    bool IsAdmitted();

    // Stop spawning workers. Called on WORLDHOOK_ON_SHUTDOWN.
    void BeginShutdown();
}

#endif
