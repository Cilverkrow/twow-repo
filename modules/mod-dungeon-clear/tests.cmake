# mod-dungeon-clear — unit test suites.
#
# Included from the ROOT CMakeLists.txt when BUILD_TESTING is ON, deliberately
# NOT from mod-dungeon-clear.cmake. The module .cmake is only read when the
# module's linkage is not "disabled" (modules/CMakeLists.txt), so tests defined
# there could not be built in the default configuration — the one CI uses. It is
# also included twice per configure (DISCOVERY and POST_TARGETS phases), which
# would have defined every target twice.
#
# The old `dungeon_clear_tests` target could never have been built at all: it
# linked gtest_main, gmock_main and game-interface and compiled
# src/test/mocks/TestMap.cpp — googletest was fetched nowhere in this tree,
# game-interface is an AzerothCore target that does not exist here, and
# src/test/ does not exist. ctest consequently discovered zero tests.
#
# ---------------------------------------------------------------------------
# Why there are two targets, and why the fast one is a SUBSET
# ---------------------------------------------------------------------------
# The test .cpp files are almost all hermetic: they reach at most a few LEAF
# core headers (Errors.h, Common.h, SharedDefines.h, ObjectGuid.h, the spline
# and movemap headers) and no core code. But a test binary also has to compile
# the module .cpp files it links against, and half of THOSE are not hermetic —
# they include Player.h, Map.h, ObjectMgr.h, PlayerbotAI.h and only compile with
# src/AcCompat.h force-included, which pulls in the entire core and the
# playerbot tree.
#
# So the fast target is exactly the largest closed component of the module's
# link graph that needs no core archive. That set was not guessed: it was
# computed by compiling everything and then iteratively pruning every object
# with an unresolved reference until the link succeeded. Measured result — 565
# assertions across 65 suites, all passing, in 13ms.
#
# The excluded tests are excluded for a REASON, not by oversight, and each falls
# into one of three groups:
#
#  1. Needs a core-coupled module source. TestRoomAggro, TestNavGeometry,
#     TestSplineWindow, TestDungeonEvent, TestEventRegistry, TestDifficultyGate,
#     TestScriptedPull, TestSocialQuarantine, TestPullDecisions, TestBossRoster,
#     TestBossPullback, TestDcDiagSnapshot, TestTestDungeonRegistry,
#     TestTestGearTiers, TestTestRunRecord, TestTestRunLiveJson,
#     TestTestPlanSummary, and the Tier-2 nav probes (TestAzjolNerubRouteProbe,
#     TestRampartsLedgeProbe, TestMechanarElevatorProbe, with NavHarness.cpp)
#     all pull in DcEngageGeometry / DungeonPathFollower / LongRangePathfinder /
#     DungeonEventExecutor / DungeonClearRouteRegistry / ObjectiveHookRegistry /
#     DcStrategyGate / DcDiagSnapshot / DcTestDungeonRegistry, which are the
#     module's live-server half. They belong to a target that links game and
#     playerbots; getting them there is a porting job, not build wiring.
#
#  2. Unported AzerothCore test code — see the two notes further down.
#
#  3. TestDcZoneLine, which genuinely needs libgame — the full target below.
# ---------------------------------------------------------------------------

set(DC_MOD_PATH "${CMAKE_CURRENT_LIST_DIR}")

# The module's own implementation files that the fast suite exercises. Explicit,
# not GLOBbed: the whole point of this target is that it does NOT drag in the
# module code that talks to a live server, and a glob would silently re-add it.
set(DC_TEST_MODULE_SOURCES
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Data/BossPullbackRegistry.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Data/DcHazardRegistry.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Data/DcNavPenaltyRegistry.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Data/DcNeverTargetRegistry.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Data/DcSocialQuarantineRegistry.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Data/FightInPlaceRegistry.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Data/RoomAggroRegistry.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Data/RouteSweepRegistry.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Data/SealedEncounterRegistry.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Util/DcPullDecision.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Util/DcPullDecisionIo.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Util/DcRegroupDecision.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Util/DcRouteFilter.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Util/DcSmartRestDecision.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Util/DcWaitAtBossDecision.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Util/DungeonClearApproach.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Util/DungeonClearApproachIo.cpp"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Util/DungeonClearMath.cpp"
    "${DC_MOD_PATH}/src/TestRun/DcTestComp.cpp"
    "${DC_MOD_PATH}/src/TestRun/DcTestGearTiers.cpp"
    "${DC_MOD_PATH}/src/TestRun/DcTestPlan.cpp"
    "${DC_MOD_PATH}/src/TestRun/DcTestRoster.cpp"
    "${DC_MOD_PATH}/src/TestRun/DcTestRunSelect.cpp"
    "${DC_MOD_PATH}/src/TestRun/DcTestRunVerdict.cpp"
    "${DC_MOD_PATH}/src/TestRun/DcWipeContext.cpp"
    "${DC_MOD_PATH}/src/Util/DcWatchHop.cpp"
)

set(DC_TEST_FAST_SOURCES
    "${DC_MOD_PATH}/t/TestApproachDecisions.cpp"
    "${DC_MOD_PATH}/t/TestBossOrdering.cpp"
    "${DC_MOD_PATH}/t/TestCombatRegroup.cpp"
    "${DC_MOD_PATH}/t/TestDcHazard.cpp"
    "${DC_MOD_PATH}/t/TestDoorPolicy.cpp"
    "${DC_MOD_PATH}/t/TestDungeonClearApproach.cpp"
    "${DC_MOD_PATH}/t/TestDungeonClearMath.cpp"
    "${DC_MOD_PATH}/t/TestFactionEntrySwap.cpp"
    "${DC_MOD_PATH}/t/TestFightInPlace.cpp"
    "${DC_MOD_PATH}/t/TestHealReposition.cpp"
    "${DC_MOD_PATH}/t/TestNavPenalty.cpp"
    "${DC_MOD_PATH}/t/TestNeverTarget.cpp"
    "${DC_MOD_PATH}/t/TestPostCombatRez.cpp"
    "${DC_MOD_PATH}/t/TestRelevanceLadder.cpp"
    "${DC_MOD_PATH}/t/TestScenarioDriver.cpp"
    "${DC_MOD_PATH}/t/TestSealedEncounter.cpp"
    "${DC_MOD_PATH}/t/TestSettingsRegistry.cpp"
    "${DC_MOD_PATH}/t/TestSmartRest.cpp"
    "${DC_MOD_PATH}/t/TestStrandedRecovery.cpp"
    "${DC_MOD_PATH}/t/TestStrategyGate.cpp"
    "${DC_MOD_PATH}/t/TestTestComp.cpp"
    "${DC_MOD_PATH}/t/TestTestPlanSchedule.cpp"
    "${DC_MOD_PATH}/t/TestTestRoster.cpp"
    "${DC_MOD_PATH}/t/TestTestRunSelect.cpp"
    "${DC_MOD_PATH}/t/TestTestRunVerdict.cpp"
    "${DC_MOD_PATH}/t/TestWaitAtBoss.cpp"
    "${DC_MOD_PATH}/t/TestWatchHop.cpp"
    "${DC_MOD_PATH}/t/TestWipeContext.cpp"
    "${DC_MOD_PATH}/t/replay_decisions.cpp"
    "${DC_MOD_PATH}/t/replay_pull.cpp"
)

add_executable(dungeon_clear_tests_fast
    ${DC_TEST_FAST_SOURCES}
    ${DC_TEST_MODULE_SOURCES}
)

# MODULES_COMMON_INCLUDES is the exact header search path the shipping module
# compiles against (published as a cache entry by modules/CMakeLists.txt). The
# tests must resolve the same headers as the code under test; the core headers
# they do reach are leaves, so this costs an include path, not a link edge.
target_include_directories(dungeon_clear_tests_fast PRIVATE
    ${MODULES_COMMON_INCLUDES}
    "${DC_MOD_PATH}/src"
    "${DC_MOD_PATH}/src/compat"
    "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Util"
    "${DC_MOD_PATH}/t"
    # Log.h -> Util.h -> "fmt/format.h". dep/fmt is a real target in the server
    # build; the tests need only its headers.
    "${CMAKE_SOURCE_DIR}/dep/fmt/include"
    ${Boost_INCLUDE_DIRS}
)

# Force-include the test prelude, mirroring what the shipping module does with
# AcCompat.h but with a fraction of its reach — see DcTestPrelude.h for why the
# module's headers need it and why AcCompat.h itself cannot be used here.
if(MSVC)
    target_compile_options(dungeon_clear_tests_fast PRIVATE
        "/FI${DC_MOD_PATH}/t/DcTestPrelude.h")
else()
    target_compile_options(dungeon_clear_tests_fast PRIVATE
        "SHELL:-include ${DC_MOD_PATH}/t/DcTestPrelude.h")
endif()

# DC_FIXTURE_DIR: the replay runner reads captured-decision fixtures from the
# source tree (the binary runs from the build dir).
# DC_MAPDATA_DIR: points the Tier-2 navmesh suite at a sliced mmaps directory.
# Client-derived map data is never committed, so it is normally absent and those
# cases GTEST_SKIP.
target_compile_definitions(dungeon_clear_tests_fast PRIVATE
    DC_FIXTURE_DIR="${DC_MOD_PATH}/t/fixtures"
    DC_MAPDATA_DIR="${DC_MOD_PATH}/t/fixtures/mapdata"
)

# Same MSVC math-macro ordering trap the module sources hit — see the long note
# at the top of mod-dungeon-clear.cmake. Empty value on purpose (C4005).
if(MSVC)
    target_compile_options(dungeon_clear_tests_fast PRIVATE /D_USE_MATH_DEFINES=)
endif()

# Detour: DcRouteFilter derives a dtQueryFilter. It is a small standalone static
# library, not part of game.
target_link_libraries(dungeon_clear_tests_fast PRIVATE
    gtest_main
    gmock_main
    Detour
)

set_target_properties(dungeon_clear_tests_fast PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
)

add_test(NAME dungeon_clear_fast
         COMMAND dungeon_clear_tests_fast
         WORKING_DIRECTORY "${CMAKE_BINARY_DIR}")

# ---------------------------------------------------------------------------
# Full suite: the tests that instantiate real core types.
#
# TestDcZoneLine builds AreaTrigger (AreaTriggerEntry) values and calls
# DcZoneLine, whose .cpp reaches ObjectMgr and Player — so it needs libgame, not
# just the core headers.
#
# Off by default: this target's link dependency is the entire server, and a
# -DBUILD_TESTING=ON build that only wants the fast suite should not have to
# compile libgame first.
#
# TWO tests are in neither target, because they are unported AzerothCore test
# code rather than anything the build can arrange:
#
#   TestDungeonClearUtil.cpp includes "WorldMock.h", "TestMap.h" and eight
#   "ScriptDefines/*.h" headers. None of them exist anywhere in this tree — they
#   are AzerothCore's test scaffolding, along with the game-interface target
#   and src/test/mocks/TestMap.cpp that the old target named.
#
#   TestDcProgressWatchdog.cpp names ObjectGuid::LowType (no such member type
#   here; it is a plain uint32) and HighGuid::GameObject (this core's HighGuid
#   is an unscoped enum whose enumerator is HIGHGUID_GAMEOBJECT). The code under
#   test, DcApproachState::ObserveDoorStall, compiles here fine — only the test
#   needs porting.
# ---------------------------------------------------------------------------
option(BUILD_DUNGEON_CLEAR_FULL_TESTS
       "Build the dungeon-clear tests that link the game core (implies building libgame)" OFF)

if(BUILD_DUNGEON_CLEAR_FULL_TESTS AND TARGET game)
    add_executable(dungeon_clear_tests_full
        "${DC_MOD_PATH}/t/TestDcZoneLine.cpp"
        "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Util/DcZoneLine.cpp"
        "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Util/DungeonClearMath.cpp"
    )

    target_include_directories(dungeon_clear_tests_full PRIVATE
        ${MODULES_COMMON_INCLUDES}
        "${DC_MOD_PATH}/src"
        "${DC_MOD_PATH}/src/compat"
        "${DC_MOD_PATH}/src/Ai/Dungeon/DungeonClear/Util"
        "${DC_MOD_PATH}/t"
        "${CMAKE_SOURCE_DIR}/dep/fmt/include"
        ${Boost_INCLUDE_DIRS}
    )

    if(MSVC)
        target_compile_options(dungeon_clear_tests_full PRIVATE
            "/FI${DC_MOD_PATH}/t/DcTestPrelude.h" /D_USE_MATH_DEFINES=)
    else()
        target_compile_options(dungeon_clear_tests_full PRIVATE
            "SHELL:-include ${DC_MOD_PATH}/t/DcTestPrelude.h")
    endif()

    target_link_libraries(dungeon_clear_tests_full PRIVATE
        gtest_main
        gmock_main
        game
    )

    set_target_properties(dungeon_clear_tests_full PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    )

    add_test(NAME dungeon_clear_full
             COMMAND dungeon_clear_tests_full
             WORKING_DIRECTORY "${CMAKE_BINARY_DIR}")
elseif(BUILD_DUNGEON_CLEAR_FULL_TESTS)
    message(WARNING "BUILD_DUNGEON_CLEAR_FULL_TESTS is ON but there is no game target in this configuration; skipping dungeon_clear_tests_full")
endif()
