// Host-side glue for bot lifecycle and dispatch. Implements:
//   - Player::{Create,Remove}Playerbot{AI,Mgr}, Player::isRealPlayer
//   - Player::UpdatePlayerbotHooks (per-Player tick)
//   - World::{Update,Init}Playerbots* (world-tick driver, startup init)
//   - Player_DispatchBotOutgoing{Packet,ChatCommand} (free functions called
//     from WorldSession; the bot-AI null-check happens here so the host
//     call sites stay unconditional)
//
// Lives in the bot module so it sees both the host headers and the bot
// module's full PlayerbotAI / PlayerbotMgr types — the host declares the
// methods, only the bot module satisfies the linker with real bodies. The
// matching BUILD_PLAYERBOTS=OFF stubs live in src/game/PlayerbotStubs.cpp.

#include "playerbot/playerbot.h"
#include "Objects/Player.h"
#include "World.h"
#include "playerbot/RandomPlayerbotMgr.h"
#include "playerbot/RandomPlayerbotFactory.h"
#include "playerbot/PlayerbotAIConfig.h"
#include "ahbot/AhBot.h"
#include "BotDiagnostics.h"
#include "playerbot/AiFactory.h"
#include "playerbot/strategy/actions/ChangeTalentsAction.h"

void Player::CreatePlayerbotAI()
{
    if (!m_playerbotAI)
        m_playerbotAI = new PlayerbotAI(this);
}

void Player::RemovePlayerbotAI()
{
    if (m_playerbotAI)
    {
        delete m_playerbotAI;
        m_playerbotAI = nullptr;
    }
}

void Player::CreatePlayerbotMgr()
{
    if (!m_playerbotMgr)
    {
        m_playerbotMgr = new PlayerbotMgr(this);
        // RandomPlayerbotMgr tracks real players in its own `players` map
        // (used by SyncLevelWithPlayers, RandomBotLoginWithPlayer, LFG
        // auto-queue). Without this call the map never gets populated and
        // those features silently never trigger.
        sRandomPlayerbotMgr.OnPlayerLogin(this);
    }
}

void Player::RemovePlayerbotMgr()
{
    if (m_playerbotMgr)
    {
        // Log out the master's alt bots first; otherwise their PlayerbotAI
        // outlives the mgr and they linger in-world with a dangling master.
        m_playerbotMgr->LogoutAllBots();
        sRandomPlayerbotMgr.OnPlayerLogout(this);
        delete m_playerbotMgr;
        m_playerbotMgr = nullptr;
    }
}

bool Player::isRealPlayer() const
{
    return !m_playerbotAI || m_playerbotAI->IsRealPlayer();
}

// One-shot startup init. Singleton bot managers (RandomPlayerbotMgr,
// PlayerBotLoginMgr, etc.) lazy-instantiate on first reference; we just
// need the config file loaded here. No-op when AiPlayerbot.Enabled=0.
void AddSC_playerbot_hooks();

void World::InitPlayerbotsAtStartup()
{
    sPlayerbotAIConfig.Initialize();

    // Register the modules hook objects. This is the modules one bootstrap
    // from the core: a file-scope instance would run before the ScriptRegistry
    // containers are constructed, so the registration has to be called, and
    // something in the core has to call it. Everything the bots need from the
    // core after this point arrives through the hooks in PlayerbotScripts.cpp.
    AddSC_playerbot_hooks();
}

