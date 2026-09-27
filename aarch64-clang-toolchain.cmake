set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

if(NOT ARMGNU)
  set(ARMGNU "$ENV{ARMGNU}")
endif()
if(NOT ARMGNU)
  message(FATAL_ERROR "Set ARMGNU (-DARMGNU=... or env) to an ARM GNU Toolchain 11.3.Rel1 aarch64-none-linux-gnu root")
endif()

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
