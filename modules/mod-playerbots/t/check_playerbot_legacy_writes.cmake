if(NOT DEFINED PB_MODULE_DIR)
  message(FATAL_ERROR "PB_MODULE_DIR is required")
endif()

file(GLOB_RECURSE runtime_files
  "${PB_MODULE_DIR}/src/*.cpp"
  "${PB_MODULE_DIR}/src/*.h")
set(tool_files
  "${PB_MODULE_DIR}/data/sql/other/delete_randombots.sql"
  "${PB_MODULE_DIR}/data/sql/other/delete_all_randombots.sql"
  "${PB_MODULE_DIR}/data/sql/other/reset_randombots.sql")

set(legacy_write_pattern
  "(DELETE[ \t\r\n]+FROM|INSERT[ \t\r\n]+INTO|UPDATE|REPLACE[ \t\r\n]+INTO|TRUNCATE([ \t\r\n]+TABLE)?)[ \t\r\n`]*(TW_CHAR[.`]+)?AI_PLAYERBOT_RANDOM_BOTS")

foreach(path IN LISTS runtime_files tool_files)
  file(READ "${path}" content)
  string(TOUPPER "${content}" content_upper)
  string(REGEX MATCH "${legacy_write_pattern}" forbidden "${content_upper}")
  if(forbidden)
    message(FATAL_ERROR "Legacy PlayerBot event write found in ${path}: ${forbidden}")
  endif()
endforeach()

message(STATUS "PlayerBot legacy event write guard passed")
