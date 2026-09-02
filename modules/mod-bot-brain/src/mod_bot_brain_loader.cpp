/*
 * mod-bot-brain -- module entry point.
 *
 * The only contract the module system asks for is a loader function named
 * Addmod_bot_brainScripts(); modules/CMakeLists.txt derives that name from the
 * directory and the discovery glob finds the directory, so adding this module
 * cost no edit anywhere else in the tree.
 *
 * Three scripts:
 *   - a WorldScript that loads config, does the /v1/contract handshake at
 *     startup, and registers the AI-context augmenter;
 *   - a PlayerScript on PLAYERHOOK_ON_UPDATE that drives the planning pipeline
 *     on the bot's OWN map thread (the same choice, for the same reason, as
 *     mod-dungeon-clear's gate: doing this from the world thread while the
 *     bot's map thread is inside its AI tick tears the trigger list apart);
 *   - a PlayerScript on logout that forgets the bot.
 */

#include "BotBrainPlayerbots.h"

#include "BotBrainConfig.h"
#include "BotBrainContextAccess.h"
#include "BotBrainPipeline.h"

#include "ScriptObjects.h"

#include "Log.h"
#include "Player.h"
#include "playerbot/PlayerbotAI.h"
#include "playerbot/BotSlots.h"

namespace
{
    class BotBrainWorldScript : public WorldScript
    {
    public:
        BotBrainWorldScript()
            : WorldScript("mod_bot_brain_world", {
                WORLDHOOK_ON_AFTER_CONFIG_LOAD,
                WORLDHOOK_ON_STARTUP,
                WORLDHOOK_ON_SHUTDOWN
            })
        {
        }

        void OnAfterConfigLoad(bool /*reload*/) override
        {
            botbrain::LoadConfig();
        }

        void OnStartup() override
        {
            // Register unconditionally: the augmenter is what puts the travel
            // override in front of the stock one, and the override falls
            // through to stock behaviour whenever the feature is off. Doing it
            // conditionally would mean a config reload could not turn the
            // feature on without a restart.
            botbrain::RegisterBotBrainContexts();

            if (!botbrain::GetSettings().enabled)
            {
                sLog.outString("mod-bot-brain: disabled (BotBrain.Enable = 0); bots use the stock travel chooser");
                return;
            }

            // Fail closed: the pipeline stays inert unless this succeeds, so
            // contract skew is a single boot-time log line instead of a silent
            // stream of dropped intents in production.
            botbrain::Handshake();
        }

        void OnShutdown() override
        {
            botbrain::BeginShutdown();
        }
    };

    class BotBrainPlayerScript : public PlayerScript
    {
    public:
        BotBrainPlayerScript()
            : PlayerScript("mod_bot_brain_player", {
                PLAYERHOOK_ON_UPDATE,
                PLAYERHOOK_ON_LOGOUT
            })
        {
        }

        void OnUpdate(Player* player, uint32 /*diff*/) override
        {
            if (!player)
                return;
            PlayerbotAI* botAI = GetBotAI(player);
            if (!botAI)
                return;     // real players are never planned for
            botbrain::Tick(player, botAI);
        }

        void OnLogout(Player* player) override
        {
            if (player)
                botbrain::Forget(player->GetObjectGuid());
        }
    };
}

void Addmod_bot_brainScripts()
{
    new BotBrainWorldScript();
    new BotBrainPlayerScript();
}
