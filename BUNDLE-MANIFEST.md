# litert-lm-server aarch64-glibc self-contained bundle — MANIFEST (BC_087)

Status: **BUNDLE SHIPPED (v0.1.0, 2026-07-23).** The compiler-family pivot landed: a
clang-19 aarch64 cc_toolchain (`bazel/cross_aarch64_clang/`) over the same ARM-GNU 11.3
sysroot cleared the NEON `target("dotprod")` wall; engine, C-ABI lib and CMake server are
all readelf-proven AArch64. Bundle assembled per this manifest, qemu-smoke-tested, and
published as a GitHub release asset (sha256 in the release notes).

Target: prpl gateway (musl host) carrying its own glibc aarch64 runtime. Host build
box: imac (x86_64, 14 GB RAM). Cross, CPU/serialized inference.

---

## Toolchain status (Step 1 — DONE + PROVEN; Step 2 — wall identified + unblock proven)

**Cross recipe (durable deliverable):** `bazel/cross_aarch64/{BUILD,README.md,hello.cc}`
in the litert-lm-server repo (working copy also at
`bazel-native/LiteRT-LM/cross_aarch64/`). It registers a `platform()` +
`toolchain()` binding an aarch64-glibc cc_toolchain to
`@platforms//cpu:aarch64 + os:linux`, selected via `--platforms` + `--extra_toolchains`.

**PROVEN:** a trivial `cc_binary` built with the recipe is genuine aarch64 glibc:
`ELF 64-bit LSB executable, ARM aarch64, ... interpreter /lib/ld-linux-aarch64.so.1, ... for GNU/Linux` (glibc, `libstdc++.so.6`+`libc.so.6` NEEDED).

**Full-tree cross-build (`//c:litert-lm`, `//runtime/engine:litert_lm_main`)** requires
four things together (all documented in `bazel/cross_aarch64/README.md`):
1. the C++ platform+toolchain recipe (`--platforms` + `--extra_toolchains`);
2. rust `aarch64-unknown-linux-gnu` in `rust_register_toolchains(extra_target_triples)`
   (WORKSPACE) — `@tokenizers_cpp` pulls in Rust;
3. host clang on `PATH` (`.bazelrc` forces `CC=clang`; host tools like `cxxbridge_cmd`
   need `@local_config_cc`);
4. `--cpu=aarch64` — vendored libs (`@cpuinfo`, TF/XLA) key arch `select()`s on the
   legacy `--cpu`, not `@platforms//cpu`.

With all four, analysis passes clean (13 427 targets configured) and the build compiled
**~1958/3450 target actions for aarch64** before the wall.

**WALL (compiler family):** ARM-GNU **gcc 11.3** rejects TFLite/LiteRT's Clang-style
NEON attribute `__attribute__((target("dotprod")))` in
`@litert//tflite/kernels/internal/optimized/4bit/neon_fully_connected_aarch64_sdot.cc`
(`error: pragma or attribute 'target("dotprod")' is not valid`). LiteRT's aarch64
optimized kernels are written for Clang; the ARM-GNU gcc toolchain is the wrong family.

**UNBLOCK (cheaply PROVEN):** the vendored **clang-19** cross-compiles aarch64+glibc
using the SAME ARM-GNU sysroot and **accepts** `target("dotprod")` — verified with a
one-file probe producing a genuine aarch64 glibc ELF:

    clang++ --target=aarch64-linux-gnu -march=armv8.2-a+dotprod \
      --sysroot=<arm-gnu>/aarch64-none-linux-gnu/libc \
      --gcc-toolchain=<arm-gnu>  <src>  # exit 0, ARM aarch64 ELF

Next step to produce the artifact: author a **clang-based** aarch64 cc_toolchain
(clang + lld, `--target=aarch64-linux-gnu`, ARM-GNU sysroot via `--sysroot`/
`--gcc-toolchain`) in place of the GNU one, keep requirements 2–4, resume the build.
Same sysroot ⇒ bundle layout, runtime-lib list, and licensing below are unchanged.
Cost note: iterating the 3450-target build costs ~10 min/wall on a 14 GB swap-bound box;
the number of further Clang-vs-GNU deltas past dotprod is unquantified — hence STOP+report
rather than thrash, per the cost mandate.

---

## Deliverable 1 — Bundle layout + runtime lib list + rpath/interpreter scheme

Layout (versioned tarball `litert-lm-server-aarch64-glibc-<ver>.tar.gz`):

    litert-lm-server-aarch64-glibc-<ver>/
      bin/litert-lm-server              # aarch64 ELF, patched interpreter+rpath
      lib/liblitert-lm.so               # aarch64 C-ABI engine (from //c:litert-lm)
      lib/libGemmaModelConstraintProvider.so  # prebuilt aarch64 (LiteRT-LM runfiles) — NEEDED by liblitert-lm.so
      lib/ld-linux-aarch64.so.1         # bundled glibc loader
      lib/libc.so.6  libm.so.6  libdl.so.2  libpthread.so.0  librt.so.1
      lib/libstdc++.so.6  libgcc_s.so.1
      run                               # wrapper (below)
      licenses/                         # Apache-2.0 (LiteRT-LM + server), glibc/GCC-runtime notices, ARM-GNU manifest
      BUNDLE-MANIFEST.md

Runtime libs are copied from the ARM-GNU 11.3 aarch64 sysroot
(`@aarch64_linux_toolchain/aarch64-none-linux-gnu/`): loader + `libc/lib64/*` for
glibc, `lib64/{libstdc++.so.6,libgcc_s.so.1}` for the C++/GCC runtime. The exact `NEEDED` closure was re-checked on the final artifacts (2026-07-23):
`bin/litert-lm-server` -> liblitert-lm.so, libstdc++, libm, libgcc_s, libc;
`liblitert-lm.so` -> libGemmaModelConstraintProvider.so (+ glibc set + loader);
`libGemmaModelConstraintProvider.so` -> libm, libpthread, librt, libdl, libc.
All members are in `lib/`; the build-box absolute RPATH on the server binary is
replaced by `$ORIGIN/../lib`, and both engine libs get rpath `$ORIGIN`.

**rpath/interpreter scheme (musl-host-safe):**
- `patchelf --set-interpreter '$ORIGIN/../lib/ld-linux-aarch64.so.1' bin/litert-lm-server`
- `patchelf --set-rpath '$ORIGIN/../lib' bin/litert-lm-server`
- `patchelf --set-rpath '$ORIGIN' lib/liblitert-lm.so`
- `run` wrapper as belt-and-suspenders (works even if patchelf is skipped):

      #!/bin/sh
      d=$(cd "$(dirname "$0")" && pwd)
      exec "$d/lib/ld-linux-aarch64.so.1" --library-path "$d/lib" "$d/bin/litert-lm-server" "$@"

This makes the bundle self-contained: it carries its own glibc loader + libc, so it
runs on a **musl** gateway host with no glibc installed. `patchelf` 0.18 + `qemu-user` are installed on imac (2026-07-23); the shipped bundle is
patchelf-patched AND carries the `run` wrapper. Note the `$ORIGIN` PT_INTERP is not
kernel-expanded on direct exec — the `run` wrapper (loader-explicit) is the supported
entrypoint on the gateway.

## Deliverable 2 — `.litertlm` model provisioning

- Server contract: `--model <path>` (required), `--port 8080` (default), `--host`,
  `--model-id`; endpoints `/health`, `/v1/models`, `/v1/chat/completions`.
- Validated model on imac: `qwen3_0_6b_mixed_int4.litertlm` (497 664 000 bytes,
  `models/`). At first load the engine writes a sibling XNNPACK cache
  (`*.litertlm.xnnpack_cache_<...>`, ~339 MB) next to the model — the model dir must be
  **writable** on the gateway (or pre-warm the cache and ship it read-only).
- **Recommendation:** do NOT bake the ~0.5 GB model into the gateway image. Pull it at
  first run into a writable data volume and point `--model` at it. Keep the bundle
  (binary+libs, tens of MB) separate from the model payload so image and model version
  independently. If pinned/offline, mount the model read-only and point XNNPACK cache at
  a writable tmp via the model dir being writable.
- **The target directory must be PERSISTENT, NON-TMPFS and hold ~1 GB** (~0.5 GB model +
  ~339 MB XNNPACK cache, plus headroom). An earlier revision of this manifest suggested
  `/var/lib/litert-lm/models/`; that is **wrong on an OpenWrt gateway**, where `/var` is
  **tmpfs (RAM)** and the NAND overlay is far too small. On the ipq807x CPE this needs
  external or data-partition storage (USB or a mounted data volume) — prpl-harness
  defaults the uci model path to a provisioned mount (`/mnt/litert-lm/models`) and will
  confirm the real CPE mount at deploy. Corrected per prpl-harness#BC_090.

## Deliverable 3 — License (SHIPPING A BUNDLE — read this)

- **litert-lm-server** (our code, `server.cpp`): our project's license — state it in the
  repo (currently unstated in README; add a LICENSE before shipping).
- **liblitert-lm.so** (LiteRT-LM / LiteRT / TensorFlow): **Apache-2.0**
  (LiteRT-LM `LICENSE` is Apache 2.0). Permissive.
- **Vendored glibc runtime libs (the self-contained payload) — GPL/LGPL, FLAG:**
  - glibc (`libc.so.6`, `libm.so.6`, loader `ld-linux-aarch64.so.1`, `libdl`,
    `libpthread`, `librt`): **LGPL-2.1-or-later**.
  - `libstdc++.so.6`: **GPL-3.0 WITH GCC-Runtime-Library-Exception**.
  - `libgcc_s.so.1`: **GPL WITH GCC-Runtime-Library-Exception**.
  - Sourced from ARM GNU Toolchain 11.3.Rel1 (`aarch64-none-linux-gnu`); the Bazel
    cc_toolchain wrapper is TF-tagged `licenses(["restricted"])` (GPLv3).
  - Implication: shipping these libs is fine (the GCC runtime exception + LGPL dynamic
    linking permit redistribution), **but** LGPL requires you convey license text and
    allow re-linking of the LGPL libs, and you must include the glibc/libstdc++/libgcc
    license notices in the bundle. Include a `licenses/` dir with the ARM-GNU/glibc/GCC
    notices. (Switching the compiler to clang does NOT change this — the *runtime libs*
    are still glibc + libstdc++/libgcc from the GNU sysroot.)

## Deliverable 4 — Arch token

- Token: **`aarch64`**
- Exact `file` string (from the proven aarch64 glibc build):
  `ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), dynamically linked,
  interpreter /lib/ld-linux-aarch64.so.1, ... for GNU/Linux` (post-patchelf the
  interpreter becomes `$ORIGIN/../lib/ld-linux-aarch64.so.1`).
- Triple: `aarch64-none-linux-gnu` (build) / runtime `aarch64-linux-gnu` glibc.

## Tarball sha256

Published per release: the authoritative sha256 for each
`litert-lm-server-aarch64-glibc-<ver>.tar.gz` is stated in the GitHub release notes of
the tag that ships it (and mirrored in the prpl feed pin). v0.1.0 built 2026-07-23 from
LITERT_REF 622f1f3c / clang-19 cross toolchain; qemu-aarch64 smoke-tested (health +
chat completion) before publish.

---

## Provenance / build knobs (for whoever resumes)

- Bazel 7.6.1 via bazelisk; output base `/home/imac/.cache/bazel/_bazel_imac/18dd4e31...`
  (the existing x86 base — reused to avoid a multi-GB TF re-fetch; aarch64 outputs are a
  separate config dir and do not evict the k8 artifacts).
- LiteRT-LM WORKSPACE refs: `LITERT_REF=622f1f3c…`, `TENSORFLOW_REF=f197d455…`.
- ARM-GNU sysroot: `@aarch64_linux_toolchain` (ARM GNU Toolchain 11.3.Rel1).
- Host clang for host tools + the proposed target compiler: vendored LLVM 19.1.7 at
  `/home/imac/lemonade-litert-build/toolchain/LLVM-19.1.7-Linux-X64/bin`.
- WORKSPACE edit made this session: added `"aarch64-unknown-linux-gnu"` to
  `rust_register_toolchains(extra_target_triples=...)`.
