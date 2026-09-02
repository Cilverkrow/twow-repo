# mod-bot-brain -- module build hook.
#
# Included from modules/CMakeLists.txt in both the DISCOVERY and POST_TARGETS
# phases, and only when this module's linkage is not "disabled". Targets are
# only touched in POST_TARGETS, where they exist.
#
# The unit test suite is NOT declared here. It lives in tests.cmake, included
# directly from the root CMakeLists.txt under BUILD_TESTING -- the same split
# mod-dungeon-clear and mod-playerbots use, and for the same two reasons: this
# file is skipped entirely when the module is disabled (the configuration a CI
# test run uses), and it is included twice per configure, which would define
# every target here twice over.

if(TORTOISE_MODULE_CMAKE_PHASE STREQUAL "POST_TARGETS")
  GetModuleProjectName("${TORTOISE_CURRENT_MODULE}" BB_TARGET)
  GetModuleProjectName("mod-playerbots" BB_PLAYERBOTS_TARGET)

  # This module subclasses ChooseTravelTargetAction and registers into the bot
  # AI context, so it compiles mod-playerbots' headers and links its objects.
  # Linking the target is the whole statement: CollectModuleIncludeDirectories
  # publishes every directory under modules/mod-playerbots/src that holds a
  # header, PUBLIC on that target, and CMake carries them here.
  if(NOT TARGET ${BB_PLAYERBOTS_TARGET})
    message(FATAL_ERROR
      "mod-bot-brain overrides a mod-playerbots action and cannot be built "
      "without it. Enable it (-DMODULE_MOD_PLAYERBOTS=static) or disable this "
      "module (-DMODULE_MOD_BOT_BRAIN=disabled).")
  endif()

  target_link_libraries(${BB_TARGET} PUBLIC ${BB_PLAYERBOTS_TARGET})

  # The same three vendor feature gates mod-playerbots compiles itself with.
  #
  # They are PRIVATE on that target, so they do not travel over the link, and
  # this module compiles the very same headers. That is not a style question
  # here: this module DERIVES from ChooseTravelTargetAction and passes
  # TravelTarget and TravelDestination objects back into that library. The
  # macros gate member declarations (ServerFacade.h's ArenaType block is the
  # one that fails loudly; the quiet ones are level caps and struct members),
  # so compiling without them means the two halves disagree about class layout
  # -- an ODR violation that links cleanly and misbehaves at runtime.
  #
  # Without MANGOSBOT_ZERO the build does not even get that far: it stops at
  #   ServerFacade.h:286: error: 'ArenaType' does not name a type
  # because that declaration sits behind #ifndef MANGOSBOT_ZERO and the type
  # exists nowhere in this tree.
  #
  # mod-dungeon-clear does NOT set these and subclasses the same classes. That
  # predates this module and is not ours to change here, but it is the reason
  # this comment is long: the pattern to copy is this one, not that one.
  target_compile_definitions(${BB_TARGET} PRIVATE CMANGOS MANGOSBOT_ZERO ENABLE_PLAYERBOTS)
endif()
