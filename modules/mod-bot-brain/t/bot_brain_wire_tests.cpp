/*
 * mod-bot-brain -- unit tests for the wire contract.
 *
 * Hand-rolled assertions, one plain main(), no test framework: the same shape
 * as modules/mod-playerbots/t/persistent_active_roster_tests.cpp, and for the
 * same reason -- it keeps the suite compilable in the default configuration
 * with no dependency to fetch.
 *
 * What is worth testing here is exactly what has already gone wrong: field
 * NAMES, field NESTING, absent-vs-zero, and units. Those are the mistakes that
 * a compiler cannot catch and that a live server catches only as "the bot did
 * nothing, again".
 *
 * Run with `--dump-request` and the binary prints the sample plan request to
 * stdout instead of running the suite. That is not a convenience: it is how the
 * encoder is checked against the REAL service (`go run ./cmd/bot-brain`, then
 * POST the dump to /v1/plan), which is the only check that can catch a name
 * this file and the encoder agree on but the Go struct does not.
 */

#include "BotBrainWire.h"

#include <cstdio>
#include <cstring>
#include <string>

namespace
{
    int g_failures = 0;
    int g_checks = 0;

    void Check(bool condition, char const* what, int line)
    {
        ++g_checks;
        if (condition)
            return;
        ++g_failures;
        std::printf("FAIL line %d: %s\n", line, what);
    }

#define CHECK(cond) Check((cond), #cond, __LINE__)

    bool Contains(std::string const& haystack, char const* needle)
    {
        return haystack.find(needle) != std::string::npos;
    }

    // A snapshot with every field populated the way the world-thread builder
    // would populate it for a healthy level-12 bot standing next to a vendor.
    botbrain::Snapshot SampleSnapshot()
    {
        botbrain::Snapshot s;
        s.bot.realm = 1;
        s.bot.guid = 4242;

        s.chr.name = "Grimblade";
        s.chr.level = 12;
        s.chr.cls = 1;
        s.chr.race = 2;
        s.chr.faction = "horde";
        s.chr.money = 13370;
        s.chr.freeBagSlots = 3;

        s.pos.mapId = 1;
        s.pos.x = -618.5;
        s.pos.y = -4251.75;
        s.pos.z = 38.25;
        s.pos.orientation = 3.14159;
        s.pos.zoneId = 14;
        s.pos.areaId = 363;

        s.vitals.healthPct = 82.5;
        s.vitals.hasPowerPct = true;
        s.vitals.powerPct = 40.0;
        s.vitals.hasDurabilityPct = true;
        s.vitals.durabilityPct = 61.0;

        s.around.hostileCount = 2;
        s.around.groupSize = 1;

        botbrain::QuestEntry q;
        q.questId = 788;
        q.status = "incomplete";
        q.objectivesDone = 3;
        q.objectivesTotal = 10;
        q.questLevel = 12;
        s.quests.push_back(q);

        botbrain::PointOfInterest poi;
        poi.id = "d1p0";
        poi.kind = "vendor";
        poi.pos.mapId = 1;
        poi.pos.x = -600.0;
        poi.pos.y = -4200.0;
        poi.pos.z = 38.0;
        poi.hasDistanceYards = true;
        poi.distanceYards = 55.5;
        s.pois.push_back(poi);

        s.observedAtMs = 1756700000000LL;
        return s;
    }

    botbrain::PlanRequest SampleRequest()
    {
        botbrain::PlanRequest req;
        req.contractVersion = botbrain::kContractVersion;
        req.requestId = "sample-request";
        req.sentAtMs = 1756700000100LL;
        req.deadlineMs = 750;
        req.snapshots.push_back(SampleSnapshot());
        return req;
    }

    // ---------------------------------------------------------------------
    // The field names and nesting the Go contract actually uses.
    // ---------------------------------------------------------------------
    void TestEncodedFieldNames()
    {
        std::string const json = botbrain::EncodePlanRequest(SampleRequest());

        CHECK(Contains(json, "\"contract_version\":\"1.0\""));
        CHECK(Contains(json, "\"snapshots\":["));

        // The array is "pois". A "poi" key here would be silently ignored by
        // the service and every bot would get an intent-less response.
        CHECK(Contains(json, "\"pois\":["));
        CHECK(!Contains(json, "\"poi\":["));

        // durability_pct is nested under vitals, not under char.
        std::string::size_type const vitals = json.find("\"vitals\":{");
        std::string::size_type const durability = json.find("\"durability_pct\"");
        std::string::size_type const chr = json.find("\"char\":{");
        CHECK(vitals != std::string::npos);
        CHECK(durability != std::string::npos);
        CHECK(durability > vitals);
        CHECK(!(chr < durability && durability < vitals));

        CHECK(Contains(json, "\"bot\":{\"realm\":1,\"guid\":4242}"));
        CHECK(Contains(json, "\"free_bag_slots\":3"));
        CHECK(Contains(json, "\"observed_at_ms\":1756700000000"));
        CHECK(Contains(json, "\"map_id\":1"));
        CHECK(Contains(json, "\"orientation\":"));
    }

    // ---------------------------------------------------------------------
    // Percentages are 0..100. A 0..1 encoder would produce "health_pct":0.825
    // and the service would happily accept it, which is why this is a test and
    // not a comment.
    // ---------------------------------------------------------------------
    void TestPercentagesAreOutOfOneHundred()
    {
        std::string const json = botbrain::EncodePlanRequest(SampleRequest());
        CHECK(Contains(json, "\"health_pct\":82.5"));
        CHECK(Contains(json, "\"power_pct\":40"));
        CHECK(Contains(json, "\"durability_pct\":61"));
        CHECK(!Contains(json, "\"health_pct\":0.825"));
    }

    // ---------------------------------------------------------------------
    // Absent is not zero. The Go side models durability and power as pointers
    // precisely so a planner can tell "not computed" from "at zero".
    // ---------------------------------------------------------------------
    void TestOptionalsAreOmittedNotZeroed()
    {
        botbrain::PlanRequest req = SampleRequest();
        req.snapshots[0].vitals.hasDurabilityPct = false;
        req.snapshots[0].vitals.hasPowerPct = false;
        req.snapshots[0].pois[0].hasDistanceYards = false;

        std::string const json = botbrain::EncodePlanRequest(req);
        CHECK(!Contains(json, "durability_pct"));
        CHECK(!Contains(json, "power_pct"));
        CHECK(!Contains(json, "distance_yards"));

        // ...while the required ones are still there at their zero values.
        CHECK(Contains(json, "\"health_pct\":"));
        CHECK(Contains(json, "\"hostile_count\":"));
    }

    // ---------------------------------------------------------------------
    // ValidateSnapshot mirrors the service's own Validate(), so a snapshot the
    // far side would reject is dropped here, one process earlier.
    // ---------------------------------------------------------------------
    void TestValidateMirrorsTheService()
    {
        std::string error;
        botbrain::Snapshot good = SampleSnapshot();
        CHECK(botbrain::ValidateSnapshot(good, error));

        botbrain::Snapshot noGuid = SampleSnapshot();
        noGuid.bot.guid = 0;
        CHECK(!botbrain::ValidateSnapshot(noGuid, error));

        botbrain::Snapshot noRealm = SampleSnapshot();
        noRealm.bot.realm = 0;
        CHECK(!botbrain::ValidateSnapshot(noRealm, error));

        botbrain::Snapshot badLevel = SampleSnapshot();
        badLevel.chr.level = 0;
        CHECK(!botbrain::ValidateSnapshot(badLevel, error));
        badLevel.chr.level = 61;
        CHECK(!botbrain::ValidateSnapshot(badLevel, error));

        botbrain::Snapshot badHealth = SampleSnapshot();
        badHealth.vitals.healthPct = 101.0;
        CHECK(!botbrain::ValidateSnapshot(badHealth, error));
        badHealth.vitals.healthPct = -1.0;
        CHECK(!botbrain::ValidateSnapshot(badHealth, error));
    }

    // ---------------------------------------------------------------------
    // Decoding a plan response.
    // ---------------------------------------------------------------------
    void TestDecodePlanResponse()
    {
        std::string const body =
            "{\"contract_version\":\"1.0\",\"request_id\":\"r1\",\"intents\":["
            "{\"bot\":{\"realm\":1,\"guid\":4242},\"intent_id\":\"i1\",\"kind\":\"travel_to\","
            "\"travel\":{\"poi_id\":\"d1p0\"},\"confidence\":0.75,\"expires_at_ms\":1756700030000,"
            "\"source\":\"rule\",\"rationale\":\"bags full\"}],"
            "\"stats\":{\"snapshots_in\":1,\"intents_out\":1,\"plan_ms\":3}}";

        botbrain::PlanResponse response;
        std::string error;
        CHECK(botbrain::DecodePlanResponse(body, response, error));
        CHECK(response.contractVersion == "1.0");
        CHECK(response.requestId == "r1");
        CHECK(response.intents.size() == 1);
        if (response.intents.size() == 1)
        {
            botbrain::Intent const& i = response.intents[0];
            CHECK(i.bot.realm == 1);
            CHECK(i.bot.guid == 4242);
            CHECK(i.intentId == "i1");
            CHECK(i.kind == botbrain::kIntentTravelTo);
            CHECK(i.hasTravel);
            CHECK(i.travelPoiId == "d1p0");
            CHECK(!i.hasStopWithinYards);
            CHECK(i.confidence > 0.74 && i.confidence < 0.76);
            CHECK(i.expiresAtMs == 1756700030000LL);
            CHECK(i.source == "rule");
        }
        CHECK(response.planMs == 3);
    }

    // ---------------------------------------------------------------------
    // A newer brain emitting a kind this build has never heard of must cost
    // that one intent, not the batch.
    // ---------------------------------------------------------------------
    void TestUnknownKindsAreDroppedNotRejected()
    {
        std::string const body =
            "{\"contract_version\":\"1.9\",\"request_id\":\"r2\",\"intents\":["
            "{\"bot\":{\"realm\":1,\"guid\":1},\"intent_id\":\"a\",\"kind\":\"teleport_bot\"},"
            "{\"bot\":{\"realm\":1,\"guid\":2},\"intent_id\":\"b\",\"kind\":\"rest\"}]}";

        botbrain::PlanResponse response;
        std::string error;
        CHECK(botbrain::DecodePlanResponse(body, response, error));
        CHECK(response.intents.size() == 1);
        if (response.intents.size() == 1)
            CHECK(response.intents[0].kind == botbrain::kIntentRest);
    }

    // An intent that cannot be attributed to a bot is dropped: applying it to
    // the wrong bot is the one failure mode worse than doing nothing.
    void TestUnattributableIntentsAreDropped()
    {
        std::string const body =
            "{\"intents\":["
            "{\"bot\":{\"realm\":0,\"guid\":4242},\"intent_id\":\"a\",\"kind\":\"rest\"},"
            "{\"bot\":{\"realm\":1,\"guid\":0},\"intent_id\":\"b\",\"kind\":\"rest\"},"
            "{\"bot\":{\"realm\":1,\"guid\":7},\"intent_id\":\"\",\"kind\":\"rest\"}]}";

        botbrain::PlanResponse response;
        std::string error;
        CHECK(botbrain::DecodePlanResponse(body, response, error));
        CHECK(response.intents.empty());
    }

    void TestMalformedBodiesFailCleanly()
    {
        botbrain::PlanResponse response;
        std::string error;
        CHECK(!botbrain::DecodePlanResponse("", response, error));
        CHECK(!botbrain::DecodePlanResponse("not json", response, error));
        CHECK(!botbrain::DecodePlanResponse("[1,2,3]", response, error));

        // A well-formed response carrying nothing useful is NOT an error: "no
        // intent for this bot" is a normal answer and means "keep stock AI".
        CHECK(botbrain::DecodePlanResponse("{}", response, error));
        CHECK(response.intents.empty());
    }

    // ---------------------------------------------------------------------
    // The startup handshake.
    // ---------------------------------------------------------------------
    void TestContractHandshake()
    {
        std::string const body =
            "{\"version\":\"1.0\",\"supported_majors\":[1],"
            "\"known_intent_kinds\":[\"idle\",\"travel_to\"],\"max_batch\":2048}";

        botbrain::ContractInfo info;
        std::string error;
        CHECK(botbrain::DecodeContractInfo(body, info, error));
        CHECK(info.version == "1.0");
        CHECK(info.maxBatch == 2048);
        CHECK(botbrain::ContractMajorSupported(info, botbrain::kContractMajor));

        botbrain::ContractInfo skewed;
        CHECK(botbrain::DecodeContractInfo("{\"version\":\"2.0\",\"supported_majors\":[2]}", skewed, error));
        CHECK(!botbrain::ContractMajorSupported(skewed, botbrain::kContractMajor));

        botbrain::ContractInfo broken;
        CHECK(!botbrain::DecodeContractInfo("{\"supported_majors\":[1]}", broken, error));
    }

    void TestIntentKindClassification()
    {
        CHECK(botbrain::IsKnownIntentKind("idle"));
        CHECK(botbrain::IsKnownIntentKind("travel_to"));
        CHECK(botbrain::IsKnownIntentKind("abandon_quest"));
        CHECK(!botbrain::IsKnownIntentKind("delete_bot"));
        CHECK(!botbrain::IsKnownIntentKind(""));

        // Only POI-directed kinds can reach the travel-target applier.
        CHECK(botbrain::IsPoiDirectedKind("travel_to"));
        CHECK(botbrain::IsPoiDirectedKind("vendor_sell"));
        CHECK(botbrain::IsPoiDirectedKind("repair"));
        CHECK(!botbrain::IsPoiDirectedKind("idle"));
        CHECK(!botbrain::IsPoiDirectedKind("rest"));
        CHECK(!botbrain::IsPoiDirectedKind("abandon_quest"));
    }
}

int main(int argc, char** argv)
{
    if (argc > 1 && std::strcmp(argv[1], "--dump-request") == 0)
    {
        std::string const json = botbrain::EncodePlanRequest(SampleRequest());
        std::fwrite(json.data(), 1, json.size(), stdout);
        return 0;
    }

    TestEncodedFieldNames();
    TestPercentagesAreOutOfOneHundred();
    TestOptionalsAreOmittedNotZeroed();
    TestValidateMirrorsTheService();
    TestDecodePlanResponse();
    TestUnknownKindsAreDroppedNotRejected();
    TestUnattributableIntentsAreDropped();
    TestMalformedBodiesFailCleanly();
    TestContractHandshake();
    TestIntentKindClassification();

    std::printf("bot_brain_wire_tests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
