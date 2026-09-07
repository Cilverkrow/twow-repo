#include "BotBrainPlayerbots.h"

#include "BotBrainStrategy.h"

#include "playerbot/strategy/Action.h"
#include "playerbot/strategy/Trigger.h"

using namespace ai;

namespace botbrain
{
    void BotBrainStrategy::InitNonCombatTriggers(std::list<TriggerNode*>& triggers)
    {
        // One trigger, one action. The trigger is true only while an intent of a
        // kind this build can apply is waiting, so on the overwhelming majority
        // of ticks this costs a mutex and two field reads and contributes
        // nothing to the engine's decision.
        //
        // Relevance 6.5 sits just above the stock food/drink pair at 6.0
        // (generic/UseFoodStrategy.cpp), and that ordering is deliberate rather
        // than a grab for priority: BotBrainApplyAction carries `rest` out by
        // calling those very actions through DoSpecificAction, so winning the
        // tick produces the identical behaviour and additionally records an
        // outcome. Losing it would leave the bot eating anyway while the intent
        // aged out unreported, which would make the brain look ignored on
        // exactly the ticks it was right.
        //
        // It stays below combat and survival rungs, which are tier-0 and not
        // this module's business.
        triggers.push_back(new TriggerNode(
            "bot brain intent",
            NextAction::array(0, new NextAction("bot brain apply", 6.5f), NULL)));
    }
}
