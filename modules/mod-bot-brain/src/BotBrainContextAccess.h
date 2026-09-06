/*
 * mod-bot-brain -- attaching to every bot's AI context.
 *
 * This uses the seam that already exists. RegisterAiContextAugmenter (see
 * core/modules/mod-playerbots/src/playerbot/AiContextAugment.h) is called for every
 * bot context as it is built at PlayerbotAI.cpp:150, and registering also walks
 * the bots that already exist -- so this module does not care whether it ran
 * before or after the random-bot factory. mod-dungeon-clear does the same thing
 * in fifteen lines (src/AiObjectContextAccess.h:34-45); this is the second user
 * of that seam, which is the point of having one.
 *
 * OWNERSHIP -- a fresh instance per bot, never a function-local static.
 * NamedObjectContextList's destructor deletes every context that is not marked
 * shared, and NamedObjectContext caches created objects BY NAME inside the
 * context instance. One shared instance would therefore (1) be `delete`d the
 * first time any bot context is torn down -- glibc aborts with "free():
 * invalid pointer" on the first relogin -- and (2) hand every later bot the
 * action bound to the FIRST bot's PlayerbotAI. Per-bot instances are exactly
 * how the stock class contexts behave.
 */

#ifndef MOD_BOT_BRAIN_CONTEXT_ACCESS_H
#define MOD_BOT_BRAIN_CONTEXT_ACCESS_H

#include "BotBrainPlayerbots.h"

#include "BotBrainStrategy.h"
#include "BotBrainTravelAction.h"

#include "playerbot/AiContextAugment.h"
#include "playerbot/strategy/AiObjectContext.h"
#include "playerbot/strategy/NamedObjectContext.h"

namespace botbrain
{
    // Registered under the STOCK name. AddShared uses AddFront, so this context
    // is consulted before the stock ActionContext and wins the name.
    // ChooseTravelTargetAction.cpp is never touched.
    class BotBrainActionContext : public ai::NamedObjectContext<ai::Action>
    {
    public:
        BotBrainActionContext() : ai::NamedObjectContext<ai::Action>(false, false)
        {
            creators["choose travel target"] = &BotBrainActionContext::choose_travel_target;
        }

    private:
        static ai::Action* choose_travel_target(PlayerbotAI* botAI)
        {
            return new ChooseTravelTargetFromIntentAction(botAI);
        }
    };

    class BotBrainStrategyContext : public ai::NamedObjectContext<ai::Strategy>
    {
    public:
        BotBrainStrategyContext() : ai::NamedObjectContext<ai::Strategy>(false, false)
        {
            creators["bot brain"] = &BotBrainStrategyContext::bot_brain;
        }

    private:
        static ai::Strategy* bot_brain(PlayerbotAI* botAI) { return new BotBrainStrategy(botAI); }
    };

    inline void AugmentContext(PlayerbotAI* /*botAI*/, ai::AiObjectContext* context)
    {
        context->AddShared(new BotBrainStrategyContext());
        context->AddShared(new BotBrainActionContext());
    }

    inline void RegisterBotBrainContexts()
    {
        RegisterAiContextAugmenter(&AugmentContext);
    }
}

#endif
