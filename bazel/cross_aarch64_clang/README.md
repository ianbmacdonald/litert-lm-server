# aarch64-glibc cross toolchain (clang) — the one that ships

Clang front-end over the ARM GNU 11.3.Rel1 `aarch64-none-linux-gnu` sysroot
(`@aarch64_linux_toolchain`). Supersedes `../cross_aarch64` (gcc variant), which hits
LiteRT's Clang-style NEON attribute `__attribute__((target("dotprod")))` wall — clang
compiles all dotprod/SVE kernels with the SAME sysroot, so bundle layout and licensing
are unchanged.

Build (all four requirements together, from the LiteRT-LM workspace):

    bazel build //runtime/engine:litert_lm_main //c:litert-lm \
      --platforms=//cross_aarch64_clang:linux_aarch64 \
      --extra_toolchains=//cross_aarch64_clang:cc_toolchain_aarch64_clang \
      --cpu=aarch64

1. this platform+toolchain recipe;
2. rust `aarch64-unknown-linux-gnu` in `rust_register_toolchains(extra_target_triples)`;
3. host clang on PATH (host tools / `@local_config_cc`);
4. legacy `--cpu=aarch64` (vendored libs key `select()`s on it).

The CMake mirror for the server binary is `../../aarch64-clang-toolchain.cmake`
(`cmake -DCMAKE_TOOLCHAIN_FILE=... -B build-aarch64`).

Toolchain gotchas already fixed in this config (do not re-learn):
- clang needs its resource dir resolvable under `-no-canonical-prefixes`;
- host `ld.bfd` rejects `-m aarch64linux` → link with `-fuse-ld=lld`;
- use the `clang` driver for `.c` (clang++ forces C++) and add explicit
  `-lstdc++ -lm -lpthread -ldl` where needed.

`wrappers/` exec the host's system clang/lld and llvm binutils (`/usr/bin/clang`,
`/usr/lib/llvm-21/...`) — retarget the two lines if your host lays them out elsewhere.
