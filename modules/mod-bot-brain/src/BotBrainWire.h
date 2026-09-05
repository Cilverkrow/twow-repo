/*
 * mod-bot-brain -- the wire contract, in C++.
 *
 * This header is the C++ mirror of services/bot-brain/contract (Go). It is the
 * ONLY part of this module that a test can compile without a world server, and
 * that is deliberate: every field-name and unit mistake this contract has
 * already produced is a mistake that a hermetic test can catch.
 *
 * It deliberately depends on nothing but <cstdint>, <string>, <vector> and
 * rapidjson. No core header, no playerbot header, no ObjectGuid, no Player.
 *
 * Units and shapes that have already caused bugs, spelled out so the next
 * reader does not have to rediscover them:
 *
 *   - the POI array is "pois", NOT "poi";
 *   - "durability_pct" is nested under "vitals", NOT under "char", and it is a
 *     POINTER on the Go side: absent is not the same as zero, so this header
 *     models it as a value plus a has* flag and omits the key when unset;
 *   - every percentage is 0..100, never 0..1. The one exception is
 *     Intent.confidence, which really is 0..1 because the Go side validates it
 *     that way;
 *   - angles are radians;
 *   - bot.guid and bot.realm must both be non-zero or the service's
 *     Snapshot.Validate() rejects the snapshot and the bot gets no intent.
 *
 * Unknown intent kinds are IGNORED, never rejected -- a newer brain talking to
 * an older worldserver is a supported state, and the bot simply keeps running
 * stock AI.
 */

#ifndef MOD_BOT_BRAIN_WIRE_H
#define MOD_BOT_BRAIN_WIRE_H

#include <cstdint>
#include <string>
#include <vector>

namespace botbrain
{
    // The contract version this build speaks. Must track
    // services/bot-brain/contract/version.go (VersionMajor.VersionMinor).
    extern char const* const kContractVersion;
    int constexpr kContractMajor = 1;
    int constexpr kContractMinor = 2;

    // Intent kinds this build understands. Anything else is dropped silently.
    extern char const* const kIntentIdle;
    extern char const* const kIntentTravelTo;
    extern char const* const kIntentGrindArea;
    extern char const* const kIntentVendorSell;
    extern char const* const kIntentRepair;
    extern char const* const kIntentRest;
    extern char const* const kIntentPickQuest;
    extern char const* const kIntentTurnInQuest;
    extern char const* const kIntentAbandonQuest;

    bool IsKnownIntentKind(std::string const& kind);

    // A kind whose destination is a POI in the same snapshot. These are the
    // only kinds this module can currently act on, because the only applier it
    // has is the travel-target chooser.
    bool IsPoiDirectedKind(std::string const& kind);

    struct BotId
    {
        uint32_t realm = 0;
        uint64_t guid = 0;

        // The brain's stable key for this bot (ADR-0039), minted once into
        // cv_brain.bot_identity and never derived from the pair above -
        // RealmMerge shifts every guid, so a derived id would rename the bot
        // and orphan everything the brain remembered about it.
        //
        // Optional on the wire: a snapshot taken before the row exists is
        // still worth planning for, just without memory. Empty means "not
        // yet minted", never "no bot".
        std::string uuid;

        // Deliberately still (realm, guid): this is the addressing identity,
        // the pair the applier uses to decide an intent is for THIS bot
        // (BotBrainPipeline.cpp:700). The uuid is the memory key, not the
        // address, and comparing on it would silently accept an intent for a
        // bot whose row has not been minted.
        bool IsZero() const { return realm == 0 || guid == 0; }
        bool operator==(BotId const& o) const { return realm == o.realm && guid == o.guid; }
    };

    struct Position
    {
        uint32_t mapId = 0;
        double x = 0.0;
        double y = 0.0;
        double z = 0.0;
        double orientation = 0.0;   // radians
        uint32_t zoneId = 0;
        uint32_t areaId = 0;
        uint32_t instanceId = 0;
    };

    struct Vitals
    {
        double healthPct = 0.0;          // 0..100
        bool hasPowerPct = false;
        double powerPct = 0.0;           // 0..100
        bool isDead = false;
        bool inCombat = false;
        bool isResting = false;
        bool isMounted = false;
        bool hasDurabilityPct = false;   // absent != 0
        double durabilityPct = 0.0;      // 0..100
    };

    struct Character
    {
        std::string name;
        uint8_t level = 0;
        uint8_t cls = 0;
        uint8_t race = 0;
        std::string faction;             // "alliance" | "horde"
        uint64_t money = 0;              // copper
        uint32_t freeBagSlots = 0;
        std::vector<std::string> traitKeys;
    };

    struct QuestEntry
    {
        uint32_t questId = 0;
        std::string status;              // "incomplete" | "complete" | "failed"
        uint32_t objectivesDone = 0;
        uint32_t objectivesTotal = 0;
        uint8_t requiredLevel = 0;
        uint8_t questLevel = 0;
    };

    struct PointOfInterest
    {
        std::string id;                  // opaque, valid for this snapshot only
        std::string kind;                // "vendor", "repair", "quest_giver", ...
        Position pos;
        bool hasDistanceYards = false;
        double distanceYards = 0.0;
        uint32_t relatedQuestId = 0;
        std::vector<std::string> tags;
    };

    struct Surroundings
    {
        uint32_t hostileCount = 0;
        uint32_t friendlyPlayerCount = 0;
        uint32_t friendlyBotCount = 0;
        bool hasRadiusYards = false;
        double radiusYards = 0.0;
        bool hasNearestHostileYards = false;
        double nearestHostileYards = 0.0;
        uint32_t groupSize = 1;
        bool isGroupLeader = false;
    };

    struct IntentOutcome
    {
        std::string intentId;
        std::string kind;
        std::string result;              // "accepted" | "rejected" | ...
        std::string reason;
        int64_t issuedAtMs = 0;
        // The destination the intent named, so the planner learns WHERE it was
        // refused and not merely THAT it was. Without it the same POI is still
        // nearest next tick and the bot is re-sent somewhere it cannot go.
        // Empty when the intent named no POI, or was not POI-directed.
        std::string poiId;
    };

    struct Snapshot
    {
        BotId bot;
        Character chr;
        Position pos;
        Vitals vitals;
        Surroundings around;
        std::vector<QuestEntry> quests;
        std::vector<PointOfInterest> pois;
        bool hasLastOutcome = false;
        IntentOutcome lastOutcome;
        int64_t observedAtMs = 0;
        std::vector<std::string> hints;
    };

    struct PlanRequest
    {
        std::string contractVersion;
        std::string requestId;
        int64_t sentAtMs = 0;
        int64_t deadlineMs = 0;
        std::vector<Snapshot> snapshots;
    };

    struct Intent
    {
        BotId bot;
        std::string intentId;
        std::string kind;
        bool hasTravel = false;
        std::string travelPoiId;
        bool hasStopWithinYards = false;
        double stopWithinYards = 0.0;
        bool hasQuest = false;
        uint32_t questId = 0;
        int32_t priority = 0;
        double confidence = 0.0;         // 0..1, unlike the percentages
        int64_t expiresAtMs = 0;
        std::string source;
        std::string rationale;
    };

    struct PlanError
    {
        BotId bot;
        std::string code;
        std::string message;
    };

    struct PlanResponse
    {
        std::string contractVersion;
        std::string requestId;
        std::vector<Intent> intents;
        std::vector<PlanError> errors;
        int64_t planMs = 0;
        std::string degradedReason;
    };

    struct ContractInfo
    {
        std::string version;
        std::vector<int> supportedMajors;
        std::vector<std::string> knownIntentKinds;
        int maxBatch = 0;
    };

    // Mirrors Snapshot.Validate() in the Go service, so a snapshot this module
    // would have had rejected on the far side is dropped here instead -- one
    // process earlier, where the log line can name the bot.
    bool ValidateSnapshot(Snapshot const& s, std::string& error);

    // Serialise. Snapshots that fail ValidateSnapshot are the caller's problem;
    // this function encodes whatever it is given.
    std::string EncodePlanRequest(PlanRequest const& req);

    // Parse. Both return false and set `error` on malformed input; neither ever
    // throws. Unknown intent kinds are dropped from the result rather than
    // failing the parse.
    bool DecodePlanResponse(std::string const& body, PlanResponse& out, std::string& error);
    bool DecodeContractInfo(std::string const& body, ContractInfo& out, std::string& error);

    // True when the peer can serve the major this build speaks. A false here at
    // startup is the whole point of the /v1/contract handshake: skew is found
    // at boot, not one dropped intent at a time.
    bool ContractMajorSupported(ContractInfo const& info, int wantMajor);
}

#endif
