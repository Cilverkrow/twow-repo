#include "BotBrainWire.h"

#include "rapidjson/document.h"
#include "rapidjson/stringbuffer.h"
#include "rapidjson/writer.h"

#include <cstring>

namespace botbrain
{
    // Built from kContractMajor/kContractMinor rather than written out again.
    // See the header: the hand-written copy said "1.0" while the numbers said
    // 1.3, and nothing could notice because the two were never compared.
    char const* const kContractVersion = BOT_BRAIN_CONTRACT_VERSION;

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

    bool HasArrivalAction(std::string const& kind)
    {
        return kind == kIntentVendorSell || kind == kIntentRepair ||
               kind == kIntentPickQuest || kind == kIntentTurnInQuest;
    }

    bool IsAppliedKind(std::string const& kind)
    {
        // Applied where the bot stands, needing no destination at all. The list
        // is the honest statement of what this build can do, not of what the
        // contract allows -- see the header.
        // abandon_quest is deliberately absent, and it is the clearest example
        // of why this predicate is about capability rather than vocabulary.
        //
        // DropQuestAction -- the only stock action that drops a NAMED quest --
        // opens with `if (!GetMaster()) return false;`, and the bots this module
        // plans for have no master by construction; that is why they take the
        // random-bot strategy branch at all. CleanQuestLogAction does run for
        // them, but it drops by POLICY (failed, grey, no progress) and ignores
        // which quest was asked for, so using it here would report success for
        // abandoning quest X while having abandoned Y and Z.
        //
        // So the honest answer is that this build cannot carry the kind out, and
        // the planner is told so with "unsupported_kind" rather than being lied
        // to with a completion.
        return kind == kIntentRest;
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
            // Omitted rather than sent empty: absent means "not minted yet",
            // and an empty string would be a third state the service has to
            // guess about.
            WriteStrIfSet(w, "uuid", id.uuid);
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
                WriteStrIfSet(w, "poi_id", s.lastOutcome.poiId);
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

        // The command, gated twice: by what this request allowed, and by what
        // this build knows how to execute. Both are dropped silently to
        // nothing, because "a command I cannot run" and "a command nobody asked
        // for" must never become "some other command".
        out.command = GetString(doc, "command");
        if (!allowCommands || !IsKnownDialogueCommand(out.command))
            out.command.clear();

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
                    e.bot.uuid = GetString(bot->value, "uuid");
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
                    intent.bot.uuid = GetString(bot->value, "uuid");
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

    // -----------------------------------------------------------------------
    // Dialogue
    // -----------------------------------------------------------------------

    char const* const kDialogueChannelSay = "say";
    char const* const kDialogueChannelParty = "party";
    char const* const kDialogueChannelGuild = "guild";
    char const* const kDialogueChannelWhisper = "whisper";
    char const* const kDialogueChannelGuildEvent = "guild_event";

    bool IsKnownDialogueChannel(std::string const& channel)
    {
        return channel == kDialogueChannelSay || channel == kDialogueChannelParty ||
               channel == kDialogueChannelGuild || channel == kDialogueChannelWhisper ||
               channel == kDialogueChannelGuildEvent;
    }

    char const* const kDialogueSpeakerPlayer = "player";
    char const* const kDialogueSpeakerBot = "bot";

    char const* const kDialogueLanguage = "de";

    char const* const kDialogueCommandFollow = "follow";
    char const* const kDialogueCommandStay = "stay";
    char const* const kDialogueCommandFlee = "flee";
    char const* const kDialogueCommandAttack = "attack";
    char const* const kDialogueCommandEquipUpgrades = "equip_upgrades";

    bool IsKnownDialogueCommand(std::string const& command)
    {
        return command == kDialogueCommandFollow || command == kDialogueCommandStay ||
               command == kDialogueCommandFlee || command == kDialogueCommandAttack ||
               command == kDialogueCommandEquipUpgrades;
    }

    char const* const kSilenceNothingToSay = "nothing_to_say";
    char const* const kSilenceDisabled = "dialogue_disabled";
    char const* const kSilenceUnavailable = "inference_unavailable";
    char const* const kSilenceBudget = "budget_exhausted";
    char const* const kSilenceBusy = "busy";
    char const* const kSilenceFiltered = "filtered";
    char const* const kSilenceDeadline = "deadline_exceeded";

    namespace
    {
        // The service's validateChatText, byte for byte in intent.
        //
        // The control-character rule is the one that is easy to leave out and
        // the one that matters most: a message carrying a newline can forge a
        // turn boundary in a chat-shaped prompt, and a REPLY carrying one
        // becomes two chat lines in a channel that agreed to one.
        bool ChatTextIsSane(std::string const& s, std::size_t max)
        {
            if (s.empty() || s.size() > max)
                return false;

            bool allSpace = true;
            for (std::size_t i = 0; i < s.size(); ++i)
            {
                unsigned char const c = static_cast<unsigned char>(s[i]);
                if (c < 0x20 || c == 0x7f)
                    return false;
                // The C1 range, as the service refuses it. In UTF-8 those code
                // points are two bytes (0xc2 0x80..0x9f), never a bare byte, so
                // this is checked on the decoded pair rather than on 0x80..0x9f
                // -- which are ordinary continuation bytes, and refusing those
                // would refuse every non-ASCII message on this realm.
                if (c == 0xc2 && i + 1 < s.size())
                {
                    unsigned char const next = static_cast<unsigned char>(s[i + 1]);
                    if (next >= 0x80 && next <= 0x9f)
                        return false;
                }
                if (c != ' ' && c != 0x09)
                    allSpace = false;
            }
            return !allSpace;
        }

        // Lowercase identifier, the shape a catalog key has. A "trait key" that
        // is really a sentence is an attempt, not a typo: the catalog would drop
        // it silently three layers in, and this refuses it at the door where it
        // shows up in a log.
        bool TraitKeyIsSane(std::string const& k)
        {
            if (k.empty() || k.size() > kMaxDialogueTraitKeyBytes)
                return false;
            for (std::size_t i = 0; i < k.size(); ++i)
            {
                char const c = k[i];
                if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')
                    continue;
                return false;
            }
            return true;
        }

        // The service's validateSpeakerName: letters only, 2..12 of them.
        //
        // Counted in RUNES, so a German or French name is twelve characters to
        // the player who typed it and not eight. "Letter" is approximated as
        // "an ASCII letter, or a well-formed multi-byte sequence that is not a
        // C1 control" -- unicode.IsLetter has no equivalent here without
        // dragging a table into a header that deliberately depends on nothing.
        //
        // The approximation errs on the permissive side for non-ASCII and on
        // the strict side for ASCII, which is the right way round: the property
        // this check exists for is that a name cannot close a quote, open a
        // brace, start a new line or carry a digit or a space, and every one of
        // those characters is ASCII. The service runs the real check and refuses
        // a name this one waved through, which costs a 400 the log will name.
        bool SpeakerNameIsSane(std::string const& name)
        {
            if (name.empty())
                return true;   // absent is normal -- guild_event has no speaker

            std::size_t runes = 0;
            for (std::size_t i = 0; i < name.size(); ++i)
            {
                unsigned char const c = static_cast<unsigned char>(name[i]);
                if (c < 0x80)
                {
                    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')))
                        return false;
                    ++runes;
                    continue;
                }
                // A multi-byte sequence. Length from the lead byte; the
                // continuation bytes are skipped, and a malformed sequence is
                // refused rather than guessed at.
                std::size_t len = 0;
                if ((c & 0xe0) == 0xc0) len = 2;
                else if ((c & 0xf0) == 0xe0) len = 3;
                else if ((c & 0xf8) == 0xf0) len = 4;
                else return false;   // lone continuation byte, or a 5+ byte lead

                if (i + len > name.size())
                    return false;
                for (std::size_t j = 1; j < len; ++j)
                    if ((static_cast<unsigned char>(name[i + j]) & 0xc0) != 0x80)
                        return false;
                // C1 controls dressed as two-byte UTF-8.
                if (len == 2 && c == 0xc2)
                    return false;
                i += len - 1;
                ++runes;
            }
            return runes >= 2 && runes <= kMaxDialogueSpeakerNameRunes;
        }
    }

    bool ValidateDialogueRequest(DialogueRequest const& req, std::string& error)
    {
        if (req.bot.IsZero())
        {
            error = "dialogue request has a zero realm or guid";
            return false;
        }
        if (!IsKnownDialogueChannel(req.channel))
        {
            error = "dialogue request has unknown channel " + req.channel;
            return false;
        }
        if (req.speaker != kDialogueSpeakerPlayer && req.speaker != kDialogueSpeakerBot)
        {
            error = "dialogue request has unknown speaker " + req.speaker;
            return false;
        }
        if (!SpeakerNameIsSane(req.speakerName))
        {
            error = "dialogue request has a speaker name that cannot be a character name";
            return false;
        }
        if (!req.language.empty() && req.language != kDialogueLanguage)
        {
            error = "dialogue request asks for language " + req.language;
            return false;
        }
        if (!ChatTextIsSane(req.message, kMaxDialogueMessageBytes))
        {
            error = "dialogue request message is empty, oversized, or carries a control character";
            return false;
        }
        if (req.traitKeys.size() > kMaxDialogueTraitKeys)
        {
            error = "dialogue request carries more than the permitted trait keys";
            return false;
        }
        for (std::string const& k : req.traitKeys)
        {
            if (!TraitKeyIsSane(k))
            {
                error = "dialogue request carries a trait key that is not a lowercase identifier";
                return false;
            }
        }
        return true;
    }

    std::string EncodeDialogueRequest(DialogueRequest const& req)
    {
        rapidjson::StringBuffer buffer;
        JsonWriter w(buffer);

        w.StartObject();
        WriteStr(w, "contract_version", req.contractVersion);
        WriteStrIfSet(w, "request_id", req.requestId);
        w.Key("bot");
        WriteBotId(w, req.bot);
        WriteStr(w, "channel", req.channel);
        WriteStr(w, "speaker", req.speaker);
        // Omitted rather than sent empty: absent is a legal state (guild_event
        // has no single speaker) and the service treats the two alike.
        WriteStrIfSet(w, "speaker_name", req.speakerName);
        WriteStr(w, "message", req.message);
        WriteStringArrayIfSet(w, "trait_keys", req.traitKeys);
        WriteStrIfSet(w, "language", req.language);
        WriteIntIfSet(w, "sent_at_ms", req.sentAtMs);
        WriteIntIfSet(w, "deadline_ms", req.deadlineMs);
        // Omitted when false, which is what the Go side's omitempty expects and
        // what makes "this worldserver does not do commands" the shape of a
        // request rather than a flag in it.
        if (req.allowCommands)
        {
            w.Key("allow_commands");
            w.Bool(true);
        }
        w.EndObject();

        return std::string(buffer.GetString(), buffer.GetSize());
    }

    bool DecodeDialogueResponse(std::string const& body, bool allowCommands, DialogueResponse& out, std::string& error)
    {
        rapidjson::Document doc;
        if (!Parse(body, doc, error))
            return false;

        out.contractVersion = GetString(doc, "contract_version");
        out.requestId = GetString(doc, "request_id");

        rapidjson::Value::ConstMemberIterator bot = doc.FindMember("bot");
        if (bot != doc.MemberEnd())
        {
            out.bot.realm = static_cast<uint32_t>(GetUint64(bot->value, "realm", 0));
            out.bot.guid = GetUint64(bot->value, "guid", 0);
            out.bot.uuid = GetString(bot->value, "uuid");
        }

        rapidjson::Value::ConstMemberIterator spoke = doc.FindMember("spoke");
        out.spoke = spoke != doc.MemberEnd() && spoke->value.IsBool() && spoke->value.GetBool();
        out.reply = GetString(doc, "reply");
        out.reason = GetString(doc, "reason");

        // The command, gated twice: by what this request allowed, and by what
        // this build knows how to execute. Both are dropped silently to
        // nothing, because "a command I cannot run" and "a command nobody asked
        // for" must never become "some other command".
        out.command = GetString(doc, "command");
        if (!allowCommands || !IsKnownDialogueCommand(out.command))
            out.command.clear();

        rapidjson::Value::ConstMemberIterator stats = doc.FindMember("stats");
        if (stats != doc.MemberEnd())
        {
            out.replyMs = GetInt64(stats->value, "reply_ms", 0);
            out.traitsApplied = static_cast<int32_t>(GetInt64(stats->value, "traits_applied", 0));
            out.unknownFields = static_cast<int32_t>(GetInt64(stats->value, "unknown_fields", 0));
        }

        // The last gate before text this process did not write reaches a game
        // channel. The service runs the same check; this one is what makes a
        // disagreement between the two cost a quiet bot rather than an unvetted
        // line, and it is why the caller never has to trust `spoke` alone.
        if (out.spoke && !ChatTextIsSane(out.reply, kMaxDialogueReplyBytes))
        {
            out.spoke = false;
            out.reply.clear();
            out.reason = kSilenceFiltered;
            // out.command is deliberately NOT cleared here. A sentence this
            // side will not vouch for says nothing about whether the player
            // asked the bot to come, and the command has already passed its own
            // two gates above.
            return true;
        }
        if (!out.spoke)
        {
            out.reply.clear();
            if (out.reason.empty())
                out.reason = kSilenceUnavailable;
        }
        else
        {
            out.reason.clear();
        }
        return true;
    }
}
