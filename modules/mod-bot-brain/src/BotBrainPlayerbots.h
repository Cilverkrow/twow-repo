/*
 * mod-bot-brain -- the prelude every playerbot include needs.
 *
 * mod-playerbots' headers are not self-contained, and nothing in that tree
 * pretends otherwise: its own translation units get their prerequisites from
 * core/modules/mod-playerbots/botpch.h, applied as a precompiled header on that
 * target only (mod-playerbots.cmake:160). A module that includes a playerbot
 * header without the same prelude collects a screenful of errors out of headers
 * it does not own -- WorldPosition.h alone wants <random> for
 * std::discrete_distribution, plus InstanceTemplate, GenericTransport and
 * sMapStore; TravelValues.h wants <future>; TravelMgr.h wants AreaTableEntry
 * and GetArea.
 *
 * The load-bearing include is cmangos-compat-shim.h, which is what defines
 * AreaTableEntry, GenericTransport and friends for this tree. Its own header
 * comment states the ordering it requires: AFTER the core's headers, so its
 * proxy methods can inline-call into them, and BEFORE any playerbot header,
 * which references its typedefs. That ordering is why this file exists as a
 * file rather than as a bare #include at the top of five .cpp files that a
 * tidy-up would helpfully sort into alphabetical order and break.
 *
 * This is deliberately NOT a copy of botpch.h. It is the subset this module
 * actually needs, and it is not registered as a PCH -- six translation units do
 * not justify one.
 *
 * Fixing mod-playerbots' headers to be self-contained would be the real
 * solution, and is not available: that tree is a vendored copy of upstream
 * (Shyalya/tortoise-wow, playerbots-integration-gh) and every line changed in
 * it is permanent merge friction.
 *
 * NOTE: playerbot.h ends with `#undef sLog` / `#define sLog BotLog::Instance()`.
 * Every logging call in a file that includes this therefore lands in bots.log
 * when AiPlayerbot.BotLogFile is set, and in the main log otherwise. That is
 * the right destination for this module -- its output is about bots -- but it
 * is worth knowing before going looking for a line in the wrong file.
 */

#ifndef MOD_BOT_BRAIN_PLAYERBOTS_H
#define MOD_BOT_BRAIN_PLAYERBOTS_H

// Core, first.
#include "Common.h"
#include "Log.h"
#include "ObjectGuid.h"
#include "ObjectMgr.h"
#include "SharedDefines.h"
#include "World.h"
#include "Maps/MapManager.h"
#include "Objects/Player.h"
#include "Objects/Unit.h"
#include "Group/Group.h"
#include "Spells/Spell.h"
#include "Spells/SpellMgr.h"

// STL that the playerbot headers use without including.
#include <future>
#include <memory>
#include <random>

// The cmangos -> Penqle name and type shim. After the core headers, before any
// playerbot header. See its own comment in botpch.h.
#include "cmangos-compat-shim.h"

// Playerbot, last.
#include "playerbot/BotSlots.h"
#include "playerbot/playerbot.h"

#endif
