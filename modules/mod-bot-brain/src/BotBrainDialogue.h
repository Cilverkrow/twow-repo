/*
 * mod-bot-brain -- the bot's voice.
 *
 * ---------------------------------------------------------------------------
 * What this is
 * ---------------------------------------------------------------------------
 * PlayerbotLLMInterface::Generate in the core submodule returns "". Everything
 * upstream of it -- the LLMEnabled gate, the "ai chat" strategy check, the
 * blocked-channel list, the packet templates, the async worker and the
 * tick-polled delivery -- runs and produces nothing. mod-playerbots now
 * declares a seam above that stub (playerbot/BotDialogueProvider.h); this file
 * is the provider that fills it, by asking the service that already has the
 * plumbing.
 *
 * ---------------------------------------------------------------------------
 * Why the reply comes from the service rather than from a client in here
 * ---------------------------------------------------------------------------
 * The bot brain already owns per-provider auth, request construction, hostile
 * input validation, timeouts, a circuit breaker, an egress filter, a token
 * budget that latches shut rather than overspending, and Retry-After handling.
 * A second HTTP client written in C++ would have to re-solve every one of
 * those, in the process that must not go down.
 *
 * It also means the PROMPT is built there, from the trait catalog's German
 * instruction sentences, rather than here from AiPlayerbot.LLMApiJson. That is
 * the whole reason the seam is at ChatReplyDo and not inside Generate: what
 * crosses is the structured facts (who said what, where, to which bot, with
 * which traits), not a rendered request body shaped for somebody else's API.
 *
 * ---------------------------------------------------------------------------
 * Threading
 * ---------------------------------------------------------------------------
 * Speak() is called ONLY from the std::async worker that ChatReplyDo already
 * spawns per chat message. It blocks for as long as the model takes -- seconds,
 * not the plan path's milliseconds -- and that is affordable precisely because
 * the world thread is not the one waiting: SendDelayedPacket hands the future
 * to PlayerbotAI, which polls it with wait_for(0) on the bot's own tick.
 *
 * Nothing here touches a Player, a PlayerbotAI or a WorldSession. The request
 * carries scalars and strings, the answer is a string, and the bot's identity
 * is looked up by low guid through LookupBotIdentity, which copies under a
 * mutex. That is ADR-0012's rule, and it is why a bot logging out mid-sentence
 * costs a discarded reply rather than a use-after-free.
 *
 * ---------------------------------------------------------------------------
 * Fail closed, everywhere
 * ---------------------------------------------------------------------------
 * Every path that is not "the service returned a reply this side will vouch
 * for" returns "", and "" means the bot says nothing. Module disabled,
 * dialogue disabled, no handshake, a channel with no contract name, too many
 * calls already in flight, a request our own validator refuses, a dead socket,
 * a non-200, an undecodable body, a reply with a newline in it: all silence,
 * none of it an error on the world thread.
 */

#ifndef MOD_BOT_BRAIN_DIALOGUE_H
#define MOD_BOT_BRAIN_DIALOGUE_H

namespace botbrain
{
    // Installs the provider with mod-playerbots. Called once, from
    // WORLDHOOK_ON_STARTUP.
    //
    // Registered UNCONDITIONALLY, like the context augmenter beside it and for
    // the same reason: the provider consults the live settings on every call,
    // so registering only when dialogue happens to be enabled at boot would
    // mean a config reload could not turn it on without a restart. A registered
    // provider with the feature off is silent, which is exactly what a bot does
    // today.
    void RegisterDialogueProvider();

    // Re-reads the settings the provider is allowed to see. Called on
    // WORLDHOOK_ON_AFTER_CONFIG_LOAD, right after LoadConfig().
    //
    // The provider does NOT read GetSettings() directly, and that is the point
    // of this function: GetSettings() returns a reference to a struct with
    // std::string members that LoadConfig rewrites on the world thread, while
    // the provider reads from a worker. This publishes a copy under a mutex so
    // the two cannot tear.
    void RefreshDialogueSettings();
}

#endif
