/*
 * mod-bot-brain -- the HTTP client.
 *
 * Deliberately NOT PlayerbotLLMInterface. That class is shaped for LLM chat
 * completion -- prompt splitting, api keys, chat-completion response walking --
 * and none of that is this contract. Reusing it would have meant bending both.
 *
 * This is written against core/src/shared/httplib.h, which is already on
 * MODULES_COMMON_INCLUDES.
 *
 * THE IMPORTANT PROPERTY: every function here takes and returns std::string and
 * touches nothing else. No Player, no PlayerbotAI, no WorldSession, no
 * ObjectGuid, no TravelDestination. That is what makes it safe to call from a
 * detached worker thread, and it is the ADR-0012 rule ("World/AI objects and
 * raw pointers never cross the worker boundary") expressed as a type signature
 * rather than as a comment somebody has to remember.
 *
 * Compare PlayerbotAI.cpp SendDelayedPacket, which detaches a thread holding a
 * raw WorldSession* and calls QueuePacket after a sleep: a use-after-free on
 * logout (LLM-012). Nothing in this file can do that, because nothing in this
 * file can name a session.
 */

#ifndef MOD_BOT_BRAIN_CLIENT_H
#define MOD_BOT_BRAIN_CLIENT_H

#include <cstdint>
#include <string>

namespace botbrain
{
    struct HttpResult
    {
        bool ok = false;
        int status = 0;
        std::string body;
        std::string error;      // transport-level failure, empty when ok
    };

    // GET <endpoint>/v1/contract.
    HttpResult FetchContract(std::string const& endpoint, uint32_t timeoutMs);

    // POST <endpoint>/v1/plan with `body` as application/json.
    HttpResult PostPlan(std::string const& endpoint, std::string const& body, uint32_t timeoutMs);
}

#endif
