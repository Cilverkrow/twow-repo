# persistent_active_roster_tests — the roster serialiser's unit suite.
#
# Hand-rolled assertions (no gtest): 7 test functions, 142 CHECK calls, one
# plain main() returning non-zero on failure. It compiles two translation units
# and touches no database, which makes it the cheapest test in the tree — hence
# it is wired into the normal build rather than left as a manual side project.
#
# This used to be a standalone project() with its own cmake_minimum_required,
# reachable only by pointing cmake at this directory by hand. Nothing called
# add_subdirectory on it, so it was never configured, never built and never run.
# The behaviour of the test itself is unchanged; only the wiring and the
# OpenSSL/Windows portability of this file were touched.

add_executable(persistent_active_roster_tests
    persistent_active_roster_tests.cpp
    ../playerbot/PersistentActiveRoster.cpp)

target_include_directories(persistent_active_roster_tests PRIVATE
    ../playerbot)

# The bundled dep/windows/include tree was added unconditionally and put an
# OpenSSL 1.1.1 <openssl/sha.h> ahead of the system one on every platform,
# which on Linux means compiling against bundled headers and linking a system
# libcrypto. It is a Windows-only fallback and is now spelled as one.
if(WIN32)
  target_include_directories(persistent_active_roster_tests PRIVATE
      ../../../../dep/windows/include)
endif()

target_compile_definitions(persistent_active_roster_tests PRIVATE
    ROSTER_TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/fixtures")

# Was a mandatory ROSTER_TEST_OPENSSL_LIBRARY cache path that FATAL_ERRORed the
# whole configure when unset - fine for a hand-driven build, fatal for one that
# is part of the tree. PersistentActiveRoster.cpp only needs SHA from libcrypto.
#
# Variables rather than the OpenSSL::Crypto imported target: this repository
# ships its own cmake/FindOpenSSL.cmake, and CMAKE_MODULE_PATH puts it ahead of
# CMake's built-in module. It sets OPENSSL_INCLUDE_DIR and OPENSSL_LIBRARIES but
# defines no imported targets, so OpenSSL::Crypto does not exist here. The root
# CMakeLists already ran find_package(OpenSSL REQUIRED) on UNIX; this repeats it
# for a standalone configure and is a no-op otherwise.
if(UNIX)
  find_package(OpenSSL REQUIRED)
endif()
target_include_directories(persistent_active_roster_tests PRIVATE ${OPENSSL_INCLUDE_DIR})
target_link_libraries(persistent_active_roster_tests PRIVATE ${OPENSSL_LIBRARIES})

# ...and libcrypto explicitly, because OPENSSL_LIBRARIES is not enough here.
# cmake/FindOpenSSL.cmake's find_library() searches only for "ssl", so on UNIX
# that variable resolves to libssl alone. PersistentActiveRoster.cpp calls
# SHA256(), which lives in libcrypto: without this the link fails with five
# undefined references to SHA256. The sibling adapter test needs it too: linking
# `shared` does not reliably supply it, because with --as-needed a static
# library contributes nothing the final link has not already asked for.
#
# Windows needs nothing extra: the root CMakeLists sets OPENSSL_LIBRARIES to the
# libssl and libcrypto import libraries together.
if(UNIX)
  find_library(TW_OPENSSL_CRYPTO_LIBRARY NAMES crypto)
  if(NOT TW_OPENSSL_CRYPTO_LIBRARY)
    message(FATAL_ERROR
      "persistent_active_roster_tests needs libcrypto (SHA256) but it was not found; install the OpenSSL development package or set TW_OPENSSL_CRYPTO_LIBRARY.")
  endif()
  target_link_libraries(persistent_active_roster_tests PRIVATE ${TW_OPENSSL_CRYPTO_LIBRARY})
endif()

set_target_properties(persistent_active_roster_tests PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")

add_test(NAME persistent_active_roster
         COMMAND persistent_active_roster_tests
         WORKING_DIRECTORY "${CMAKE_BINARY_DIR}")
