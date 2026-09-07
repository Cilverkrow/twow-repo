/*
 * mod-bot-brain -- the per-bot opt-in.
 *
 * A per-bot flag first and foremost: the pipeline plans only for bots that carry
 * it, so turning the feature on for a population is a config line rather than a
 * code change.
 *
 * It also carries the one trigger that lets an intent be applied where the bot
 * stands rather than by walking somewhere. That is the module's second entry
 * point into the AI; the first is the travel-chooser override, which only runs
 * while the travel state machine is choosing. Without a trigger, a kind like
 * `rest` would have no tick at which anything asked about it.
 *
 * Enable it for random bots by appending ",+bot brain" to
 * AiPlayerbot.RandomBotNonCombatStrategies, or per bot from your own
 * PlayerScript::OnLogin with
 *   botAI->ChangeStrategy("+bot brain", BOT_STATE_NON_COMBAT);
 *
 * It does NOT install the travel override -- that is registered for every bot
 * context unconditionally, and gates itself on BotBrain.Enable and on this
 * strategy. A bot without the strategy runs the stock chooser through the
 * override's fall-through, which is the same code path it runs today.
 */

#ifndef MOD_BOT_BRAIN_STRATEGY_H
#define MOD_BOT_BRAIN_STRATEGY_H

#include "BotBrainPlayerbots.h"

#include "playerbot/strategy/Strategy.h"

#include <list>
#include <string>

class PlayerbotAI;

namespace botbrain
{
    class BotBrainStrategy : public ai::Strategy
    {
    public:
        BotBrainStrategy(PlayerbotAI* botAI) : ai::Strategy(botAI) {}

        std::string getName() override { return "bot brain"; }
        int GetType() override { return ai::STRATEGY_TYPE_NONCOMBAT; }

    private:
        void InitNonCombatTriggers(std::list<ai::TriggerNode*>& triggers) override;
    };
}

#endif
