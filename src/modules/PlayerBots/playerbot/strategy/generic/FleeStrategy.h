#pragma once
#include "playerbot/strategy/Strategy.h"
#include "playerbot/strategy/Multiplier.h"

namespace ai
{
    // Dampens the "flee" action's relevance once a retreat has been performed, so the bot
    // resumes normal combat instead of being pinned in flee-mode while the flee trigger stays
    // active. The in-progress retreat itself is left intact (see GetValue).
    class FleeMultiplier : public Multiplier
    {
    public:
        FleeMultiplier(PlayerbotAI* ai) : Multiplier(ai, "flee") {}

    public:
        float GetValue(Action* action) override;
    };

    class FleeStrategy : public Strategy
    {
    public:
        FleeStrategy(PlayerbotAI* ai) : Strategy(ai) {}
        std::string getName() override { return "flee"; };
#ifdef GenerateBotHelp
        virtual std::string GetHelpName() { return "flee"; } //Must equal iternal name
        virtual std::string GetHelpDescription() {
            return "This strategy will make the bot flee when it is in danger.";
        }
        virtual std::vector<std::string> GetRelatedStrategies() { return { "flee from adds" }; }
#endif
    private:
        void InitCombatTriggers(std::list<TriggerNode*> &triggers) override;
        void InitCombatMultipliers(std::list<Multiplier*> &multipliers) override;
    };

    class FleeFromAddsStrategy : public Strategy
    {
    public:
        FleeFromAddsStrategy(PlayerbotAI* ai) : Strategy(ai) {}
        std::string getName() override { return "flee from adds"; };
#ifdef GenerateBotHelp
        virtual std::string GetHelpName() { return "flee from adds"; } //Must equal iternal name
        virtual std::string GetHelpDescription() {
            return "This a position strategy that will make the bot try to avoid adds the prevent aggro.";
        }
        virtual std::vector<std::string> GetRelatedStrategies() { return { "flee", "follow", "stay", "runaway", "guard", "free" }; }
#endif
    private:
        void InitCombatTriggers(std::list<TriggerNode*> &triggers) override;
    };
}
