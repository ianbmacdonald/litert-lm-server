set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(ARMGNU "/home/imac/.cache/bazel/_bazel_imac/18dd4e31d171336460403a9a20c69030/external/aarch64_linux_toolchain")

set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)

set(_cross "--target=aarch64-linux-gnu -march=armv8.2-a+dotprod --sysroot=${ARMGNU}/aarch64-none-linux-gnu/libc --gcc-toolchain=${ARMGNU}")
set(CMAKE_C_FLAGS_INIT "${_cross}")
set(CMAKE_CXX_FLAGS_INIT "${_cross}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "${_cross} -fuse-ld=lld")

set(CMAKE_FIND_ROOT_PATH "${ARMGNU}/aarch64-none-linux-gnu/libc")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
