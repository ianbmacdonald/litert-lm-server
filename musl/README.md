# litert-lm-server for prplOS x86_64 (musl)

`build-musl.sh` builds litert-lm-server against LiteRT-LM **v0.17.1** with the prplOS 5.1 musl
toolchain, starting from an empty directory, and packages the release bundle that the prpl
`litert-lm-server` package installs:

```
litert-lm-server-x86_64-musl-<ver>/
  bin/litert-lm-server          stripped; interpreter /lib/ld-musl-x86_64.so.1; RUNPATH $ORIGIN/../lib
  lib/libkissfft-float.so.131   the one shared library LiteRT-LM builds
  licenses/                     third-party license files + INDEX.md
  run                           POSIX sh wrapper: execs bin/litert-lm-server (LD_PRELOAD left alone)
  BUNDLE-MANIFEST-musl.md       provenance: every fetched ref, toolchain, NEEDED, sha256
```

The binary's NEEDED list is `libkissfft-float.so.131 libz.so.1 libstdc++.so.6 libgcc_s.so.1 libc.so`;
everything except kissfft comes from the prplOS rootfs. The `bundle` step checks the interpreter,
RUNPATH and NEEDED with the toolchain's readelf and refuses to package anything else.

## Prerequisites

- **prplOS 5.1 SDK staging tree** (`--staging` / `PRPLOS_STAGING_DIR`) containing
  `toolchain-x86_64_gcc-13.3.0_musl/` (OpenWrt GCC 13.3.0, musl 1.2.5) and `target-x86_64_musl/`
  (sysroot with `usr/include`, `usr/lib/libz.so`, and `root-x86/` for the smoke test).
- **cmake** ≥ 3.25 (validated with 4.2.3), GNU **make**, **git**, **python3**, **curl**, GNU **tar**.
- **Host C/C++ compiler** as `cc`/`c++` (the LiteRT-LM prebuild phase builds protoc and flatc for the host).
- **rustup** with the musl target: `rustup target add x86_64-unknown-linux-musl` (validated with
  rustc 1.98.1). Crates are fetched from crates.io.
- **systemd user manager** for `systemd-run --user --scope` (memory cap); use `--no-scope` without one.
- Network access to GitHub (LiteRT-LM and its fetched dependencies, the Temurin JRE) and crates.io.
- ~25 GB free disk in the work directory; up to 16 GB RAM at `--jobs 8`.

Java is **not** a prerequisite: the `jre` step downloads a pinned Temurin 17.0.20.1+1 JRE (URL and
sha256 in `build-musl.sh`) into the work directory. LiteRT-LM needs it to run the ANTLR tool.

## Usage

```sh
musl/build-musl.sh --staging /path/to/prplos-5.1-staging --work /path/to/empty-dir
# -> <work>/dist/litert-lm-server-x86_64-musl-v0.3.0.tar.gz and .tar.gz.sha256
```

Options: `--jobs N` (default 8), `--memory-max 16G`, `--no-scope`, `--version v0.3.0`,
`--from STEP`, `--to STEP`, `--only STEP`. Steps: `preflight jre toolchain source configure build
server licenses bundle`. Each step logs to `<work>/logs/<step>.log`; a failing step prints the tail of
its log and stops. Re-running reuses the clone, the configure and the make state.

`smoke-prplos.sh <tarball> <prplOS root-x86> <model.litertlm> <out>` unpacks the tarball into the
prplOS rootfs under bubblewrap, starts it through `run` on 2 CPUs with procd's
`LD_PRELOAD=/lib/libsetlbf.so` set and no `LD_LIBRARY_PATH`, and runs one non-streaming and one
streaming chat completion.

## What the recipe changes, and why

LiteRT-LM v0.17.1's CMake build assumes a glibc host build. Each workaround below maps to the
upstream defect it covers; none changes LiteRT-LM behavior.

| Piece | Upstream defect it works around |
|---|---|
| `wrap/musl-cc.in` `-idirafter <sysroot>/usr/include` | The prplOS sysroot carries its own (older) abseil/protobuf headers; a plain `--sysroot`/`-I` lets them shadow the versions LiteRT-LM fetches. Searching the sysroot last keeps the fetched headers authoritative. Cross-sysroot hygiene, not a LiteRT-LM bug. |
| `wrap/musl-cc.in` `-L`/`-rpath-link <sysroot>/usr/lib` | protobuf's `protoc-gen-upb` links `-lz`; the OpenWrt toolchain does not search the target sysroot by default (`cannot find -lz`). |
| `wrap/musl-cc.in` `-DFLATBUFFERS_LOCALE_INDEPENDENT=0` | flatbuffers `base.h` turns on locale-independent parsing whenever `_XOPEN_VERSION >= 700` (true on musl with `_GNU_SOURCE`), then `util.h` calls `strtoll_l`/`strtoull_l`, which musl does not provide. |
| toolchain `TFLITE_HOST_TOOLS_DIR` | LiteRT's CMake builds its own host `flatc` in a nested build during a cross build, and that nested build fails (`No rule to make target 'flatc'`). The prebuild phase already built a host flatc; point LiteRT at it. |
| toolchain `Rust_CARGO_TARGET` | Corrosion (LiteRT-LM's `litert_lm_deps` Rust staticlib: llguidance, minijinja, tokenizers, cxx) must build for `x86_64-unknown-linux-musl`, not the host triple. |
| `01-host-protoc-cache-force.patch` | `protobuf_config.cmake` switches to the host protoc only when `LITERTLM_ORCHESTRATION_PHASE` is `litert_lm`, and with non-`FORCE` cache sets, so sub-projects such as sentencepiece keep the cross-built (musl) protoc, which cannot run on the build host (`protoc: not found`). |
| `02-pin-tensorflow-and-litert-to-release-date.patch` | v0.17.1 fetches TensorFlow `master` and LiteRT `main`, so the "release" is not reproducible; current TF master has dropped `tensorflow/lite/profiling/proto/CMakeLists.txt` and no longer configures. Pinned to TF `e511b24d` and LiteRT `876bb8d5`. |
| `03-stage-tflite-archives.sh` (hook) | `tflite_target_map.cmake` hands LiteRT paths under `install/lib` that `tflite_external` (with `TFLITE_ENABLE_INSTALL=OFF`) never installs, several of them (fft2d_*, cpuinfo_internals, ruy_profiler_profiler) from targets nothing builds, and `libkleidiai.a`, which is not a target on x86_64. |
| `04-samsung-anon-namespace-gcc13-ice.patch` | GCC 13.3 segfaults (ICE in `constrain_class_visibility`) on LiteRT's Samsung vendor `AiLiteCoreManager::PublicApi`, whose members are `decltype(&fn)` of functions declared in an anonymous namespace. The patch adds a rewrite to `litert_patcher.cmake`: named namespace + using-directive, same lookup, no ICE. LiteRT builds every vendor backend unconditionally. |
| `05-tokenizers-c-musl.sh` (hook) + `tokenizers-c.Cargo.lock` | tokenizers-cpp passes no `cargo --target` for a generic Linux cross build, so `libtokenizers_c.a` (and the oniguruma the `onig` crate compiles) is built for the host glibc triple and fails to link (`undefined reference to __memcpy_chk`). Rebuilt for musl with `--locked` against the pinned lock file, because tokenizers-cpp does not commit one. |
| `06-pin-floating-dependencies.patch` | v0.17.1 also fetches tokenizers-cpp `main`, re2 `main`, stb `master` and zlib `master`. Pinned to the commits of the validated build (`c586c52f`, `972a15ce`, `2c980bb5`, `da607da7`). |
| `07-musl-post-step-hooks.patch` | Glue, not a defect: runs 03 and 05 as `ExternalProject_Add_Step`s (after tflite install, between tokenizers build and install) when the toolchain file sets `LITERTLM_MUSL_HOOK_DIR`, so one `make` builds everything with no manual mid-build edits. |
| `server` step (link line reuse) | LiteRT-LM's CMake has no installable library or shared C-ABI target. The server is linked with `litert_lm_main`'s own whole-archive link line, `server.o` swapped in for `litert_lm_main.cc.o`, build-tree rpaths dropped and `RUNPATH $ORIGIN/../lib` added. |
| `jre` step | The ANTLR tool jar that generates LiteRT-LM's tool-call parsers needs `java`, which the build neither documents nor checks (`Error 127`). |

## Licenses

`collect-licenses.py` copies the license files of every statically linked component from the exact
fetched sources (C/C++ dependencies, TFLite's own dependencies, every Rust crate in the resolved
graphs of both Rust staticlibs, the Rust standard library) into `licenses/` and writes
`licenses/INDEX.md`. A component with no findable license file fails the step (or, with
`--allow-gaps`, is listed under "Gaps"). LiteRT links its Qualcomm (QAIRT) and Samsung (Exynos AI
LiteCore) vendor code, compiled against those vendors' SDK headers; their license PDFs are copied and
listed under "Flags for review".
