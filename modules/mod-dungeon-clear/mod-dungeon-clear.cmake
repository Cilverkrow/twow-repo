# MSVC: force _USE_MATH_DEFINES onto the compiler command line.
#
# MSVC's <math.h> only defines M_PI (and the rest of the M_* family) when
# _USE_MATH_DEFINES is defined BEFORE math.h is first included; it is #pragma
# once, so setting the macro later has no effect. AzerothCore sets it in
# src/common/Define.h, which works for core translation units because they reach
# Define.h before any standard math header — but a module TU that includes
# <cmath> (directly, or via <algorithm>/<vector>/G3D) before the first core
# header does not, and then every M_PI in that TU is undeclared. That breaks the
# CORE's own headers, not just ours: Position.h::NormalizeOrientation calls
#   std::fmod(o, 2.0f * static_cast<float>(M_PI))
# so the reported "error C2065: 'M_PI': undeclared identifier" is immediately
# followed by the cascade "error C2661: 'fmod': no overloaded function takes 1
# arguments" (the second argument failed to compile, so the call is seen with
# one). Nothing we can do inside our own sources fixes a core header — a
# command-line define is the only ordering-proof place for it.
#
# This file is included from modules/CMakeLists.txt AFTER the targets are
# created, so both linkage modes can be handled here. PRIVATE: it changes how
# these sources compile, nothing downstream. Our own sources additionally avoid
# M_PI entirely (DC_PI in Util/DungeonClearTuning.h), so this is only needed for
# the core headers we include.
# Spelled as a raw /D option rather than target_compile_definitions, and with a
# trailing '=', for one reason: src/common/Define.h line 38 ALSO does
#   #define _USE_MATH_DEFINES
# with an empty replacement list. A bare -D gives the macro the value 1, which is
# a NON-identical redefinition, and MSVC then emits
#   warning C4005: '_USE_MATH_DEFINES': macro redefinition
# once per translation unit — hundreds of lines of noise that bury real
# diagnostics. '/D_USE_MATH_DEFINES=' defines it EMPTY, identical to Define.h's,
# so the redefinition is legal and silent. target_compile_definitions cannot
# express this: CMake escapes "NAME=" into -DNAME="" (verified), which is a value
# of "" and warns just the same.
if (MSVC)
    # GetModuleProjectName lowercases and maps every non [a-z0-9_] character to
    # an underscore, so this module's dynamic target is mod_mod_dungeon_clear -
    # not mod_mod-dungeon-clear, which was named here and therefore never
    # matched. Ask for the name instead of spelling it.
    GetModuleProjectName("${TORTOISE_CURRENT_MODULE}" DC_DYNAMIC_TARGET)
    foreach (DC_MATH_TARGET modules ${DC_DYNAMIC_TARGET})
        if (TARGET ${DC_MATH_TARGET})
            target_compile_options(${DC_MATH_TARGET} PRIVATE /D_USE_MATH_DEFINES=)
        endif()
    endforeach()
endif()

# The unit test suites used to be declared here. They are not any more: this
# file is only included when the module's linkage is not "disabled" (see
# modules/CMakeLists.txt), which made the tests un-buildable in the default
# configuration, and it is included TWICE per configure (DISCOVERY and
# POST_TARGETS phases), which would have defined the targets twice. They now
# live in tests.cmake, included directly from the root CMakeLists.txt under
# BUILD_TESTING.

# The module's CMakeLists.txt was deleted along with them. It called
# AC_ADD_SCRIPT / AC_ADD_CONFIG_FILE - AzerothCore macros that do not exist in
# this tree (the equivalents here are TW_ADD_SCRIPT and the conf/*.conf.dist
# glob in modules/CMakeLists.txt) - and nothing ever included it, so it was
# unreachable dead code that only invited someone to edit the wrong file.

# ---------------------------------------------------------------------------
# Tortoise port: reach the vendored playerbots tree.
#
# Upstream this module sits next to mod-playerbots, both of them AzerothCore
# modules compiled into the same `modules` library, so its includes resolve by
# themselves. Here the bot tree is a separate library under
# src/modules/PlayerBots, so the paths and the link have to be stated.
#
# The directory list mirrors what the bot module puts on its own compile line:
# its root, plus the three Penqle paths its headers reach through
# transitively. AcCompat.h - the AzerothCore-to-Penqle name and type shim -
# lives with the module and is force-included ahead of everything, because the
# names it maps appear in the upstream headers themselves, not only in code we
# could edit.
# ---------------------------------------------------------------------------

if(TORTOISE_MODULE_CMAKE_PHASE STREQUAL "POST_TARGETS")
  target_include_directories(modules
    PUBLIC
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/playerbot
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/playerbot/strategy
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/playerbot/strategy/actions
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/playerbot/strategy/triggers
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/playerbot/strategy/values
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/playerbot/strategy/generic
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/playerbot/strategy/deathknight
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/playerbot/strategy/druid
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/playerbot/strategy/hunter
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/playerbot/strategy/mage
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/playerbot/strategy/paladin
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/playerbot/strategy/priest
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/playerbot/strategy/rogue
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/playerbot/strategy/shaman
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/playerbot/strategy/warlock
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/playerbot/strategy/warrior
      ${CMAKE_SOURCE_DIR}/src/modules/PlayerBots/ahbot
      ${CMAKE_SOURCE_DIR}/src/game/MapNodes
      ${CMAKE_SOURCE_DIR}/src/framework/Network
      ${CMAKE_SOURCE_DIR}/dep/recastnavigation
      ${CMAKE_CURRENT_LIST_DIR}/src
      ${CMAKE_CURRENT_LIST_DIR}/src/compat)

  target_link_libraries(modules PUBLIC playerbots)

  target_compile_options(modules PRIVATE
    -include ${CMAKE_CURRENT_LIST_DIR}/src/AcCompat.h)
endif()
