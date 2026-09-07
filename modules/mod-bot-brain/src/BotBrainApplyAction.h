/*
 * mod-bot-brain -- applying intents that are not a place to walk to.
 *
 * The travel chooser was the module's only way into the AI, and it only runs
 * when the travel state machine is in TRAVEL_STATUS_PREPARE. That was fine while
 * every intent meant "go here", and it is why the other kinds were rejected as
 * "unsupported_kind": not because they were unimplementable, but because there
 * was no tick at which anything asked about them.
 *
 * This is the second entry point. A trigger reports that an applicable intent is
 * waiting, and the action carries it out where the bot stands.
 *
 * The action does NOT reimplement behaviour. The playerbots tree already has
 * actions for eating, drinking, selling, repairing and quest handling, and
 * PlayerbotAI::DoSpecificAction runs one by name -- which is exactly how the
 * stock RPG layer composes itself (RpgSubActions.h). Rewriting any of that here
 * would be a second, worse copy that drifts from the first.
 */

#ifndef MOD_BOT_BRAIN_APPLY_ACTION_H
#define MOD_BOT_BRAIN_APPLY_ACTION_H

#include "BotBrainPlayerbots.h"

#include "playerbot/strategy/Action.h"
#include "playerbot/strategy/Trigger.h"

#include <string>

class PlayerbotAI;

namespace botbrain
{
    // Fires while an intent this build can apply is waiting.
    //
    // Cheap on purpose: the engine evaluates triggers every tick for every bot,
    // so this takes one mutex and reads two fields. It does not consume the
    // intent -- see BotBrainPipeline.h for why a consuming peek would lose work.
    class BotBrainIntentTrigger : public ai::Trigger
    {
    public:
        BotBrainIntentTrigger(PlayerbotAI* botAI) : ai::Trigger(botAI, "bot brain intent") {}

        bool IsActive() override;
    };

    // Carries out one non-travel intent.
    //
    // Relevance is set by the strategy rather than here. Every outcome is
    // recorded, including the refusals, because an intent that was sent and
    // quietly did nothing is exactly the failure the outcome channel exists to
    // make visible.
    class BotBrainApplyAction : public ai::Action
    {
    public:
        BotBrainApplyAction(PlayerbotAI* botAI, std::string name = "bot brain apply")
            : ai::Action(botAI, name)
        {
        }

        bool Execute(ai::Event& event) override;

    private:
        // Rest is food, drink and sitting in this tree -- there is no stock
        // "rest" action to delegate to, so this picks the one the bot needs.
        bool ApplyRest(std::string& reason);
    };
}

#endif
