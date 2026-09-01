GetModuleSourceList(MODULES_MODULE_LIST)

set(MODULES_PUBLIC_INCLUDES)
set(MODULES_STATIC_MODULES)
set(MODULES_STATIC_PROJECTS)
set(MODULES_DYNAMIC_MODULES)
set(MODULES_DYNAMIC_PROJECTS)
set(MODULES_ENABLED_MODULES)

if(MODULES STREQUAL "dynamic")
  set(MODULES_DEFAULT_LINKAGE "dynamic")
elseif(MODULES STREQUAL "static")
  set(MODULES_DEFAULT_LINKAGE "static")
else()
  set(MODULES_DEFAULT_LINKAGE "disabled")
endif()

if(WIN32)
  set(MODULES_BUILD_RUNTIME_DIR "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/modules")
else()
  set(MODULES_BUILD_RUNTIME_DIR "${CMAKE_BINARY_DIR}/modules")
endif()

set(MODULES_INSTALL_RUNTIME_DIR "${LIBS_DIR}/modules")

# Core header search path, rooted at the submodule.
#
# Every entry below used to read ${CMAKE_SOURCE_DIR}/src/..., which was correct
# only while the core and the modules were the same checkout. TW_CORE_ROOT is
# what core/CMakeLists.txt sets to its own directory (CACHE INTERNAL, because
# this directory is the core's SIBLING and inherits nothing from it), so these
# paths resolve to core/src/... here and would resolve to src/... in a
# standalone core build. Nothing in this list is guessed from a relative path:
# if the submodule moves, one variable moves with it.
set(MODULES_COMMON_INCLUDES
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${TW_CORE_ROOT}/src/scripts
  ${TW_CORE_ROOT}/src/shared
  ${TW_CORE_ROOT}/src/framework
  ${TW_CORE_ROOT}/src/framework/Network
  ${TW_CORE_ROOT}/src/game
  ${TW_CORE_ROOT}/src/game/AI
  ${TW_CORE_ROOT}/src/game/Anticheat
  ${TW_CORE_ROOT}/src/game/AuctionHouse
  ${TW_CORE_ROOT}/src/game/Battlegrounds
  ${TW_CORE_ROOT}/src/game/Chat
  ${TW_CORE_ROOT}/src/game/Commands
  ${TW_CORE_ROOT}/src/game/Database
  ${TW_CORE_ROOT}/src/game/Group
  ${TW_CORE_ROOT}/src/game/Guild
  ${TW_CORE_ROOT}/src/game/Handlers
  ${TW_CORE_ROOT}/src/game/LFG
  ${TW_CORE_ROOT}/src/game/Mail
  ${TW_CORE_ROOT}/src/game/Maps
  ${TW_CORE_ROOT}/src/game/Maps/Pool
  ${TW_CORE_ROOT}/src/game/Movement
  ${TW_CORE_ROOT}/src/game/Movement/spline
  ${TW_CORE_ROOT}/src/game/Objects
  ${TW_CORE_ROOT}/src/game/OutdoorPvP
  ${TW_CORE_ROOT}/src/game/Protocol
  ${TW_CORE_ROOT}/src/game/Spells
  ${TW_CORE_ROOT}/src/game/Threat
  ${TW_CORE_ROOT}/src/game/Transports
  ${TW_CORE_ROOT}/src/game/vmap
  ${TW_CORE_ROOT}/dep/include
  ${TW_CORE_ROOT}/dep/recastnavigation
  ${TW_CORE_ROOT}/dep/include/g3dlite
  ${TW_CORE_ROOT}/dep/recastnavigation/Detour/Include
  ${TW_CORE_BINARY_DIR}
  ${TW_CORE_BINARY_DIR}/src/shared
  ${TBB_INCLUDE_DIRS}
  ${ACE_INCLUDE_DIR}
  ${MYSQL_INCLUDE_DIR}
)

# Republished as a cache entry so the out-of-tree test targets (included from
# the ROOT CMakeLists, which never sees this directory's variables) compile
# against exactly the same header search path the shipping module does. A test
# that resolves a different header than the code under test is worse than no
# test at all.
set(MODULES_COMMON_INCLUDES "${MODULES_COMMON_INCLUDES}" CACHE INTERNAL
    "Header search path shared by module targets and their test suites" FORCE)

function(GetModuleProjectName module variable)
  string(TOLOWER "mod_${module}" MODULE_PROJECT_NAME)
  string(REGEX REPLACE "[^a-z0-9_]" "_" MODULE_PROJECT_NAME "${MODULE_PROJECT_NAME}")
  set(${variable} "${MODULE_PROJECT_NAME}" PARENT_SCOPE)
endfunction()

function(GetModuleLoaderFunction module variable)
  string(REGEX REPLACE "[^A-Za-z0-9_]" "_" MODULE_FUNCTION_NAME "${module}")
  set(${variable} "Add${MODULE_FUNCTION_NAME}Scripts" PARENT_SCOPE)
endfunction()

function(GetModuleScopedProperty module_variable property_suffix variable)
  TortoiseGetGlobalProperty("TW_${module_variable}_${property_suffix}" PROPERTY_VALUE)
  set(${variable} ${PROPERTY_VALUE} PARENT_SCOPE)
endfunction()

function(ConfigureModuleLoader loader_name loader_out is_dynamic)
  set(TORTOISE_IS_DYNAMIC_MODULE_LOADER ${is_dynamic})
  set(TORTOISE_CURRENT_MODULE_PROJECT "${loader_name}")
  set(TORTOISE_MODULES_BUILD_DIRECTIVE "${CMAKE_BUILD_TYPE}")
  unset(TORTOISE_MODULES_FORWARD_DECL)
  unset(TORTOISE_MODULES_INVOKE)
  unset(TORTOISE_MODULES_EXTRA_INCLUDES)
  unset(TORTOISE_MODULES_EXTRA_INVOKE)

  unset(TW_ADD_SCRIPTS_INCLUDE)
  unset(TW_ADD_SCRIPTS_LIST)
  foreach(MODULE_NAME ${ARGN})
    ModuleNameToVariable("${MODULE_NAME}" MODULE_VARIABLE)
    GetModuleScopedProperty("${MODULE_VARIABLE}" "ADD_SCRIPTS_INCLUDE" MODULE_SCRIPT_INCLUDES)
    GetModuleScopedProperty("${MODULE_VARIABLE}" "ADD_SCRIPTS_LIST" MODULE_SCRIPT_LOADERS)
    list(APPEND TW_ADD_SCRIPTS_INCLUDE ${MODULE_SCRIPT_INCLUDES})
    list(APPEND TW_ADD_SCRIPTS_LIST ${MODULE_SCRIPT_LOADERS})
  endforeach()
  list(REMOVE_DUPLICATES TW_ADD_SCRIPTS_INCLUDE)

  foreach(TW_SCRIPT_INCLUDE ${TW_ADD_SCRIPTS_INCLUDE})
    set(TORTOISE_MODULES_EXTRA_INCLUDES "${TORTOISE_MODULES_EXTRA_INCLUDES}#include \"${TW_SCRIPT_INCLUDE}\"\n")
  endforeach()

  foreach(TW_SCRIPT_LOADER ${TW_ADD_SCRIPTS_LIST})
    string(REGEX REPLACE ";$" "" TW_SCRIPT_LOADER_CALL "${TW_SCRIPT_LOADER}")
    set(TORTOISE_MODULES_EXTRA_INVOKE "${TORTOISE_MODULES_EXTRA_INVOKE}    ${TW_SCRIPT_LOADER_CALL};\n")
  endforeach()

  foreach(MODULE_NAME ${ARGN})
    GetModuleLoaderFunction("${MODULE_NAME}" MODULE_LOADER_FUNCTION)
    set(TORTOISE_MODULES_FORWARD_DECL "${TORTOISE_MODULES_FORWARD_DECL}void ${MODULE_LOADER_FUNCTION}();\n")
    set(TORTOISE_MODULES_INVOKE "${TORTOISE_MODULES_INVOKE}    ${MODULE_LOADER_FUNCTION}();\n")
  endforeach()

  set(GENERATED_LOADER "${CMAKE_CURRENT_BINARY_DIR}/generated/${loader_name}/ModulesLoader.cpp")
  configure_file("${CMAKE_CURRENT_SOURCE_DIR}/ModulesLoader.cpp.in.cmake" "${GENERATED_LOADER}")
  set(${loader_out} "${GENERATED_LOADER}" PARENT_SCOPE)
endfunction()

foreach(SOURCE_MODULE ${MODULES_MODULE_LIST})
  GetPathToModuleSource("${SOURCE_MODULE}" MODULE_SOURCE_PATH)
  ModuleNameToVariable("${SOURCE_MODULE}" MODULE_VARIABLE)
  GetModuleProjectName("${SOURCE_MODULE}" MODULE_PROJECT_NAME)

  if("${${MODULE_VARIABLE}}" STREQUAL "default")
    set(MODULE_LINKAGE "${MODULES_DEFAULT_LINKAGE}")
  else()
    set(MODULE_LINKAGE "${${MODULE_VARIABLE}}")
  endif()

  if(NOT MODULE_LINKAGE STREQUAL "disabled")
    set(TORTOISE_MODULE_CMAKE_PHASE DISCOVERY)
    set(TORTOISE_CURRENT_MODULE "${SOURCE_MODULE}")
    set(TORTOISE_CURRENT_MODULE_VARIABLE "${MODULE_VARIABLE}")
    set(TORTOISE_CURRENT_MODULE_LINKAGE "${MODULE_LINKAGE}")
    include("${CMAKE_SOURCE_DIR}/modules/${SOURCE_MODULE}/${SOURCE_MODULE}.cmake" OPTIONAL)
    unset(TORTOISE_CURRENT_MODULE_LINKAGE)
    unset(TORTOISE_CURRENT_MODULE_VARIABLE)
    unset(TORTOISE_CURRENT_MODULE)
    unset(TORTOISE_MODULE_CMAKE_PHASE)

    list(APPEND MODULES_ENABLED_MODULES "${SOURCE_MODULE}")

    GetModuleScopedProperty("${MODULE_VARIABLE}" "SCRIPTS_SOURCES" MODULE_EXTRA_SCRIPT_SOURCES)
    if(MODULE_EXTRA_SCRIPT_SOURCES)
      list(REMOVE_DUPLICATES MODULE_EXTRA_SCRIPT_SOURCES)
    endif()
    GetModuleScopedProperty("${MODULE_VARIABLE}" "SCRIPTS_INCLUDE_DIRS" MODULE_EXTRA_SCRIPT_INCLUDE_DIRS)
    if(MODULE_EXTRA_SCRIPT_INCLUDE_DIRS)
      list(REMOVE_DUPLICATES MODULE_EXTRA_SCRIPT_INCLUDE_DIRS)
    endif()
  endif()

  if(NOT MODULE_LINKAGE STREQUAL "disabled")
    file(GLOB MODULE_CONFIG_DIST_FILES CONFIGURE_DEPENDS
      "${CMAKE_SOURCE_DIR}/modules/${SOURCE_MODULE}/conf/*.conf.dist")

    foreach(MODULE_CONFIG_DIST_FILE ${MODULE_CONFIG_DIST_FILES})
      CopyModuleConfig("${MODULE_CONFIG_DIST_FILE}")
    endforeach()
  endif()

  if(MODULE_LINKAGE STREQUAL "static")
    CollectModuleSourceFiles("${MODULE_SOURCE_PATH}" MODULE_SOURCE_FILES)
    CollectModuleIncludeDirectories("${MODULE_SOURCE_PATH}" MODULE_INCLUDE_DIRS)

    # One target per module, in static linkage as well as dynamic.
    #
    # These sources used to be poured into the shared `modules` library, which
    # left a module no place to put a compile option that is its own. The only
    # way to set one was to set it on the shared target, and then every other
    # module got it too: mod-dungeon-clear force-included its AzerothCore name
    # shim (`-include AcCompat.h`) into every static module's translation units,
    # and module number two would have inherited it without ever asking.
    #
    # With a target of its own, a module configures ${MODULE_PROJECT_NAME} and
    # affects nothing else -- the same name the dynamic branch already uses, so
    # a module's .cmake reads identically in both linkage modes.
    add_library(${MODULE_PROJECT_NAME} STATIC
      ${MODULE_SOURCE_FILES}
      ${MODULE_EXTRA_SCRIPT_SOURCES})

    target_include_directories(${MODULE_PROJECT_NAME}
      PUBLIC
        ${MODULES_COMMON_INCLUDES}
        ${MODULE_INCLUDE_DIRS}
        ${MODULE_EXTRA_SCRIPT_INCLUDE_DIRS})

    target_link_libraries(${MODULE_PROJECT_NAME}
      PUBLIC
        game)

    set_target_properties(${MODULE_PROJECT_NAME} PROPERTIES FOLDER "modules")

    # The generated loader lives in `modules` and calls Add<name>Scripts(),
    # which is defined here, so the include directories still have to reach the
    # loader's TU -- see the target_include_directories on `modules` below.
    list(APPEND MODULES_PUBLIC_INCLUDES ${MODULE_INCLUDE_DIRS})
    list(APPEND MODULES_PUBLIC_INCLUDES ${MODULE_EXTRA_SCRIPT_INCLUDE_DIRS})
    list(APPEND MODULES_STATIC_MODULES "${SOURCE_MODULE}")
    list(APPEND MODULES_STATIC_PROJECTS "${MODULE_PROJECT_NAME}")
  elseif(MODULE_LINKAGE STREQUAL "dynamic")
    CollectModuleSourceFiles("${MODULE_SOURCE_PATH}" MODULE_SOURCE_FILES)
    CollectModuleIncludeDirectories("${MODULE_SOURCE_PATH}" MODULE_INCLUDE_DIRS)
    ConfigureModuleLoader("${SOURCE_MODULE}" MODULE_DYNAMIC_LOADER ON "${SOURCE_MODULE}")

    add_library(${MODULE_PROJECT_NAME} SHARED
      ${MODULE_SOURCE_FILES}
      ${MODULE_EXTRA_SCRIPT_SOURCES}
      ${MODULE_DYNAMIC_LOADER})

    target_include_directories(${MODULE_PROJECT_NAME}
      PUBLIC
        ${MODULES_COMMON_INCLUDES}
        ${MODULE_INCLUDE_DIRS}
        ${MODULE_EXTRA_SCRIPT_INCLUDE_DIRS})

    if(WIN32)
      target_link_libraries(${MODULE_PROJECT_NAME}
        PUBLIC
          game
          shared
          framework)
    else()
      target_link_libraries(${MODULE_PROJECT_NAME}
        PUBLIC
          fmt)
    endif()

    set_target_properties(${MODULE_PROJECT_NAME}
      PROPERTIES
        FOLDER "modules"
        OUTPUT_NAME "${SOURCE_MODULE}"
        LIBRARY_OUTPUT_DIRECTORY "${MODULES_BUILD_RUNTIME_DIR}"
        RUNTIME_OUTPUT_DIRECTORY "${MODULES_BUILD_RUNTIME_DIR}")

    install(TARGETS ${MODULE_PROJECT_NAME}
      LIBRARY DESTINATION "${MODULES_INSTALL_RUNTIME_DIR}"
      RUNTIME DESTINATION "${MODULES_INSTALL_RUNTIME_DIR}")

    list(APPEND MODULES_DYNAMIC_MODULES ${SOURCE_MODULE})
    list(APPEND MODULES_DYNAMIC_PROJECTS ${MODULE_PROJECT_NAME})
  elseif(NOT MODULE_LINKAGE STREQUAL "disabled")
    message(FATAL_ERROR "Unknown linkage \"${MODULE_LINKAGE}\" for module ${SOURCE_MODULE}.")
  endif()
endforeach()

ConfigureModuleLoader("static" MODULE_STATIC_LOADER OFF ${MODULES_STATIC_MODULES})

# `modules` is the generated loader and nothing else: it holds the single
# AddModulesScripts() entry point mangosd calls, and pulls in each statically
# linked module through its own target. Listed after `game` so the linker
# resolves each Add<name>Scripts() from the library that defines it.
#
# ModulesScriptLoader.h is no longer listed, or shipped from here at all. The
# core declares AddModulesScripts() in core/src/shared/ModulesScriptLoader.h
# because the core is the side that calls it -- a declaration kept only in this
# repository would leave the two repositories agreeing on the signature by
# convention rather than by compilation. The generated loader below still
# #includes it by that name; core/src/shared is on MODULES_COMMON_INCLUDES.
add_library(modules STATIC
  ${MODULE_STATIC_LOADER})

target_include_directories(modules
  PUBLIC
    ${MODULES_COMMON_INCLUDES}
    ${MODULES_PUBLIC_INCLUDES})

target_link_libraries(modules
  PUBLIC
    game
    ${MODULES_STATIC_PROJECTS})

set_target_properties(modules PROPERTIES FOLDER "modules")

ProcessModuleConfigCopies(modules)

set(TORTOISE_MODULE_CMAKE_PHASE POST_TARGETS)
foreach(SOURCE_MODULE ${MODULES_ENABLED_MODULES})
  ModuleNameToVariable("${SOURCE_MODULE}" MODULE_VARIABLE)
  if("${${MODULE_VARIABLE}}" STREQUAL "default")
    set(TORTOISE_CURRENT_MODULE_LINKAGE "${MODULES_DEFAULT_LINKAGE}")
  else()
    set(TORTOISE_CURRENT_MODULE_LINKAGE "${${MODULE_VARIABLE}}")
  endif()
  set(TORTOISE_CURRENT_MODULE "${SOURCE_MODULE}")
  set(TORTOISE_CURRENT_MODULE_VARIABLE "${MODULE_VARIABLE}")
  include("${CMAKE_SOURCE_DIR}/modules/${SOURCE_MODULE}/${SOURCE_MODULE}.cmake" OPTIONAL)
  unset(TORTOISE_CURRENT_MODULE_VARIABLE)
  unset(TORTOISE_CURRENT_MODULE)
  unset(TORTOISE_CURRENT_MODULE_LINKAGE)
endforeach()
unset(TORTOISE_MODULE_CMAKE_PHASE)

set(WORLDSERVER_DYNAMIC_MODULES_DEPENDENCIES ${MODULES_DYNAMIC_PROJECTS} PARENT_SCOPE)
set(WORLDSERVER_DYNAMIC_MODULES ${MODULES_DYNAMIC_MODULES} PARENT_SCOPE)
set(WORLDSERVER_ENABLED_MODULES ${MODULES_ENABLED_MODULES} PARENT_SCOPE)
set(MODULES_BUILD_RUNTIME_DIR "${MODULES_BUILD_RUNTIME_DIR}" PARENT_SCOPE)

# Where a dynamic module ends up after `cmake --install`, which the root
# CMakeLists bakes into mangosd as TW_DYNAMIC_MODULES_INSTALL_DIR so
# DynamicModules.cpp knows where to dlopen from. Exported rather than
# recomputed: it is derived from the core's LIBS_DIR, and two places deriving
# the same install path is how a server ends up looking for its modules
# somewhere they were never put.
set(MODULES_INSTALL_RUNTIME_DIR "${MODULES_INSTALL_RUNTIME_DIR}" PARENT_SCOPE)
