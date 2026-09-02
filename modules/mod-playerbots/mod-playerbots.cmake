# ---------------------------------------------------------------------------
# mod-playerbots -- ike3's cmangos playerbots tree, vendored.
#
# This was `src/modules/PlayerBots`, a second module system living beside the
# real one: its own BUILD_PLAYERBOTS option, its own CMakeLists.txt with twenty
# hand-written file(GLOB)s, and a block of include paths in the ROOT
# CMakeLists.txt. Nothing else in the tree was built that way, so every
# question about how a module is added had two answers.
#
# It is a module now. The visible payoff is next door: mod-dungeon-clear
# subclasses these classes and used to reach them through 25 hand-written
# include directories, because a module cannot see inside a non-module. Those
# are gone -- CollectModuleIncludeDirectories publishes every directory under
# src/ that holds a header, and linking the target carries them across.
#
# STATIC ONLY, for three reasons worth stating because none of them is "C++
# forbids it":
#
# 1. The core's seam is resolved by the LINKER, not by dlopen. game.a calls
#    eleven free functions -- World::InitPlayerbotsAtStartup(), four chat
#    commands, and six BotActionLog_* probes compiled into Unit.cpp and
#    Spell.cpp -- and src/game/PlayerbotStubs.cpp supplies no-op versions
#    whenever this module is off. Build this as a .so and game.a still links
#    those stubs, so the stubs are what the core calls. The result is a server
#    with no bots and no error anywhere.
# 2. The framework has no way for one module to depend on another.
#    mod-dungeon-clear subclasses this module's strategy, action, trigger and
#    value classes. DynamicModules.cpp dlopens with RTLD_GLOBAL, so on Linux
#    that could in principle resolve -- but only if mod-playerbots happens to
#    load first, and load order is a config list with no dependency resolution
#    behind it. A failure that depends on alphabetical order is not a design.
# 3. Windows has no equivalent at all: a DLL exports only what is marked
#    __declspec(dllexport), and the vendored tree marks nothing.
#
# Keeping the free-function seam is deliberate rather than unfinished: six of
# the eleven symbols are diagnostic probes, and six entries in ScriptObjects.h
# to relocate logging would buy nothing.
# ---------------------------------------------------------------------------

if(TORTOISE_CURRENT_MODULE_LINKAGE STREQUAL "dynamic")
  message(FATAL_ERROR
    "mod-playerbots cannot be built dynamically: mod-dungeon-clear subclasses "
    "its strategy/action/trigger/value classes and must link into the same "
    "library. Configure with -DMODULE_MOD_PLAYERBOTS=static.")
endif()

# Everything below configures the module's target, so it only runs once the
# targets exist. This file is included twice per configure -- DISCOVERY and
# POST_TARGETS -- and an early return() would be the obvious way to say that,
# but it reads as "stop processing the includer" to anyone skimming, and the
# includer here is a foreach over every module. An if() cannot be misread.
if(TORTOISE_MODULE_CMAKE_PHASE STREQUAL "POST_TARGETS")

GetModuleProjectName("${TORTOISE_CURRENT_MODULE}" PB_TARGET)

# Vendor-tree feature gates the playerbots source expects:
#   CMANGOS           - selects the cmangos codepath in the vendored headers
#                       (vs. the TrinityCore / MaNGOS-Zero alternates). Penqle's
#                       project is named "TurtleWoW", so none of the vendored
#                       expansion checks fire on their own.
#   MANGOSBOT_ZERO    - Classic (1.12). Switches level caps, talent trees and
#                       spell ranges. MANGOSBOT_ONE is TBC, _TWO is WotLK.
#   ENABLE_PLAYERBOTS - turns the subsystem on inside the vendor's own ifdefs.
#
# PRIVATE, which is how the root CMakeLists had it. It is worth knowing that
# this means mod-dungeon-clear compiles these same headers WITHOUT the three
# macros, so the two see different definitions of anything behind them. That
# predates the move and is not changed by it; making them PUBLIC would alter
# how mod-dungeon-clear compiles and needs its own verification.
target_compile_definitions(${PB_TARGET} PRIVATE CMANGOS MANGOSBOT_ZERO ENABLE_PLAYERBOTS)

# The module reaches for nine Boost libraries; two of them, filesystem and
# thread, are compiled rather than header-only. find_package used to run only
# in the non-Windows branch, so on Windows nothing located Boost at all while
# botpch.h includes boost/algorithm/string.hpp unconditionally.
find_package(Boost 1.70 REQUIRED COMPONENTS thread filesystem system)
# ...before the include directories below name Boost_INCLUDE_DIRS, which
# find_package is what sets. Listing it first would have quietly contributed an
# empty string -- unnoticed on Debian, where Boost sits in /usr/include, and a
# hard failure anywhere it does not.

# Core paths the vendored headers reach for that MODULES_COMMON_INCLUDES does
# not already carry. PUBLIC, because a module that links this one compiles
# these headers too.
target_include_directories(${PB_TARGET} PUBLIC
  # The stubs root, which the framework does not publish on its own.
  # CollectModuleIncludeDirectories adds the module's src/ plus every directory
  # UNDER it that holds a header -- so cmangos-compat-stubs/Spells is on the
  # path but cmangos-compat-stubs is not, because no header sits directly in
  # it. The vendored sources include these as "Spells/SpellEffectDefines.h",
  # "World/WorldState.h" and "AI/ScriptDevAI/ScriptDevAIMgr.h", which need the
  # root. That is the general shape of the trap: a module whose includes are
  # subdirectory-qualified has to name the directory those paths are relative
  # to.
  # The module ROOT, which holds botpch.h and cmangos-compat-shim.h. They sit
  # here rather than under src/ because upstream keeps them here, and every
  # needless difference is a conflict on every future merge. The framework's
  # CollectModuleIncludeDirectories only walks src/, so the root has to be
  # named explicitly or nothing can resolve "botpch.h".
  ${CMAKE_CURRENT_LIST_DIR}
  ${CMAKE_CURRENT_LIST_DIR}/src/cmangos-compat-stubs
  ${TW_CORE_ROOT}/src/game/MapNodes
  ${TW_CORE_ROOT}/src/game/PacketBroadcast
  ${TW_CORE_ROOT}/src/shared/Config
  ${TW_CORE_ROOT}/src/shared/Database
  ${TW_CORE_ROOT}/src/shared/Log
  ${TW_CORE_ROOT}/src/shared/Util
  ${TW_CORE_ROOT}/dep/recastnavigation
  ${TW_CORE_ROOT}/dep/include
  ${TW_CORE_ROOT}/dep/include/g3dlite
  # ACE_ROOT and BOOST_ROOT are only the hints a builder may pass in; the paths
  # find_package actually resolved are ACE_INCLUDE_DIR and Boost_INCLUDE_DIRS.
  # Without the resolved ones this target gets no ACE include path whenever ACE
  # was found any other way -- unnoticed on Linux, where ACE sits in
  # /usr/include, and a hard failure on Windows.
  ${ACE_ROOT}
  ${ACE_INCLUDE_DIR}
  ${BOOST_ROOT}
  ${Boost_INCLUDE_DIRS}
)

if(WIN32)
  target_include_directories(${PB_TARGET} PUBLIC
    ${TW_CORE_ROOT}/dep/windows/include
    ${TW_CORE_ROOT}/dep/windows/include/mysql
  )
endif()

target_link_libraries(${PB_TARGET}
  PRIVATE shared
  PRIVATE Detour
  PRIVATE g3dlite
  PRIVATE Boost::thread
  PRIVATE Boost::filesystem
  PRIVATE Boost::system
)

if(WIN32)
  target_link_libraries(${PB_TARGET} PRIVATE zlib PRIVATE ws2_32)
else()
  target_link_libraries(${PB_TARGET} PRIVATE ZLIB::ZLIB)
endif()

if(MSVC)
  # Constrain the MSVC inliner on this module only.
  #
  # The vendored tree is very heavily templated (Strategy/Action queues,
  # Singleton<> instantiations, the storage proxies in cmangos-compat-shim.h),
  # and MSVC's default /Ob2 -- auto-inline anything the heuristic likes -- can
  # ICE the optimizer with C1001 in xhash / vector / type_traits while expanding
  # those instantiations during phase-2 codegen.
  #
  # /Ob1 honours only explicit `inline` / `__forceinline`, so it keeps /O2 speed
  # and simply does not auto-inline ordinary functions. Costs an estimated 3-5%
  # of bot-AI tick performance; buys a module that builds deterministically.
  target_compile_options(${PB_TARGET} PRIVATE $<$<CONFIG:Release>:/Ob1>)
endif()

if(USE_PCH)
  target_precompile_headers(${PB_TARGET} PRIVATE ${CMAKE_CURRENT_LIST_DIR}/botpch.h)
endif()

set_target_properties(${PB_TARGET} PROPERTIES PROJECT_LABEL "PlayerBots")

# Config templates.
#
# The expansion used to be chosen by project name with no default, and this
# project is called TurtleWoW, so none of the three names matched and
# aiplayerbot.conf.dist was never generated -- on any platform -- while the
# install(FILES) below named it unconditionally, so `cmake --install` failed for
# everyone. It stayed hidden because the server is normally run straight out of
# the build tree. Vanilla is the default now rather than a third named case.
if(${CMAKE_PROJECT_NAME} MATCHES "TBC")
  set(PB_CONF_TEMPLATE playerbot/aiplayerbot.conf.dist.in.tbc)
elseif(${CMAKE_PROJECT_NAME} MATCHES "WoTLK")
  set(PB_CONF_TEMPLATE playerbot/aiplayerbot.conf.dist.in.wotlk)
else()
  set(PB_CONF_TEMPLATE playerbot/aiplayerbot.conf.dist.in)
endif()
configure_file(
  "${CMAKE_CURRENT_LIST_DIR}/src/${PB_CONF_TEMPLATE}"
  "${CMAKE_BINARY_DIR}/aiplayerbot.conf.dist")

# AhBotConfig.cpp reads SYSCONFDIR"ahbot.conf", but this template was never
# generated or installed, so AHBot could not be switched on from a clean install
# at all -- it logged that it could not open the file and stayed off.
configure_file(
  "${CMAKE_CURRENT_LIST_DIR}/src/ahbot/ahbot.conf.dist.in"
  "${CMAKE_BINARY_DIR}/ahbot.conf.dist")

if(NOT CONF_INSTALL_DIR)
  set(CONF_INSTALL_DIR ${CONF_DIR})
endif()
install(FILES
  "${CMAKE_BINARY_DIR}/aiplayerbot.conf.dist"
  "${CMAKE_BINARY_DIR}/ahbot.conf.dist"
  DESTINATION ${CONF_INSTALL_DIR})

endif()
