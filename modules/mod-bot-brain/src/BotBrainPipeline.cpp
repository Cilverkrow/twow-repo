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
#include "Database/DatabaseEnv.h"
#include "Log.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "QuestDef.h"
#include "World.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <random>
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

        // Same lock-free handoff as DestinationExchange, for a bot's stable
        // identity (ADR-0039) instead of its travel destinations: the worker
        // writes `uuid` (empty means the attempt could not mint or find one --
        // a DB hiccup, or it lost nothing and simply has nothing to report),
        // then flips `done` with release ordering; the map thread reads `done`
        // with acquire and only then reads `uuid`.
        struct IdentityExchange
        {
            std::atomic<bool> done{false};
            std::string uuid;
        };

        // Batching is not an optimisation, it is the design
        // (services/bot-brain/contract/wire.go:16-20): one HTTP round trip
        // must serve many bots, not one per bot per interval. This exchange
        // is shared by every bot whose snapshot rode in the same request, so
        // it carries the decoded response rather than the raw body -- decoding
        // once in the worker, before `done` is set, means every bot's map
        // thread can read `response` lock-free afterwards without racing
        // another bot's thread to parse the same JSON.
        struct BatchExchange
        {
            std::atomic<bool> done{false};
            HttpResult result;
            bool decoded = false;
            std::string decodeError;
            PlanResponse response;
        };

        // Snapshots waiting to go out together. Filled under g_statesMutex as
        // each bot finishes phase B; flushed either when it reaches the
        // negotiated max batch size or when g_pendingBatch's flush deadline
        // elapses, whichever comes first.
        struct PendingBatch
        {
            std::vector<Snapshot> snapshots;
            std::vector<uint64> guids;   // g_states keys, parallel to snapshots
            uint32 flushDeadlineMs = 0;
        };

        // The handshake retry uses the same shape as the two above for the same
        // reason: the HTTP call must not run on the world thread, and a detached
        // worker must not log. The worker fills this in and the world thread
        // reads it, so every sLog line below still comes from the world thread.
        struct HandshakeExchange
        {
            std::atomic<bool> done{false};
            bool ok = false;         // a compatible peer answered
            bool skew = false;       // it answered, but speaks a major we do not
            std::string version;     // what it said it speaks
            int maxBatch = 0;
            std::string error;       // transport or decode failure
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

            // Null while this bot's snapshot sits in g_pendingBatch waiting to
            // be sent; set to the shared exchange once that batch is
            // dispatched. AwaitingPlan covers both: "not dispatched yet" and
            // "dispatched, waiting on the peer" are the same wait from this
            // bot's point of view.
            std::shared_ptr<BatchExchange> batch;

            std::vector<ResolvedPoi> poiTable;
            uint32 poiTableAtMs = 0;

            bool hasIntent = false;
            Intent intent;

            bool hasOutcome = false;
            IntentOutcome outcome;

            // ADR-0039 identity cache. Empty means "not yet minted" -- still
            // in flight, backing off after a failed attempt, or genuinely
            // never seen before. A bot with an empty uuid is planned for
            // without memory, never blocked or refused (ADR-0039 says so
            // explicitly): this is exactly the field BotId::uuid on the wire,
            // cached here so no bot pays a database round trip every tick.
            std::string uuid;
            std::shared_ptr<IdentityExchange> identity;   // non-null while a mint/lookup is in flight
            uint32 nextIdentityAttemptMs = 0;             // backoff after a failed attempt
        };

        std::mutex g_statesMutex;
        std::unordered_map<uint64, BotPlanState> g_states;   // keyed by ObjectGuid raw value

        // The batch currently accumulating snapshots, or null between batches.
        // Guarded by g_statesMutex, same as g_states: a bot joins this and
        // transitions its own phase in the same critical section, so the two
        // can never disagree about whether a snapshot was queued.
        std::shared_ptr<PendingBatch> g_pendingBatch;

        std::atomic<uint32> g_inFlight{0};
        std::atomic<bool> g_shuttingDown{false};
        std::atomic<bool> g_admitted{false};

        // Max snapshots per request, negotiated at handshake (contract
        // max_batch). Defaults to 1 -- i.e. no batching -- until a handshake
        // has actually told us otherwise, so a build that somehow starts
        // admitting before ReportHandshake runs cannot batch on a made-up
        // number.
        std::atomic<uint32> g_maxBatch{1};

        // Handshake retry state. The handshake used to run only at
        // WORLDHOOK_ON_STARTUP, so a bot-brain that started after the
        // worldserver -- or restarted at any point -- left g_admitted false for
        // the whole process lifetime, with no further log line. The brain was
        // silently off until someone restarted the realm.
        std::mutex g_handshakeMutex;
        std::shared_ptr<HandshakeExchange> g_handshakeAttempt;   // non-null while one is in flight
        std::atomic<uint32> g_nextHandshakeMs{0};                // WorldTimer ms; when a retry is allowed

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

        // A version-4 (random) UUID, canonical lowercase 8-4-4-4-12 hex form
        // (ADR-0039). thread_local rather than a shared engine: this runs on
        // detached identity workers, potentially several at once, and a PRNG
        // is not safe to share across threads without its own locking.
        std::string GenerateUuidV4()
        {
            thread_local std::mt19937_64 engine{std::random_device{}()};
            std::uniform_int_distribution<uint64_t> dist;

            uint64_t const hi = dist(engine);
            uint64_t const lo = dist(engine);

            uint8_t bytes[16];
            std::memcpy(bytes, &hi, 8);
            std::memcpy(bytes + 8, &lo, 8);
            bytes[6] = uint8_t((bytes[6] & 0x0F) | 0x40);   // RFC 4122 version 4
            bytes[8] = uint8_t((bytes[8] & 0x3F) | 0x80);   // RFC 4122 variant 10xx

            char buffer[37];
            std::snprintf(buffer, sizeof(buffer),
                "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]);
            return std::string(buffer);
        }

        // WORKER THREAD ONLY -- two blocking round trips against cv_brain,
        // which is exactly why this must never be called from Tick() itself
        // (the "no blocking database call on the world update thread" rule
        // every other worker in this file already follows). Never logs, same
        // rule as SpawnBatchWorker's and SpawnDestinationWorker's bodies: a
        // failure here is reported by returning an empty string, and the
        // caller decides whether that is worth a log line.
        //
        // Reached through CharacterDatabase, the same global mod-playerbots
        // already uses for its own project schema (cv_bots, via
        // PlayerbotDatabaseContract.h) with a fully-qualified table name --
        // there is no separate cv_brain connection, because none is needed:
        // db-init.sh grants the worldserver's own DB_USER rights on cv_brain
        // precisely so this module can reach it over the connection it
        // already has.
        std::string MintOrLookupBotUuid(uint32 realm, uint64 guid)
        {
            {
                std::unique_ptr<QueryResult> existing(CharacterDatabase.PQuery(
                    "SELECT `bot_uuid` FROM `cv_brain`.`bot_identity` WHERE `realm` = %u AND `guid` = " UI64FMTD,
                    realm, guid));
                if (existing)
                {
                    std::string const uuid = existing->Fetch()[0].GetCppString();
                    if (!uuid.empty())
                        return uuid;
                }
            }

            // Not seen before: mint one and race whoever else may be minting
            // this same (realm, guid) on another map thread right now.
            // UNIQUE(realm, guid) (see the migration) is what makes the race
            // safe -- INSERT IGNORE silently loses instead of erroring when it
            // does, and the re-read below finds the ONE row that exists
            // either way: ours if this thread won, the other worker's if it
            // did not. Never two rows, never a second identity for the same
            // bot.
            std::string const minted = GenerateUuidV4();
            CharacterDatabase.DirectPExecute(
                "INSERT IGNORE INTO `cv_brain`.`bot_identity` (`bot_uuid`,`realm`,`guid`,`first_seen`) "
                "VALUES ('%s', %u, " UI64FMTD ", " SI64FMTD ")",
                minted.c_str(), realm, guid, static_cast<int64_t>(NowUnixMs()));

            std::unique_ptr<QueryResult> winner(CharacterDatabase.PQuery(
                "SELECT `bot_uuid` FROM `cv_brain`.`bot_identity` WHERE `realm` = %u AND `guid` = " UI64FMTD,
                realm, guid));
            if (!winner)
                return std::string();   // DB hiccup on the re-read; retried on the next attempt

            return winner->Fetch()[0].GetCppString();
        }

        // Mints or looks up a bot's stable identity (ADR-0039), entirely off
        // the world thread. Captures only two integers -- realm and guid --
        // never the bot itself: the same worker-boundary shape as
        // SpawnBatchWorker and SpawnDestinationWorker (ADR-0012, and
        // BotBrainClient.h:41-44 enforces it by type signature one layer
        // down).
        void SpawnIdentityWorker(std::shared_ptr<IdentityExchange> const& exchange, uint32 realm, uint64 guid)
        {
            g_inFlight.fetch_add(1);
            std::thread([exchange, realm, guid]()
            {
                try
                {
                    exchange->uuid = MintOrLookupBotUuid(realm, guid);
                }
                catch (...)
                {
                    // An escaping exception on a detached thread is
                    // std::terminate for the whole worldserver. Swallow it;
                    // the bot simply keeps planning without memory this round
                    // -- ADR-0039 names that a supported state, not an error.
                }
                exchange->done.store(true, std::memory_order_release);
                g_inFlight.fetch_sub(1);
            }).detach();
        }

        // Posts one batch and decodes the reply, all before `done` is set.
        // Decoding here rather than back on a map thread is what lets many
        // bots' Tick() calls -- each on its own map thread -- read
        // exchange->response afterwards without a lock: by the time any of
        // them can observe `done`, the response is already fully written and
        // nothing will write it again.
        void SpawnBatchWorker(std::shared_ptr<BatchExchange> const& exchange,
            std::string const& endpoint, std::string const& body, uint32 timeoutMs)
        {
            g_inFlight.fetch_add(1);
            // Note what is captured: three strings and an integer. There is no
            // way to name a Player, a session or a bot from in here.
            std::thread([exchange, endpoint, body, timeoutMs]()
            {
                try
                {
                    exchange->result = PostPlan(endpoint, body, timeoutMs);
                    if (exchange->result.ok)
                        exchange->decoded = DecodePlanResponse(exchange->result.body, exchange->response, exchange->decodeError);
                }
                catch (...)
                {
                    // An escaping exception on a detached thread is
                    // std::terminate for the whole worldserver. Every bot in
                    // this batch simply sees a failed round trip and keeps the
                    // stock chooser.
                    exchange->decoded = false;
                    exchange->decodeError = "batch worker threw";
                }
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

        // Sends one batch and hands every bot in it the exchange to wait on.
        // Called with `batch` already detached from g_pendingBatch by the
        // caller, so nobody else can mutate it out from under this call.
        //
        // The encode + spawn happen without g_statesMutex held, same reason
        // phase B builds a snapshot before taking the lock: this can take
        // however long std::string serialisation and a thread launch take, and
        // it must not stall every other bot's Tick() in the meantime.
        void DispatchBatch(std::shared_ptr<PendingBatch> const& batch, Settings const& cfg)
        {
            PlanRequest request;
            request.contractVersion = kContractVersion;
            // No single bot owns this request id -- it is not "ws-<a bot's
            // guid>-N" the way a solo request's was, because that would read
            // as if the batch belonged to whichever bot happened to be first.
            request.requestId = MakeRequestId(0);
            request.sentAtMs = NowUnixMs();
            request.deadlineMs = cfg.timeoutMs;
            request.snapshots = batch->snapshots;

            std::shared_ptr<BatchExchange> exchange = std::make_shared<BatchExchange>();
            SpawnBatchWorker(exchange, cfg.endpoint, EncodePlanRequest(request), cfg.timeoutMs);

            std::lock_guard<std::mutex> lock(g_statesMutex);
            for (uint64 raw : batch->guids)
            {
                BotPlanState* state = Find(raw);
                // A null state (Forget already ran) or a phase that is not
                // AwaitingPlan (should not happen, but Tick never assumes it)
                // means this bot will never look at `exchange` -- exactly the
                // "a bot logging out mid-flight leaves a result nobody reads"
                // property the other exchanges already rely on.
                if (state && state->phase == Phase::AwaitingPlan)
                    state->batch = exchange;
            }
        }

        // Writes an outcome into a state the caller ALREADY holds g_statesMutex
        // for. TakeTravelIntent runs under that lock, so it cannot call the
        // public RecordOutcome, which takes it -- that would deadlock the world
        // thread on the first rejected intent.
        void StoreOutcome(BotPlanState& state, std::string const& intentId, std::string const& kind,
            std::string const& result, std::string const& reason, std::string const& poiId)
        {
            if (intentId.empty())
                return;

            state.hasOutcome = true;
            state.outcome.intentId = intentId;
            state.outcome.kind = kind;
            state.outcome.result = result;
            state.outcome.reason = reason;
            state.outcome.poiId = poiId;
            state.outcome.issuedAtMs = NowUnixMs();
        }

        // The transport half of a handshake: no logging, no globals touched.
        // That is what makes it safe to call from a detached worker, and it is
        // the whole reason it is split out of Handshake().
        void AttemptHandshake(std::string const& endpoint, uint32 timeoutMs, HandshakeExchange& out)
        {
            HttpResult const result = FetchContract(endpoint, timeoutMs);
            if (!result.ok)
            {
                out.error = result.error;
                return;
            }

            ContractInfo info;
            std::string error;
            if (!DecodeContractInfo(result.body, info, error))
            {
                out.error = "unusable JSON: " + error;
                return;
            }

            out.version = info.version;
            out.maxBatch = info.maxBatch;

            if (!ContractMajorSupported(info, kContractMajor))
            {
                out.skew = true;
                return;
            }

            out.ok = true;
        }

        // Turns an attempt into log lines and the admission bit.
        //
        // WORLD THREAD ONLY. This is the half AttemptHandshake deliberately does
        // not do, because the detached workers in this file never log -- they
        // fill an exchange and let the world thread speak for them.
        void ReportHandshake(HandshakeExchange const& out, std::string const& endpoint, bool isRetry)
        {
            if (out.ok)
            {
                if (isRetry)
                {
                    // Worth a normal-level line: "the brain came back" is the
                    // event an operator waits for after restarting the service,
                    // and without it the only evidence is bots quietly starting
                    // to behave differently.
                    sLog.outString("mod-bot-brain: contract handshake recovered -- peer %s speaks %s, max batch %d; planning resumes",
                        endpoint.c_str(), out.version.c_str(), out.maxBatch);
                }
                else
                {
                    sLog.outString("mod-bot-brain: contract handshake OK -- peer %s speaks %s, max batch %d",
                        endpoint.c_str(), out.version.c_str(), out.maxBatch);
                }

                // A non-positive max_batch is a malformed or absent field, not
                // an instruction to batch zero snapshots per request -- fall
                // back to sending one at a time rather than wedge every bot in
                // AwaitingPlan behind a batch that can never reach its own
                // threshold.
                g_maxBatch.store(out.maxBatch > 0 ? uint32(out.maxBatch) : 1, std::memory_order_relaxed);
                g_admitted.store(true);
                return;
            }

            // Failures are loud once at boot and quiet on every retry. A service
            // down for an hour would otherwise write the same error sixty times,
            // which teaches people to filter exactly the line that matters when
            // it finally changes.
            if (out.skew)
            {
                if (isRetry)
                {
                    sLog.outDetail("mod-bot-brain: handshake retry found contract skew (peer speaks %s); still off",
                        out.version.c_str());
                }
                else
                {
                    sLog.outError("mod-bot-brain: contract skew -- this build speaks major %d, %s serves version %s; the brain stays off",
                        kContractMajor, endpoint.c_str(), out.version.c_str());
                }
                return;
            }

            if (isRetry)
            {
                sLog.outDetail("mod-bot-brain: handshake retry with %s failed (%s)",
                    endpoint.c_str(), out.error.c_str());
            }
            else
            {
                sLog.outError("mod-bot-brain: contract handshake with %s failed (%s); the brain stays off and bots keep the stock chooser. It is retried every BotBrain.BackoffMs.",
                    endpoint.c_str(), out.error.c_str());
            }
        }

        // Drives the retry from the world thread.
        //
        // Cheap in the common case: once admitted this is a single relaxed load
        // and a return, which matters because Tick runs per bot per tick.
        //
        // Called from Tick, so retries only happen while there is at least one
        // bot around -- which is exactly when being un-admitted costs anything.
        void MaybeRetryHandshake()
        {
            if (g_admitted.load(std::memory_order_relaxed))
                return;
            if (g_shuttingDown.load())
                return;

            Settings const& cfg = GetSettings();
            if (!cfg.enabled)
                return;

            uint32 const now = WorldTimer::getMSTime();

            std::shared_ptr<HandshakeExchange> finished;
            {
                std::lock_guard<std::mutex> lock(g_handshakeMutex);

                if (g_handshakeAttempt)
                {
                    if (!g_handshakeAttempt->done.load(std::memory_order_acquire))
                        return;                        // one is in flight; wait for it
                    finished = g_handshakeAttempt;
                    g_handshakeAttempt.reset();
                }
                else
                {
                    if (!Elapsed(now, g_nextHandshakeMs.load(std::memory_order_relaxed)))
                        return;

                    std::shared_ptr<HandshakeExchange> exchange = std::make_shared<HandshakeExchange>();
                    g_handshakeAttempt = exchange;

                    // Arm the next window before spawning rather than when the
                    // worker returns, so a worker that outlives BackoffMs cannot
                    // have a second attempt queued up behind it.
                    g_nextHandshakeMs.store(now + cfg.backoffMs, std::memory_order_relaxed);

                    std::string const endpoint = cfg.endpoint;
                    uint32 const timeoutMs = cfg.timeoutMs;

                    std::thread([exchange, endpoint, timeoutMs]()
                    {
                        try
                        {
                            AttemptHandshake(endpoint, timeoutMs, *exchange);
                        }
                        catch (...)
                        {
                            // An escaping exception on a detached thread is
                            // std::terminate for the entire worldserver.
                            exchange->error = "handshake worker threw";
                        }
                        exchange->done.store(true, std::memory_order_release);
                    }).detach();
                    return;
                }
            }

            // Reported outside the lock: ReportHandshake logs, and holding a
            // mutex across a log write is how an unrelated slow sink becomes a
            // world-thread stall.
            if (finished)
                ReportHandshake(*finished, cfg.endpoint, true);
        }

        // Drives the flush deadline from the world thread. Called from Tick
        // for every bot, not just the ones contributing to the pending batch:
        // that is deliberate, because the batch that needs flushing may belong
        // to bots this particular call is not about. As long as some bot ticks
        // regularly -- which is guaranteed whenever any bot exists -- a batch
        // that never reaches MaxBatch still goes out promptly instead of
        // waiting for a snapshot count it may never see (a realm with three
        // bots is not going to accumulate 2048 of anything).
        void MaybeFlushPendingBatch()
        {
            if (g_shuttingDown.load())
                return;   // BeginShutdown means stop spawning workers, full stop

            Settings const& cfg = GetSettings();
            if (!cfg.enabled)
                return;

            uint32 const now = WorldTimer::getMSTime();

            std::shared_ptr<PendingBatch> toDispatch;
            {
                std::lock_guard<std::mutex> lock(g_statesMutex);
                if (!g_pendingBatch)
                    return;
                if (!Elapsed(now, g_pendingBatch->flushDeadlineMs))
                    return;
                toDispatch = g_pendingBatch;
                g_pendingBatch.reset();
            }

            DispatchBatch(toDispatch, cfg);
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

        HandshakeExchange out;
        AttemptHandshake(cfg.endpoint, cfg.timeoutMs, out);

        // Boot already runs on the world thread, so it may log directly. The
        // retry path routes an identical outcome through the same reporter, so
        // the two cannot drift into saying different things about one event.
        ReportHandshake(out, cfg.endpoint, false);
        return out.ok;
    }

    void Forget(ObjectGuid guid)
    {
        std::lock_guard<std::mutex> lock(g_statesMutex);
        uint64 const raw = guid.GetRawValue();
        g_states.erase(raw);

        // A bot that logs out while its snapshot is still sitting in
        // g_pendingBatch (not dispatched yet) is not a crash risk either way --
        // DispatchBatch's Find() would simply find nothing for this guid and
        // move on, the same way a dispatched batch's response is safely
        // ignored once g_states no longer has an entry to write it into. This
        // is just tidiness: don't ask the brain to plan for a bot that is
        // already gone by the time the batch goes out.
        if (g_pendingBatch)
        {
            for (size_t i = 0; i < g_pendingBatch->guids.size(); ++i)
            {
                if (g_pendingBatch->guids[i] != raw)
                    continue;
                g_pendingBatch->guids.erase(g_pendingBatch->guids.begin() + i);
                g_pendingBatch->snapshots.erase(g_pendingBatch->snapshots.begin() + i);
                break;
            }
        }
    }

    void RecordOutcome(Player* bot, std::string const& intentId, std::string const& kind,
        std::string const& result, std::string const& reason, std::string const& poiId)
    {
        if (!bot || intentId.empty())
            return;

        std::lock_guard<std::mutex> lock(g_statesMutex);
        BotPlanState* state = Find(bot->GetObjectGuid().GetRawValue());
        if (!state)
            return;

        StoreOutcome(*state, intentId, kind, result, reason, poiId);
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

        // Every path out of here that is not "accepted" records WHY, so the next
        // snapshot carries it as last_outcome. Before this, RecordOutcome had a
        // single call site and it passed "accepted": the planner was told about
        // successes only and learned nothing from failures, so a bot whose
        // travel was refused got sent to the same place on the next tick, and
        // the next, indefinitely.
        //
        // The rejections below are the server's own validation, not the bot's
        // experience of the world. They say "this intent was unusable", which is
        // feedback about the PLAN - exactly what a planner can act on.
        if (!IsPoiDirectedKind(candidate.kind))
        {
            StoreOutcome(*state, candidate.intentId, candidate.kind, "rejected", "unsupported_kind", candidate.travelPoiId);
            return false;
        }
        if (!candidate.hasTravel || candidate.travelPoiId.empty())
        {
            // A POI-directed kind that names no POI is a malformed intent rather
            // than an unusable one, and the distinction is worth keeping: this
            // one means the two sides disagree about the contract.
            StoreOutcome(*state, candidate.intentId, candidate.kind, "rejected", "unknown_poi", candidate.travelPoiId);
            return false;
        }

        int64_t const now = NowUnixMs();
        if (candidate.expiresAtMs && candidate.expiresAtMs < now)
        {
            // "expired" is its own result, not a rejection: nothing was wrong
            // with the plan, it simply arrived too late to be worth applying.
            // A planner should read this as "be faster", not "choose elsewhere".
            StoreOutcome(*state, candidate.intentId, candidate.kind, "expired", "", candidate.travelPoiId);
            return false;
        }

        // The POI ids are snapshot-scoped by contract. An id from a table this
        // old is a stale destination, which is precisely what that scoping rule
        // exists to prevent.
        if (Elapsed(WorldTimer::getMSTime(), state->poiTableAtMs + cfg.poiTableTtlMs))
        {
            StoreOutcome(*state, candidate.intentId, candidate.kind, "rejected", "stale_poi", candidate.travelPoiId);
            return false;
        }

        for (ResolvedPoi const& row : state->poiTable)
        {
            if (row.id != candidate.travelPoiId)
                continue;
            if (!row.destination || !row.position)
            {
                // The id resolved, but the server could not turn it into a place
                // to walk to. From the planner's side that is the same actionable
                // fact as an unreachable destination: do not pick this one again.
                StoreOutcome(*state, candidate.intentId, candidate.kind, "rejected", "unreachable", candidate.travelPoiId);
                return false;
            }
            intent = candidate;
            poi = row;
            return true;
        }

        // Fell off the end of the table: the intent named a POI this snapshot
        // never offered.
        StoreOutcome(*state, candidate.intentId, candidate.kind, "rejected", "unknown_poi", candidate.travelPoiId);
        return false;
    }

    void Tick(Player* bot, PlayerbotAI* botAI)
    {
        // Before the admission gate, deliberately: this is the call that can
        // re-open it. The handshake used to run only at WORLDHOOK_ON_STARTUP, so
        // a bot-brain that started after the worldserver -- or restarted at any
        // point -- left the module inert for the whole process lifetime, with no
        // further log line to say so.
        MaybeRetryHandshake();

        // Also before the gate, and for the same shape of reason: the pending
        // batch this call flushes may not be this bot's own. Whichever bot's
        // Tick() happens to run while the deadline is past is the one that
        // sends it -- the batch does not care which map thread does the work.
        MaybeFlushPendingBatch();

        if (!ShouldPlanFor(bot, botAI))
            return;

        Settings const& cfg = GetSettings();
        uint32 const now = WorldTimer::getMSTime();
        uint64 const raw = bot->GetObjectGuid().GetRawValue();

        // Phase A/D bookkeeping happens under the lock; the two expensive
        // steps (building the snapshot, spawning a worker) happen after it.
        std::shared_ptr<DestinationExchange> readyDestinations;
        std::shared_ptr<BatchExchange> readyPlan;
        bool startRequest = false;
        bool hasOutcome = false;
        IntentOutcome outcome;
        std::string uuid;

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

                    // ADR-0039: this is "the pipeline is about to build a
                    // snapshot" -- absorb a finished mint/lookup first, then
                    // kick a new one off if this bot has never been minted
                    // and no attempt is already in flight. Fire-and-forget:
                    // THIS snapshot goes out with whatever is cached right
                    // now (possibly still empty -- "not yet minted", not "no
                    // bot"). It never waits on the database.
                    if (state.identity && state.identity->done.load(std::memory_order_acquire))
                    {
                        state.uuid = state.identity->uuid;
                        state.identity.reset();
                    }
                    if (state.uuid.empty() && !state.identity && Elapsed(now, state.nextIdentityAttemptMs))
                    {
                        state.identity = std::make_shared<IdentityExchange>();
                        SpawnIdentityWorker(state.identity, realmID, bot->GetGUIDLow());
                        // Reused as the retry backoff: cheap, already tuned
                        // for "the peer/DB is having trouble, do not hammer
                        // it every tick", and there is no reason this needs
                        // its own config knob yet.
                        state.nextIdentityAttemptMs = now + cfg.backoffMs;
                    }
                    uuid = state.uuid;
                    break;

                case Phase::AwaitingPlan:
                    // Two sub-waits share this phase: the snapshot may still be
                    // sitting in g_pendingBatch (state.batch still null -- not
                    // dispatched yet), or it may be riding a dispatched batch
                    // that has not answered yet. Either way there is nothing
                    // for this bot to do until state.batch is both set and done.
                    if (!state.batch || !state.batch->done.load(std::memory_order_acquire))
                        return;
                    readyPlan = state.batch;
                    state.batch.reset();
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
            // Cached above, off the world thread's critical path (ADR-0039).
            // Empty is a valid value here, meaning "not yet minted" -- the
            // Go side plans for this bot without memory rather than
            // rejecting the snapshot.
            snapshot.bot.uuid = uuid;
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

            // ---- Join the shared batch instead of sending alone. -----------
            // This is BotBrainPipeline's half of "batching is not an
            // optimisation, it is the design" (contract/wire.go:16-20): at
            // 1000 bots, one round trip per bot per interval spends more time
            // in HTTP than in planning. Joining costs nothing this bot can
            // observe -- it still waits in AwaitingPlan exactly as before,
            // just possibly a little longer, bounded by BotBrain.BatchFlushMs.
            std::shared_ptr<PendingBatch> toDispatch;
            {
                std::lock_guard<std::mutex> lock(g_statesMutex);
                BotPlanState& state = g_states[raw];
                state.poiTable = table;
                state.poiTableAtMs = now;
                state.hasOutcome = false;
                state.phase = Phase::AwaitingPlan;
                state.batch.reset();   // not dispatched yet; MaybeFlushPendingBatch or the size check below will set it

                if (!g_pendingBatch)
                {
                    g_pendingBatch = std::make_shared<PendingBatch>();
                    g_pendingBatch->flushDeadlineMs = now + cfg.batchFlushMs;
                }
                g_pendingBatch->snapshots.push_back(snapshot);
                g_pendingBatch->guids.push_back(raw);

                // max_batch (2048 at the time of writing) is negotiated at
                // handshake, not hardcoded, so a future contract can raise or
                // lower it without a worldserver rebuild.
                uint32 const maxBatch = g_maxBatch.load(std::memory_order_relaxed);
                if (uint32(g_pendingBatch->snapshots.size()) >= (maxBatch ? maxBatch : 1))
                {
                    toDispatch = g_pendingBatch;
                    g_pendingBatch.reset();
                }
            }

            if (toDispatch)
                DispatchBatch(toDispatch, cfg);
            return;
        }

        // ---- Phase D: take the answer. -------------------------------------
        // readyPlan is shared with every other bot that rode the same batch.
        // Everything read from it here (result, decoded, decodeError,
        // response) was written by the worker BEFORE it set `done`, so this is
        // a plain read of already-settled data -- no race with another bot's
        // map thread reading the same exchange concurrently.
        if (readyPlan)
        {
            std::lock_guard<std::mutex> lock(g_statesMutex);
            BotPlanState& state = g_states[raw];
            state.phase = Phase::Idle;

            if (!readyPlan->result.ok || !readyPlan->decoded)
            {
                std::string const error = readyPlan->result.ok ? readyPlan->decodeError : readyPlan->result.error;

                // Silent by design at BASIC level: a brain that is down must
                // not fill the log once per bot per interval.
                sLog.outDetail("mod-bot-brain: plan for %s failed (%s); stock chooser continues",
                    bot->GetName() ? bot->GetName() : "?", error.c_str());
                state.nextRequestMs = now + cfg.backoffMs;
                return;
            }

            state.nextRequestMs = now + cfg.intervalMs;

            // At most one intent per snapshot (contract/wire.go:81), and the
            // Go planner keys its results in a map[BotID]Intent -- so this
            // `break` on first match is correct as-is, batched or not. It is
            // NOT "only look at bot 0's intent": the filter above it discards
            // every intent not addressed to guidLow/realmID first, so the
            // first match found IS this bot's one intent, never another bot's.
            uint64 const guidLow = bot->GetGUIDLow();
            for (Intent const& intent : readyPlan->response.intents)
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
