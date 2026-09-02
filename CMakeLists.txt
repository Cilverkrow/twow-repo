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
# This file used to BE the server core's CMakeLists.txt, with the module
# framework spliced into it, and src/game and src/shared next to it were a
# second copy of files that also live in twow-core. That is what this change
# ends: the core is the `core/` submodule now, and there is exactly one copy of
# every core source in the tree.
#
# It is a SHORT file, and that is the design rather than an omission. The core
# already owns everything about building a server, the module framework
# included -- upstream grew one of its own and twow-core tracks it. So the
# platform has three pieces of policy and nothing else:
#
#   1. point the core's module framework at THIS repository's modules/
#   2. add_subdirectory(core)
#   3. add the module test suites, which live beside a module but must not be
#      owned by it
#
# Everything else -- compilers, dependencies, mangosd, realmd, install rules,
# the `modules` library and linking it into mangosd -- happens inside core/.
# ===========================================================================

cmake_minimum_required(VERSION 3.16...3.29)

# Named for what it builds. The core keeps `project(TurtleWoW)` of its own, and
# mod-playerbots.cmake branches on CMAKE_PROJECT_NAME to pick a config template
# ("TBC"/"WoTLK"/else vanilla) -- so this name has to keep failing both of those
# matches, exactly as "TurtleWoW" did.
project(TurtleWoWPlatform)

# The submodule has to actually be there. Without this the first symptom is
# "add_subdirectory given source core which is not an existing directory",
# which tells a first-time cloner nothing about what they left out. Recursive
# matters as much as the init: the core carries the Eluna engine as a submodule
# of its own and BUILD_ELUNA, which defaults ON, FATAL_ERRORs without it.
if(NOT EXISTS "${CMAKE_SOURCE_DIR}/core/CMakeLists.txt")
  message(FATAL_ERROR
    "core/ is empty. This repository consumes twow-core as a git submodule "
    "(ADR-0020); run `git submodule update --init --recursive` and configure again.")
endif()

# ---------------------------------------------------------------------------
# 1. Which modules get built.
#
# TW_MODULES_DIR is the core's one input on this subject: it defaults to the
# core's own modules/ and is FORCEd here to ours. One directory wins, whole --
# the two are not merged, and core/modules/ is not built.
#
# Ours wins because it is the superset and the maintained one: four modules the
# core's copy does not have (mod-donation, mod-leech, mod-solo-dungeon,
# mod-worldbuff -- all four extracted out of World.cpp and Unit.cpp here), the
# persistent-active-roster feature in mod-playerbots, and every test suite.
# tests.cmake exists only on this side, so consuming the core's copy would mean
# `ctest` finding nothing. Our modules/CMakeLists.txt is also ahead: one static
# target per module, so a module's compile options stop leaking into every
# other module's translation units.
#
# core/modules/ stays where it is rather than being deleted, and that is a
# deliberate reversal of an earlier "pure core" rule: upstream built a module
# system of its own, so deleting the directory re-wins the same argument on
# every merge and silently drops upstream's framework whenever the delete does
# NOT conflict. See the long note in twow-core's .github/workflows/ci.yml. It
# is inbound upstream content that this build supersedes, not a second live
# copy: nothing under core/modules/ is ever compiled here.
set(TW_MODULES_DIR "${CMAKE_SOURCE_DIR}/modules" CACHE PATH
    "Directory containing the modules to build." FORCE)

# Default `static`, not the core's `disabled`.
#
# Nothing in this tree passes -DMODULES on every path, and with `disabled` a
# build silently ships with no modules at all -- which stopped being merely
# untidy once AutoWorldBuff, AutoDonationPoints, Leech and SoloDungeonRepop
# moved out of the core and became modules. A module exists to be built;
# turning them off is the special case and is asked for explicitly.
set(MODULES "static" CACHE STRING "Module build mode: disabled, static, dynamic, or default.")

# ---------------------------------------------------------------------------
# Testing.
#
# include(CTest) is what calls enable_testing() in the TOP-LEVEL directory, and
# without a top-level enable_testing() `ctest` in the build root discovers
# nothing, however many add_test() calls the subdirectories make. The core
# declares the same option and skips this call when it is not on top, precisely
# so that this one is the one that counts.
option(BUILD_TESTING "Build the unit test suites (googletest is fetched when ON)" OFF)
if(BUILD_TESTING)
  include(CTest)
endif()

# ---------------------------------------------------------------------------
# 2. The core.
add_subdirectory(core)

# ---------------------------------------------------------------------------
# 3. The core's compile settings, re-applied at THIS scope.
#
# This looks redundant and is not. Directory properties and CMAKE_CXX_FLAGS
# flow downwards only, and core/ is BELOW this file: nothing it sets reaches a
# target declared here. The module test suites in step 4 are declared here, and
# they compile core headers.
#
# Miss this and they compile without DO_MYSQL, without SYSCONFDIR, and -- worst,
# because it links clean and says nothing -- without DT_VIRTUAL_QUERYFILTER,
# which decides whether dtQueryFilter::getCost is virtual. A test binary that
# disagrees with libDetour about that is exercising a different class than the
# one that ships.
#
# set_property(... PROPERTY ...) REPLACES the directory's COMPILE_DEFINITIONS,
# so this has to be the first thing at this scope that touches them.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_FLAGS "${TW_CORE_CXX_FLAGS}")
set_property(DIRECTORY PROPERTY COMPILE_DEFINITIONS ${TW_CORE_DEFINITIONS})
set_property(DIRECTORY APPEND PROPERTY
  COMPILE_DEFINITIONS $<$<CONFIG:Debug>:${TW_CORE_DEFINITIONS_DEBUG}>
)
set_property(DIRECTORY APPEND PROPERTY
  COMPILE_DEFINITIONS $<$<CONFIG:Release>:${TW_CORE_DEFINITIONS_RELEASE}>
)

# ---------------------------------------------------------------------------
# 4. Test suites that live beside a module but must not be tied to it.
#
# modules/<name>/<name>.cmake is only included when that module's linkage is not
# "disabled", so putting the test targets there made them un-buildable in the
# default configuration - exactly the configuration CI wants to run tests in.
# The suite is source-level: it compiles the module's own .cpp files directly,
# so it needs the sources on disk, not the `modules` library.
if(BUILD_TESTING)
  include("${CMAKE_SOURCE_DIR}/modules/mod-bot-brain/tests.cmake")
  include("${CMAKE_SOURCE_DIR}/modules/mod-dungeon-clear/tests.cmake")
  include("${CMAKE_SOURCE_DIR}/modules/mod-playerbots/tests.cmake")
endif()
