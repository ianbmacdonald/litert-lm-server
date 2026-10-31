#!/usr/bin/env bash
# Build litert-lm-server for prplOS 5.1 x86_64 or aarch64 (musl) from scratch and package the release bundle.
#
#   musl/build-musl.sh [--arch aarch64] --staging <prplOS staging dir> --work <empty or previous work dir>
#
# Steps (run in order; each one fails loudly and names its log):
#   preflight  tools, rust musl target, staging tree layout
#   jre        pinned Temurin 17 JRE (ANTLR code generation needs java)
#   toolchain  render compiler wrappers, CMake toolchain file and hook env into <work>/toolchain
#   source     clone LiteRT-LM at the pinned tag, verify the commit, apply patches/musl/litert-lm/*.patch
#   configure  cmake the LiteRT-LM superbuild with the musl toolchain
#   build      make the superbuild (hook 05 runs inside it as an ExternalProject step)
#   server     compile server.cpp and link it with litert_lm_main's whole-archive link line
#   licenses   collect third-party license files into <work>/licenses
#   bundle     assemble, verify (readelf) and tar the bundle into <work>/dist
#
# Re-running is safe: finished downloads, the clone and the configure are reused, make is
# incremental, and server/licenses/bundle are regenerated. --from/--to/--only restrict the steps.
# A changed patch set refuses to reuse a work dir (the fetched external trees would not be
# re-patched or reconfigured); start from an empty one.
set -euo pipefail
exec 3>&2

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
PATCHES=$REPO/patches/musl/litert-lm
HOOKS=$HERE/hooks

LITERTLM_REPO=https://github.com/google-ai-edge/LiteRT-LM.git
LITERTLM_TAG=v0.19.0
LITERTLM_SHA=771b06e1a2c7f70a399a718599109facf37e38fd
JRE_URL=https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1%2B1/OpenJDK17U-jre_x64_linux_hotspot_17.0.20.1_1.tar.gz
JRE_SHA256=0b2b640e3046b64c8ec504de0ab9d91bb5610182bda21fad454681ce54d45a62
EXPECTED_NEEDED="libc.so libgcc_s.so.1 libkissfft-float.so.131 libstdc++.so.6 libz.so.1"
KISSFFT_SONAME=libkissfft-float.so.131

ARCH=${MUSL_ARCH:-x86_64}
STAGING=${PRPLOS_STAGING_DIR:-}
WORK=${MUSL_WORK_DIR:-}
JOBS=${MUSL_JOBS:-8}
MEMORY_MAX=${MUSL_MEMORY_MAX:-16G}
VERSION=${MUSL_BUNDLE_VERSION:-v0.4.0}
SCOPE=1
FROM=""
TO=""
ONLY=""
STEPS="preflight jre toolchain source configure build server licenses bundle"

usage() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    cat <<EOF

Options (environment variable in brackets):
  --arch A          x86_64 (default) or aarch64 (cortex-a53) [MUSL_ARCH]
  --staging DIR     prplOS SDK staging dir holding toolchain-x86_64_gcc-13.3.0_musl and
                    target-x86_64_musl, or toolchain-aarch64_cortex-a53_gcc-13.3.0_musl and
                    target-aarch64_cortex-a53_musl [PRPLOS_STAGING_DIR]
  --work DIR        work directory; everything is created under it [MUSL_WORK_DIR]
  --jobs N          make parallelism, default 8 [MUSL_JOBS]
  --memory-max SZ   MemoryMax for the systemd user scope around heavy steps, default 16G [MUSL_MEMORY_MAX]
  --no-scope        do not wrap heavy steps in systemd-run --user --scope (still nice 19)
  --version V       bundle version, default v0.4.0 [MUSL_BUNDLE_VERSION]
  --from STEP       start at STEP;  --to STEP  stop after STEP;  --only STEP  run only STEP
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH=$2; shift 2 ;;
        --staging) STAGING=$2; shift 2 ;;
        --work) WORK=$2; shift 2 ;;
        --jobs) JOBS=$2; shift 2 ;;
        --memory-max) MEMORY_MAX=$2; shift 2 ;;
        --no-scope) SCOPE=0; shift ;;
        --version) VERSION=$2; shift 2 ;;
        --from) FROM=$2; shift 2 ;;
        --to) TO=$2; shift 2 ;;
        --only) ONLY=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "build-musl.sh: unknown argument $1" >&2; usage >&2; exit 2 ;;
    esac
done

die() { echo "build-musl.sh: ERROR: $*" >&2; exit 1; }
[ -n "$STAGING" ] || die "--staging (or PRPLOS_STAGING_DIR) is required"
[ -n "$WORK" ] || die "--work (or MUSL_WORK_DIR) is required"
case "$JOBS" in ''|*[!0-9]*) die "--jobs must be a number" ;; esac
[ "$JOBS" -le 12 ] || echo "build-musl.sh: warning: --jobs $JOBS is above the 12 this recipe was validated with" >&2
for s in $FROM $TO $ONLY; do case " $STEPS " in *" $s "*) ;; *) die "unknown step $s (steps: $STEPS)" ;; esac; done

STAGING=$(cd "$STAGING" 2>/dev/null && pwd) || die "staging dir does not exist"
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
case "$ARCH" in
    x86_64) SDK_TARGET=x86_64 ROOTFS_NAME=root-x86 CPU_FLAGS="" ;;
    aarch64) SDK_TARGET=aarch64_cortex-a53 ROOTFS_NAME=root-qualcommax CPU_FLAGS=" -march=armv8-a+crc -mtune=cortex-a53" ;;
    *) die "--arch must be x86_64 or aarch64" ;;
esac
CROSS=$ARCH-openwrt-linux-musl
RUST_TARGET=$ARCH-unknown-linux-musl
EXPECTED_INTERP=/lib/ld-musl-$ARCH.so.1
TC_DIR=$STAGING/toolchain-${SDK_TARGET}_gcc-13.3.0_musl
TC_BIN=$TC_DIR/bin
TARGET_DIR=$STAGING/target-${SDK_TARGET}_musl
ROOTFS=$TARGET_DIR/$ROOTFS_NAME
TOOLCHAIN=$WORK/toolchain
SRC=$WORK/src
BUILD=$WORK/build
INNER=$BUILD/litert_lm/build
OUT=$WORK/out
LOGS=$WORK/logs
DIST=$WORK/dist
NAME=litert-lm-server-$ARCH-musl-$VERSION
export STAGING_DIR=$STAGING
export PATH=$WORK/jre/bin:$HOME/.cargo/bin:$PATH
export CARGO_BUILD_JOBS=4
unset CMAKE_BUILD_PARALLEL_LEVEL
mkdir -p "$LOGS" "$WORK/stamps" "$WORK/downloads"
if [ -f "$WORK/stamps/arch" ]; then
    [ "$(cat "$WORK/stamps/arch")" = "$ARCH" ] || die "work dir $WORK was built for $(cat "$WORK/stamps/arch"), not $ARCH: use an empty --work"
else
    echo "$ARCH" > "$WORK/stamps/arch"
fi

# Run a heavy command at nice 19, inside a memory-capped systemd user scope unless --no-scope.
heavy() {
    if [ "$SCOPE" = 1 ]; then
        systemd-run --user --scope --quiet -p MemoryMax="$MEMORY_MAX" -p MemorySwapMax=0 -- nice -n 19 "$@"
    else
        nice -n 19 "$@"
    fi
}

CURRENT_STEP=""
CURRENT_LOG=""
on_exit() {
    rc=$?
    if [ $rc -ne 0 ] && [ -n "$CURRENT_STEP" ]; then
        echo "build-musl.sh: step '$CURRENT_STEP' FAILED (rc=$rc)" >&3
        if [ -n "$CURRENT_LOG" ] && [ -f "$CURRENT_LOG" ]; then
            echo "---- last 40 lines of $CURRENT_LOG ----" >&3
            tail -n 40 "$CURRENT_LOG" >&3
            echo "---- full log: $CURRENT_LOG ----" >&3
        fi
    fi
}
trap on_exit EXIT

step_preflight() {
    local t missing=""
    for t in bash cmake make git python3 curl tar gzip sha256sum cargo rustup rustc nice sed awk find; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    [ -z "$missing" ] || die "missing tools:$missing"
    [ "$SCOPE" = 0 ] || command -v systemd-run > /dev/null 2>&1 || die "missing tools: systemd-run (or pass --no-scope)"
    [ "$SCOPE" = 0 ] || systemd-run --user --scope --quiet -p MemoryMax=1G -- true \
        || die "systemd-run --user --scope does not work here (no user manager?); pass --no-scope"
    rustup target list --installed > "$LOGS/rust-targets.txt" || die "rustup target list failed"
    grep -x "$RUST_TARGET" "$LOGS/rust-targets.txt" > /dev/null \
        || die "rust target $RUST_TARGET missing: rustup target add $RUST_TARGET"
    [ -x "$TC_BIN/$CROSS-gcc" ] || die "no musl gcc at $TC_BIN/$CROSS-gcc"
    [ -x "$TC_BIN/$CROSS-g++" ] || die "no musl g++ in $TC_BIN"
    [ -d "$TARGET_DIR/usr/include" ] || die "no target sysroot headers at $TARGET_DIR/usr/include"
    [ -e "$TARGET_DIR/usr/lib/libz.so" ] || die "no target zlib at $TARGET_DIR/usr/lib/libz.so"
    "$TC_BIN/$CROSS-gcc" --version | head -1
    cmake --version | head -1
    rustc --version
    echo "arch=$ARCH staging=$STAGING work=$WORK jobs=$JOBS memory_max=$MEMORY_MAX scope=$SCOPE version=$VERSION"
}

step_jre() {
    local tgz=$WORK/downloads/${JRE_URL##*/}
    if [ -x "$WORK/jre/bin/java" ] && [ -f "$WORK/stamps/jre" ]; then echo "JRE present"; "$WORK/jre/bin/java" -version 2>&1; return 0; fi
    if [ ! -f "$tgz" ] || ! echo "$JRE_SHA256  $tgz" | sha256sum -c --status; then
        curl -fL --retry 3 -o "$tgz.part" "$JRE_URL" || die "JRE download failed: $JRE_URL"
        mv "$tgz.part" "$tgz"
    fi
    echo "$JRE_SHA256  $tgz" | sha256sum -c || die "JRE sha256 mismatch for $tgz"
    rm -rf "$WORK/jre" "$WORK/jre.tmp"
    mkdir -p "$WORK/jre.tmp"
    tar -xzf "$tgz" -C "$WORK/jre.tmp" --strip-components=1
    mv "$WORK/jre.tmp" "$WORK/jre"
    "$WORK/jre/bin/java" -version 2>&1 || die "extracted JRE does not run"
    touch "$WORK/stamps/jre"
}

render() {
    sed -e "s#@STAGING_DIR@#$STAGING#g" -e "s#@TC_BIN@#$TC_BIN#g" -e "s#@TC_DIR@#$TC_DIR#g" \
        -e "s#@TARGET_DIR@#$TARGET_DIR#g" -e "s#@TOOLCHAIN_DIR@#$TOOLCHAIN#g" -e "s#@BUILD_DIR@#$BUILD#g" -e "s#@WORK_DIR@#$WORK#g" \
        -e "s#@ARCH@#$ARCH#g" -e "s#@CPU_FLAGS@#$CPU_FLAGS#g" "$@"
}

step_toolchain() {
    mkdir -p "$TOOLCHAIN"
    render -e "s#@TOOL@#gcc#g" "$HERE/wrap/musl-cc.in" > "$TOOLCHAIN/musl-gcc"
    render -e "s#@TOOL@#g++#g" "$HERE/wrap/musl-cc.in" > "$TOOLCHAIN/musl-g++"
    render "$HERE/musl-toolchain.cmake.in" > "$TOOLCHAIN/musl-toolchain.cmake"
    cat > "$TOOLCHAIN/musl-env.sh" <<EOF
# Rendered by build-musl.sh; sourced by the 05 hook step.
export STAGING_DIR=$STAGING
export PATH=$WORK/jre/bin:$HOME/.cargo/bin:\$PATH
MUSL_CC=$TOOLCHAIN/musl-gcc
MUSL_CXX=$TOOLCHAIN/musl-g++
MUSL_AR=$TC_BIN/$CROSS-ar
MUSL_NM=$TC_BIN/$CROSS-nm
MUSL_JOBS=4
EOF
    cp "$HOOKS/05-tokenizers-c-musl.sh" "$HOOKS/tokenizers-c.Cargo.lock" "$TOOLCHAIN/"
    chmod +x "$TOOLCHAIN/musl-gcc" "$TOOLCHAIN/musl-g++" "$TOOLCHAIN"/0*.sh
    echo 'int main(void){return 0;}' > "$TOOLCHAIN/probe.c"
    "$TOOLCHAIN/musl-gcc" -o "$TOOLCHAIN/probe" "$TOOLCHAIN/probe.c" -lz || die "musl-gcc wrapper cannot link a probe against -lz"
    "$TC_BIN/$CROSS-readelf" -lW "$TOOLCHAIN/probe" > "$TOOLCHAIN/probe.readelf" || die "readelf failed on the probe"
    grep -F "$EXPECTED_INTERP" "$TOOLCHAIN/probe.readelf" > /dev/null \
        || die "probe binary does not use $EXPECTED_INTERP"
    ls -la "$TOOLCHAIN"
}

step_source() {
    if [ ! -d "$SRC/.git" ]; then
        git clone --branch "$LITERTLM_TAG" --depth 1 "$LITERTLM_REPO" "$SRC.tmp" || die "clone of $LITERTLM_REPO $LITERTLM_TAG failed"
        mv "$SRC.tmp" "$SRC"
    fi
    local head
    head=$(git -C "$SRC" rev-parse HEAD)
    [ "$head" = "$LITERTLM_SHA" ] || die "LiteRT-LM $LITERTLM_TAG resolved to $head, expected $LITERTLM_SHA"
    local p
    for p in "$PATCHES"/*.patch; do
        if git -C "$SRC" apply --reverse --check "$p" 2>/dev/null; then
            echo "already applied: ${p##*/}"
        else
            git -C "$SRC" apply --check "$p" || die "patch ${p##*/} does not apply to $LITERTLM_TAG"
            git -C "$SRC" apply "$p"
            echo "applied: ${p##*/}"
        fi
    done
    git -C "$SRC" status --short
    patchset_hash > "$WORK/stamps/patchset.new"
    if [ -f "$WORK/stamps/patchset" ] && ! cmp -s "$WORK/stamps/patchset" "$WORK/stamps/patchset.new"; then
        die "the patch set changed since this work dir was configured; build in an empty work dir"
    fi
    mv "$WORK/stamps/patchset.new" "$WORK/stamps/patchset"
}

patchset_hash() {
    (cd "$REPO" && sha256sum patches/musl/litert-lm/*.patch musl/hooks/* musl/musl-toolchain.cmake.in musl/wrap/*.in)
}

# LiteRT-LM >= 0.19 takes the prebuild (host protoc/flatc) compilers from LITERTLM_CC/CXX and the
# target compilers from LITERTLM_CC_NDK/CXX_NDK; without them both phases use the toolchain file's
# musl compilers and the host tools cannot run (flatc: not found).
step_configure() {
    if [ -f "$BUILD/Makefile" ] && [ -f "$WORK/stamps/configure" ]; then echo "configured already"; return 0; fi
    mkdir -p "$BUILD"
    cmake -S "$SRC" -B "$BUILD" -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN/musl-toolchain.cmake" -DENABLE_CCACHE=OFF \
        -DLITERTLM_CC="$(command -v cc)" -DLITERTLM_CXX="$(command -v c++)" \
        -DLITERTLM_CC_NDK="$TOOLCHAIN/musl-gcc" -DLITERTLM_CXX_NDK="$TOOLCHAIN/musl-g++" \
        || die "cmake configure failed"
    touch "$WORK/stamps/configure"
}

step_build() {
    date -u +"build start %FT%TZ"
    # Unix Makefiles: the nested ExternalProject builds share one make jobserver capped at --jobs.
    heavy make -C "$BUILD" -j"$JOBS" || die "superbuild make failed"
    date -u +"build end %FT%TZ"
    [ -f "$INNER/litert_lm_main" ] || die "superbuild finished without $INNER/litert_lm_main"
    [ -f "$INNER/CMakeFiles/litert_lm_main.dir/link.txt" ] || die "no litert_lm_main link.txt"
}

step_server() {
    mkdir -p "$OUT"
    "$TOOLCHAIN/musl-g++" -std=c++17 -O2 -DNDEBUG -I"$SRC" -I"$SRC/c" -I"$REPO/third_party" \
        -c "$REPO/server.cpp" -o "$OUT/server.o" || die "server.cpp compile failed"
    # Reuse litert_lm_main's whole-archive link line: swap in server.o and the output name, drop the
    # build-tree rpaths, and give the binary RUNPATH $ORIGIN/../lib so it finds lib/ without a wrapper.
    python3 - "$INNER/CMakeFiles/litert_lm_main.dir/link.txt" "$OUT" > "$OUT/link-server.sh" <<'PY' || die "link.txt rewrite failed"
import re, sys
link, out = sys.argv[1], sys.argv[2]
cmd = open(link).read().strip()
objs = re.findall(r" CMakeFiles/litert_lm_main\.dir/\S*litert_lm_main\.cc\.o(?= )", cmd)
assert len(objs) == 1, f"main object not found once in link.txt: {objs}"
cmd = cmd.replace(objs[0], f" {out}/server.o")
assert cmd.count(" -o litert_lm_main ") == 1, "output name not found once in link.txt"
cmd = cmd.replace(" -o litert_lm_main ", f" -o {out}/litert-lm-server ")
cmd = re.sub(r" -Wl,--dependency-file=\S+", "", cmd)
cmd, n = re.subn(r" -Wl,-rpath,\S+", "", cmd)
cmd += " -Wl,--enable-new-dtags '-Wl,-rpath,$ORIGIN/../lib'"
print("set -e")
print(cmd)
PY
    (cd "$INNER" && heavy bash "$OUT/link-server.sh") || die "server link failed"
    local kiss
    kiss=$(find "$INNER/_deps/kissfft_lib-build" -maxdepth 1 -name 'libkissfft-float.so.131*' -type f -print -quit)
    [ -n "$kiss" ] || die "no libkissfft-float.so.131* in $INNER/_deps/kissfft_lib-build"
    "$TC_BIN/$CROSS-strip" -o "$OUT/$KISSFFT_SONAME" "$kiss"
    "$TC_BIN/$CROSS-strip" -o "$OUT/litert-lm-server.stripped" "$OUT/litert-lm-server"
    ls -la "$OUT"
}

step_licenses() {
    python3 "$HERE/collect-licenses.py" --repo "$REPO" --src "$SRC" --build "$BUILD" \
        --lockfile "$HOOKS/tokenizers-c.Cargo.lock" --out "$WORK/licenses" \
        --rust-target "$RUST_TARGET" --arch "$ARCH" || die "license collection failed"
}

readelf_evidence() {
    local re=$TC_BIN/$CROSS-readelf f=$1
    echo "## $f"
    "$re" -lW "$f" | grep -E "Requesting program interpreter" || true
    "$re" -dW "$f" | grep -E "\((NEEDED|RUNPATH|RPATH|SONAME)\)" || true
}

step_bundle() {
    local b=$DIST/$NAME re=$TC_BIN/$CROSS-readelf
    [ -f "$OUT/litert-lm-server.stripped" ] || die "run the server step first"
    [ -f "$WORK/licenses/INDEX.md" ] || die "run the licenses step first"
    rm -rf "$b" "$DIST/$NAME.tar.gz" "$DIST/$NAME.tar.gz.sha256"
    mkdir -p "$b/bin" "$b/lib"
    install -m 0755 "$OUT/litert-lm-server.stripped" "$b/bin/litert-lm-server"
    install -m 0755 "$OUT/$KISSFFT_SONAME" "$b/lib/$KISSFFT_SONAME"
    render "$HERE/run.in" > "$b/run"
    chmod 0755 "$b/run"
    cp -a "$WORK/licenses" "$b/licenses"

    # Verify before packaging.
    local interp runpath needed
    interp=$("$re" -lW "$b/bin/litert-lm-server" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
    [ "$interp" = "$EXPECTED_INTERP" ] || die "interpreter is '$interp', expected $EXPECTED_INTERP"
    runpath=$("$re" -dW "$b/bin/litert-lm-server" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')
    [ "$runpath" = '$ORIGIN/../lib' ] || die "RUNPATH is '$runpath', expected \$ORIGIN/../lib"
    "$re" -dW "$b/bin/litert-lm-server" > "$DIST/dynamic.txt" || die "readelf -d failed"
    if grep -F "(RPATH)" "$DIST/dynamic.txt" > /dev/null; then die "binary carries a DT_RPATH"; fi
    rm -f "$DIST/dynamic.txt"
    needed=$("$re" -dW "$b/bin/litert-lm-server" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort | tr '\n' ' ' | sed 's/ $//')
    [ "$needed" = "$EXPECTED_NEEDED" ] || die "NEEDED is '$needed', expected '$EXPECTED_NEEDED'"
    local n
    [ -e "$ROOTFS$EXPECTED_INTERP" ] || die "the musl loader $EXPECTED_INTERP is not in the prplOS rootfs $ROOTFS"
    for n in libc.so libgcc_s.so.1 libstdc++.so.6 libz.so.1; do
        [ -e "$ROOTFS/lib/$n" ] || [ -e "$ROOTFS/usr/lib/$n" ] || die "NEEDED $n is not in the prplOS rootfs $ROOTFS"
    done
    { readelf_evidence "$b/bin/litert-lm-server"; readelf_evidence "$b/lib/$KISSFFT_SONAME"; } > "$DIST/readelf-$NAME.txt"

    # CPU-only (patch 0002): nothing compiled from an NPU vendor SDK may reach the binary. Since
    # v0.19 LiteRT's core runtime carries its own (Apache-2.0) per-vendor option setters
    # (LrtQualcommOptions*, LrtSamsungOptions*) and their help strings, which name QAIRT, QNN
    # libraries and Exynos; those are not SDK code. The check therefore looks for the SDK's own
    # API symbols (QNN C API Qnn<Area>_<fn>, QnnInterface_*, MediaTek Neuron*_, Samsung ENN) in
    # the symbol table, defined or undefined.
    "$TC_BIN/$CROSS-nm" -C "$OUT/litert-lm-server" > "$DIST/symbols-and-strings.txt" || die "nm failed"
    if grep -E '[ _](Qnn[A-Z][A-Za-z]*_[A-Za-z]+|QnnInterface|Neuron[A-Z][A-Za-z]*_[A-Za-z]+|NeuronAdapter|graph_wrapper_api|graphgen_c|Enn[A-Z][A-Za-z]*)\b' \
        "$DIST/symbols-and-strings.txt" > "$DIST/vendor-sdk-hits.txt"; then
        die "vendor SDK symbols in the binary (see $DIST/vendor-sdk-hits.txt)"
    fi
    rm -f "$DIST/symbols-and-strings.txt" "$DIST/vendor-sdk-hits.txt"

    local bin_sha kiss_sha srv_rev srv_dirty
    bin_sha=$(sha256sum "$b/bin/litert-lm-server" | cut -d' ' -f1)
    kiss_sha=$(sha256sum "$b/lib/$KISSFFT_SONAME" | cut -d' ' -f1)
    srv_rev=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)
    srv_dirty=$(git -C "$REPO" status --porcelain -- server.cpp litert_lm_compat.h third_party musl patches 2>/dev/null | wc -l)
    {
        echo "# $NAME — build manifest"
        echo
        echo "prplOS 5.1 $ARCH (musl) build of litert-lm-server, produced by \`musl/build-musl.sh\`."
        echo "Install: bin/ and lib/ are siblings (the binary's RUNPATH is \`\$ORIGIN/../lib\`); \`run\` execs"
        echo "bin/litert-lm-server and leaves LD_PRELOAD untouched (procd's /lib/libsetlbf.so is musl and valid here)."
        echo
        echo "## Sources"
        echo
        echo "| Component | Ref |"
        echo "|---|---|"
        echo "| litert-lm-server | $srv_rev$([ "$srv_dirty" = 0 ] || echo ' (uncommitted changes)') |"
        echo "| LiteRT-LM | $LITERTLM_TAG = $(git -C "$SRC" rev-parse HEAD) |"
        local d
        for d in $(find "$INNER/external" "$INNER/third_party" "$INNER/_deps" -mindepth 1 -maxdepth 4 -name .git 2>/dev/null | sort); do
            echo "| ${d#$INNER/} | $(git -C "$(dirname "$d")" rev-parse HEAD 2>/dev/null || echo '?') |" | sed 's#/.git |# |#'
        done
        echo
        echo "LiteRT-LM $LITERTLM_TAG pins TensorFlow, tokenizers-cpp, stb and the tagged dependencies itself;"
        echo "patch 0001 pins the three it leaves on moving branches: LiteRT, RE2 and zlib."
        echo
        echo "## Toolchain"
        echo
        echo "- $("$TC_BIN/$CROSS-gcc" --version | head -1)"
        echo "- musl $(sed -n 's/^LIBC_VERSION=//p' "$TC_DIR/info.mk" 2>/dev/null) (prplOS 5.1 staging: $STAGING)"
        [ -z "$CPU_FLAGS" ] || echo "- target CPU flags (compiler wrappers):$CPU_FLAGS"
        echo "- $(cmake --version | head -1); $(rustc --version); $(cargo --version)"
        echo "- JRE for ANTLR: Temurin 17.0.20.1+1 (sha256 $JRE_SHA256)"
        echo "- build host: $(uname -srm)"
        echo
        echo "## Patches (patches/musl/litert-lm) and hooks (musl/hooks)"
        echo
        for d in "$PATCHES"/*.patch "$HOOKS"/*; do echo "- \`${d##*/}\` sha256 $(sha256sum "$d" | cut -d' ' -f1)"; done
        echo
        echo "## Binary"
        echo
        echo "- bin/litert-lm-server sha256 \`$bin_sha\` ($(stat -c %s "$b/bin/litert-lm-server") bytes, stripped)"
        echo "- lib/$KISSFFT_SONAME sha256 \`$kiss_sha\`"
        echo "- interpreter: $interp"
        echo "- RUNPATH: $runpath"
        echo "- NEEDED: $needed"
        echo
        echo "Statically linked: LiteRT-LM, LiteRT, TensorFlow Lite and their dependencies; the full list"
        echo "with license files is licenses/INDEX.md."
    } > "$b/BUNDLE-MANIFEST-musl.md"

    local epoch
    epoch=$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || date +%s)
    (cd "$DIST" && tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$epoch" -cf - "$NAME" | gzip -n -9 > "$NAME.tar.gz")
    (cd "$DIST" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
    cat "$DIST/readelf-$NAME.txt"
    cat "$DIST/$NAME.tar.gz.sha256"
    ls -la "$DIST"
}

run_step() {
    CURRENT_STEP=$1
    CURRENT_LOG=$LOGS/$1.log
    local t0=$SECONDS
    echo "==> [$1] $(date -u +%FT%TZ) (log: $CURRENT_LOG)"
    "step_$1" > "$CURRENT_LOG" 2>&1
    echo "    [$1] ok in $((SECONDS - t0))s"
    CURRENT_STEP=""
}

started=0
[ -z "$FROM" ] && [ -z "$ONLY" ] && started=1
for s in $STEPS; do
    if [ -n "$ONLY" ]; then [ "$s" = "$ONLY" ] || continue
    elif [ "$started" = 0 ]; then [ "$s" = "$FROM" ] || continue; started=1; fi
    run_step "$s"
    if [ "$s" = "$TO" ]; then break; fi
done
if [ -f "$DIST/$NAME.tar.gz" ]; then echo "build-musl.sh: done. Bundle: $DIST/$NAME.tar.gz"; else echo "build-musl.sh: done (no bundle yet)"; fi
