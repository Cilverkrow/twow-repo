/*
 * Fills a waiting player's dungeon queue with random bots.
 *
 * The idea is deliberately boring: bots are inserted into the very same
 * m_queue that real players sit in, as ordinary QueuedPlayer entries. Everything
 * after that - role assignment, faction and hardcore checks, group building,
 * the offer - is done by the existing matcher in LFTQeueue.cpp. No parallel
 * mechanism, and nothing to keep in sync.
 *
 * Rules, in the order they matter:
 *   - Real players come first. As soon as one joins the queue, every fill bot
 *     that is not already part of an offer is dropped again, so a human can
 *     take the slot. An offer that has already gone out is left alone; pulling
 *     a group apart mid-formation would be worse than one bot too many.
 *   - Bots only appear after LFT.BotFill.DelaySeconds. Filling instantly would
 *     mean nobody ever waits for a human again.
 *   - Same faction, same hardcore mode, level within LFT.BotFill.LevelRange of
 *     the waiting player. The instance names the client sends are free text and
 *     carry no level information, so the waiting player is the reference.
 *
 * Getting the group to the dungeon is not handled here: the party leader types
 * "summon" in party chat and the playerbot module teleports them.
 */

#include "Config/Config.h"
#include "LFTMgr.h"

#include "AccountMgr.h"
#include "Group.h"
#include "ObjectAccessor.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "World.h"

#include <algorithm>

namespace
{
    // Bots are recognised the same way the leech restriction does it: random
    // bots live on RNDBOT accounts. Keeps this inside the core instead of
    // pulling in the playerbot module.
    struct SeedDungeon
    {
        std::string name;
        uint32 minLevel;
        uint32 maxLevel;
    };

    // "Name:min-max,Name:min-max". The names have to match what the client addon
    // sends, because the server never interprets them - it only compares them
    // between queued players, so a seed listing an instance under a different
    // spelling would run a dungeon nobody real can ever join.
    std::vector<SeedDungeon> ParseSeedDungeons(std::string const& text)
    {
        std::vector<SeedDungeon> out;
        std::stringstream entries(text);
        std::string entry;

        while (std::getline(entries, entry, ','))
        {
            size_t const colon = entry.rfind(':');
            size_t const dash = entry.rfind('-');
            if (colon == std::string::npos || dash == std::string::npos || dash < colon)
                continue;

            SeedDungeon dungeon;
            dungeon.name = entry.substr(0, colon);

            try
            {
                dungeon.minLevel = std::stoul(entry.substr(colon + 1, dash - colon - 1));
                dungeon.maxLevel = std::stoul(entry.substr(dash + 1));
            }
            catch (std::exception const&)
            {
                sLog.outError("LFT.BotFill.SeedDungeons: cannot read '%s'", entry.c_str());
                continue;
            }

            out.push_back(dungeon);
        }

        return out;
    }

    bool IsRandomBotAccount(Player const* player)
    {
        WorldSession const* session = player ? player->GetSession() : nullptr;
        if (!session)
            return false;

        std::string name;
        if (!sAccountMgr.GetName(session->GetAccountId(), name))
            return false;

        for (char& c : name)
            if (c >= 'a' && c <= 'z')
                c = c - 'a' + 'A';

        return name.rfind("RNDBOT", 0) == 0;
    }

    bool ListsInstance(std::vector<std::string> const& instances, std::string const& instance)
    {
        return std::find(instances.begin(), instances.end(), instance) != instances.end();
    }

    char const* RoleSuffix(uint8 role)
    {
        if (role == LFT_ROLE_TANK)
            return "t";
        if (role == LFT_ROLE_HEALER)
            return "h";
        return "d";
    }
}

bool LFTManager::IsFillBot(ObjectGuid const& guid) const
{
    return m_fillBots.find(guid) != m_fillBots.end();
}

void LFTManager::ForgetFillBot(ObjectGuid const& guid)
{
    m_fillBots.erase(guid);
}

// Is a real player waiting for this instance, and since when?
bool LFTManager::RealPlayerWaitsFor(std::string const& instance, time_t& oldestJoin) const
{
    bool found = false;
    for (QueueMap::const_iterator itr = m_queue.begin(); itr != m_queue.end(); ++itr)
    {
        if (IsFillBot(itr->first))
            continue;

        if (!ListsInstance(itr->second.instances, instance))
            continue;

        if (!found || itr->second.joinTime < oldestJoin)
            oldestJoin = itr->second.joinTime;

        found = true;
    }

    return found;
}

// Remove fill bots nobody is waiting on any more - the human left, or a human
// joined and should get the slot instead.
void LFTManager::DropUnneededFillBots()
{
    for (std::set<ObjectGuid>::iterator itr = m_fillBots.begin(); itr != m_fillBots.end();)
    {
        ObjectGuid const guid = *itr;

        // Already promised to a group: leave it be, cancelling now would break
        // a group that is in the middle of forming.
        if (m_playerOffers.find(guid) != m_playerOffers.end())
        {
            ++itr;
            continue;
        }

        QueueMap::const_iterator queued = m_queue.find(guid);
        bool needed = false;

        if (queued != m_queue.end())
        {
            for (std::string const& instance : queued->second.instances)
            {
                time_t oldest = 0;
                if (RealPlayerWaitsFor(instance, oldest))
                {
                    needed = true;
                    break;
                }
            }
        }

        if (needed)
        {
            ++itr;
            continue;
        }

        if (Player* bot = GetPlayer(guid))
            Playerbot_SetForcedRole(bot, 0);

        if (queued != m_queue.end())
        {
            std::string const name = queued->second.name;
            m_queue.erase(guid);
            SendQueueLeft(guid, name);
        }

        itr = m_fillBots.erase(itr);
    }
}

// The fill mechanism only ever reacts to somebody already waiting, so on a realm
// with nobody online it does nothing at all - bots fight in battlegrounds around
// the clock and never set foot in an instance. This puts one bot into the queue
// as a seed; FillInstanceWithBots then builds the group around it exactly as it
// would around a person.
void LFTManager::SeedBotOnlyQueue()
{
    uint32 const maxRuns = (uint32)sConfig.GetIntDefault("LFT.BotFill.SeedRuns", 0);
    if (!maxRuns)
        return;

    // Anybody already waiting takes precedence, seed or human: the normal fill
    // path handles them, and a second seed would only start a competing run.
    if (!m_queue.empty())
        return;

    static std::vector<SeedDungeon> const dungeons =
        ParseSeedDungeons(sConfig.GetStringDefault("LFT.BotFill.SeedDungeons", ""));

    if (dungeons.empty())
        return;

    // Count instances rather than groups. A party that wiped and released still
    // occupies its run, and two groups inside one instance is not a case worth
    // telling apart here.
    std::set<uint32> occupied;
    for (auto const& entry : sObjectAccessor.GetPlayers())
    {
        Player* player = entry.second;
        if (!player || !player->IsInWorld())
            continue;

        Map* map = player->GetMap();
        if (map && map->IsDungeon())
            occupied.insert(map->GetInstanceId());
    }

    if (occupied.size() >= maxRuns)
        return;

    for (auto const& entry : sObjectAccessor.GetPlayers())
    {
        Player* bot = entry.second;
        if (!bot || !bot->IsInWorld() || !bot->IsAlive())
            continue;

        if (!bot->GetPlayerbotAI() || !IsRandomBotAccount(bot))
            continue;

        if (bot->GetGroup() || bot->InBattleGround() || bot->InBattleGroundQueue())
            continue;

        if (bot->GetMap() && bot->GetMap()->IsDungeon())
            continue;

        uint8 const roles = AllowedRoleMask(bot);
        if (!roles)
            continue;

        uint32 const level = bot->GetLevel();

        for (SeedDungeon const& dungeon : dungeons)
        {
            if (level < dungeon.minLevel || level > dungeon.maxLevel)
                continue;

            sLog.outBasic("LFT: seeding '%s' with %s (level %u)", dungeon.name.c_str(), bot->GetName(), level);
            EnqueuePlayer(bot, bot->GetObjectGuid(), { dungeon.name }, roles);
            return;
        }
    }
}

void LFTManager::FillInstanceWithBots(std::string const& instance, QueuedPlayer const& waiter)
{
    // What is already covered? Mirrors PickRole's caps: one tank, one healer,
    // three damage. Counted greedily in queue order, which is how the matcher
    // will assign them later.
    uint8 tanks = 0;
    uint8 healers = 0;
    uint8 damage = 0;
    uint32 inQueue = 0;

    for (ObjectGuid const& guid : GetQueueOrder())
    {
        QueueMap::const_iterator itr = m_queue.find(guid);
        if (itr == m_queue.end() || !ListsInstance(itr->second.instances, instance))
            continue;

        if (!CanQueuedPlayersGroup(waiter, itr->second))
            continue;

        ++inQueue;

        if ((itr->second.roleMask & LFT_ROLE_TANK) && tanks < 1)
            ++tanks;
        else if ((itr->second.roleMask & LFT_ROLE_HEALER) && healers < 1)
            ++healers;
        else if ((itr->second.roleMask & LFT_ROLE_DAMAGE) && damage < 3)
            ++damage;
    }

    if (inQueue >= 5)
        return;

    uint32 const levelRange = sWorld.getConfig(CONFIG_UINT32_LFT_BOTFILL_LEVEL_RANGE);
    uint32 const waiterLevel = waiter.level;

    // Fill tank first, then healer, then damage - the roles people actually
    // wait for.
    while (inQueue < 5)
    {
        uint8 wanted;
        if (tanks < 1)
            wanted = LFT_ROLE_TANK;
        else if (healers < 1)
            wanted = LFT_ROLE_HEALER;
        else if (damage < 3)
            wanted = LFT_ROLE_DAMAGE;
        else
            break;

        Player* chosen = nullptr;

        for (auto const& entry : sObjectAccessor.GetPlayers())
        {
            Player* bot = entry.second;
            if (!bot || !bot->IsInWorld() || !bot->IsAlive())
                continue;

            if (!bot->GetPlayerbotAI() || !IsRandomBotAccount(bot))
                continue;

            if (bot->GetGroup() || bot->InBattleGround() || bot->InBattleGroundQueue())
                continue;

            if (m_queue.find(bot->GetObjectGuid()) != m_queue.end())
                continue;

            if (bot->GetTeam() != waiter.team)
                continue;

            uint32 const botLevel = bot->GetLevel();
            if (botLevel + levelRange < waiterLevel || waiterLevel + levelRange < botLevel)
                continue;

            if (!(AllowedRoleMask(bot) & wanted))
                continue;

            // And what the bot's AI can actually do, which is not the same thing.
            // AllowedRoleMask says a shaman may queue as tank; the bot side has no
            // tank strategy for one at all, so it would stand there doing nothing
            // while the group has no tank and, worse, no healer either.
            if (!(Playerbot_GetAllowedRoles(bot) & wanted))
                continue;

            chosen = bot;
            break;
        }

        // No suitable bot for this role - try the next one down rather than
        // giving up on the whole group.
        if (!chosen)
        {
            if (wanted == LFT_ROLE_TANK)
                tanks = 1;
            else if (wanted == LFT_ROLE_HEALER)
                healers = 1;
            else
                break;

            continue;
        }

        std::vector<std::string> instances;
        instances.push_back(instance);

        EnqueuePlayer(chosen, ObjectGuid(), instances, wanted);
        m_fillBots.insert(chosen->GetObjectGuid());

        sLog.outBasic("LFT: filled %s as %s for %s (level %u)", chosen->GetName(),
            RoleSuffix(wanted), waiter.name.c_str(), waiterLevel);

        ++inQueue;
        if (wanted == LFT_ROLE_TANK)
            ++tanks;
        else if (wanted == LFT_ROLE_HEALER)
            ++healers;
        else
            ++damage;
    }
}

// Bots never see the offer popup, so accept on their behalf.
void LFTManager::AcceptOffersForFillBots()
{
    for (OffersMap::const_iterator itr = m_offers.begin(); itr != m_offers.end();)
    {
        uint32 const offerId = itr->first;
        Offer const& offer = itr->second;
        ++itr;

        for (auto const& role : offer.roles)
        {
            if (!IsFillBot(role.first) || offer.accepted.find(role.first) != offer.accepted.end())
                continue;

            Player* bot = GetPlayer(role.first);
            if (!bot)
                continue;

            // Hand the assigned role to the bot's AI before it accepts. Its
            // combat strategy comes from talents otherwise, so a fury warrior
            // pulled in as a tank would keep swinging instead of holding aggro.
            Playerbot_SetForcedRole(bot, role.second);
            sLog.outBasic("LFT: %s accepts as %s", bot->GetName(), RoleSuffix(role.second));

            HandleOfferAccept(bot);

            // Accepting may complete the offer and invalidate the map.
            if (m_offers.find(offerId) == m_offers.end())
                break;
        }
    }
}

void LFTManager::UpdateBotFill(uint32 diff)
{
    if (!sWorld.getConfig(CONFIG_BOOL_LFT_BOTFILL_ENABLE))
    {
        if (!m_fillBots.empty())
            DropUnneededFillBots();

        return;
    }

    AcceptOffersForFillBots();

    if (m_botFillTimer > diff)
    {
        m_botFillTimer -= diff;
        return;
    }

    m_botFillTimer = 5 * IN_MILLISECONDS;

    DropUnneededFillBots();

    SeedBotOnlyQueue();

    time_t const now = time(nullptr);
    uint32 const delay = sWorld.getConfig(CONFIG_UINT32_LFT_BOTFILL_DELAY);

    // Collect the instances real players have waited long enough for. Copied
    // out first because filling modifies m_queue.
    std::vector<std::pair<std::string, QueuedPlayer>> pending;

    for (QueueMap::const_iterator itr = m_queue.begin(); itr != m_queue.end(); ++itr)
    {
        if (IsFillBot(itr->first) || m_playerOffers.find(itr->first) != m_playerOffers.end())
            continue;

        if (uint32(now - itr->second.joinTime) < delay)
            continue;

        for (std::string const& instance : itr->second.instances)
            pending.push_back(std::make_pair(instance, itr->second));
    }

    for (auto const& entry : pending)
        FillInstanceWithBots(entry.first, entry.second);
}
