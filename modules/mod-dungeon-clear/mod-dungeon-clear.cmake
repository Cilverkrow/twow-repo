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
if (MSVC AND TORTOISE_MODULE_CMAKE_PHASE STREQUAL "POST_TARGETS")
    # GetModuleProjectName lowercases and maps every non [a-z0-9_] character to
    # an underscore, so this module's target is mod_mod_dungeon_clear - not
    # mod_mod-dungeon-clear, which was named here and therefore never matched.
    # Ask for the name instead of spelling it.
    GetModuleProjectName("${TORTOISE_CURRENT_MODULE}" DC_TARGET)
    target_compile_options(${DC_TARGET} PRIVATE /D_USE_MATH_DEFINES=)
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
# Reach mod-playerbots.
#
# This module subclasses the bot tree's strategy, action, trigger and value
# classes, so it compiles their headers and links their objects.
#
# It used to say so in 25 hand-written include directories plus a link, applied
# to the shared `modules` target, because the bot tree was not a module and a
# module cannot see inside a non-module. It is one now, so linking its target is
# the whole statement: CollectModuleIncludeDirectories publishes every directory
# under modules/mod-playerbots/src that holds a header, PUBLIC on that target,
# and CMake carries them here.
#
# AcCompat.h -- the AzerothCore-to-Penqle name and type shim -- is force-included
# ahead of everything, because the names it maps appear in the upstream headers
# themselves, not only in code we could edit. PRIVATE and on this module's own
# target: the shim renames types that appear in the CORE headers too, so
# applying it anywhere else changes how unrelated code sees the core.
# ---------------------------------------------------------------------------

if(TORTOISE_MODULE_CMAKE_PHASE STREQUAL "POST_TARGETS")
  GetModuleProjectName("${TORTOISE_CURRENT_MODULE}" DC_TARGET)
  GetModuleProjectName("mod-playerbots" DC_PLAYERBOTS_TARGET)

  if(NOT TARGET ${DC_PLAYERBOTS_TARGET})
    message(FATAL_ERROR
      "mod-dungeon-clear derives from mod-playerbots classes and cannot be built "
      "without it. Enable it (-DMODULE_MOD_PLAYERBOTS=static) or disable this "
      "module (-DMODULE_MOD_DUNGEON_CLEAR=disabled).")
  endif()

  target_link_libraries(${DC_TARGET} PUBLIC ${DC_PLAYERBOTS_TARGET})

  if(MSVC)
    target_compile_options(${DC_TARGET} PRIVATE
      /FI${CMAKE_CURRENT_LIST_DIR}/src/AcCompat.h)
  else()
    target_compile_options(${DC_TARGET} PRIVATE
      -include ${CMAKE_CURRENT_LIST_DIR}/src/AcCompat.h)
  endif()
endif()
