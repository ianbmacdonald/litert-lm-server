cmake_minimum_required(VERSION 3.16)
project(litert_lm_server CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# Location of the prebuilt LiteRT-LM C ABI (header + linkable .so).
# Override with -DLITERT_LM_ROOT=... if the build tree moves.
set(LITERT_LM_ROOT "/home/imac/lemonade-litert-build/bazel-native/LiteRT-LM"
    CACHE PATH "Root of the LiteRT-LM bazel build tree")
set(LITERT_LM_INCLUDE_DIR "${LITERT_LM_ROOT}/c")
set(LITERT_LM_LIB_DIR "${LITERT_LM_ROOT}/bazel-bin/c")

find_package(Threads REQUIRED)

add_executable(litert-lm-server server.cpp)
target_include_directories(litert-lm-server PRIVATE
    "${LITERT_LM_INCLUDE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party")
target_link_libraries(litert-lm-server PRIVATE
    "${LITERT_LM_LIB_DIR}/liblitert-lm.so"
    Threads::Threads)
# Embed rpath so the .so resolves at runtime without LD_LIBRARY_PATH.
set_target_properties(litert-lm-server PROPERTIES
    BUILD_RPATH "${LITERT_LM_LIB_DIR}"
    INSTALL_RPATH "${LITERT_LM_LIB_DIR}")
