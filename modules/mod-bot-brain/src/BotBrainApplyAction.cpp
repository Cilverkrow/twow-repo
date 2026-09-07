#include "BotBrainPlayerbots.h"

#include "BotBrainApplyAction.h"

#include "BotBrainConfig.h"
#include "BotBrainPipeline.h"
#include "BotBrainWire.h"

#include "playerbot/PlayerbotAI.h"

#include "Log.h"
#include "Player.h"

using namespace ai;

namespace botbrain
{
    bool BotBrainIntentTrigger::IsActive()
    {
        // The two gates the whole module hangs on, checked before touching bot
        // state: a disabled module and a failed handshake both mean the stock AI
        // owns this bot completely.
        if (!GetSettings().enabled || !IsAdmitted())
            return false;

        return HasPendingAppliedIntent(bot);
    }

    bool BotBrainApplyAction::Execute(Event& /*event*/)
    {
        if (!GetSettings().enabled || !IsAdmitted())
            return false;

        Intent intent;
        if (!TakeAppliedIntent(bot, intent))
        {
            // The trigger fired and the intent is gone: another applier took it,
            // or it expired between the two calls. Not an error, and not ours to
            // report -- whoever consumed it recorded why.
            return false;
        }

        std::string reason;
        bool applied = false;

        if (intent.kind == kIntentRest)
            applied = ApplyRest(reason);
        else
        {
            // TakeAppliedIntent only yields kinds IsAppliedKind admits, so this is
            // unreachable unless the two fall out of step. Report it rather than
            // returning a bare false: a kind that is advertised as applicable and
            // then silently does nothing is the failure this module is built to
            // avoid.
            reason = "unsupported_kind";
        }

        if (!applied)
        {
            RecordOutcome(bot, intent.intentId, intent.kind, "failed",
                reason.empty() ? "action_refused" : reason, std::string());
            return false;
        }

        // "completed", not "accepted". The travel path says accepted because it
        // sets a destination the bot then walks to over many ticks, and nothing
        // yet observes the arrival. This action either performed the thing or did
        // not, and it knows which by the time it returns -- so it can report the
        // stronger result honestly.
        RecordOutcome(bot, intent.intentId, intent.kind, "completed", std::string(), std::string());

        if (GetSettings().logApplied)
        {
            sLog.outBasic("mod-bot-brain: %s (guid %u) applied intent %s (kind %s, source %s)",
                bot->GetName(), bot->GetGUIDLow(), intent.intentId.c_str(),
                intent.kind.c_str(), intent.source.c_str());
        }
        return true;
    }

    bool BotBrainApplyAction::ApplyRest(std::string& reason)
    {
        // There is no stock "rest" action to delegate to: in this tree resting is
        // eating, drinking and sitting. Food first, because the rule planner emits
        // rest on low HEALTH (BOT_BRAIN_RULE_REST_BELOW_HP_PCT), then drink for a
        // caster who is full but empty.
        //
        // DoSpecificAction collapses OK/IMPOSSIBLE/USELESS/FAILED into a bool, so
        // a refusal cannot be told apart here. That is worth one honest reason
        // code rather than a guess: "no_consumable" would be a lie when the real
        // cause was that the bot is already eating.
        if (ai->DoSpecificAction("food", Event(), true))
            return true;
        if (ai->DoSpecificAction("drink", Event(), true))
            return true;

        reason = "action_refused";
        return false;
    }
}
