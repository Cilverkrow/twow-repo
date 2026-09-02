// Must precede every playerbot header -- see BotBrainPlayerbots.h.
#include "BotBrainPlayerbots.h"

#include "BotBrainPipeline.h"

#include "BotBrainClient.h"
#include "BotBrainConfig.h"

#include "playerbot/PlayerbotAI.h"
#include "playerbot/TravelMgr.h"
#include "playerbot/WorldPosition.h"
#include "playerbot/strategy/actions/ChooseTravelTargetAction.h"
#include "playerbot/strategy/values/TravelValues.h"

#include "Bag.h"
#include "Log.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "QuestDef.h"
#include "World.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <map>
#include <mutex>
#include <sstream>
#include <thread>
#include <unordered_map>
#include <vector>

using namespace ai;

namespace botbrain
{
    char const* const kStrategyName = "bot brain";

    namespace
    {
        // The purposes a travel intent can name. Deliberately not
        // TravelDestinationPurpose::None, which means "every purpose" in
        // GetDestinations and would hand the brain the entire world.
        uint32 constexpr kPurposeMask =
            uint32(TravelDestinationPurpose::QuestGiver) |
            uint32(TravelDestinationPurpose::QuestAllObjective) |
            uint32(TravelDestinationPurpose::QuestTaker) |
            uint32(TravelDestinationPurpose::Repair) |
            uint32(TravelDestinationPurpose::Vendor) |
            uint32(TravelDestinationPurpose::Grind);

        // A worker writes its result, then flips `done` with release ordering;
        // the map thread reads `done` with acquire ordering and only then
        // touches the payload. No mutex needed, and no chance of the map thread
        // reading a half-written vector.
        struct DestinationExchange
        {
            std::atomic<bool> done{false};
            PartitionedTravelList list;
        };

        struct PlanExchange
        {
            std::atomic<bool> done{false};
            HttpResult result;
        };

        enum class Phase
        {
            Idle,
            AwaitingDestinations,
            AwaitingPlan
        };

        struct BotPlanState
        {
            Phase phase = Phase::Idle;
            uint32 nextRequestMs = 0;

            std::shared_ptr<DestinationExchange> destinations;
            std::shared_ptr<PlanExchange> plan;

            std::vector<ResolvedPoi> poiTable;
            uint32 poiTableAtMs = 0;

            bool hasIntent = false;
            Intent intent;

            bool hasOutcome = false;
            IntentOutcome outcome;
        };

        std::mutex g_statesMutex;
        std::unordered_map<uint64, BotPlanState> g_states;   // keyed by ObjectGuid raw value

        std::atomic<uint32> g_inFlight{0};
        std::atomic<bool> g_shuttingDown{false};
        std::atomic<bool> g_admitted{false};
        std::atomic<uint64> g_requestCounter{0};

        int64_t NowUnixMs()
        {
            using namespace std::chrono;
            return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
        }

        // Elapsed-millisecond helper that survives WorldTimer's 32-bit wrap.
        bool Elapsed(uint32 now, uint32 deadline)
        {
            return int32(now - deadline) >= 0;
        }

        std::string MakeRequestId(uint64 guid)
        {
            char buffer[64];
            std::snprintf(buffer, sizeof(buffer), "ws-%llu-%llu",
                static_cast<unsigned long long>(guid),
                static_cast<unsigned long long>(g_requestCounter.fetch_add(1) + 1));
            return std::string(buffer);
        }

        char const* PurposeToPoiKind(TravelDestinationPurpose purpose)
        {
            switch (purpose)
            {
                case TravelDestinationPurpose::QuestGiver:      return "quest_giver";
                case TravelDestinationPurpose::QuestTaker:      return "quest_turnin";
                case TravelDestinationPurpose::QuestObjective1:
                case TravelDestinationPurpose::QuestObjective2:
                case TravelDestinationPurpose::QuestObjective3:
                case TravelDestinationPurpose::QuestObjective4: return "quest_objective";
                case TravelDestinationPurpose::Repair:          return "repair";
                case TravelDestinationPurpose::Vendor:          return "vendor";
                case TravelDestinationPurpose::Trainer:         return "trainer";
                case TravelDestinationPurpose::Mail:            return "mailbox";
                case TravelDestinationPurpose::Grind:
                case TravelDestinationPurpose::Boss:            return "grind_area";
                default:                                       return "";
            }
        }

        // ------------------------------------------------------------------
        // Snapshot construction. Map thread only: every line here dereferences
        // the bot.
        // ------------------------------------------------------------------

        void FillCharacter(Player* bot, Character& out)
        {
            out.name = bot->GetName() ? bot->GetName() : "";
            out.level = uint8(bot->GetLevel());
            out.cls = uint8(bot->getClass());
            out.race = uint8(bot->getRace());
            out.faction = bot->GetTeam() == ALLIANCE ? "alliance" : "horde";
            out.money = bot->GetMoney();

            uint32 free = 0;
            for (uint8 slot = INVENTORY_SLOT_ITEM_START; slot < INVENTORY_SLOT_ITEM_END; ++slot)
                if (!bot->GetItemByPos(INVENTORY_SLOT_BAG_0, slot))
                    ++free;

            for (uint8 bagSlot = INVENTORY_SLOT_BAG_START; bagSlot < INVENTORY_SLOT_BAG_END; ++bagSlot)
            {
                Bag const* bag = static_cast<Bag*>(bot->GetItemByPos(INVENTORY_SLOT_BAG_0, bagSlot));
                if (!bag)
                    continue;
                ItemPrototype const* proto = bag->GetProto();
                if (!proto || proto->Class != ITEM_CLASS_CONTAINER || proto->SubClass != ITEM_SUBCLASS_CONTAINER)
                    continue;
                free += bag->GetFreeSlots();
            }
            out.freeBagSlots = free;
        }

        void FillVitals(Player* bot, Vitals& out)
        {
            uint32 const maxHealth = bot->GetMaxHealth();
            out.healthPct = maxHealth ? (100.0 * double(bot->GetHealth()) / double(maxHealth)) : 0.0;
            if (out.healthPct < 0.0)
                out.healthPct = 0.0;
            if (out.healthPct > 100.0)
                out.healthPct = 100.0;

            Powers const power = bot->GetPowerType();
            uint32 const maxPower = bot->GetMaxPower(power);
            if (maxPower)
            {
                out.hasPowerPct = true;
                out.powerPct = 100.0 * double(bot->GetPower(power)) / double(maxPower);
            }

            out.isDead = bot->IsDead();
            out.inCombat = bot->IsInCombat();
            out.isResting = bot->GetRestType() != REST_TYPE_NO;
            out.isMounted = bot->IsMounted();

            // Computed here rather than taken from AI_VALUE("durability") so
            // that "no equipped item has durability" stays distinguishable from
            // "durability is zero" -- the contract models it as a pointer for
            // exactly that reason, and a planner must not read absence as fine.
            uint32 total = 0;
            uint32 totalMax = 0;
            for (int slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
            {
                Item* item = bot->GetItemByPos(uint16((INVENTORY_SLOT_BAG_0 << 8) | slot));
                if (!item)
                    continue;
                uint32 const maxDurability = item->GetUInt32Value(ITEM_FIELD_MAXDURABILITY);
                if (!maxDurability)
                    continue;
                totalMax += maxDurability;
                total += item->GetUInt32Value(ITEM_FIELD_DURABILITY);
            }
            if (totalMax)
            {
                out.hasDurabilityPct = true;
                out.durabilityPct = 100.0 * double(total) / double(totalMax);
            }
        }

        void FillPosition(Player* bot, Position& out)
        {
            out.mapId = bot->GetMapId();
            out.x = bot->GetPositionX();
            out.y = bot->GetPositionY();
            out.z = bot->GetPositionZ();
            out.orientation = bot->GetOrientation();     // radians
            out.zoneId = bot->GetZoneId();
            out.areaId = bot->GetAreaId();
            out.instanceId = bot->GetInstanceId();
        }

        void FillSurroundings(Player* bot, PlayerbotAI* botAI, Surroundings& out)
        {
            Group* group = bot->GetGroup();
            out.groupSize = group ? group->GetMembersCount() : 1;
            out.isGroupLeader = group && botAI->IsGroupLeader();

            // Counts, never entity lists -- an entity list per bot per tick is
            // the payload that kills this design at 1000 bots.
            //
            // Only the hostile count is populated, and only from the AI's own
            // per-tick "my attacker count" value, which is already computed for
            // this bot this tick and costs nothing to read. The name is exactly
            // that -- ValueContext.h:181 registers "my attacker count"; asking
            // for "attacker count" returns nullptr from the dynamic_cast in
            // AiObjectContext::GetValue and dereferencing it is a crash, not a
            // zero.
            //
            // The friendly counts stay zero: there is no cached value for them,
            // and a grid search per bot per planning round is not worth two
            // numbers no planner currently reads. If a planner starts needing
            // them, populate them HERE -- they must not be inferred from zero.
            if (ai::Value<uint8>* attackers = botAI->GetAiObjectContext()->GetValue<uint8>("my attacker count"))
                out.hostileCount = attackers->Get();
        }

        void FillQuests(Player* bot, std::vector<QuestEntry>& out)
        {
            for (uint8 slot = 0; slot < MAX_QUEST_LOG_SIZE; ++slot)
            {
                uint32 const questId = bot->GetQuestSlotQuestId(slot);
                if (!questId)
                    continue;

                Quest const* quest = sObjectMgr.GetQuestTemplate(questId);
                if (!quest)
                    continue;

                QuestEntry entry;
                entry.questId = questId;

                switch (bot->GetQuestStatus(questId))
                {
                    case QUEST_STATUS_COMPLETE:   entry.status = "complete"; break;
                    case QUEST_STATUS_FAILED:     entry.status = "failed"; break;
                    case QUEST_STATUS_INCOMPLETE: entry.status = "incomplete"; break;
                    default:                      continue;   // not in the log in any meaningful sense
                }

                // Counted objectives only. A talk-to or an escort has none,
                // which the contract spells as total 0 -- not "no work left".
                uint32 done = 0;
                uint32 total = 0;
                QuestStatusMap::const_iterator status = bot->GetQuestStatusMap().find(questId);
                for (int i = 0; i < QUEST_OBJECTIVES_COUNT; ++i)
                {
                    if (!quest->ReqCreatureOrGOId[i] && !quest->ReqItemId[i])
                        continue;
                    uint32 const required = quest->ReqCreatureOrGOId[i]
                        ? quest->ReqCreatureOrGOCount[i]
                        : quest->ReqItemCount[i];
                    if (!required)
                        continue;
                    ++total;
                    if (status == bot->GetQuestStatusMap().end())
                        continue;
                    uint32 const have = quest->ReqCreatureOrGOId[i]
                        ? status->second.m_creatureOrGOcount[i]
                        : status->second.m_itemcount[i];
                    if (have >= required)
                        ++done;
                }
                entry.objectivesDone = done;
                entry.objectivesTotal = total;
                entry.requiredLevel = uint8(quest->GetMinLevel());
                entry.questLevel = uint8(quest->GetQuestLevel());

                out.push_back(entry);
            }
        }

        // Flatten the partitioned list into POIs, nearest partition first, and
        // stop at maxPois. The map is keyed by partition distance ascending, so
        // walking it in order is already "nearest first".
        void BuildPois(PartitionedTravelList const& list, WorldPosition const& center,
            uint32 maxPois, std::vector<PointOfInterest>& pois, std::vector<ResolvedPoi>& table)
        {
            uint32 index = 0;
            for (auto const& partition : list)
            {
                for (TravelPoint const& point : partition.second)
                {
                    if (pois.size() >= maxPois)
                        return;

                    TravelDestination* destination = std::get<0>(point);
                    WorldPosition* position = std::get<1>(point);
                    if (!destination || !position)
                        continue;

                    char const* kind = PurposeToPoiKind(destination->GetPurpose());
                    if (!kind || !*kind)
                        continue;

                    // Cross-map candidates are a tier-0 decision (flight paths),
                    // and the contract says a POI is always on the bot's map.
                    if (position->getMapId() != center.getMapId())
                        continue;

                    char id[24];
                    std::snprintf(id, sizeof(id), "p%u", index++);

                    PointOfInterest poi;
                    poi.id = id;
                    poi.kind = kind;
                    poi.pos.mapId = position->getMapId();
                    poi.pos.x = position->getX();
                    poi.pos.y = position->getY();
                    poi.pos.z = position->getZ();
                    poi.pos.orientation = position->getO();
                    poi.hasDistanceYards = true;
                    poi.distanceYards = std::get<2>(point);

                    if (QuestTravelDestination const* quest = dynamic_cast<QuestTravelDestination const*>(destination))
                        poi.relatedQuestId = quest->GetQuestId();

                    pois.push_back(poi);

                    ResolvedPoi resolved;
                    resolved.id = poi.id;
                    resolved.destination = destination;
                    resolved.position = position;
                    table.push_back(resolved);
                }
            }
        }

        // ------------------------------------------------------------------
        // Workers. Each captures only values and a shared_ptr to its exchange,
        // so a bot logging out mid-flight leaves a result nobody reads.
        // ------------------------------------------------------------------

        void SpawnDestinationWorker(std::shared_ptr<DestinationExchange> const& exchange,
            WorldPosition const& center, PlayerTravelInfo const& info)
        {
            g_inFlight.fetch_add(1);
            std::thread([exchange, center, info]()
            {
                PartitionedTravelList list;
                try
                {
                    list = sTravelMgr.GetPartitions(center, travelPartitions, info, kPurposeMask);
                }
                catch (...)
                {
                    // An escaping exception on a detached thread is
                    // std::terminate for the whole worldserver. Swallow it; the
                    // bot gets an empty list and keeps travelling stock.
                }
                exchange->list = std::move(list);
                exchange->done.store(true, std::memory_order_release);
                g_inFlight.fetch_sub(1);
            }).detach();
        }

        void SpawnPlanWorker(std::shared_ptr<PlanExchange> const& exchange,
            std::string const& endpoint, std::string const& body, uint32 timeoutMs)
        {
            g_inFlight.fetch_add(1);
            // Note what is captured: three strings and an integer. There is no
            // way to name a Player, a session or a bot from in here.
            std::thread([exchange, endpoint, body, timeoutMs]()
            {
                exchange->result = PostPlan(endpoint, body, timeoutMs);
                exchange->done.store(true, std::memory_order_release);
                g_inFlight.fetch_sub(1);
            }).detach();
        }

        // ------------------------------------------------------------------

        BotPlanState* Find(uint64 raw)
        {
            std::unordered_map<uint64, BotPlanState>::iterator it = g_states.find(raw);
            return it == g_states.end() ? nullptr : &it->second;
        }

        bool ShouldPlanFor(Player* bot, PlayerbotAI* botAI)
        {
            Settings const& cfg = GetSettings();
            if (!cfg.enabled || !g_admitted.load() || g_shuttingDown.load())
                return false;
            if (!bot || !botAI || !bot->IsInWorld())
                return false;
            // Opt in per bot. Off for every bot that does not carry the
            // strategy, whatever the config says.
            return botAI->HasStrategy(kStrategyName, BotState::BOT_STATE_NON_COMBAT);
        }
    }

    void BeginShutdown()
    {
        g_shuttingDown.store(true);
    }

    bool IsAdmitted()
    {
        return g_admitted.load();
    }

    bool Handshake()
    {
        g_admitted.store(false);

        Settings const& cfg = GetSettings();
        if (!cfg.enabled)
            return false;

        HttpResult const result = FetchContract(cfg.endpoint, cfg.timeoutMs);
        if (!result.ok)
        {
            sLog.outError("mod-bot-brain: contract handshake with %s failed (%s); the brain stays off and bots keep the stock chooser",
                cfg.endpoint.c_str(), result.error.c_str());
            return false;
        }

        ContractInfo info;
        std::string error;
        if (!DecodeContractInfo(result.body, info, error))
        {
            sLog.outError("mod-bot-brain: contract handshake returned unusable JSON (%s); the brain stays off",
                error.c_str());
            return false;
        }

        if (!ContractMajorSupported(info, kContractMajor))
        {
            sLog.outError("mod-bot-brain: contract skew -- this build speaks major %d, %s serves version %s; the brain stays off",
                kContractMajor, cfg.endpoint.c_str(), info.version.c_str());
            return false;
        }

        sLog.outString("mod-bot-brain: contract handshake OK -- peer %s speaks %s, max batch %d",
            cfg.endpoint.c_str(), info.version.c_str(), info.maxBatch);
        g_admitted.store(true);
        return true;
    }

    void Forget(ObjectGuid guid)
    {
        std::lock_guard<std::mutex> lock(g_statesMutex);
        g_states.erase(guid.GetRawValue());
    }

    void RecordOutcome(Player* bot, std::string const& intentId, std::string const& kind,
        std::string const& result, std::string const& reason)
    {
        if (!bot || intentId.empty())
            return;

        std::lock_guard<std::mutex> lock(g_statesMutex);
        BotPlanState* state = Find(bot->GetObjectGuid().GetRawValue());
        if (!state)
            return;

        state->hasOutcome = true;
        state->outcome.intentId = intentId;
        state->outcome.kind = kind;
        state->outcome.result = result;
        state->outcome.reason = reason;
        state->outcome.issuedAtMs = NowUnixMs();
    }

    bool TakeTravelIntent(Player* bot, Intent& intent, ResolvedPoi& poi)
    {
        if (!bot)
            return false;

        Settings const& cfg = GetSettings();
        std::lock_guard<std::mutex> lock(g_statesMutex);
        BotPlanState* state = Find(bot->GetObjectGuid().GetRawValue());
        if (!state || !state->hasIntent)
            return false;

        // Offered once, whatever happens next: a rejected intent that stayed in
        // the mailbox would be retried on every tick forever.
        Intent const candidate = state->intent;
        state->hasIntent = false;

        if (!IsPoiDirectedKind(candidate.kind) || !candidate.hasTravel || candidate.travelPoiId.empty())
            return false;

        int64_t const now = NowUnixMs();
        if (candidate.expiresAtMs && candidate.expiresAtMs < now)
            return false;

        // The POI ids are snapshot-scoped by contract. An id from a table this
        // old is a stale destination, which is precisely what that scoping rule
        // exists to prevent.
        if (Elapsed(WorldTimer::getMSTime(), state->poiTableAtMs + cfg.poiTableTtlMs))
            return false;

        for (ResolvedPoi const& row : state->poiTable)
        {
            if (row.id != candidate.travelPoiId)
                continue;
            if (!row.destination || !row.position)
                return false;
            intent = candidate;
            poi = row;
            return true;
        }

        return false;
    }

    void Tick(Player* bot, PlayerbotAI* botAI)
    {
        if (!ShouldPlanFor(bot, botAI))
            return;

        Settings const& cfg = GetSettings();
        uint32 const now = WorldTimer::getMSTime();
        uint64 const raw = bot->GetObjectGuid().GetRawValue();

        // Phase A/D bookkeeping happens under the lock; the two expensive
        // steps (building the snapshot, spawning a worker) happen after it.
        std::shared_ptr<DestinationExchange> readyDestinations;
        std::shared_ptr<PlanExchange> readyPlan;
        bool startRequest = false;
        bool hasOutcome = false;
        IntentOutcome outcome;

        {
            std::lock_guard<std::mutex> lock(g_statesMutex);
            BotPlanState& state = g_states[raw];

            switch (state.phase)
            {
                case Phase::Idle:
                    if (!Elapsed(now, state.nextRequestMs))
                        return;
                    if (g_inFlight.load() >= cfg.maxInFlight)
                        return;
                    startRequest = true;
                    break;

                case Phase::AwaitingDestinations:
                    if (!state.destinations || !state.destinations->done.load(std::memory_order_acquire))
                        return;
                    readyDestinations = state.destinations;
                    state.destinations.reset();
                    hasOutcome = state.hasOutcome;
                    outcome = state.outcome;
                    break;

                case Phase::AwaitingPlan:
                    if (!state.plan || !state.plan->done.load(std::memory_order_acquire))
                        return;
                    readyPlan = state.plan;
                    state.plan.reset();
                    break;
            }
        }

        // ---- Phase A: ask for destinations, off the map thread. ------------
        if (startRequest)
        {
            std::shared_ptr<DestinationExchange> exchange = std::make_shared<DestinationExchange>();
            WorldPosition const center(bot);
            PlayerTravelInfo const info(bot);
            SpawnDestinationWorker(exchange, center, info);

            std::lock_guard<std::mutex> lock(g_statesMutex);
            BotPlanState& state = g_states[raw];
            state.destinations = exchange;
            state.phase = Phase::AwaitingDestinations;
            return;
        }

        // ---- Phase B: build the snapshot, on the map thread, bot alive. ----
        if (readyDestinations)
        {
            std::vector<PointOfInterest> pois;
            std::vector<ResolvedPoi> table;
            WorldPosition const center(bot);
            BuildPois(readyDestinations->list, center, cfg.maxPois, pois, table);

            Snapshot snapshot;
            snapshot.bot.realm = realmID;
            snapshot.bot.guid = bot->GetGUIDLow();
            FillCharacter(bot, snapshot.chr);
            FillPosition(bot, snapshot.pos);
            FillVitals(bot, snapshot.vitals);
            FillSurroundings(bot, botAI, snapshot.around);
            FillQuests(bot, snapshot.quests);
            snapshot.pois = pois;
            snapshot.observedAtMs = NowUnixMs();
            if (hasOutcome)
            {
                snapshot.hasLastOutcome = true;
                snapshot.lastOutcome = outcome;
            }

            std::string error;
            if (!ValidateSnapshot(snapshot, error))
            {
                // Refuse locally rather than let the service refuse it: this
                // side can name the bot. bot.realm being zero is the usual
                // cause -- a worldserver started without a realm id.
                sLog.outError("mod-bot-brain: snapshot for %s rejected locally (%s)",
                    bot->GetName() ? bot->GetName() : "?", error.c_str());
                std::lock_guard<std::mutex> lock(g_statesMutex);
                BotPlanState& state = g_states[raw];
                state.phase = Phase::Idle;
                state.nextRequestMs = now + cfg.backoffMs;
                return;
            }

            PlanRequest request;
            request.contractVersion = kContractVersion;
            request.requestId = MakeRequestId(snapshot.bot.guid);
            request.sentAtMs = NowUnixMs();
            request.deadlineMs = cfg.timeoutMs;
            request.snapshots.push_back(snapshot);

            std::shared_ptr<PlanExchange> exchange = std::make_shared<PlanExchange>();
            SpawnPlanWorker(exchange, cfg.endpoint, EncodePlanRequest(request), cfg.timeoutMs);

            std::lock_guard<std::mutex> lock(g_statesMutex);
            BotPlanState& state = g_states[raw];
            state.plan = exchange;
            state.poiTable = table;
            state.poiTableAtMs = now;
            state.hasOutcome = false;
            state.phase = Phase::AwaitingPlan;
            return;
        }

        // ---- Phase D: take the answer. -------------------------------------
        if (readyPlan)
        {
            PlanResponse response;
            std::string error;
            bool decoded = false;

            if (!readyPlan->result.ok)
                error = readyPlan->result.error;
            else
                decoded = DecodePlanResponse(readyPlan->result.body, response, error);

            std::lock_guard<std::mutex> lock(g_statesMutex);
            BotPlanState& state = g_states[raw];
            state.phase = Phase::Idle;

            if (!decoded)
            {
                // Silent by design at BASIC level: a brain that is down must
                // not fill the log once per bot per interval.
                sLog.outDetail("mod-bot-brain: plan for %s failed (%s); stock chooser continues",
                    bot->GetName() ? bot->GetName() : "?", error.c_str());
                state.nextRequestMs = now + cfg.backoffMs;
                return;
            }

            state.nextRequestMs = now + cfg.intervalMs;

            uint64 const guidLow = bot->GetGUIDLow();
            for (Intent const& intent : response.intents)
            {
                if (intent.bot.guid != guidLow || intent.bot.realm != realmID)
                    continue;   // never apply an intent addressed to another bot
                state.hasIntent = true;
                state.intent = intent;
                break;
            }
        }
    }
}
