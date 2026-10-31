# Patches for the musl (prplOS) build

Each directory holds a `git format-patch` series for one third-party source, made against the
upstream commit named below. `musl/build-musl.sh` applies them in order with `git apply` after it
clones and verifies that commit; `git am` applies them as well.

| Directory | Upstream | Base commit |
|---|---|---|
| `litert-lm/` | https://github.com/google-ai-edge/LiteRT-LM | `v0.19.0` = `771b06e1a2c7f70a399a718599109facf37e38fd` |

No other third-party tree is patched as source. Two LiteRT-LM patches change other trees at build
time, through LiteRT-LM's own CMake (so they are LiteRT-LM patches):

- `0002` turns LiteRT's NPU and vendor options off (LiteRT then skips its `vendors/` directory)
  and drops the 17 vendor archives from LiteRT-LM's committed LiteRT target map.
- `0004` deletes one line of tokenizers-cpp's `CMakeLists.txt` (`c586c52f`) and runs
  `musl/hooks/05-tokenizers-c-musl.sh`, which rebuilds tokenizers-cpp's Rust crate for the musl
  target against `musl/hooks/tokenizers-c.Cargo.lock` (tokenizers-cpp commits no lock file).

| Patch | Why |
|---|---|
| `0001-build-pin-LiteRT-RE2-and-zlib-to-commits` | v0.19.0 fetches LiteRT `main`, RE2 `main` and zlib `master`. Pinned to their heads as of the release commit: LiteRT `4873c048`, RE2 `2da00568`, zlib `da607da7`. |
| `0002-build-CPU-only-LiteRT-no-NPU-vendor-SDKs` | v0.19.0 hard-codes `LITERT_ENABLE_NPU=ON` and `LITERT_ENABLE_QUALCOMM=ON`, which downloads the Qualcomm QAIRT and Samsung SDK headers and builds their dispatch libraries. |
| `0003-build-use-the-host-protoc-wherever-one-is-known-with` | The host protoc is selected only in one phase and without `FORCE`; a sub-project that caches the cross-built protoc cannot run it. |
| `0004-build-musl-cross-build-hooks-for-tokenizers-cpp` | tokenizers-cpp builds its Rust archive for the host glibc triple in a generic Linux cross build, and hard-codes a nonexistent `aarch64-unknown-linux-gnu-gcc` on aarch64. Active only when the toolchain file sets `LITERTLM_MUSL_HOOK_DIR`. |
| `0005-build-no-shallow-clone-of-commit-pinned-FetchContent` | ANTLR, MiniZip and Minja are pinned to commits but cloned with `GIT_SHALLOW`, which only holds the branch tip; ANTLR's checkout already fails (`unable to read tree`). |
| `0006-build-link-KleidiAI-on-aarch64` | On aarch64 XNNPACK calls KleidiAI, whose archive the committed (x86_64-generated) TFLite target map does not name; `libLiteRt.so` fails to link (`undefined reference to kai_run_lhs_quant_pack_qai8dxp_f32`). No-op on x86_64. |

To re-cut the series against a new tag: check out the tag, `git am` these files, resolve, then
`git format-patch --zero-commit --no-signature -o patches/musl/litert-lm <tag>..HEAD`.
