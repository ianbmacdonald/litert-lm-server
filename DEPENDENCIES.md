# litert-lm-server: external sources

Everything the musl build (`musl/build-musl.sh`, LiteRT-LM v0.19.0 CMake road) fetches, as
resolved in the validated x86_64 and aarch64 builds on 2026-10-31 (identical except the two
arch-specific archives noted) (`git rev-parse HEAD` of every checkout in the
build tree, plus the URL of every archive download). Statically linked unless noted. The server
itself vendors two headers: `third_party/httplib.h` (cpp-httplib, MIT) and `third_party/json.hpp`
(nlohmann/json, MIT).

No dependency's licence stops its source from being shipped in a public feed. The NPU vendor SDKs
(Qualcomm QAIRT, Samsung LiteCore, MediaTek NeuroPilot), which are not redistributable, are never
fetched: patch `0002` turns LiteRT's NPU support off, and LiteRT then skips its `vendors/`
directory (its `third_party/qairt` and `third_party/exynos_ai_litecore` are Bazel stubs of a few
lines, no SDK code). `bundle` refuses a binary carrying vendor SDK symbols.

## Pinned by LiteRT-LM v0.19.0 or by our patches

`(0001)` marks a pin added by `patches/musl/litert-lm/0001-*` (upstream fetches a moving branch).

| Source | URL | Commit / archive | Licence | Via |
|---|---|---|---|---|
| LiteRT-LM | https://github.com/google-ai-edge/LiteRT-LM | `771b06e1a2c7f70a399a718599109facf37e38fd` (v0.19.0) | Apache-2.0 | `build-musl.sh` clone |
| LiteRT | https://github.com/google-ai-edge/LiteRT | `4873c04819d7350b4a53e73458de3010029d3499` (0001) | Apache-2.0 | ExternalProject `litert_external` |
| TensorFlow (TFLite) | https://github.com/tensorflow/tensorflow | `fadb2ca7b5c17ba3b9380f32487cef62eebcf2c9` | Apache-2.0 | ExternalProject `tflite_external` |
| TensorFlow (second checkout, TFLite shim) | https://github.com/tensorflow/tensorflow | `a344c313f75bbe28d00abe63f5d49cd6f233b6d0` (`v2.21.0-rc0`) | Apache-2.0 | FetchContent in `tflite/shims/CMakeLists-shim.txt` |
| Abseil | https://github.com/abseil/abseil-cpp | `5650e9cf76d3be4318d5fa3af38ee483ddfd5e4a` (`20260526.0`) | Apache-2.0 | ExternalProject, prebuild + target |
| Protobuf | https://github.com/protocolbuffers/protobuf | `f377bfefc5e2cfab68b816903c25b23e091c439d` (`v36.1`) | BSD-3-Clause | ExternalProject, prebuild (host protoc) + target |
| FlatBuffers | https://github.com/google/flatbuffers | `187240970746d00bbd26b0f5873ed54d2477f9f3` (`v25.9.23`) | Apache-2.0 | ExternalProject, prebuild (host flatc) + target |
| GoogleTest | https://github.com/google/googletest | `52eb8108c5bdec04579160ae17225d66034bd723` (`v1.17.0`) | BSD-3-Clause | ExternalProject (build only, not linked) |
| SentencePiece | https://github.com/google/sentencepiece | `e0cce7d37b065b5140349dbe12c6bcf6192fdd78` (`v0.2.2`) | Apache-2.0 | ExternalProject |
| RE2 | https://github.com/google/re2 | `2da0056814cf180480a19f5cf811e7e1c054bf6d` (0001) | BSD-3-Clause | ExternalProject |
| OpenCL headers | https://github.com/KhronosGroup/OpenCL-Headers | `8275634cf9ec31b6484c2e6be756237cb583999d` (`v2024.05.08`) | Apache-2.0 | ExternalProject (headers only) |
| tokenizers-cpp | https://github.com/mlc-ai/tokenizers-cpp | `c586c52f93f7b060753bd2388eb96a105cb7374d` | Apache-2.0 | ExternalProject |
| msgpack-c (tokenizers-cpp submodule) | https://github.com/msgpack/msgpack-c | `092bc69b6e815980bce7808595c914dd3a29f905` | BSL-1.0 | git submodule |
| SentencePiece (tokenizers-cpp submodule) | https://github.com/google/sentencepiece | `e0f0f966959108415183d6cbe7a9051ca8bc2da1` | Apache-2.0 | git submodule |
| ANTLR 4 C++ runtime | https://github.com/antlr/antlr4 | `7d5770395bb7b02eb56e7c62662cb1d7c08f42a3` | BSD-3-Clause | FetchContent `antlr_lib` |
| ANTLR 4 tool (build-time code generator, not linked) | https://www.antlr.org/download/antlr-4.13.2-complete.jar | 4.13.2 jar | BSD-3-Clause | FetchContent URL `antlr_tool` |
| Corrosion (CMake/cargo glue, build only) | https://github.com/corrosion-rs/corrosion | `1499b14e4906a2890f5cee1547c8848db261753d` (`v0.6.1`) | MIT | FetchContent |
| llguidance | https://github.com/guidance-ai/llguidance | `f0971424ec072d3e4d4196bcc7f31a2f60527df9` (`v1.9.1`) | MIT | FetchContent |
| libpng | https://github.com/glennrp/libpng | `f135775ad4e5d4408d2e12ffcc71bb36e6b48551` (`v1.6.40`) | libpng-2.0 | FetchContent |
| KissFFT | https://github.com/mborgerding/kissfft | `7bce4153c6bc8aba2db0e889e576f9d00505cbe1` (`131.2.0`) | BSD-3-Clause | FetchContent; the one shared library in the bundle |
| miniaudio | https://github.com/mackron/miniaudio | `9634bedb5b5a2ca38c1ee7108a9358a4e233f14d` (`0.11.25`) | Unlicense or MIT-0 | FetchContent |
| MiniZip | https://github.com/domoticz/minizip | `aee7fbddf118d9363575af96310c29fa747d70c0` | Zlib | FetchContent |
| Minja | https://github.com/google/minja | `021c2293c187789ef13d56c6cfd89c9b134fd80f` | MIT | FetchContent |
| nlohmann/json | https://github.com/nlohmann/json | `55f93686c01528224f448c19128836e7df245f72` (`v3.12.0`) and `v3.12.0.zip` | MIT | FetchContent (git, and a URL zip) |
| stb | https://github.com/nothings/stb | `f58f558c120e9b32c217290b80bad1a0729fbb2c` | MIT or Unlicense | FetchContent |
| zlib | https://github.com/madler/zlib | `da607da739fa6047df13e66a2af6b8bec7c2a498` (0001) | Zlib | FetchContent |
| SafeInt (LiteRT) | https://github.com/dcleblanc/SafeInt | `4cafc9196c4da9c817992b20f5253ef967685bf8` (`3.0.28`) | MIT | FetchContent in LiteRT shim |
| ml-drift (LiteRT; GPU delegate sources, GPU off) | https://github.com/google-ai-edge/ml-drift | `1b18771f44c0be3d972847b31a80f6dc3d6964b5` | Apache-2.0 | FetchContent in LiteRT shim |

## Fetched by TFLite's own CMake (pinned in TensorFlow `fadb2ca7`)

| Source | URL | Commit / archive | Licence |
|---|---|---|---|
| XNNPACK | https://github.com/google/XNNPACK | `d89ef6669a14db203b3b7935b1b3862cb63fb6df` | BSD-3-Clause |
| cpuinfo | https://github.com/pytorch/cpuinfo | `8ce83db858065145192c97af90cb668ad72a12e9` | BSD-2-Clause |
| pthreadpool | https://github.com/google/pthreadpool/archive/15a6644ba1c45f1acc16ac1e883efc3e56c6bed2.zip | archive | BSD-2-Clause |
| FP16 | https://github.com/Maratyszcza/FP16/archive/0a92994d729ff76a58f692d3028ca1b64b145d91.zip | archive | MIT |
| FXdiv | https://github.com/Maratyszcza/FXdiv | `63058eff77e11aa15bf531df5dd34395ec3017c8` | MIT |
| ruy | https://github.com/google/ruy | `3286a34cc8de6149ac6844107dfdffac91531e72` | Apache-2.0 |
| ruy submodules (cpuinfo, googletest; not linked) | https://github.com/pytorch/cpuinfo, https://github.com/google/googletest | `082deffc80ce517f81dc2f3aebe6ba671fcd09c9`, `6c58c11d5497b6ee1df3cb400ce30deb72fc28c0` | BSD-2-Clause, BSD-3-Clause |
| gemmlowp | https://github.com/google/gemmlowp | `16e8662c34917be0065110bfcd9cc27d30f52fdf` | Apache-2.0 |
| Eigen | https://gitlab.com/libeigen/eigen | `ea13a98decd497a8c5588fb5de71b57bcf10d864` | MPL-2.0 (weak copyleft: source of the files must stay available; a source feed satisfies it) |
| farmhash | https://github.com/google/farmhash | `0d859a811870d10f53a594927d0d0b97573ad06d` | MIT |
| fft2d (Ooura) | https://storage.googleapis.com/mirror.tensorflow.org/github.com/petewarden/OouraFFT/archive/v1.0.tar.gz | archive | Ooura permissive |
| ml_dtypes (+ its Eigen submodule `7bf2968f`) | https://github.com/jax-ml/ml_dtypes | `00d98cd92ade342fef589c0470379abb27baebe9` | Apache-2.0, MPL-2.0 |
| ARM_NEON_2_x86_SSE (headers; x86_64 only) | https://storage.googleapis.com/mirror.tensorflow.org/github.com/intel/ARM_NEON_2_x86_SSE/archive/a15b489e1222b2087007546b4912e21293ea86ff.tar.gz | archive | BSD-2-Clause |
| KleidiAI (aarch64 only; linked by patch 0006) | https://gitlab.arm.com/kleidi/kleidiai/-/archive/4bc7bd457930de119f8b826ecfdebfbd9c08cf8c/kleidiai-4bc7bd457930de119f8b826ecfdebfbd9c08cf8c.zip | archive `4bc7bd45` | Apache-2.0 (BSD-3-Clause for its third_party/) |

## Rust crates (crates.io)

Two Rust static libraries are linked: LiteRT-LM's `litert_lm_deps` (llguidance, minijinja,
tokenizers, cxx, antlr4rust, serde, ...), resolved by LiteRT-LM v0.19.0's committed `Cargo.lock`,
and tokenizers-cpp's `tokenizers_c`, resolved by `musl/hooks/tokenizers-c.Cargo.lock` (ours:
tokenizers-cpp commits no lock file). Every crate's licence file is copied into the bundle's
`licenses/` by `musl/collect-licenses.py`; all are MIT, Apache-2.0, BSD, Unicode-3.0, Zlib or
similar permissive licences (see `licenses/INDEX.md` in the bundle). Plus the Rust standard library
of the toolchain (`rustc 1.98.1`, MIT/Apache-2.0).

## Build-time only (not shipped)

- Temurin 17.0.20.1+1 JRE, to run the ANTLR tool: URL and sha256 in `musl/build-musl.sh`.
- Host C/C++ compiler, cmake >= 3.25, rustup with `<arch>-unknown-linux-musl`, the prplOS 5.1 SDK.

## Building offline

LiteRT-LM v0.19.0 has no single "use local sources" switch: it is a superbuild of nested
ExternalProjects and FetchContent calls, the inner ones configured by the outer ones, and several
ExternalProjects (LiteRT, TFLite, RE2, tokenizers-cpp) have an `UPDATE_COMMAND` that runs
`git fetch origin <commit>` on every build. What works:

1. **Git sources (every row with a commit above):** serve them from a local mirror and redirect with
   git's `url.<base>.insteadOf`, e.g. a `GIT_CONFIG_GLOBAL` file holding
   `[url "file:///dl/git/"] insteadOf = https://github.com/` (and the same for `gitlab.com`). The
   superbuild's own clones, its `git fetch origin <commit>` update steps and the submodules all go
   through it unchanged. Each mirror must contain the pinned commit (a `git clone --mirror`
   does).
2. **Archive downloads (antlr jar, json zip, pthreadpool, FP16, fft2d, neon2sse, kleidiai):** FetchContent and
   ExternalProject skip the download when the file is already in their download directory with the
   expected name; pre-seed those paths, or mirror the URLs with an HTTP proxy. TFLite's modules also
   honour `-DOVERRIDABLE_FETCH_CONTENT_<name>_...`-style overrides, but those must reach TFLite's
   nested configure, which the outer CMake does not forward.
3. **FetchContent rows in LiteRT-LM's own `cmake/modules/fetch_content.cmake`:** the standard
   `FETCHCONTENT_SOURCE_DIR_<NAME>` (e.g. `FETCHCONTENT_SOURCE_DIR_ANTLR_LIB`) works when set in the
   toolchain file (the only file every nested configure reads); `FETCHCONTENT_FULLY_DISCONNECTED=ON`
   likewise.
4. **Rust:** `cargo vendor` both lock files (LiteRT-LM's `Cargo.lock` and
   `musl/hooks/tokenizers-c.Cargo.lock`) and point `CARGO_HOME/config.toml` at the vendored
   directory with `[source.crates-io] replace-with = "vendored"`; build with `CARGO_NET_OFFLINE=true`.

Validated tonight: the networked build. Not validated: an offline replay (see the leg report).
