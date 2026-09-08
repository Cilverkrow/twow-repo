# mod-bot-brain -- unit test suite.
#
# Included from the ROOT CMakeLists.txt under BUILD_TESTING, deliberately NOT
# from mod-bot-brain.cmake: that file is only read when the module's linkage is
# not "disabled" (modules/CMakeLists.txt), which would make this target
# un-buildable in exactly the configuration a test run uses, and it is read
# twice per configure, which would define the target twice.
#
# The suite compiles ONE module source: BotBrainWire.cpp. That is not a subset
# chosen for convenience -- the wire layer is the only part of this module that
# is hermetic by construction (it includes <cstdint>, <string>, <vector> and
# rapidjson, and nothing else), and keeping it that way is what makes the
# contract testable without a world server, a database or a bot.
#
# Everything else in the module needs a live Player, a PlayerbotAI and
# sTravelMgr, and belongs to the runtime half.

set(BB_MODULE_DIR "${TW_MODULES_DIR}/mod-bot-brain")

add_executable(bot_brain_wire_tests
  "${BB_MODULE_DIR}/t/bot_brain_wire_tests.cpp"
  "${BB_MODULE_DIR}/src/BotBrainWire.cpp")

target_include_directories(bot_brain_wire_tests PRIVATE
  "${BB_MODULE_DIR}/src"
  "${TW_CORE_ROOT}/dep/include")

# Where the golden fixtures live, baked in rather than searched for at runtime.
#
# A test that cannot find its fixtures must FAIL, not quietly pass having
# checked nothing - which is exactly what a relative path plus a
# WORKING_DIRECTORY would risk the first time someone runs the binary by hand.
target_compile_definitions(bot_brain_wire_tests PRIVATE
  BB_GOLDEN_DIR="${CMAKE_SOURCE_DIR}/contracts/bot-brain/v1/golden")

set_target_properties(bot_brain_wire_tests PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")

add_test(NAME bot_brain_wire
  COMMAND bot_brain_wire_tests
  WORKING_DIRECTORY "${CMAKE_BINARY_DIR}")

# ---------------------------------------------------------------------------
# Personality profile selection (personality-context-contract-v1, sections 4.1
# and 9).
#
# Header-only, so there is no module source to compile and nothing to link:
# PersonalityPolicy.h is a pure decision function over a generated catalog,
# deliberately free of Player, PlayerbotAI and the database, in the same spirit
# as the wire suite above. It does not need dep/include either -- no rapidjson,
# no fixtures, no golden directory -- because everything it decides, it decides
# from its arguments.
add_executable(personality_policy_tests
  "${BB_MODULE_DIR}/t/personality_policy_tests.cpp")

target_include_directories(personality_policy_tests PRIVATE
  "${BB_MODULE_DIR}/src")

set_target_properties(personality_policy_tests PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")

add_test(NAME personality_policy
  COMMAND personality_policy_tests
  WORKING_DIRECTORY "${CMAKE_BINARY_DIR}")
