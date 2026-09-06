/*
 * mod-bot-brain -- the applier.
 *
 * This is the whole C++-side footprint of the feature: one Action subclass
 * registered under the EXISTING name "choose travel target". Registering a
 * NamedObjectContext<Action> with that name overrides the stock action,
 * because AiObjectContext::AddShared appends with AddFront and GetObject takes
 * the first context that answers (NamedObjectContext.h:283-287).
 *
 * ChooseTravelTargetAction.cpp is not touched, and neither is anything else
 * under core/modules/mod-playerbots. That tree is a vendored copy of upstream and
 * every line changed in it is permanent merge friction.
 *
 * Behaviour when there is no intent -- no service, slow service, expired
 * intent, unknown POI, wrong bot -- is ChooseTravelTargetAction::Execute(),
 * unchanged. Killing the brain does not change how bots travel; it only stops
 * them being told where to go.
 */

#ifndef MOD_BOT_BRAIN_TRAVEL_ACTION_H
#define MOD_BOT_BRAIN_TRAVEL_ACTION_H

#include "BotBrainPlayerbots.h"

#include "playerbot/strategy/actions/ChooseTravelTargetAction.h"

namespace botbrain
{
    class ChooseTravelTargetFromIntentAction : public ai::ChooseTravelTargetAction
    {
    public:
        ChooseTravelTargetFromIntentAction(PlayerbotAI* botAI,
            std::string name = "choose travel target")
            : ai::ChooseTravelTargetAction(botAI, name) {}

        bool Execute(ai::Event& event) override;
    };
}

#endif
