/*
 * mod-bot-brain -- unit tests for the wire contract.
 *
 * Hand-rolled assertions, one plain main(), no test framework: the same shape
 * as core/modules/mod-playerbots/t/persistent_active_roster_tests.cpp, and for the
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
 *
 * Run with `--check-response` and the binary reads a PlanResponse body from
 * stdin, decodes it with the REAL decoder (the same DecodePlanResponse the
 * worldserver calls), and prints one line per decoded intent/error plus a
 * final DECODE_OK/DECODE_FAIL verdict, exiting 1 on a decode failure. This is
 * the other half of the live-service check: --dump-request proves the encoder
 * against the real service's INPUT side, --check-response proves the decoder
 * against its OUTPUT side. See test/integration/bot-brain-live.sh, which pipes
 * one into the other through a live `go run ./cmd/bot-brain` over a real
 * socket.
 */

#include "BotBrainWire.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
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

    // ---------------------------------------------------------------- goldens
    //
    // The fixtures in contracts/bot-brain/v1/golden/ are the contract as an
    // artifact rather than as two hand-written copies. Each is checked by the
    // side that must READ it: the Go service reads plan-request.json, and this
    // file reads the two the service PRODUCES.
    //
    // That asymmetry is the point. A test where the encoder checks its own
    // output proves the encoder is self-consistent, which was never in doubt.
    // What has actually gone wrong is a field NAME or NESTING that one side
    // renamed and the other did not - see BotBrainWire.cpp's "'pois'. Not
    // 'poi'. This name has been got wrong before."
    //
    // BB_GOLDEN_DIR is a compile definition rather than a runtime search,
    // because a test that cannot find its fixtures must FAIL, not silently pass
    // having checked nothing.
    bool ReadFile(std::string const& path, std::string& out)
    {
        std::ifstream in(path.c_str(), std::ios::binary);
        if (!in)
            return false;
        std::ostringstream buffer;
        buffer << in.rdbuf();
        out = buffer.str();
        return true;
    }

    std::string GoldenPath(char const* name)
    {
#ifdef BB_GOLDEN_DIR
        return std::string(BB_GOLDEN_DIR) + "/" + name;
#else
        return std::string("contracts/bot-brain/v1/golden/") + name;
#endif
    }

    // The response the service sends back. Decoded, not compared as text: what
    // matters is that OUR decoder pulls the right value out of THEIR encoder's
    // output, which is exactly the direction a shared struct definition cannot
    // check for us.
    void TestGoldenPlanResponse()
    {
        std::string body;
        std::string const path = GoldenPath("plan-response.json");
        if (!ReadFile(path, body))
        {
            std::printf("FAIL: cannot read %s\n", path.c_str());
            ++g_failures;
            return;
        }

        botbrain::PlanResponse response;
        std::string error;
        CHECK(botbrain::DecodePlanResponse(body, response, error));
        if (!error.empty())
            std::printf("  decode error: %s\n", error.c_str());

        CHECK(response.requestId == "req-golden-0001");
        CHECK(response.intents.size() == 2);
        CHECK(response.errors.size() == 1);

        if (response.intents.size() == 2)
        {
            botbrain::Intent const& first = response.intents[0];
            CHECK(first.bot.realm == 1);
            CHECK(first.bot.guid == 4242);
            // The memory key from ADR-0039. Empty here would mean the decoder
            // silently ignores a field the service is sending.
            CHECK(!first.bot.uuid.empty());
            CHECK(first.intentId == "int-golden-0001");
            CHECK(first.kind == "travel_to");
            CHECK(first.hasTravel);
            CHECK(first.travelPoiId == "p0");
            CHECK(first.hasStopWithinYards);
            CHECK(first.source == "rule");

            // Absent-vs-zero, end to end: the second intent carries no travel
            // block at all, and that must decode as ABSENT rather than as a
            // travel to POI "".
            botbrain::Intent const& second = response.intents[1];
            CHECK(second.bot.guid == 4243);
            CHECK(second.kind == "idle");
            CHECK(!second.hasTravel);
        }

        if (response.errors.size() == 1)
        {
            CHECK(response.errors[0].bot.guid == 4244);
            CHECK(response.errors[0].code == "bot_unplannable");
        }
    }

    // The handshake payload. If this decodes wrong the module fails closed on
    // every worldserver start, so it is worth a fixture of its own.
    void TestGoldenContractInfo()
    {
        std::string body;
        std::string const path = GoldenPath("contract-info.json");
        if (!ReadFile(path, body))
        {
            std::printf("FAIL: cannot read %s\n", path.c_str());
            ++g_failures;
            return;
        }

        botbrain::ContractInfo info;
        std::string error;
        CHECK(botbrain::DecodeContractInfo(body, info, error));
        if (!error.empty())
            std::printf("  decode error: %s\n", error.c_str());

        CHECK(!info.version.empty());
        CHECK(info.maxBatch == 2048);
        CHECK(!info.supportedMajors.empty());
        CHECK(botbrain::ContractMajorSupported(info, botbrain::kContractMajor));

        // The vocabulary the service says it understands must contain the one
        // kind this module can actually apply.
        bool hasTravel = false;
        for (std::size_t i = 0; i < info.knownIntentKinds.size(); ++i)
            if (info.knownIntentKinds[i] == "travel_to")
                hasTravel = true;
        CHECK(hasTravel);
    }

    // The version the fixtures declare must be the version this build speaks.
    // ops/ci/check-contract-version.sh enforces the same thing from outside;
    // this catches it in the suite, where the failure names the field.
    void TestGoldenVersionMatchesThisBuild()
    {
        std::string body;
        if (!ReadFile(GoldenPath("contract-info.json"), body))
        {
            std::printf("FAIL: cannot read contract-info.json\n");
            ++g_failures;
            return;
        }

        botbrain::ContractInfo info;
        std::string error;
        if (!botbrain::DecodeContractInfo(body, info, error))
        {
            std::printf("FAIL: contract-info.json did not decode: %s\n", error.c_str());
            ++g_failures;
            return;
        }

        char expected[32];
        std::snprintf(expected, sizeof(expected), "%d.%d",
            botbrain::kContractMajor, botbrain::kContractMinor);
        if (info.version != expected)
        {
            std::printf("FAIL: golden declares %s, this build speaks %s\n",
                info.version.c_str(), expected);
            ++g_failures;
        }
        ++g_checks;
    }
}

namespace
{
    // Reads all of stdin, unmodified. The live-service script pipes a real
    // HTTP response body in here; nothing about that body is trusted, which is
    // exactly what DecodePlanResponse is for.
    std::string ReadStdin()
    {
        std::ostringstream buffer;
        buffer << std::cin.rdbuf();
        return buffer.str();
    }

    // Decodes a PlanResponse from stdin with the REAL decoder and prints what
    // it found, one line per fact, so a shell script can grep for the exact
    // shape it expects without this file having to know what that is. Exit
    // code is the verdict: 0 only if the body decoded.
    //
    // This is deliberately dumb: it does not decide whether the intents are
    // the RIGHT ones for the sample request. That judgment belongs to the
    // script driving the live service, which knows what request it sent.
    int CheckResponse()
    {
        std::string const body = ReadStdin();

        botbrain::PlanResponse response;
        std::string error;
        if (!botbrain::DecodePlanResponse(body, response, error))
        {
            std::printf("DECODE_FAIL: %s\n", error.c_str());
            return 1;
        }

        std::printf("DECODE_OK request_id=%s intents=%zu errors=%zu plan_ms=%lld degraded=%s\n",
            response.requestId.c_str(), response.intents.size(), response.errors.size(),
            static_cast<long long>(response.planMs),
            response.degradedReason.empty() ? "-" : response.degradedReason.c_str());

        for (std::size_t i = 0; i < response.intents.size(); ++i)
        {
            botbrain::Intent const& in = response.intents[i];
            std::printf("INTENT bot_realm=%u bot_guid=%llu intent_id=%s kind=%s has_travel=%d "
                "travel_poi_id=%s confidence=%.3f source=%s\n",
                in.bot.realm, static_cast<unsigned long long>(in.bot.guid), in.intentId.c_str(),
                in.kind.c_str(), in.hasTravel ? 1 : 0, in.travelPoiId.c_str(), in.confidence,
                in.source.c_str());
        }
        for (std::size_t i = 0; i < response.errors.size(); ++i)
        {
            botbrain::PlanError const& e = response.errors[i];
            std::printf("ERROR bot_realm=%u bot_guid=%llu code=%s\n",
                e.bot.realm, static_cast<unsigned long long>(e.bot.guid), e.code.c_str());
        }
        return 0;
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

    if (argc > 1 && std::strcmp(argv[1], "--check-response") == 0)
        return CheckResponse();

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

    // The cross-language checks. Everything above proves this file agrees
    // with itself; these three prove it agrees with what the Go service
    // actually emits, which is the only failure mode a shared header
    // cannot rule out.
    TestGoldenPlanResponse();
    TestGoldenContractInfo();
    TestGoldenVersionMatchesThisBuild();

    std::printf("bot_brain_wire_tests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
