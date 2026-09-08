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

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace botbrain
{
    // The contract version this build speaks. Must track
    // services/bot-brain/contract/version.go (VersionMajor.VersionMinor).
    //
    // The NUMBERS are the source of truth and the string is built from them, so
    // the two cannot disagree. They did: kContractVersion was written out by
    // hand as "1.0" and stayed there through 1.1, 1.2 and 1.3, so every request
    // this module ever sent advertised a version the module did not implement.
    //
    // That was not cosmetic. Negotiate() in version.go checks the MAJOR against
    // the supported set and then clamps the peer's MINOR -- so the service
    // negotiated an effective 1.0 for this client and would have withheld
    // anything gated on a later minor, silently and correctly, from a build that
    // supported it.
#define BOT_BRAIN_CONTRACT_MAJOR 1
#define BOT_BRAIN_CONTRACT_MINOR 5
#define BOT_BRAIN_STRINGIFY_(x) #x
#define BOT_BRAIN_STRINGIFY(x) BOT_BRAIN_STRINGIFY_(x)
#define BOT_BRAIN_CONTRACT_VERSION     BOT_BRAIN_STRINGIFY(BOT_BRAIN_CONTRACT_MAJOR) "." BOT_BRAIN_STRINGIFY(BOT_BRAIN_CONTRACT_MINOR)

    extern char const* const kContractVersion;
    int constexpr kContractMajor = BOT_BRAIN_CONTRACT_MAJOR;
    int constexpr kContractMinor = BOT_BRAIN_CONTRACT_MINOR;

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

    // A kind whose destination is a POI in the same snapshot. These are applied
    // by the travel-target chooser: the bot walks there.
    bool IsPoiDirectedKind(std::string const& kind);

    // A POI-directed kind that does something WHEN IT ARRIVES, rather than
    // treating arrival as the whole point.
    //
    // travel_to and grind_area are deliberately absent: for those, being there
    // IS the outcome, and inventing a terminal action for them would turn a
    // successful journey into a failure whenever the invented action declined.
    bool HasArrivalAction(std::string const& kind);

    // A kind applied by something other than the travel chooser -- an action the
    // bot performs where it stands, rather than a place to go.
    //
    // This is deliberately NOT "every kind that is not POI-directed". It names
    // what this build can actually carry out, so a kind the planner may legally
    // send but nothing here implements is still rejected as "unsupported_kind"
    // rather than silently accepted and dropped. The set grows as appliers are
    // written; `idle` will never join it, because doing nothing is what the bot
    // does when no intent applies at all.
    bool IsAppliedKind(std::string const& kind);

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
        std::string result;              // "accepted" | "completed" | "rejected" | "failed" | "expired"
        // "unreachable" | "stale_poi" | "unknown_poi" | "unsupported_kind" |
        // "action_refused". The last means the intent was attempted where the bot
        // stood and the in-core action declined -- "not now", as against
        // "unsupported_kind" which means nothing tried at all and never will.
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

    // -----------------------------------------------------------------------
    // Dialogue (POST /v1/dialogue) -- services/bot-brain/contract/dialogue.go
    // -----------------------------------------------------------------------
    //
    // Unbatched, unlike the plan request above, and that is the contract's
    // decision rather than an omission here: planning is a thousand bots on a
    // tick and batching is the only way to afford it, while dialogue is an
    // event -- one player says one thing and the reply is worth nothing if it
    // arrives with the next tick's batch.
    //
    // SILENCE IS A 200. A bot with nothing to say, a dead model, an exhausted
    // budget and a shed request all come back as spoke=false with a reason. The
    // only non-200 is a request that did not decode, which is why the bounds
    // below are mirrored here and checked BEFORE the request goes out: a 400 is
    // this side's bug, and it should cost a log line that names the bot rather
    // than a silent bot and a counter in another process.

    // Channels the service serves. Anything else is refused rather than
    // defaulted, because guessing "say" would apply the wrong length rule to
    // the one place length matters.
    extern char const* const kDialogueChannelSay;
    extern char const* const kDialogueChannelParty;
    extern char const* const kDialogueChannelGuild;
    extern char const* const kDialogueChannelWhisper;
    extern char const* const kDialogueChannelGuildEvent;

    bool IsKnownDialogueChannel(std::string const& channel);

    // What KIND of speaker spoke, not which one.
    extern char const* const kDialogueSpeakerPlayer;
    extern char const* const kDialogueSpeakerBot;

    // The only language this build of the service produces: the catalog's 124
    // instructions are German sentences.
    extern char const* const kDialogueLanguage;

    // Commands a reply may ask for: the closed set from
    // contract/dialogue.go's DialogueCommand.
    //
    // Each one is the name of a chat command mod-playerbots already accepts
    // from a player who types it. Nothing here executes anything -- these are
    // wire spellings, and the module maps them onto core's BotDialogueCommand,
    // which is what the worldserver runs, as the speaker, through
    // PlayerbotAI::HandleCommand.
    //
    // The set is closed on THIS side as well as the service's, and that
    // duplication is the point: a service that learned a sixth command before
    // this build did makes a bot do nothing rather than something.
    extern char const* const kDialogueCommandFollow;
    extern char const* const kDialogueCommandStay;
    extern char const* const kDialogueCommandFlee;
    extern char const* const kDialogueCommandAttack;
    extern char const* const kDialogueCommandEquipUpgrades;

    bool IsKnownDialogueCommand(std::string const& command);

    // Silence reasons. Stable strings, switchable, and the reason an operator
    // can tell "nothing to say" from "the model is unreachable" from "the token
    // budget latched" -- three states that look identical from the game.
    extern char const* const kSilenceNothingToSay;
    extern char const* const kSilenceDisabled;
    extern char const* const kSilenceUnavailable;
    extern char const* const kSilenceBudget;
    extern char const* const kSilenceBusy;
    extern char const* const kSilenceFiltered;
    extern char const* const kSilenceDeadline;

    // Bounds, mirroring contract/dialogue.go. Bytes except where noted.
    std::size_t constexpr kMaxDialogueMessageBytes = 512;
    std::size_t constexpr kMaxDialogueReplyBytes = 255;
    std::size_t constexpr kMaxDialogueTraitKeys = 12;
    std::size_t constexpr kMaxDialogueSpeakerNameRunes = 12;   // RUNES, not bytes
    std::size_t constexpr kMaxDialogueTraitKeyBytes = 64;

    struct DialogueRequest
    {
        std::string contractVersion;
        std::string requestId;

        // Echoed back on the response and never sent to the model: it is how
        // the worldserver matches a reply to a character.
        BotId bot;

        std::string channel;        // one of the kDialogueChannel* above
        std::string speaker;        // kDialogueSpeakerPlayer | kDialogueSpeakerBot

        // The speaker's character name, and the ONLY identity that leaves this
        // process. Optional; letters only, 2..kMaxDialogueSpeakerNameRunes of
        // them. That shape is what makes it safe to interpolate into a prompt:
        // no quote to close, no brace, no newline, no colon.
        std::string speakerName;

        // What was said. Player-typed, therefore hostile.
        std::string message;

        // The bot's personality, as keys from the 124-key catalog. Empty is
        // normal and always has been -- a bot whose profile has not been
        // generated yet still talks, just without a personality.
        std::vector<std::string> traitKeys;

        std::string language;       // empty or kDialogueLanguage
        int64_t sentAtMs = 0;
        int64_t deadlineMs = 0;

        // Whether this utterance may come back with a command. False -- the
        // default -- means text only: the service does not put the command
        // vocabulary in front of the model at all, and a command that arrives
        // anyway is dropped on both sides.
        bool allowCommands = false;
    };

    struct DialogueResponse
    {
        std::string contractVersion;
        std::string requestId;
        BotId bot;
        bool spoke = false;
        std::string reply;          // empty unless spoke
        std::string reason;         // one of the kSilence* above, unless spoke
        // What the speaker asked the bot to do, or empty. One of the
        // kDialogueCommand* above and nothing else: DecodeDialogueResponse
        // drops a value it does not know rather than passing it on, so this
        // field is either executable or empty.
        //
        // Independent of `spoke`. A bot may say something and act, act without
        // saying anything, or neither.
        std::string command;
        int64_t replyMs = 0;
        int32_t traitsApplied = 0;
        int32_t unknownFields = 0;
    };

    // Mirrors DialogueRequest.Validate() in the Go service, for the reason
    // ValidateSnapshot exists: a request that would have been a 400 is refused
    // one process earlier, where the log line can name the bot. Unlike a
    // snapshot, this one is also the last chance to notice that the world
    // handed us a name or a message that cannot have come from a character.
    bool ValidateDialogueRequest(DialogueRequest const& req, std::string& error);

    std::string EncodeDialogueRequest(DialogueRequest const& req);

    // Parse. Returns false and sets `error` on malformed input; never throws.
    //
    // A response that decodes but claims to have spoken with a reply this side
    // will not accept -- empty, over kMaxDialogueReplyBytes, or carrying a
    // control character that would forge a second chat line -- is decoded as
    // SILENCE with kSilenceFiltered rather than as a failure. The far side runs
    // the same check; this one is what makes a disagreement cost a quiet bot
    // instead of an unvetted line in a game channel.
    //
    // A command is treated the same way and independently: one this build does
    // not know, or one on a response to a request that did not set
    // allowCommands, is CLEARED. Never guessed at, never passed through, and
    // never a reason to drop a reply that is otherwise fine. `allowCommands`
    // must be the value that was sent on the request this body answers.
    bool DecodeDialogueResponse(std::string const& body, bool allowCommands, DialogueResponse& out, std::string& error);
}

#endif
