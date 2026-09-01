# Test suites for mod-playerbots.
#
# Included from the ROOT CMakeLists under BUILD_TESTING, not from
# mod-playerbots.cmake. That file is only read when the module's linkage is not
# "disabled", which would make these targets un-buildable in exactly the
# configuration a test run wants; and it is read twice per configure (DISCOVERY
# and POST_TARGETS), which would define every target here twice over. Both
# suites are source-level -- they compile the module's own .cpp files directly
# -- so they need the sources on disk, not the module library.

set(PB_MODULE_DIR "${CMAKE_SOURCE_DIR}/modules/mod-playerbots")

# --------------------------------------------------------------------------
# persistent_active_roster_tests -- the roster serialiser's unit suite.
#
# Hand-rolled assertions (no gtest): 7 test functions, 142 CHECK calls, one
# plain main() returning non-zero on failure. Two translation units, no
# database, no test framework, which makes it the cheapest test in the tree --
# hence it is wired into the normal testing build rather than left opt-in.
#
# It used to be a standalone project() with its own cmake_minimum_required,
# reachable only by pointing cmake at its directory by hand. Nothing called
# add_subdirectory on it, so it was never configured, never built and never run.
# --------------------------------------------------------------------------

add_executable(persistent_active_roster_tests
  "${PB_MODULE_DIR}/t/persistent_active_roster_tests.cpp"
  "${PB_MODULE_DIR}/src/playerbot/PersistentActiveRoster.cpp")

target_include_directories(persistent_active_roster_tests PRIVATE
  "${PB_MODULE_DIR}/src/playerbot")

# The bundled dep/windows/include tree was added unconditionally and put an
# OpenSSL 1.1.1 <openssl/sha.h> ahead of the system one on every platform,
# which on Linux means compiling against bundled headers and linking a system
# libcrypto. It is a Windows-only fallback and is spelled as one.
if(WIN32)
  target_include_directories(persistent_active_roster_tests PRIVATE
    "${CMAKE_SOURCE_DIR}/dep/windows/include")
endif()

target_compile_definitions(persistent_active_roster_tests PRIVATE
  ROSTER_TEST_FIXTURE_DIR="${PB_MODULE_DIR}/t/fixtures")

# Variables rather than the OpenSSL::Crypto imported target: this repository
# ships its own cmake/FindOpenSSL.cmake and CMAKE_MODULE_PATH puts it ahead of
# CMake's built-in module. It sets OPENSSL_INCLUDE_DIR and OPENSSL_LIBRARIES but
# defines no imported targets, so OpenSSL::Crypto does not exist here.
if(UNIX)
  find_package(OpenSSL REQUIRED)
endif()
target_include_directories(persistent_active_roster_tests PRIVATE ${OPENSSL_INCLUDE_DIR})
target_link_libraries(persistent_active_roster_tests PRIVATE ${OPENSSL_LIBRARIES})

# ...and libcrypto by name, because OPENSSL_LIBRARIES is not enough here: this
# repository's FindOpenSSL.cmake searches only for "ssl", so on UNIX that
# variable resolves to libssl alone, and PersistentActiveRoster.cpp calls
# SHA256(), which lives in libcrypto. Without this the link fails with five
# undefined references to SHA256.
if(UNIX)
  find_library(TW_OPENSSL_CRYPTO_LIBRARY NAMES crypto)
  if(NOT TW_OPENSSL_CRYPTO_LIBRARY)
    message(FATAL_ERROR
      "persistent_active_roster_tests needs libcrypto (SHA256) but it was not found; "
      "install the OpenSSL development package or set TW_OPENSSL_CRYPTO_LIBRARY.")
  endif()
  target_link_libraries(persistent_active_roster_tests PRIVATE ${TW_OPENSSL_CRYPTO_LIBRARY})
endif()

set_target_properties(persistent_active_roster_tests PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")

add_test(NAME persistent_active_roster
  COMMAND persistent_active_roster_tests
  WORKING_DIRECTORY "${CMAKE_BINARY_DIR}")

# --------------------------------------------------------------------------
# persistent_active_roster_database_tests -- the same serialiser against a live
# MariaDB. Opt-in: it needs a running database, so it is not part of a plain
# testing build.
# --------------------------------------------------------------------------

if(BUILD_PERSISTENT_ROSTER_ADAPTER_TESTS)

add_executable(persistent_active_roster_database_tests
  "${PB_MODULE_DIR}/t/persistent_active_roster_database_tests.cpp"
  "${PB_MODULE_DIR}/src/playerbot/PersistentActiveRoster.cpp"
  "${PB_MODULE_DIR}/src/playerbot/PersistentActiveRosterDatabase.cpp")

target_include_directories(persistent_active_roster_database_tests PRIVATE
  "${PB_MODULE_DIR}/src/playerbot"
  "${CMAKE_SOURCE_DIR}/src/shared"
  "${CMAKE_SOURCE_DIR}/src/framework"
  "${CMAKE_BINARY_DIR}/src/shared"
  "${CMAKE_BINARY_DIR}"
  ${ACE_INCLUDE_DIR}
  ${MYSQL_INCLUDE_DIR}
  ${OPENSSL_INCLUDE_DIR})

# The bundled Windows headers must not be on the include path elsewhere: they
# shadow the system OpenSSL and MySQL headers that ${OPENSSL_INCLUDE_DIR} and
# ${MYSQL_INCLUDE_DIR} already point at.
if(WIN32)
  target_include_directories(persistent_active_roster_database_tests PRIVATE
    "${CMAKE_SOURCE_DIR}/dep/include-windows"
    "${CMAKE_SOURCE_DIR}/dep/windows/include")
endif()

target_compile_definitions(persistent_active_roster_database_tests PRIVATE
  ROSTER_DATABASE_INJECTED_ONLY)

target_link_libraries(persistent_active_roster_database_tests PRIVATE
  shared
  framework
  ${ACE_LIBRARIES})

if(WIN32)
  # Separate debug/release import libraries are a Windows arrangement. Elsewhere
  # MYSQL_DEBUG_LIBRARY and OPENSSL_DEBUG_LIBRARIES are empty, and a `debug`
  # keyword followed by nothing is a hard CMake error:
  #   The "debug" argument must be followed by a library.
  target_link_libraries(persistent_active_roster_database_tests PRIVATE
    optimized ${MYSQL_LIBRARY}
    optimized ${OPENSSL_LIBRARIES}
    debug ${MYSQL_DEBUG_LIBRARY}
    debug ${OPENSSL_DEBUG_LIBRARIES}
    ws2_32)
else()
  # libcrypto by name, for the same reason the unit suite above needs it.
  # Linking `shared` does not reliably drag it in: with --as-needed (the default
  # on Ubuntu) a static library contributes nothing the final link has not
  # already asked for, and CI failed here with "undefined reference to symbol
  # 'SHA256@@OPENSSL_3.0.0'" while a Debian container linked it fine.
  target_link_libraries(persistent_active_roster_database_tests PRIVATE
    ${MYSQL_LIBRARY}
    ${OPENSSL_LIBRARIES}
    ${TW_OPENSSL_CRYPTO_LIBRARY})
endif()

set_target_properties(persistent_active_roster_database_tests PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/adapter-bin")

endif()
