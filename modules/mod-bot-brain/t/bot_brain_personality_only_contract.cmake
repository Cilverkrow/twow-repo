# twow-repo#664 (OB-00 01.11.2026): BotBrain.Personality.Enable - identity + profile for bots the
# planner does not cover, so their dialogue carries their traits; nothing else (no snapshot, no
# /v1/plan, no intent). Pins the key (default off, under BotBrain.Enable), the call site (only on
# the "not planned" branch of Tick), the gates, the worker order (uuid before profile) and that the
# function never touches the planning machinery.
cmake_policy(VERSION 3.16)

foreach(var BB_CONFIG_H BB_CONFIG_CPP BB_PIPELINE BB_CONF_DIST)
  if(NOT DEFINED ${var} OR NOT EXISTS "${${var}}")
    message(FATAL_ERROR "personality-only contract: ${var} does not name a file")
  endif()
endforeach()

function(read_lf path out)
  file(READ "${path}" text)
  string(REPLACE "\r" "" text "${text}")
  set(${out} "${text}" PARENT_SCOPE)
endfunction()

function(require text needle what)
  string(FIND "${text}" "${needle}" at)
  if(at EQUAL -1)
    message(FATAL_ERROR "personality-only contract: missing ${what}: ${needle}")
  endif()
endfunction()

function(forbid text needle what)
  string(FIND "${text}" "${needle}" at)
  if(NOT at EQUAL -1)
    message(FATAL_ERROR "personality-only contract: forbidden ${what}: ${needle}")
  endif()
endfunction()

read_lf("${BB_CONFIG_H}" config_h)
read_lf("${BB_CONFIG_CPP}" config_cpp)
read_lf("${BB_PIPELINE}" pipeline)
read_lf("${BB_CONF_DIST}" conf_dist)

# 1. The key: off by default everywhere, logged under an enabled brain.
require("${config_h}" "bool personalityEnabled = false;" "member default off")
require("${config_cpp}" "cfg.personalityEnabled = sConfig.GetBoolDefault(\"BotBrain.Personality.Enable\", false);" "config read, default off")
require("${config_cpp}" "personality without planning %s (BotBrain.Personality.Enable)" "startup log line")
require("${conf_dist}" "\nBotBrain.Personality.Enable = 0\n" "dist key, off")

# 2. The call site: only where the planner does NOT cover the bot, and Tick returns right after.
require("${pipeline}" "        if (!ShouldPlanFor(bot, botAI))\n        {\n" "the not-planned branch")
string(FIND "${pipeline}" "        if (!ShouldPlanFor(bot, botAI))\n        {\n" branch_at)
string(SUBSTRING "${pipeline}" ${branch_at} 400 branch)
require("${branch}" "            ResolvePersonalityOnly(bot, botAI);\n            return;\n        }" "personality-only then return")
set(call "ResolvePersonalityOnly(bot, botAI);")
string(LENGTH "${pipeline}" len_with)
string(REPLACE "${call}" "" without "${pipeline}")
string(LENGTH "${without}" len_without)
string(LENGTH "${call}" len_call)
math(EXPR ncalls "(${len_with} - ${len_without}) / ${len_call}")
if(NOT ncalls EQUAL 1)
  message(FATAL_ERROR "personality-only contract: expected exactly one call site, found ${ncalls}")
endif()

# 3. The function: gates, order, and no planning machinery inside it.
string(FIND "${pipeline}" "void ResolvePersonalityOnly(Player* bot, PlayerbotAI* botAI)" fn_at)
if(fn_at EQUAL -1)
  message(FATAL_ERROR "personality-only contract: ResolvePersonalityOnly not found")
endif()
string(SUBSTRING "${pipeline}" ${fn_at} -1 rest)
string(FIND "${rest}" "\n        }\n" fn_end)
string(SUBSTRING "${rest}" 0 ${fn_end} fn)
require("${fn}" "if (!cfg.enabled || !cfg.personalityEnabled || g_shuttingDown.load())\n                return;" "switch gates")
require("${fn}" "if (g_inFlight.load() >= cfg.maxInFlight)\n                return;" "worker ceiling")
require("${fn}" "% kPersonalityOnlyWindowS != 0)\n                return;" "per-bot time window")
require("${fn}" "SpawnIdentityWorker(state.identity, realmID, bot->GetGUIDLow());" "identity worker")
require("${fn}" "return;   // no seed yet, so no profile yet" "no profile without the uuid seed")
require("${fn}" "SpawnPersonalityWorker(exchange, request);" "profile worker")
string(FIND "${fn}" "SpawnIdentityWorker(" id_at)
string(FIND "${fn}" "SpawnPersonalityWorker(" pers_at)
if(NOT id_at LESS pers_at)
  message(FATAL_ERROR "personality-only contract: the identity must come before the profile (the uuid is the seed)")
endif()
foreach(planning "Snapshot" "g_pendingBatch" "SpawnBatchWorker" "DispatchBatch" "state.phase" "nextRequestMs" "AddStrategy" "ReconcileStrategies")
  forbid("${fn}" "${planning}" "planning machinery in ResolvePersonalityOnly")
endforeach()

message(STATUS "bot_brain_personality_only_contract: ok")
