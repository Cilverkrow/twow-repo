#include "BotBrainPlayerbots.h"

#include "BotBrainTravelAction.h"

#include "BotBrainConfig.h"
#include "BotBrainPipeline.h"

#include "playerbot/PlayerbotAI.h"
#include "playerbot/TravelMgr.h"
#include "playerbot/WorldPosition.h"
#include "playerbot/strategy/values/TravelValues.h"

#include "Log.h"
#include "Player.h"

#include <chrono>

using namespace ai;

namespace botbrain
{
    bool ChooseTravelTargetFromIntentAction::Execute(Event& event)
    {
        if (!GetSettings().enabled || !IsAdmitted())
            return ChooseTravelTargetAction::Execute(event);

        TravelTarget* travelTarget = AI_VALUE(TravelTarget*, "travel target");

        // Same precondition as the stock action: only step in at the moment the
        // bot is actually choosing. Anything else and the travel state machine
        // is mid-transition and not ours to touch.
        if (travelTarget->GetStatus() != TravelStatus::TRAVEL_STATUS_PREPARE)
            return ChooseTravelTargetAction::Execute(event);

        FutureDestinations* futureDestinations = AI_VALUE(FutureDestinations*, "future travel destinations");

        // A stock destination request that has not landed yet must be left
        // alone: abandoning a pending std::async future means its destructor
        // blocks the map thread until the worker finishes. Wait for it the way
        // the stock action does, and apply the intent on a later tick -- the
        // intent is still in the mailbox because TakeTravelIntent has not been
        // called.
        if (futureDestinations->valid() &&
            futureDestinations->wait_for(std::chrono::seconds(0)) == std::future_status::timeout)
            return ChooseTravelTargetAction::Execute(event);

        Intent intent;
        ResolvedPoi poi;
        if (!TakeTravelIntent(bot, intent, poi))
            return ChooseTravelTargetAction::Execute(event);

        // Drain the completed stock request so the value is left exactly as the
        // stock path would have left it.
        if (futureDestinations->valid())
            futureDestinations->get();

        travelTarget->SetStatus(TravelStatus::TRAVEL_STATUS_NONE);

        Player* requester = event.getOwner() ? event.getOwner() : (GetMaster() ? GetMaster() : bot);

        TravelTarget newTarget(ai, poi.destination, poi.position);
        newTarget.SetRelevance(uint32(AI_VALUE2(int, "manual int", "future travel relevance")));

        setNewTarget(requester, &newTarget, travelTarget);

        if (GetSettings().logApplied)
            sLog.outBasic("mod-bot-brain: %s (guid %u) travel target set from intent %s -> poi %s (kind %s, source %s, confidence %.2f)",
                bot->GetName() ? bot->GetName() : "?",
                bot->GetGUIDLow(),
                intent.intentId.c_str(),
                poi.id.c_str(),
                intent.kind.c_str(),
                intent.source.empty() ? "?" : intent.source.c_str(),
                intent.confidence);

        RecordOutcome(bot, intent.intentId, intent.kind, "accepted", std::string(), poi.id);
        return true;
    }
}
