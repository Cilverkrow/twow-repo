// Must precede every playerbot header -- see BotBrainPlayerbots.h.
#include "BotBrainPlayerbots.h"

#include "BotBrainDialogue.h"

#include "BotBrainClient.h"
#include "BotBrainConfig.h"
#include "BotBrainPipeline.h"
#include "BotBrainWire.h"

#include "playerbot/BotDialogueProvider.h"

#include "Log.h"

#include <atomic>
#include <chrono>
#include <mutex>
#include <string>
#include <vector>

namespace botbrain
{
    namespace
    {
        // The settings the worker is allowed to see. See RefreshDialogueSettings.
        struct DialogueSettings
        {
            bool enabled = false;
            std::string endpoint;
            uint32_t timeoutMs = 8000;
            uint32_t maxInFlight = 8;
            bool commandsEnabled = false;
        };

        std::mutex g_settingsMutex;
        DialogueSettings g_settings;

        DialogueSettings CurrentSettings()
        {
            std::lock_guard<std::mutex> lock(g_settingsMutex);
            return g_settings;
        }

        // Concurrent calls, across every bot on the realm. Each one is holding a
        // worldserver worker thread that the chat path spawned, so this bounds
        // threads and not merely politeness towards the model.
        std::atomic<uint32_t> g_inFlight{0};

        int64_t NowUnixMs()
        {
            using namespace std::chrono;
            return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
        }

        // mod-playerbots' chat-source vocabulary -> the contract's channels.
        //
        // The core seam reports EVERY ChatChannelSource it has, deliberately,
        // leaving the policy here. This is that policy, and it is conservative:
        //
        //   say, yell        -> "say"      local chat, 1-2 sentences
        //   party, raid      -> "party"    group channel, action-oriented
        //   guild            -> "guild"    social, up to four sentences
        //   whisper          -> "whisper"  personal
        //
        // Everything else -- world, general, trade, lfg, the two defence
        // channels, guild recruitment, and both emote sources -- maps to
        // nothing and the bot stays quiet. Not because the service would refuse
        // them (it would: the channel enum is closed) but because section 11.2's
        // style rules are written for conversations, and a bot writing German
        // prose into trade chat is a different feature that nobody has designed.
        //
        // "guild_event" has no source in this core and is therefore never sent;
        // it exists in the contract for a caller that can tell a gathering from
        // ordinary guild chat, and this one cannot.
        std::string ContractChannel(std::string const& source)
        {
            if (source == "say" || source == "yell")
                return kDialogueChannelSay;
            if (source == "party" || source == "raid")
                return kDialogueChannelParty;
            if (source == "guild")
                return kDialogueChannelGuild;
            if (source == "whisper")
                return kDialogueChannelWhisper;
            return std::string();
        }

        // Takes one of the in-flight slots, or reports that they are all taken.
        // Never blocks and never queues: a bot over the limit is silent
        // immediately, which is the answer the chat path can actually use.
        bool AcquireSlot(uint32_t limit)
        {
            uint32_t current = g_inFlight.load(std::memory_order_relaxed);
            for (;;)
            {
                if (current >= limit)
                    return false;
                if (g_inFlight.compare_exchange_weak(current, current + 1,
                        std::memory_order_acq_rel, std::memory_order_relaxed))
                    return true;
            }
        }

        struct SlotGuard
        {
            // User-provided, and it has to be: a const object of a class with
            // no user-provided default constructor is ill-formed, and this one
            // wants to be const at every use site.
            SlotGuard() {}
            ~SlotGuard() { g_inFlight.fetch_sub(1, std::memory_order_acq_rel); }
            SlotGuard(SlotGuard const&) = delete;
            SlotGuard& operator=(SlotGuard const&) = delete;
        };

        // The contract's command spellings -> core's enum.
        //
        // One switch, over literals, and everything unrecognised is None. The
        // wire decoder has already refused anything outside the closed set, so
        // this is the second of two checks; they are both here because the cost
        // of them disagreeing is a bot doing something nobody asked for, and
        // the cost of both being present is five lines.
        //
        // Nothing in this function decides whether the command may HAPPEN. That
        // is PlayerbotAI::HandleCommand's job, one process boundary and one
        // thread away, where the speaker's PlayerbotSecurity level is checked
        // exactly as it is for the same word typed in chat.
        BotDialogueCommand CoreCommand(std::string const& wire)
        {
            if (wire == kDialogueCommandFollow)
                return BotDialogueCommand::Follow;
            if (wire == kDialogueCommandStay)
                return BotDialogueCommand::Stay;
            if (wire == kDialogueCommandFlee)
                return BotDialogueCommand::Flee;
            if (wire == kDialogueCommandAttack)
                return BotDialogueCommand::Attack;
            if (wire == kDialogueCommandEquipUpgrades)
                return BotDialogueCommand::EquipUpgrades;
            return BotDialogueCommand::None;
        }

        // The provider. WORKER THREAD ONLY. Returns the line to say and at most
        // one command -- and silence, doing nothing, is the answer on every
        // path but one.
        BotDialogueAnswer Speak(BotDialogueRequest const& request)
        {
            BotDialogueAnswer const silence;

            DialogueSettings const cfg = CurrentSettings();
            if (!cfg.enabled || cfg.endpoint.empty())
                return silence;

            // Fail closed on the handshake, exactly as the planning pipeline
            // does: an unadmitted peer is a peer whose contract major we have
            // not agreed on, and guessing is how a version skew becomes a
            // sentence in a game channel.
            if (!IsAdmitted())
                return silence;

            std::string const channel = ContractChannel(request.channel);
            if (channel.empty())
                return silence;

            if (!AcquireSlot(cfg.maxInFlight))
                return silence;
            SlotGuard const guard;

            DialogueRequest wire;
            if (!LookupBotIdentity(request.botGuidLow, wire.bot, wire.traitKeys))
                return silence;

            // The profile is quota'd at seven keys and the contract allows
            // twelve, so this only ever fires if a manual assignment ran away.
            // Truncating rather than refusing keeps the bot talking with the
            // personality it does have; the order is the policy's, so the keys
            // that survive are the ones it ranked highest.
            if (wire.traitKeys.size() > kMaxDialogueTraitKeys)
                wire.traitKeys.resize(kMaxDialogueTraitKeys);

            wire.contractVersion = kContractVersion;
            wire.channel = channel;
            wire.speaker = request.speakerIsBot ? kDialogueSpeakerBot : kDialogueSpeakerPlayer;
            wire.speakerName = request.speakerName;
            wire.message = request.message;
            wire.language = kDialogueLanguage;
            wire.sentAtMs = NowUnixMs();

            // Asked for only when the operator turned commands on AND the chat
            // path could say who spoke. A speaker of zero means either an
            // unresolvable player or another bot, and in both cases there is
            // nobody the command could be executed as -- so the service is not
            // asked for one, which also keeps the vocabulary out of the prompt.
            wire.allowCommands = cfg.commandsEnabled && request.speakerGuidLow != 0;

            // The core's own timeout is advisory and derived from a config key
            // that predates this path; ours is what the socket and the service
            // are actually held to. Take the smaller when the core asked for
            // less, so an operator who shortened LLMGenerationTimeout gets what
            // they asked for.
            uint32_t timeoutMs = cfg.timeoutMs;
            if (request.timeoutMs && request.timeoutMs < timeoutMs)
                timeoutMs = request.timeoutMs;
            wire.deadlineMs = int64_t(timeoutMs);

            // request_id is deliberately not set: absent is tolerated and the
            // brain mints one, which is one fewer place for two processes to
            // disagree about a uuid format.

            std::string error;
            if (!ValidateDialogueRequest(wire, error))
            {
                // A name we cannot vouch for is dropped rather than sent: the
                // field is optional, so losing it costs a less personal reply,
                // while sending it costs a 400 and total silence for that bot.
                std::string const rejected = wire.speakerName;
                wire.speakerName.clear();
                if (rejected.empty() || !ValidateDialogueRequest(wire, error))
                {
                    // Anything still wrong here is OUR bug, not the peer's, and
                    // it would have been a 400. Loud, and named.
                    sLog.outError("mod-bot-brain: refusing to send a dialogue request for guid %u: %s",
                        request.botGuidLow, error.c_str());
                    return silence;
                }
            }

            HttpResult const result = PostDialogue(cfg.endpoint, EncodeDialogueRequest(wire), timeoutMs);
            if (!result.ok)
            {
                // Detail, not error: a model that is down, busy or slow is an
                // expected state of this feature, and the service already
                // counts it. An error line per chat message would bury the
                // validation failure above, which is the one that means a bug.
                sLog.outDetail("mod-bot-brain: dialogue call failed for guid %u: %s",
                    request.botGuidLow, result.error.c_str());
                return silence;
            }

            DialogueResponse response;
            // The request's own allowCommands is passed back in: a command on a
            // response to a request that did not ask for one is dropped by the
            // decoder rather than reasoned about here.
            if (!DecodeDialogueResponse(result.body, wire.allowCommands, response, error))
            {
                sLog.outError("mod-bot-brain: undecodable dialogue response for guid %u: %s",
                    request.botGuidLow, error.c_str());
                return silence;
            }

            BotDialogueAnswer answer;
            answer.command = CoreCommand(response.command);

            if (answer.command != BotDialogueCommand::None)
            {
                // At BASIC level and unconditionally, because this is the one
                // thing this module can cause to HAPPEN in the world. An
                // operator reading back after an incident needs the bot, the
                // channel and the command; who it will be executed as, and
                // whether it was permitted, is core's log line to write.
                sLog.outString("mod-bot-brain: bot %u was asked to '%s' by the speaker in %s",
                    request.botGuidLow, response.command.c_str(), channel.c_str());
            }

            if (!response.spoke)
            {
                // The reason is the only way an operator tells "the bot had
                // nothing to say" (healthy, and common by design) from a
                // latched token budget or an open breaker. Note this is NOT a
                // return: a bot that was told to come here and had nothing to
                // add is silent and still moving.
                sLog.outDetail("mod-bot-brain: bot %u stayed silent: %s",
                    request.botGuidLow, response.reason.c_str());
                return answer;
            }

            // DecodeDialogueResponse has already refused a reply that is empty,
            // oversized or carries a control character, so anything that
            // reaches here is a single line safe to put in a chat packet.
            answer.reply = response.reply;
            return answer;
        }
    }

    void RefreshDialogueSettings()
    {
        Settings const& live = GetSettings();

        DialogueSettings next;
        // Both switches, because BotBrain.Enable is "the brain plans" and
        // BotBrain.Dialogue.Enable is "and it also spends model tokens when a
        // player types". Neither implies the other.
        next.enabled = live.enabled && live.dialogueEnabled;
        next.endpoint = live.endpoint;
        next.timeoutMs = live.dialogueTimeoutMs;
        next.maxInFlight = live.dialogueMaxInFlight;
        next.commandsEnabled = live.dialogueCommandsEnabled;

        std::lock_guard<std::mutex> lock(g_settingsMutex);
        g_settings = next;
    }

    void RegisterDialogueProvider()
    {
        RegisterBotDialogueProvider(&Speak);
    }
}
