# Copyright (C) 2005-2011 MaNGOS <http://getmangos.com/>
# Copyright (C) 2009-2011 MaNGOSZero <https://github.com/mangos/zero>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

# ===========================================================================
# The platform build (ADR-0020, ADR-0025).
#
# This file used to BE the core's CMakeLists.txt, with the module framework
# spliced into it. The core is now a submodule at core/ that configures and
# builds on its own -- `cmake -S core -B build-core` is a supported, tested
# arrangement -- and everything that knows the word "module" lives here.
#
# The order below is the whole design and is not interchangeable:
#
#   1. discover modules      pure directory globbing; needs no target and no
#                            compiler, only modules/*/src on disk
#   2. hand the core its inputs   three variables read while core/src/shared is
#                            configured, so they must be set before step 3
#   3. add_subdirectory(core)     builds game/shared/framework/mangosd/realmd and
#                            publishes what a host needs back (LIBS_DIR, the
#                            compile settings, the tw_core_extensions seam)
#   4. re-apply the core's compile settings HERE, because directory properties
#      are inherited by children and core/ is a sibling of modules/, not its
#      parent
#   5. add_subdirectory(modules)  creates one target per module and the loader
#   6. attach the loader to the seam
#
# Step 4 is the one that looks redundant and is not: skip it and every module
# translation unit compiles core headers without DO_MYSQL, without SYSCONFDIR
# and -- worst, because it is silent -- without DT_VIRTUAL_QUERYFILTER, which
# changes the layout of dtQueryFilter. That last one links cleanly and produces
# pathfinding that ignores the filters modules install.
# ===========================================================================

cmake_minimum_required(VERSION 3.16...3.29)

# Named for what it builds. The core keeps `project(TurtleWoW)` of its own, and
# mod-playerbots.cmake branches on CMAKE_PROJECT_NAME to pick a config template
# ("TBC"/"WoTLK"/else vanilla) -- so this name has to keep failing both of those
# matches, exactly as "TurtleWoW" did.
project(TurtleWoWPlatform)

set(CMAKE_MODULE_PATH
  ${CMAKE_MODULE_PATH}
  ${CMAKE_SOURCE_DIR}/cmake
)

# The submodule has to actually be there. Without this the first symptom is
# "add_subdirectory given source core which is not an existing directory",
# which does not tell a first-time cloner what they left out.
if(NOT EXISTS "${CMAKE_SOURCE_DIR}/core/CMakeLists.txt")
  message(FATAL_ERROR
    "core/ is empty. This repository consumes twow-core as a git submodule "
    "(ADR-0020); run `git submodule update --init --recursive` and configure again.")
endif()

# ---------------------------------------------------------------------------
# 1. Module discovery.
include(ConfigureModules)

set(MODULES "static" CACHE STRING "Module build mode: disabled, static, dynamic, or default.")
ConfigureModuleBuildOptions()

# Unit tests. OFF by default so a normal server build pays nothing for them.
#
# Declared here as well as in the core because include(CTest) only calls
# enable_testing() in the directory that includes it: run it first inside core/
# and `ctest` in the build root finds nothing, however many add_test() calls the
# subdirectories make. Declaring the option before the core is added also keeps
# CTest's own default-ON declaration from winning.
option(BUILD_TESTING "Build the unit test suites (googletest is fetched when ON)" OFF)
if(BUILD_TESTING)
  include(CTest)
endif()

# ---------------------------------------------------------------------------
# 2. What the core is told.
#
# Note what is NOT here: no module name, no linkage mode, no path into
# modules/*/src. The core is told the shape of what is attached, never its
# contents, which is what lets `cmake -S core` remain a working build.
set(TW_EXT_SOURCE_MODULES_DIR "${CMAKE_SOURCE_DIR}/modules")
set(TW_EXT_MODULE_CONFIG_LIST "${TW_MODULE_CONFIG_LIST}")

set(TW_EXT_ENABLED_MODULES)
foreach(SOURCE_MODULE ${MODULES_MODULE_LIST})
  GetModuleEffectiveLinkage("${SOURCE_MODULE}" MODULE_LINKAGE)
  if(NOT MODULE_LINKAGE STREQUAL "disabled")
    list(APPEND TW_EXT_ENABLED_MODULES "${SOURCE_MODULE}")
  endif()
endforeach()

# The two core options that stand in for "somebody else defines these symbols".
# They are separate options because they cover separate symbol sets, and the
# answers genuinely differ: the loader is always supplied from here, the
# playerbot hooks only when that module is present.
#
# Unconditionally ON, including at -DMODULES=disabled: modules/CMakeLists.txt
# always produces the `modules` library, and with nothing enabled its generated
# loader is simply an empty AddModulesScripts(). That is still a definition, so
# the core must still not compile the no-op or the two collide at link time.
set(TW_EXTERNAL_MODULE_LOADER ON CACHE BOOL "" FORCE)

# Membership first, then linkage. GetModuleEffectiveLinkage answers "static" for
# a module that does not exist at all, because an unset MODULE_MOD_* variable is
# indistinguishable from one holding the "default" sentinel -- so asking it
# directly about a checkout with no mod-playerbots in it would suppress
# PlayerbotStubs.cpp and leave eleven symbols undefined at the final link.
list(FIND TW_EXT_ENABLED_MODULES "mod-playerbots" TW_PLAYERBOTS_INDEX)
if(TW_PLAYERBOTS_INDEX EQUAL -1)
  set(TW_EXTERNAL_PLAYERBOT_HOOKS OFF CACHE BOOL "" FORCE)
else()
  set(TW_EXTERNAL_PLAYERBOT_HOOKS ON CACHE BOOL "" FORCE)
endif()

# ---------------------------------------------------------------------------
# 3. The core.
add_subdirectory(core)

# ---------------------------------------------------------------------------
# 4. The core's compile settings, re-applied at this scope.
#
# core/CMakeLists.txt exports these with PARENT_SCOPE precisely so this can
# happen; see the long comment at the bottom of that file for why each one
# matters. Everything added below this line -- modules/, the test suites --
# compiles core headers, and compiling them under a different set of macros than
# the core itself used is at best a link error and at worst an ODR violation.
#
# DT_VIRTUAL_QUERYFILTER is inside TW_CORE_DEFINITIONS rather than being spelled
# with its own add_definitions() call above this line, and that is deliberate:
# set_property(... PROPERTY ...) REPLACES the directory's COMPILE_DEFINITIONS,
# so anything add_definitions() contributed beforehand is silently discarded
# here. (The core's own root has exactly that ordering bug; it survives there
# only because the flag is also pushed through CMAKE_CXX_FLAGS on GCC and
# Clang, which is what the comment beside it in core/CMakeLists.txt is about.)
set_property(DIRECTORY PROPERTY COMPILE_DEFINITIONS ${TW_CORE_DEFINITIONS})
set_property(DIRECTORY APPEND PROPERTY
  COMPILE_DEFINITIONS $<$<CONFIG:Debug>:${TW_CORE_DEFINITIONS_DEBUG}>
)
set_property(DIRECTORY APPEND PROPERTY
  COMPILE_DEFINITIONS $<$<CONFIG:Release>:${TW_CORE_DEFINITIONS_RELEASE}>
)

message(STATUS "")
message(STATUS "Platform build")
if(MODULES_MODULE_LIST)
  message(STATUS "Build modules         : ${MODULES}")
  foreach(SOURCE_MODULE ${MODULES_MODULE_LIST})
    ModuleNameToVariable("${SOURCE_MODULE}" MODULE_VARIABLE)
    GetModuleEffectiveLinkage("${SOURCE_MODULE}" MODULE_EFFECTIVE_LINKAGE)
    message(STATUS "  ${SOURCE_MODULE}: ${MODULE_EFFECTIVE_LINKAGE} (${MODULE_VARIABLE}=${${MODULE_VARIABLE}})")
  endforeach()
else()
  message(STATUS "Build modules         : ${MODULES} (no modules found)")
endif()

if(MODULES_DYNAMIC_LINKING_REQUIRED)
  message(STATUS "Module dynamic linking: Required")
else()
  message(STATUS "Module dynamic linking: Not required")
endif()
message(STATUS "")

# ---------------------------------------------------------------------------
# 5. The modules.
add_subdirectory(modules)

# ---------------------------------------------------------------------------
# 6. Attaching them to the core.
#
# tw_core_extensions is an INTERFACE library the core creates and links into
# mangosd; populating it from here is what actually connects the two halves.
# `modules` carries every statically linked module target with it, so one link
# entry is enough.
target_link_libraries(tw_core_extensions INTERFACE modules)

# The three macros DynamicModules.cpp reads. They live on the seam rather than
# in the core because all three describe artifacts this repository produces:
# which shared libraries to dlopen, where they were installed, and the build
# directive each loaded library must report back before it is trusted (a Debug
# module inside a Release server is an ABI mismatch whose crash is otherwise
# unattributable). A standalone core gets DynamicModules.cpp's own #ifndef
# defaults, which are empty strings -- "load nothing".
string(REPLACE ";" "," TW_DYNAMIC_MODULES_CSV "${WORLDSERVER_DYNAMIC_MODULES}")
target_compile_definitions(tw_core_extensions
  INTERFACE
    TW_DYNAMIC_MODULES="${TW_DYNAMIC_MODULES_CSV}"
    TW_MODULES_BUILD_DIRECTIVE="${CMAKE_BUILD_TYPE}"
    TW_DYNAMIC_MODULES_INSTALL_DIR="${MODULES_INSTALL_RUNTIME_DIR}")

# A dynamically linked module is dlopened, not linked, so nothing in the target
# graph would otherwise make it exist before mangosd runs.
if(WORLDSERVER_DYNAMIC_MODULES_DEPENDENCIES)
  add_dependencies(mangosd ${WORLDSERVER_DYNAMIC_MODULES_DEPENDENCIES})
endif()

# ---------------------------------------------------------------------------
# Test suites that live beside a module but must not be tied to it.
#
# modules/<name>/<name>.cmake is only included when that module's linkage is not
# "disabled", so putting the test targets there made them un-buildable in the
# default configuration - exactly the configuration CI wants to run tests in.
# The suite is source-level: it compiles the module's own .cpp files directly,
# so it needs the sources on disk, not the `modules` library.
if(BUILD_TESTING)
  include("${CMAKE_SOURCE_DIR}/modules/mod-dungeon-clear/tests.cmake")
  include("${CMAKE_SOURCE_DIR}/modules/mod-playerbots/tests.cmake")
endif()
