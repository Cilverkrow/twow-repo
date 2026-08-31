cmake_minimum_required(VERSION 3.20)
project(ssc_external_llm_bridge_tests LANGUAGES CXX)

set(SSC_SOURCE_ROOT "" CACHE PATH "Absolute root of the isolated SSC source worktree")
if(NOT IS_ABSOLUTE "${SSC_SOURCE_ROOT}" OR NOT EXISTS "${SSC_SOURCE_ROOT}/src/shared/json.hpp")
    message(FATAL_ERROR "Set -DSSC_SOURCE_ROOT=<absolute isolated source root>")
endif()

add_executable(external_llm_bridge_tests external_llm_bridge_tests.cpp)
target_compile_features(external_llm_bridge_tests PRIVATE cxx_std_17)
target_compile_definitions(external_llm_bridge_tests PRIVATE UNICODE _UNICODE)
target_compile_options(external_llm_bridge_tests PRIVATE /EHsc)
target_include_directories(external_llm_bridge_tests PRIVATE
    "${SSC_SOURCE_ROOT}/src/shared"
    "${SSC_SOURCE_ROOT}/src/modules/PlayerBots")
target_link_libraries(external_llm_bridge_tests PRIVATE bcrypt)
