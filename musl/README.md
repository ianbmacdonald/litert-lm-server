# litert-lm-server for prplOS x86_64 (musl)

`build-musl.sh` builds litert-lm-server against LiteRT-LM **v0.19.0** with the prplOS 5.1 musl
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
# -> <work>/dist/litert-lm-server-x86_64-musl-v0.4.0.tar.gz and .tar.gz.sha256
```

`--arch aarch64` builds the prplOS 5.1 aarch64 (Cortex-A53) bundle instead, from a staging dir holding
`toolchain-aarch64_cortex-a53_gcc-13.3.0_musl/` and `target-aarch64_cortex-a53_musl/` (rust target
`aarch64-unknown-linux-musl`), compiled with `-march=armv8-a+crc -mtune=cortex-a53`, into
`litert-lm-server-aarch64-musl-<ver>.tar.gz`; the default is `--arch x86_64`.

Options: `--arch x86_64|aarch64`, `--jobs N` (default 8, validated up to 12), `--memory-max 16G`, `--no-scope`, `--version v0.4.0`,
`--from STEP`, `--to STEP`, `--only STEP`. Steps: `preflight jre toolchain source configure build
server licenses bundle`. Each step logs to `<work>/logs/<step>.log`; a failing step prints the tail of
its log and stops. Re-running reuses the clone, the configure and the make state.

`smoke-prplos.sh <tarball> <prplOS root-x86> <model.litertlm> <out>` unpacks the tarball into the
prplOS rootfs under bubblewrap, starts it through `run` on 2 CPUs with procd's
`LD_PRELOAD=/lib/libsetlbf.so` set and no `LD_LIBRARY_PATH`, and runs one non-streaming and one
streaming chat completion.

`smoke-feed.sh <bundle dir> <prplOS root> <model.litertlm> <out> [port] [max_tokens]` runs the
server the way a container does: PID 1 of its own PID namespace (bubblewrap `--as-pid-1`) in a
systemd user unit, with `--host 0.0.0.0`. It checks `/health`, one chat completion, the listening
socket (`ss -ltnp`) and the SIGTERM exit time (limit 2 s; a server without a handler never exits
at PID 1 and fails).

## What the recipe changes, and why

LiteRT-LM v0.19.0's CMake build assumes a glibc host build. Each workaround below maps to the
upstream defect it covers; none changes LiteRT-LM behavior. The LiteRT-LM patches are a
`git format-patch` series in `patches/musl/litert-lm/` against `v0.19.0` (`771b06e1`); see
`patches/musl/README.md`.

| Piece | Upstream defect it works around |
|---|---|
| `wrap/musl-cc.in` `-idirafter <sysroot>/usr/include` | The prplOS sysroot carries its own (older) abseil/protobuf headers; a plain `--sysroot`/`-I` lets them shadow the versions LiteRT-LM fetches. Searching the sysroot last keeps the fetched headers authoritative. Cross-sysroot hygiene, not a LiteRT-LM bug. |
| `wrap/musl-cc.in` `-L`/`-rpath-link <sysroot>/usr/lib` | protobuf's `protoc-gen-upb` links `-lz`; the OpenWrt toolchain does not search the target sysroot by default (`cannot find -lz`). |
| `wrap/musl-cc.in` `-ffile-prefix-map=<work>=.` | Not a defect: keeps the work directory out of `__FILE__` strings so the C/C++ objects do not depend on where the build ran. |
| `wrap/musl-cc.in` `-DFLATBUFFERS_LOCALE_INDEPENDENT=0` | flatbuffers `base.h` turns on locale-independent parsing whenever `_XOPEN_VERSION >= 700` (true on musl with `_GNU_SOURCE`), then `util.h` calls `strtoll_l`/`strtoull_l`, which musl does not provide. |
| configure `LITERTLM_CC`/`LITERTLM_CXX` and `LITERTLM_CC_NDK`/`LITERTLM_CXX_NDK` | v0.19.0 takes the prebuild-phase (host protoc/flatc) compilers from `CMAKE_C_COMPILER` unless `LITERTLM_CC` is set, and that is the toolchain file's musl gcc in a cross build, so the host tools are musl binaries that cannot run (`flatc: not found`). The host compilers go in `LITERTLM_CC*`, the musl wrappers in `LITERTLM_C*_NDK` (its name for the target compilers). |
| configure `ENABLE_CCACHE=OFF` | v0.19.0 turns a compiler launcher (sccache/ccache) on by default whenever one is installed; off keeps the build independent of the host. |
| toolchain `TFLITE_HOST_TOOLS_DIR` | LiteRT's CMake builds its own host `flatc` in a nested build during a cross build, and that nested build fails (`No rule to make target 'flatc'`). The prebuild phase already built a host flatc; point LiteRT at it. |
| toolchain `Rust_CARGO_TARGET` | Corrosion (LiteRT-LM's `litert_lm_deps` Rust staticlib: llguidance, minijinja, tokenizers, cxx) must build for `<arch>-unknown-linux-musl`, not the host triple. |
| `0001` pin LiteRT, RE2, zlib | v0.19.0 fetches LiteRT `main`, RE2 `main` and zlib `master`, so the release is not reproducible. Pinned to their heads at the release commit: LiteRT `4873c048`, RE2 `2da00568`, zlib `da607da7`. (v0.19.0 itself pins TensorFlow `fadb2ca7`, tokenizers-cpp `c586c52f` and stb `f58f558c`.) |
| `0002` CPU-only LiteRT | v0.19.0 hard-codes `-DLITERT_ENABLE_NPU=ON -DLITERT_ENABLE_QUALCOMM=ON`; LiteRT then downloads the Qualcomm QAIRT and Samsung LiteCore SDK headers and builds their dispatch libraries. NPU, Qualcomm and Samsung off (LiteRT then skips `vendors/`), and `build_config.h` gets `LITERT_BUILD_CONFIG_DISABLE_NPU 1`. |
| `0003` host protoc with `FORCE` | `protobuf_config.cmake` selects the host protoc only in the `litert_lm` phase and with non-`FORCE` cache sets, so a sub-project that caches the cross-built (musl) protoc keeps it and cannot run it (`protoc: not found`). |
| `0004` tokenizers-cpp hooks + `hooks/05-tokenizers-c-musl.sh` + `hooks/tokenizers-c.Cargo.lock` | tokenizers-cpp passes no `cargo --target` for a generic Linux cross build, so `libtokenizers_c.a` (and the oniguruma the `onig` crate compiles) is built for the host glibc triple and fails to link (`undefined reference to __memcpy_chk`); on aarch64 it hard-codes `--target aarch64-unknown-linux-gnu` with a nonexistent `aarch64-unknown-linux-gnu-gcc`. The patch adds two ExternalProject steps when the toolchain file sets `LITERTLM_MUSL_HOOK_DIR`: drop that aarch64 line, and rebuild the crate for musl with `--locked` against the pinned lock file (tokenizers-cpp does not commit one). |
| `0005` no shallow clone of commit pins | ANTLR, MiniZip and Minja are pinned to commits but declared `GIT_SHALLOW true`; a shallow clone holds only the branch tip, so ANTLR's checkout already fails (`fatal: unable to read tree (7d577039...)`). |
| `server` step (link line reuse) | LiteRT-LM's CMake has no installable library or shared C-ABI target. The server is linked with `litert_lm_main`'s own whole-archive link line, `server.o` swapped in for `litert_lm_main.cc.o`, build-tree rpaths dropped and `RUNPATH $ORIGIN/../lib` added. |
| `jre` step | The ANTLR tool jar that generates LiteRT-LM's tool-call parsers needs `java`, which the build neither documents nor checks (`Error 127`). |

## Licenses

`collect-licenses.py` copies the license files of every statically linked component from the exact
fetched sources (C/C++ dependencies, TFLite's own dependencies, every Rust crate in the resolved
graphs of both Rust staticlibs, the Rust standard library) into `licenses/` and writes
`licenses/INDEX.md`. A component with no findable license file fails the step (or, with
`--allow-gaps`, is listed under "Gaps"). No NPU vendor SDK is fetched or linked (patch 0002); the collector fails if a vendor SDK header tree shows up in the
build.

## Packaging for OpenWrt / prplOS

Notes from the first package of this bundle (prpl-harness, prplOS 5.1 x86_64 SDK):

- Install `bin/` and `lib/` as siblings (the binary's RUNPATH is `$ORIGIN/../lib`). The `/usr/bin` entry
  can exec `bin/litert-lm-server` directly or be a symlink to `run`.
- Declare `DEPENDS:=+libstdcpp +libgcc +zlib` unconditionally. A per-arch form such as `+x86_64:zlib`
  did not satisfy the SDK's shared-library check (`missing dependencies for the following libraries:
  libz.so.1`).
- The SDK does not build zlib, so it cannot see the `libz.so.1` soname even with the dependency
  declared. Declare it through `Package/<name>/extra_provides` (`echo 'libz.so.1'`).
- procd's `LD_PRELOAD=/lib/libsetlbf.so` is a musl library and is valid in this process; unsetting it
  is harmless but not needed.
- An XNNPACK cache written next to the model by the glibc v0.2.2 bundle is reused (renamed in place,
  no second copy).
