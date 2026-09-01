// Periodically hands online players the three vanilla world buffs.
//
// Lifted from World::Update() and World::UpdateWorldBuffTimer(), where it lived
// inline with no file of its own. Behaviour is unchanged: the same spells, the
// same zones, the same per-buff independent timers, the same announcement
// wording. The characterization test written before the move pins that.
//
// Each buff carries its OWN timer rather than sharing one, by request: before
// that all three always arrived together. The very first roll after a start
// uses a short interval so that frequent restarts do not push the buffs back by
// a whole long interval every time.

#include "ScriptObjects.h"

#include "AccountMgr.h"
#include "Config/Config.h"
#include "Log.h"
#include "Objects/Player.h"
#include "SharedDefines.h"
#include "Util.h"
#include "World.h"
#include "WorldSession.h"

#include <algorithm>
#include <functional>
#include <string>

namespace
{
    // Zone and area ids from the world database. Stranglethorn Vale, Orgrimmar
    // and Stormwind City are top-level zones. The Crossroads is only an AREA
    // inside the Barrens, which is why it is matched with GetAreaId() rather
    // than GetZoneId().
    uint32 constexpr ZONE_STRANGLETHORN_VALE = 33;
    uint32 constexpr ZONE_ORGRIMMAR          = 1637;
    uint32 constexpr ZONE_STORMWIND_CITY     = 1519;
    uint32 constexpr AREA_THE_CROSSROADS     = 380;

    uint32 constexpr SPELL_SPIRIT_OF_ZANDALAR = 24425;
    uint32 constexpr SPELL_WARCHIEFS_BLESSING = 16609;
    uint32 constexpr SPELL_RALLYING_CRY       = 22888;

    // World::SendWorldText takes a language id; 3 is LANG_SYSTEMMESSAGE. Spelled
    // out here because the core passes the bare number at the original site.
    uint32 constexpr LANG_SYSTEMMESSAGE = 3;

    struct BuffTimer
    {
        uint32 timer = 0;
        uint32 warningMs = 0;
        bool warned = false;
        bool firstSinceRestart = true;
    };

    class WorldBuffScript : public WorldScript
    {
    public:
        WorldBuffScript()
            : WorldScript("mod_worldbuff_world", { WORLDHOOK_ON_UPDATE })
        {
        }

        void OnUpdate(uint32 diff) override
        {
            if (!sConfig.GetBoolDefault("AutoWorldBuff.Enable", false))
                return;

            Tick(diff, m_zandalar, SPELL_SPIRIT_OF_ZANDALAR,
                "Spirit of Zandalar (in Stranglethorn Vale)",
                [](Player* p) { return p->GetZoneId() == ZONE_STRANGLETHORN_VALE; });

            Tick(diff, m_warchief, SPELL_WARCHIEFS_BLESSING,
                "Warchief's Blessing (in Crossroads/Orgrimmar)",
                [](Player* p) {
                    return p->GetTeam() == HORDE &&
                           (p->GetAreaId() == AREA_THE_CROSSROADS || p->GetZoneId() == ZONE_ORGRIMMAR);
                });

            // Rallying Cry is NOT faction exclusive. The buff comes from the
            // Onyxia and Nefarian heads, which are turned in in BOTH capitals -
            // Horde in Orgrimmar, Alliance in Stormwind. It was wrongly limited
            // to Alliance in Stormwind at first, on the assumption that it was
            // the Alliance counterpart to Warchief's Blessing. Only Warchief's
            // Blessing above is actually Horde exclusive.
            Tick(diff, m_dragonslayer, SPELL_RALLYING_CRY,
                "Rallying Cry of the Dragonslayer (in Stormwind City/Orgrimmar)",
                [](Player* p) {
                    return (p->GetTeam() == ALLIANCE && p->GetZoneId() == ZONE_STORMWIND_CITY) ||
                           (p->GetTeam() == HORDE && p->GetZoneId() == ZONE_ORGRIMMAR);
                });
        }

    private:
        // One independent buff's warning / reroll / cast cycle.
        static void Tick(uint32 diff, BuffTimer& state, uint32 spellId,
            char const* announceLabel, std::function<bool(Player*)> const& eligible)
        {
            // One warning per cycle, shortly before the buff is renewed.
            if (!state.warned && state.warningMs > 0 && state.timer <= state.warningMs)
            {
                state.warned = true;
                uint32 const warnMinutes = std::max<uint32>(1, state.warningMs / 60000);
                sWorld.SendWorldText(LANG_SYSTEMMESSAGE,
                    string_format("{} will be refreshed in {} minute(s)!", announceLabel, warnMinutes).c_str());
            }

            if (state.timer > diff)
            {
                state.timer -= diff;
                return;
            }

            uint32 minMs;
            uint32 maxMs;
            if (state.firstSinceRestart)
            {
                // A short interval for the very first roll after a start, so
                // that frequent restarts do not push the buffs back by a whole
                // long interval every single time.
                minMs = sConfig.GetIntDefault("AutoWorldBuff.FirstMinInterval", 600000);   // 10min
                maxMs = sConfig.GetIntDefault("AutoWorldBuff.FirstMaxInterval", 7200000);  // 2h
                state.firstSinceRestart = false;
            }
            else
            {
                minMs = sConfig.GetIntDefault("AutoWorldBuff.MinInterval", 3600000);   // 1h
                maxMs = sConfig.GetIntDefault("AutoWorldBuff.MaxInterval", 10800000);  // 3h
            }
            if (maxMs < minMs)
                maxMs = minMs;
            state.timer = minMs + (maxMs > minMs ? urand(0, maxMs - minMs) : 0);

            state.warningMs = sConfig.GetIntDefault("AutoWorldBuff.WarningInterval", 600000); // 10min
            if (state.warningMs >= state.timer)
                state.warningMs = state.timer / 2;  // safety net if the warning outlasts the interval
            state.warned = false;

            uint32 buffedCount = 0;
            for (auto const& entry : sWorld.GetAllSessions())
            {
                WorldSession* session = entry.second;
                if (!session)
                    continue;

                Player* player = session->GetPlayer();
                if (!player || !player->IsInWorld())
                    continue;

                // Random bots sit on RNDBOT accounts; their session carries no
                // username, so look it up by account id. The Discord bridge
                // character on account DISCORD is a genuine session too, but
                // not a player, so it is excluded as well.
                std::string accountName;
                sAccountMgr.GetName(session->GetAccountId(), accountName);
                if (accountName.rfind("RNDBOT", 0) == 0 || accountName == "DISCORD")
                    continue;

                if (eligible(player))
                {
                    player->CastSpell(player, spellId, true);
                    ++buffedCount;
                }
            }

            if (buffedCount)
                sWorld.SendWorldText(LANG_SYSTEMMESSAGE,
                    string_format("World buff refreshed: {}!", announceLabel).c_str());
        }

        BuffTimer m_zandalar;
        BuffTimer m_warchief;
        BuffTimer m_dragonslayer;
    };
}

void Addmod_worldbuffScripts()
{
    new WorldBuffScript();
}
