cmake_minimum_required(VERSION 3.20)
project(persistent_active_roster_tests LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_executable(persistent_active_roster_tests
    persistent_active_roster_tests.cpp
    ../playerbot/PersistentActiveRoster.cpp)
target_include_directories(persistent_active_roster_tests PRIVATE
    ../playerbot
    ../../../../dep/windows/include)
target_compile_definitions(persistent_active_roster_tests PRIVATE
    ROSTER_TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/fixtures")
target_link_libraries(persistent_active_roster_tests PRIVATE
    "${CMAKE_CURRENT_LIST_DIR}/../../../../dep/windows/lib/x64_release/libcrypto.lib")
if(WIN32)
  target_link_libraries(persistent_active_roster_tests PRIVATE Normaliz)
endif()
