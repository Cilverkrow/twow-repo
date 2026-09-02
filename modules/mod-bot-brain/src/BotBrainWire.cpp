#include "BotBrainWire.h"

#include "rapidjson/document.h"
#include "rapidjson/stringbuffer.h"
#include "rapidjson/writer.h"

#include <cstring>

namespace botbrain
{
    char const* const kContractVersion = "1.0";

    char const* const kIntentIdle = "idle";
    char const* const kIntentTravelTo = "travel_to";
    char const* const kIntentGrindArea = "grind_area";
    char const* const kIntentVendorSell = "vendor_sell";
    char const* const kIntentRepair = "repair";
    char const* const kIntentRest = "rest";
    char const* const kIntentPickQuest = "pick_quest";
    char const* const kIntentTurnInQuest = "turn_in_quest";
    char const* const kIntentAbandonQuest = "abandon_quest";

    bool IsKnownIntentKind(std::string const& kind)
    {
        return kind == kIntentIdle || kind == kIntentTravelTo || kind == kIntentGrindArea ||
               kind == kIntentVendorSell || kind == kIntentRepair || kind == kIntentRest ||
               kind == kIntentPickQuest || kind == kIntentTurnInQuest || kind == kIntentAbandonQuest;
    }

    bool IsPoiDirectedKind(std::string const& kind)
    {
        return kind == kIntentTravelTo || kind == kIntentGrindArea || kind == kIntentVendorSell ||
               kind == kIntentRepair || kind == kIntentPickQuest || kind == kIntentTurnInQuest;
    }

    bool ValidateSnapshot(Snapshot const& s, std::string& error)
    {
        if (s.bot.guid == 0)
        {
            error = "snapshot has zero bot.guid";
            return false;
        }
        if (s.bot.realm == 0)
        {
            error = "snapshot has zero bot.realm";
            return false;
        }
        if (s.chr.level == 0 || s.chr.level > 60)
        {
            error = "snapshot has level outside 1..60";
            return false;
        }
        if (s.vitals.healthPct < 0.0 || s.vitals.healthPct > 100.0)
        {
            error = "snapshot has health_pct outside 0..100";
            return false;
        }
        return true;
    }

    namespace
    {
        typedef rapidjson::Writer<rapidjson::StringBuffer> JsonWriter;

        void WriteStr(JsonWriter& w, char const* key, std::string const& value)
        {
            w.Key(key);
            w.String(value.data(), static_cast<rapidjson::SizeType>(value.size()));
        }

        void WriteStrIfSet(JsonWriter& w, char const* key, std::string const& value)
        {
            if (value.empty())
                return;
            WriteStr(w, key, value);
        }

        void WriteUintIfSet(JsonWriter& w, char const* key, uint64_t value)
        {
            if (!value)
                return;
            w.Key(key);
            w.Uint64(value);
        }

        void WriteIntIfSet(JsonWriter& w, char const* key, int64_t value)
        {
            if (!value)
                return;
            w.Key(key);
            w.Int64(value);
        }

        void WriteStringArrayIfSet(JsonWriter& w, char const* key, std::vector<std::string> const& values)
        {
            if (values.empty())
                return;
            w.Key(key);
            w.StartArray();
            for (std::string const& v : values)
                w.String(v.data(), static_cast<rapidjson::SizeType>(v.size()));
            w.EndArray();
        }

        void WriteBotId(JsonWriter& w, BotId const& id)
        {
            w.StartObject();
            w.Key("realm");
            w.Uint(id.realm);
            w.Key("guid");
            w.Uint64(id.guid);
            w.EndObject();
        }

        void WritePosition(JsonWriter& w, Position const& p)
        {
            w.StartObject();
            w.Key("map_id");
            w.Uint(p.mapId);
            w.Key("x");
            w.Double(p.x);
            w.Key("y");
            w.Double(p.y);
            w.Key("z");
            w.Double(p.z);
            w.Key("orientation");
            w.Double(p.orientation);
            WriteUintIfSet(w, "zone_id", p.zoneId);
            WriteUintIfSet(w, "area_id", p.areaId);
            WriteUintIfSet(w, "instance_id", p.instanceId);
            w.EndObject();
        }

        void WriteVitals(JsonWriter& w, Vitals const& v)
        {
            w.StartObject();
            w.Key("health_pct");
            w.Double(v.healthPct);
            if (v.hasPowerPct)
            {
                w.Key("power_pct");
                w.Double(v.powerPct);
            }
            w.Key("is_dead");
            w.Bool(v.isDead);
            w.Key("in_combat");
            w.Bool(v.inCombat);
            w.Key("is_resting");
            w.Bool(v.isResting);
            w.Key("is_mounted");
            w.Bool(v.isMounted);
            // Nested here, and omitted rather than zeroed: absent means "not
            // computed", which a planner must not read as "fine".
            if (v.hasDurabilityPct)
            {
                w.Key("durability_pct");
                w.Double(v.durabilityPct);
            }
            w.EndObject();
        }

        void WriteCharacter(JsonWriter& w, Character const& c)
        {
            w.StartObject();
            WriteStr(w, "name", c.name);
            w.Key("level");
            w.Uint(c.level);
            w.Key("class");
            w.Uint(c.cls);
            w.Key("race");
            w.Uint(c.race);
            WriteStr(w, "faction", c.faction);
            w.Key("money");
            w.Uint64(c.money);
            w.Key("free_bag_slots");
            w.Uint(c.freeBagSlots);
            WriteStringArrayIfSet(w, "trait_keys", c.traitKeys);
            w.EndObject();
        }

        void WriteSurroundings(JsonWriter& w, Surroundings const& s)
        {
            w.StartObject();
            w.Key("hostile_count");
            w.Uint(s.hostileCount);
            w.Key("friendly_player_count");
            w.Uint(s.friendlyPlayerCount);
            w.Key("friendly_bot_count");
            w.Uint(s.friendlyBotCount);
            if (s.hasRadiusYards)
            {
                w.Key("radius_yards");
                w.Double(s.radiusYards);
            }
            if (s.hasNearestHostileYards)
            {
                w.Key("nearest_hostile_yards");
                w.Double(s.nearestHostileYards);
            }
            w.Key("group_size");
            w.Uint(s.groupSize);
            w.Key("is_group_leader");
            w.Bool(s.isGroupLeader);
            w.EndObject();
        }

        void WriteSnapshot(JsonWriter& w, Snapshot const& s)
        {
            w.StartObject();
            w.Key("bot");
            WriteBotId(w, s.bot);
            w.Key("char");
            WriteCharacter(w, s.chr);
            w.Key("pos");
            WritePosition(w, s.pos);
            w.Key("vitals");
            WriteVitals(w, s.vitals);
            w.Key("surroundings");
            WriteSurroundings(w, s.around);

            if (!s.quests.empty())
            {
                w.Key("quests");
                w.StartArray();
                for (QuestEntry const& q : s.quests)
                {
                    w.StartObject();
                    w.Key("quest_id");
                    w.Uint(q.questId);
                    WriteStr(w, "status", q.status);
                    w.Key("objectives_done");
                    w.Uint(q.objectivesDone);
                    w.Key("objectives_total");
                    w.Uint(q.objectivesTotal);
                    WriteUintIfSet(w, "required_level", q.requiredLevel);
                    WriteUintIfSet(w, "quest_level", q.questLevel);
                    w.EndObject();
                }
                w.EndArray();
            }

            // "pois". Not "poi". This name has been got wrong before.
            if (!s.pois.empty())
            {
                w.Key("pois");
                w.StartArray();
                for (PointOfInterest const& p : s.pois)
                {
                    w.StartObject();
                    WriteStr(w, "id", p.id);
                    WriteStr(w, "kind", p.kind);
                    w.Key("pos");
                    WritePosition(w, p.pos);
                    if (p.hasDistanceYards)
                    {
                        w.Key("distance_yards");
                        w.Double(p.distanceYards);
                    }
                    WriteUintIfSet(w, "related_quest_id", p.relatedQuestId);
                    WriteStringArrayIfSet(w, "tags", p.tags);
                    w.EndObject();
                }
                w.EndArray();
            }

            if (s.hasLastOutcome)
            {
                w.Key("last_outcome");
                w.StartObject();
                WriteStr(w, "intent_id", s.lastOutcome.intentId);
                WriteStr(w, "kind", s.lastOutcome.kind);
                WriteStr(w, "result", s.lastOutcome.result);
                WriteStrIfSet(w, "reason", s.lastOutcome.reason);
                WriteIntIfSet(w, "issued_at_ms", s.lastOutcome.issuedAtMs);
                w.EndObject();
            }

            w.Key("observed_at_ms");
            w.Int64(s.observedAtMs);
            WriteStringArrayIfSet(w, "hints", s.hints);
            w.EndObject();
        }
    }

    std::string EncodePlanRequest(PlanRequest const& req)
    {
        rapidjson::StringBuffer buffer;
        JsonWriter w(buffer);

        w.StartObject();
        WriteStr(w, "contract_version", req.contractVersion);
        WriteStrIfSet(w, "request_id", req.requestId);
        WriteIntIfSet(w, "sent_at_ms", req.sentAtMs);
        WriteIntIfSet(w, "deadline_ms", req.deadlineMs);
        w.Key("snapshots");
        w.StartArray();
        for (Snapshot const& s : req.snapshots)
            WriteSnapshot(w, s);
        w.EndArray();
        w.EndObject();

        return std::string(buffer.GetString(), buffer.GetSize());
    }

    namespace
    {
        // rapidjson accessors that never throw and never assert on a wrong type.
        // A brain that returns a string where a number belongs is a bug on the
        // far side; it must cost this bot its intent, not the worldserver.
        std::string GetString(rapidjson::Value const& v, char const* key)
        {
            if (!v.IsObject())
                return std::string();
            rapidjson::Value::ConstMemberIterator it = v.FindMember(key);
            if (it == v.MemberEnd() || !it->value.IsString())
                return std::string();
            return std::string(it->value.GetString(), it->value.GetStringLength());
        }

        double GetDouble(rapidjson::Value const& v, char const* key, double fallback)
        {
            if (!v.IsObject())
                return fallback;
            rapidjson::Value::ConstMemberIterator it = v.FindMember(key);
            if (it == v.MemberEnd() || !it->value.IsNumber())
                return fallback;
            return it->value.GetDouble();
        }

        int64_t GetInt64(rapidjson::Value const& v, char const* key, int64_t fallback)
        {
            if (!v.IsObject())
                return fallback;
            rapidjson::Value::ConstMemberIterator it = v.FindMember(key);
            if (it == v.MemberEnd() || !it->value.IsInt64())
                return fallback;
            return it->value.GetInt64();
        }

        uint64_t GetUint64(rapidjson::Value const& v, char const* key, uint64_t fallback)
        {
            if (!v.IsObject())
                return fallback;
            rapidjson::Value::ConstMemberIterator it = v.FindMember(key);
            if (it == v.MemberEnd() || !it->value.IsUint64())
                return fallback;
            return it->value.GetUint64();
        }

        bool Parse(std::string const& body, rapidjson::Document& doc, std::string& error)
        {
            if (body.empty())
            {
                error = "empty response body";
                return false;
            }
            doc.Parse<rapidjson::kParseValidateEncodingFlag>(body.data(), body.size());
            if (doc.HasParseError())
            {
                error = "response is not valid JSON/UTF-8";
                return false;
            }
            if (!doc.IsObject())
            {
                error = "response is not a JSON object";
                return false;
            }
            return true;
        }
    }

    bool DecodePlanResponse(std::string const& body, PlanResponse& out, std::string& error)
    {
        rapidjson::Document doc;
        if (!Parse(body, doc, error))
            return false;

        out = PlanResponse();
        out.contractVersion = GetString(doc, "contract_version");
        out.requestId = GetString(doc, "request_id");

        rapidjson::Value::ConstMemberIterator stats = doc.FindMember("stats");
        if (stats != doc.MemberEnd() && stats->value.IsObject())
        {
            out.planMs = GetInt64(stats->value, "plan_ms", 0);
            out.degradedReason = GetString(stats->value, "degraded_reason");
        }

        rapidjson::Value::ConstMemberIterator errs = doc.FindMember("errors");
        if (errs != doc.MemberEnd() && errs->value.IsArray())
        {
            for (rapidjson::Value::ConstValueIterator it = errs->value.Begin(); it != errs->value.End(); ++it)
            {
                if (!it->IsObject())
                    continue;
                PlanError e;
                rapidjson::Value::ConstMemberIterator bot = it->FindMember("bot");
                if (bot != it->MemberEnd() && bot->value.IsObject())
                {
                    e.bot.realm = static_cast<uint32_t>(GetUint64(bot->value, "realm", 0));
                    e.bot.guid = GetUint64(bot->value, "guid", 0);
                }
                e.code = GetString(*it, "code");
                e.message = GetString(*it, "message");
                out.errors.push_back(e);
            }
        }

        rapidjson::Value::ConstMemberIterator intents = doc.FindMember("intents");
        if (intents == doc.MemberEnd() || !intents->value.IsArray())
            return true;    // no intents is not an error: it means "nothing to suggest"

        for (rapidjson::Value::ConstValueIterator it = intents->value.Begin(); it != intents->value.End(); ++it)
        {
            if (!it->IsObject())
                continue;

            Intent intent;
            rapidjson::Value::ConstMemberIterator bot = it->FindMember("bot");
            if (bot != it->MemberEnd() && bot->value.IsObject())
            {
                intent.bot.realm = static_cast<uint32_t>(GetUint64(bot->value, "realm", 0));
                intent.bot.guid = GetUint64(bot->value, "guid", 0);
            }
            intent.intentId = GetString(*it, "intent_id");
            intent.kind = GetString(*it, "kind");

            // Drop, do not reject. A newer brain emitting kinds this build has
            // never heard of is a supported deployment state.
            if (!IsKnownIntentKind(intent.kind))
                continue;
            if (intent.bot.IsZero() || intent.intentId.empty())
                continue;

            rapidjson::Value::ConstMemberIterator travel = it->FindMember("travel");
            if (travel != it->MemberEnd() && travel->value.IsObject())
            {
                intent.hasTravel = true;
                intent.travelPoiId = GetString(travel->value, "poi_id");
                rapidjson::Value::ConstMemberIterator stop = travel->value.FindMember("stop_within_yards");
                if (stop != travel->value.MemberEnd() && stop->value.IsNumber())
                {
                    intent.hasStopWithinYards = true;
                    intent.stopWithinYards = stop->value.GetDouble();
                }
            }

            rapidjson::Value::ConstMemberIterator quest = it->FindMember("quest");
            if (quest != it->MemberEnd() && quest->value.IsObject())
            {
                intent.hasQuest = true;
                intent.questId = static_cast<uint32_t>(GetUint64(quest->value, "quest_id", 0));
            }

            intent.priority = static_cast<int32_t>(GetInt64(*it, "priority", 0));
            intent.confidence = GetDouble(*it, "confidence", 0.0);
            intent.expiresAtMs = GetInt64(*it, "expires_at_ms", 0);
            intent.source = GetString(*it, "source");
            intent.rationale = GetString(*it, "rationale");

            out.intents.push_back(intent);
        }

        return true;
    }

    bool DecodeContractInfo(std::string const& body, ContractInfo& out, std::string& error)
    {
        rapidjson::Document doc;
        if (!Parse(body, doc, error))
            return false;

        out = ContractInfo();
        out.version = GetString(doc, "version");
        if (out.version.empty())
        {
            error = "contract response has no version";
            return false;
        }

        rapidjson::Value::ConstMemberIterator majors = doc.FindMember("supported_majors");
        if (majors != doc.MemberEnd() && majors->value.IsArray())
            for (rapidjson::Value::ConstValueIterator it = majors->value.Begin(); it != majors->value.End(); ++it)
                if (it->IsInt())
                    out.supportedMajors.push_back(it->GetInt());

        rapidjson::Value::ConstMemberIterator kinds = doc.FindMember("known_intent_kinds");
        if (kinds != doc.MemberEnd() && kinds->value.IsArray())
            for (rapidjson::Value::ConstValueIterator it = kinds->value.Begin(); it != kinds->value.End(); ++it)
                if (it->IsString())
                    out.knownIntentKinds.push_back(std::string(it->GetString(), it->GetStringLength()));

        rapidjson::Value::ConstMemberIterator maxBatch = doc.FindMember("max_batch");
        if (maxBatch != doc.MemberEnd() && maxBatch->value.IsInt())
            out.maxBatch = maxBatch->value.GetInt();

        return true;
    }

    bool ContractMajorSupported(ContractInfo const& info, int wantMajor)
    {
        for (int m : info.supportedMajors)
            if (m == wantMajor)
                return true;
        return false;
    }
}
