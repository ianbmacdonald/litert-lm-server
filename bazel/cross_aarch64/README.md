# aarch64-glibc cross recipe (Bazel) for LiteRT-LM

Cross-compiles LiteRT-LM engine targets to **glibc aarch64** on an x86_64 Linux host,
using TensorFlow's prebuilt ARM-GNU 11.3 `aarch64-none-linux-gnu` toolchain
(`@aarch64_linux_toolchain`, self-contained glibc sysroot, `builtin_sysroot=None`).

## Drop-in

Copy `BUILD` (and `hello.cc` for the smoke test) into a LiteRT-LM checkout as a
package, e.g. `//cross_aarch64/`.

## Three requirements (all needed together)

1. **C++ cc_toolchain** — this `BUILD` file provides `platform(:linux_aarch64)` and
   `toolchain(:cc_toolchain_aarch64_linux_gnu)` binding
   `@local_config_embedded_arm//:cc-compiler-aarch64` to
   `@platforms//cpu:aarch64 + os:linux`. Selected via `--platforms` + `--extra_toolchains`.
   (`@local_config_embedded_arm` is provisioned by TF's elinux machinery — it exists
   after any `--config=elinux_aarch64` analysis, or is fetched on first reference here.)

2. **Rust aarch64 toolchain** — LiteRT-LM's `@tokenizers_cpp` pulls in Rust
   (HuggingFace tokenizers). Add `"aarch64-unknown-linux-gnu"` to
   `rust_register_toolchains(extra_target_triples=[...])` in `WORKSPACE`. Without it:
   `No matching toolchains found for @rules_rust//rust:toolchain_type`.

3. **Host C++ compiler on PATH** — host build tools (`cxxbridge_cmd` for the Rust cxx
   bridge) need `@local_config_cc`. `.bazelrc` forces `CC=clang`, so `clang` must be
   discoverable. Put the host clang (e.g. vendored LLVM) on `PATH` before invoking
   bazel. Without it: `Auto-Configuration Error: Cannot find gcc or CC (clang)`.

## Smoke test (cheap toolchain proof)

    bazel build //cross_aarch64:hello \
        --platforms=//cross_aarch64:linux_aarch64 \
        --extra_toolchains=//cross_aarch64:cc_toolchain_aarch64_linux_gnu
    file bazel-bin/cross_aarch64/hello
    # => ELF 64-bit LSB executable, ARM aarch64, ... interpreter /lib/ld-linux-aarch64.so.1, ... GNU/Linux

## Engine cross-build

    PATH=/path/to/host-clang/bin:$PATH \
    bazel build //runtime/engine:litert_lm_main //c:litert-lm \
        --platforms=//cross_aarch64:linux_aarch64 \
        --extra_toolchains=//cross_aarch64:cc_toolchain_aarch64_linux_gnu \
        --cpu=aarch64 \
        --jobs=2 --local_ram_resources=5120

## Fourth requirement: `--cpu=aarch64`

Many vendored libs (`@cpuinfo`, TF/XLA) key their arch `select()`s on the **legacy
`--cpu`** flag (`config_setting(values={"cpu":"aarch64"})`), not on `@platforms//cpu`.
`--platforms` alone drives cc_toolchain *resolution* but leaves `--cpu` at its host
default (`k8`), so those selects pick **x86 sources** and you get
`fatal error: cpuid.h: No such file or directory` (x86 cpuid intrinsic) from
`aarch64-none-linux-gnu-gcc`. Pass `--cpu=aarch64` to steer the legacy selects; the
registered platform/toolchain still provides the real aarch64 compiler (unlike bare
`--config=elinux_aarch64`, which sets `--cpu=aarch64` but no platform and silently
falls back to the host x86 toolchain).

Note: TF's toolchain is licensed `restricted` (GPLv3, ARM-GNU); the emitted binary
links glibc/libstdc++/libgcc (LGPL/GPL+exception) — see the bundle manifest.
