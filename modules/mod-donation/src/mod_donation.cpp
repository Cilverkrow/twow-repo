// Awards online players shop coins for time spent in the world.
//
// Lifted verbatim from World::Update(), where it lived inline with no file of
// its own, marked only by a "// --- Custom:" comment. The behaviour is
// unchanged on purpose: the accumulator shape, the eligibility rules, the
// persistence points and the wording of the chat line are all as they were, so
// the characterization test written before the move still passes after it.
//
// What did change is ownership. The module keeps its own accumulator and its
// own table; the shop's currency is credited through ShopMgr::AwardCoins rather
// than by writing shop_coins directly, because that table belongs to the shop
// (ADR-0021: one schema, one owner).

#include "ScriptObjects.h"

#include "AccountMgr.h"
#include "Chat/Chat.h"
#include "Config/Config.h"
#include "Database/DatabaseEnv.h"
#include "Log.h"
#include "Objects/Player.h"
#include "Shop/ShopMgr.h"
#include "World.h"
#include "WorldSession.h"

#include <memory>
#include <string>
#include <unordered_map>

namespace
{
    uint32 constexpr DEFAULT_INTERVAL_MS = 3600000;   // one hour
    uint32 constexpr DEFAULT_FLUSH_MS    = 300000;    // five minutes

    class DonationPointsWorldScript : public WorldScript
    {
    public:
        DonationPointsWorldScript()
            : WorldScript("mod_donation_world", { WORLDHOOK_ON_UPDATE })
        {
        }

        void OnUpdate(uint32 diff) override
        {
            if (!sConfig.GetBoolDefault("AutoDonationPoints.Enable", false))
                return;

            uint32 intervalMs = sConfig.GetIntDefault("AutoDonationPoints.IntervalMs", DEFAULT_INTERVAL_MS);

            // A zero here makes the award condition below true on every tick,
            // which means two writes to the login database and a chat line per
            // online player per tick - roughly sixty writes a second each. That
            // saturates the connection pool, the world thread waits on it, and
            // MySQL logs a row of "Aborted connection ... Got an error reading
            // communication packets" as the dying server drops its handles. The
            // warnings look like the cause and are the consequence. Fall back to
            // the default rather than letting a stray value take the server down.
            if (!intervalMs)
            {
                sLog.outError("AutoDonationPoints.IntervalMs is 0, which would award every tick. Using %u instead.",
                    DEFAULT_INTERVAL_MS);
                intervalMs = DEFAULT_INTERVAL_MS;
            }

            uint32 const amount  = sConfig.GetIntDefault("AutoDonationPoints.Amount", 1);
            uint32 const flushMs = sConfig.GetIntDefault("AutoDonationPoints.FlushIntervalMs", DEFAULT_FLUSH_MS);

            bool shouldFlush = false;
            if (m_flushTimer <= diff)
            {
                m_flushTimer = flushMs;
                shouldFlush = true;
            }
            else
                m_flushTimer -= diff;

            for (auto const& entry : sWorld.GetAllSessions())
            {
                WorldSession* session = entry.second;
                if (!session)
                    continue;

                Player* player = session->GetPlayer();
                if (!player || !player->IsInWorld())
                    continue;

                if (!IsEligible(session->GetAccountId()))
                    continue;

                uint32 const accountId = session->GetAccountId();

                // Load the persisted progress once, if this account has not
                // been seen since the server started.
                auto found = m_accumulatorMs.find(accountId);
                if (found == m_accumulatorMs.end())
                    found = m_accumulatorMs.emplace(accountId, LoadProgress(accountId)).first;

                uint32& accumulatedMs = found->second;
                accumulatedMs += diff;

                if (accumulatedMs >= intervalMs)
                {
                    accumulatedMs -= intervalMs;
                    sShopMgr.AwardCoins(accountId, amount);
                    SaveProgress(accountId, accumulatedMs);
                    ChatHandler(player).PSendSysMessage(
                        "You received %u Donation Point(s) for your time online!", amount);
                }
                else if (shouldFlush)
                {
                    SaveProgress(accountId, accumulatedMs);
                }
            }
        }

    private:
        // Bots and the Discord bridge are not players and must not collect.
        //
        // Compared case insensitively: the bridge account is spelled "discord"
        // in this database while the comparison ran against "DISCORD", so the
        // bridge of all things collected the points and its chat output turned
        // up as "[Server]: You have ..." in the Discord channel. The same
        // applies to the RNDBOT prefix.
        static bool IsEligible(uint32 accountId)
        {
            std::string name;
            sAccountMgr.GetName(accountId, name);
            for (char& c : name)
                if (c >= 'a' && c <= 'z')
                    c = c - 'a' + 'A';

            return name.rfind("RNDBOT", 0) != 0 && name != "DISCORD";
        }

        static uint32 LoadProgress(uint32 accountId)
        {
            std::unique_ptr<QueryResult> result(LoginDatabase.PQuery(
                "SELECT `accumulated_ms` FROM `donation_point_progress` WHERE `account_id` = %u", accountId));
            return result ? result->Fetch()[0].GetUInt32() : 0;
        }

        static void SaveProgress(uint32 accountId, uint32 accumulatedMs)
        {
            LoginDatabase.PExecute(
                "INSERT INTO `donation_point_progress` (`account_id`, `accumulated_ms`) VALUES (%u, %u) "
                "ON DUPLICATE KEY UPDATE `accumulated_ms` = %u",
                accountId, accumulatedMs, accumulatedMs);
        }

        // Per-account rather than one shared timer, so it does not matter when
        // somebody logged in: everyone gets their own full interval of playing
        // time before the next award.
        std::unordered_map<uint32 /*accountId*/, uint32 /*accumulatedMs*/> m_accumulatorMs;
        uint32 m_flushTimer = 0;
    };
}

void Addmod_donationScripts()
{
    new DonationPointsWorldScript();
}
