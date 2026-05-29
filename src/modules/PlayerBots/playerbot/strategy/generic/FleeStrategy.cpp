
#include "playerbot/playerbot.h"
#include "FleeStrategy.h"
#include "playerbot/PlayerbotAIConfig.h"
#include "playerbot/ServerFacade.h"
#include "playerbot/strategy/Action.h"
#include "playerbot/strategy/values/LastMovementValue.h"

using namespace ai;

float FleeMultiplier::GetValue(Action* action)
{
    // Only the basic "flee" action is dampened; "runaway" / "flee to master" are untouched.
    if (!action || action->getName() != "flee")
        return 1.0f;

    LastMovement& lastMovement = AI_VALUE(LastMovement&, "last movement");

    // Never fled (or the flee window was cleared) -> allow flee at full relevance.
    if (!lastMovement.lastFlee)
        return 1.0f;

    // While the bot is actively retreating, do NOT dampen: flee should keep winning so the
    // existing in-progress-flee debounce in MovementAction::Flee() carries the retreat to
    // completion instead of a normal action interrupting it after a fraction of a second.
    if (sServerFacade.isMoving(bot))
        return 1.0f;

    // Retreat done and the bot has settled: suppress re-fleeing for a short backoff so normal
    // combat actions outrank flee, then allow it again. The window mirrors the flee timing
    // scale already used in Flee() (fleeDelay = urand(2, returnDelay/1000)).
    time_t elapsed = time(0) - lastMovement.lastFlee;
    if (elapsed <= (time_t)(sPlayerbotAIConfig.returnDelay / 1000))
        return 0.01f;

    return 1.0f;
}

void FleeStrategy::InitCombatMultipliers(std::list<Multiplier*> &multipliers)
{
    multipliers.push_back(new FleeMultiplier(ai));
}

void FleeStrategy::InitCombatTriggers(std::list<TriggerNode*> &triggers)
{
    triggers.push_back(new TriggerNode(
        "panic",
        NextAction::array(0, new NextAction("flee", ACTION_EMERGENCY + 9), NULL)));

    triggers.push_back(new TriggerNode(
        "outnumbered",
        NextAction::array(0, new NextAction("flee", ACTION_EMERGENCY + 9), NULL)));
}

void FleeFromAddsStrategy::InitCombatTriggers(std::list<TriggerNode*> &triggers)
{
    triggers.push_back(new TriggerNode(
        "has nearest adds",
        NextAction::array(0, new NextAction("runaway", 50.0f), NULL)));
}
