#!/usr/bin/env bash
# Build litert-lm-server for prplOS 5.1 x86_64 (musl) from scratch and package the release bundle.
#
#   musl/build-musl.sh --staging <prplOS staging dir> --work <empty or previous work dir>
#
# Steps (run in order; each one fails loudly and names its log):
#   preflight  tools, rust musl target, staging tree layout
#   jre        pinned Temurin 17 JRE (ANTLR code generation needs java)
#   toolchain  render compiler wrappers, CMake toolchain file and hook env into <work>/toolchain
#   source     clone LiteRT-LM at the pinned tag, verify the commit, apply patches/0*.patch
#   configure  cmake the LiteRT-LM superbuild with the musl toolchain
#   build      make the superbuild (hooks 03 and 05 run inside it as ExternalProject steps)
#   server     compile server.cpp and link it with litert_lm_main's whole-archive link line
#   licenses   collect third-party license files into <work>/licenses
#   bundle     assemble, verify (readelf) and tar the bundle into <work>/dist
#
# Re-running is safe: finished downloads, the clone and the configure are reused, make is
# incremental, and server/licenses/bundle are regenerated. --from/--to/--only restrict the steps.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")

LITERTLM_REPO=https://github.com/google-ai-edge/LiteRT-LM.git
LITERTLM_TAG=v0.17.1
LITERTLM_SHA=5e58e9a0aef7abf7091207a8b1d1063a1c800f08
JRE_URL=https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1%2B1/OpenJDK17U-jre_x64_linux_hotspot_17.0.20.1_1.tar.gz
JRE_SHA256=0b2b640e3046b64c8ec504de0ab9d91bb5610182bda21fad454681ce54d45a62
EXPECTED_NEEDED="libc.so libgcc_s.so.1 libkissfft-float.so.131 libstdc++.so.6 libz.so.1"
EXPECTED_INTERP=/lib/ld-musl-x86_64.so.1
KISSFFT_SONAME=libkissfft-float.so.131

STAGING=${PRPLOS_STAGING_DIR:-}
WORK=${MUSL_WORK_DIR:-}
JOBS=${MUSL_JOBS:-8}
MEMORY_MAX=${MUSL_MEMORY_MAX:-16G}
VERSION=${MUSL_BUNDLE_VERSION:-v0.3.0}
SCOPE=1
FROM=""
TO=""
ONLY=""
STEPS="preflight jre toolchain source configure build server licenses bundle"

usage() {
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
    cat <<EOF

Options (environment variable in brackets):
  --staging DIR     prplOS SDK staging dir holding toolchain-x86_64_gcc-13.3.0_musl and
                    target-x86_64_musl [PRPLOS_STAGING_DIR]
  --work DIR        work directory; everything is created under it [MUSL_WORK_DIR]
  --jobs N          make parallelism, default 8 [MUSL_JOBS]
  --memory-max SZ   MemoryMax for the systemd user scope around heavy steps, default 16G [MUSL_MEMORY_MAX]
  --no-scope        do not wrap heavy steps in systemd-run --user --scope (still nice 19)
  --version V       bundle version, default v0.3.0 [MUSL_BUNDLE_VERSION]
  --from STEP       start at STEP;  --to STEP  stop after STEP;  --only STEP  run only STEP
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
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
[ "$JOBS" -le 8 ] || echo "build-musl.sh: warning: --jobs $JOBS is above the 8 this recipe was validated with" >&2
for s in $FROM $TO $ONLY; do case " $STEPS " in *" $s "*) ;; *) die "unknown step $s (steps: $STEPS)" ;; esac; done

STAGING=$(cd "$STAGING" 2>/dev/null && pwd) || die "staging dir does not exist"
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
TC_DIR=$STAGING/toolchain-x86_64_gcc-13.3.0_musl
TC_BIN=$TC_DIR/bin
TARGET_DIR=$STAGING/target-x86_64_musl
ROOTFS=$TARGET_DIR/root-x86
TOOLCHAIN=$WORK/toolchain
SRC=$WORK/src
BUILD=$WORK/build
INNER=$BUILD/litert_lm/build
OUT=$WORK/out
LOGS=$WORK/logs
DIST=$WORK/dist
NAME=litert-lm-server-x86_64-musl-$VERSION
export STAGING_DIR=$STAGING
export PATH=$WORK/jre/bin:$HOME/.cargo/bin:$PATH
export CARGO_BUILD_JOBS=4
unset CMAKE_BUILD_PARALLEL_LEVEL
mkdir -p "$LOGS" "$WORK/stamps" "$WORK/downloads"

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
        echo "build-musl.sh: step '$CURRENT_STEP' FAILED (rc=$rc)" >&2
        if [ -n "$CURRENT_LOG" ] && [ -f "$CURRENT_LOG" ]; then
            echo "---- last 40 lines of $CURRENT_LOG ----" >&2
            tail -n 40 "$CURRENT_LOG" >&2
            echo "---- full log: $CURRENT_LOG ----" >&2
        fi
    fi
}
trap on_exit EXIT

step_preflight() {
    local t missing=""
    for t in bash cmake make git python3 curl tar gzip sha256sum cargo rustup rustc systemd-run nice sed awk find; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    [ -z "$missing" ] || die "missing tools:$missing"
    [ "$SCOPE" = 0 ] || systemd-run --user --scope --quiet -p MemoryMax=1G -- true \
        || die "systemd-run --user --scope does not work here (no user manager?); pass --no-scope"
    rustup target list --installed > "$LOGS/rust-targets.txt" || die "rustup target list failed"
    grep -x x86_64-unknown-linux-musl "$LOGS/rust-targets.txt" > /dev/null \
        || die "rust target x86_64-unknown-linux-musl missing: rustup target add x86_64-unknown-linux-musl"
    [ -x "$TC_BIN/x86_64-openwrt-linux-musl-gcc" ] || die "no musl gcc at $TC_BIN/x86_64-openwrt-linux-musl-gcc"
    [ -x "$TC_BIN/x86_64-openwrt-linux-musl-g++" ] || die "no musl g++ in $TC_BIN"
    [ -d "$TARGET_DIR/usr/include" ] || die "no target sysroot headers at $TARGET_DIR/usr/include"
    [ -e "$TARGET_DIR/usr/lib/libz.so" ] || die "no target zlib at $TARGET_DIR/usr/lib/libz.so"
    "$TC_BIN/x86_64-openwrt-linux-musl-gcc" --version | head -1
    cmake --version | head -1
    rustc --version
    echo "staging=$STAGING work=$WORK jobs=$JOBS memory_max=$MEMORY_MAX scope=$SCOPE version=$VERSION"
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
        -e "s#@TARGET_DIR@#$TARGET_DIR#g" -e "s#@TOOLCHAIN_DIR@#$TOOLCHAIN#g" -e "s#@BUILD_DIR@#$BUILD#g" "$@"
}

step_toolchain() {
    mkdir -p "$TOOLCHAIN"
    render -e "s#@TOOL@#gcc#g" "$HERE/wrap/musl-cc.in" > "$TOOLCHAIN/musl-gcc"
    render -e "s#@TOOL@#g++#g" "$HERE/wrap/musl-cc.in" > "$TOOLCHAIN/musl-g++"
    render "$HERE/musl-toolchain.cmake.in" > "$TOOLCHAIN/musl-toolchain.cmake"
    cat > "$TOOLCHAIN/musl-env.sh" <<EOF
# Rendered by build-musl.sh; sourced by the 03/05 hook steps.
export STAGING_DIR=$STAGING
export PATH=$WORK/jre/bin:$HOME/.cargo/bin:\$PATH
MUSL_CC=$TOOLCHAIN/musl-gcc
MUSL_CXX=$TOOLCHAIN/musl-g++
MUSL_AR=$TC_BIN/x86_64-openwrt-linux-musl-ar
MUSL_NM=$TC_BIN/x86_64-openwrt-linux-musl-nm
MUSL_JOBS=4
EOF
    cp "$HERE/patches/03-stage-tflite-archives.sh" "$HERE/patches/05-tokenizers-c-musl.sh" \
       "$HERE/patches/tokenizers-c.Cargo.lock" "$TOOLCHAIN/"
    chmod +x "$TOOLCHAIN/musl-gcc" "$TOOLCHAIN/musl-g++" "$TOOLCHAIN"/0*.sh
    echo 'int main(void){return 0;}' > "$TOOLCHAIN/probe.c"
    "$TOOLCHAIN/musl-gcc" -o "$TOOLCHAIN/probe" "$TOOLCHAIN/probe.c" -lz || die "musl-gcc wrapper cannot link a probe against -lz"
    "$TC_BIN/x86_64-openwrt-linux-musl-readelf" -lW "$TOOLCHAIN/probe" > "$TOOLCHAIN/probe.readelf" || die "readelf failed on the probe"
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
    for p in "$HERE"/patches/0*.patch; do
        if git -C "$SRC" apply --reverse --check "$p" 2>/dev/null; then
            echo "already applied: ${p##*/}"
        else
            git -C "$SRC" apply --check "$p" || die "patch ${p##*/} does not apply to $LITERTLM_TAG"
            git -C "$SRC" apply "$p"
            echo "applied: ${p##*/}"
        fi
    done
    git -C "$SRC" status --short
}

step_configure() {
    if [ -f "$BUILD/Makefile" ] && [ -f "$WORK/stamps/configure" ]; then echo "configured already"; return 0; fi
    mkdir -p "$BUILD"
    cmake -S "$SRC" -B "$BUILD" -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN/musl-toolchain.cmake" || die "cmake configure failed"
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
obj = " CMakeFiles/litert_lm_main.dir/runtime/engine/litert_lm_main.cc.o "
assert cmd.count(obj) == 1, "main object not found once in link.txt"
cmd = cmd.replace(obj, f" {out}/server.o ")
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
    "$TC_BIN/x86_64-openwrt-linux-musl-strip" -o "$OUT/$KISSFFT_SONAME" "$kiss"
    "$TC_BIN/x86_64-openwrt-linux-musl-strip" -o "$OUT/litert-lm-server.stripped" "$OUT/litert-lm-server"
    ls -la "$OUT"
}

step_licenses() {
    python3 "$HERE/collect-licenses.py" --repo "$REPO" --src "$SRC" --build "$BUILD" \
        --lockfile "$HERE/patches/tokenizers-c.Cargo.lock" --out "$WORK/licenses" || die "license collection failed"
}

readelf_evidence() {
    local re=$TC_BIN/x86_64-openwrt-linux-musl-readelf f=$1
    echo "## $f"
    "$re" -lW "$f" | grep -E "Requesting program interpreter" || true
    "$re" -dW "$f" | grep -E "\((NEEDED|RUNPATH|RPATH|SONAME)\)" || true
}

step_bundle() {
    local b=$DIST/$NAME re=$TC_BIN/x86_64-openwrt-linux-musl-readelf
    [ -f "$OUT/litert-lm-server.stripped" ] || die "run the server step first"
    [ -f "$WORK/licenses/INDEX.md" ] || die "run the licenses step first"
    rm -rf "$b" "$DIST/$NAME.tar.gz" "$DIST/$NAME.tar.gz.sha256"
    mkdir -p "$b/bin" "$b/lib"
    install -m 0755 "$OUT/litert-lm-server.stripped" "$b/bin/litert-lm-server"
    install -m 0755 "$OUT/$KISSFFT_SONAME" "$b/lib/$KISSFFT_SONAME"
    install -m 0755 "$HERE/run.in" "$b/run"
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
    for n in libc.so libgcc_s.so.1 libstdc++.so.6 libz.so.1; do
        [ -e "$ROOTFS/lib/$n" ] || [ -e "$ROOTFS/usr/lib/$n" ] || die "NEEDED $n is not in the prplOS rootfs $ROOTFS"
    done
    { readelf_evidence "$b/bin/litert-lm-server"; readelf_evidence "$b/lib/$KISSFFT_SONAME"; } > "$DIST/readelf-$NAME.txt"

    local bin_sha kiss_sha srv_rev srv_dirty
    bin_sha=$(sha256sum "$b/bin/litert-lm-server" | cut -d' ' -f1)
    kiss_sha=$(sha256sum "$b/lib/$KISSFFT_SONAME" | cut -d' ' -f1)
    srv_rev=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)
    srv_dirty=$(git -C "$REPO" status --porcelain -- server.cpp third_party musl 2>/dev/null | wc -l)
    {
        echo "# $NAME — build manifest"
        echo
        echo "prplOS 5.1 x86_64 (musl) build of litert-lm-server, produced by \`musl/build-musl.sh\`."
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
        echo "TensorFlow is pinned to e511b24d67413f9e28d56457c026689e45c95a03 and LiteRT to"
        echo "876bb8d5b5dd2d69d89797d9b49d52565f046ae5 by patch 02 (LiteRT-LM v0.17.1 tracks their moving"
        echo "master/main branches). tokenizers-cpp, re2, stb and zlib are pinned by patch 06."
        echo
        echo "## Toolchain"
        echo
        echo "- $("$TC_BIN/x86_64-openwrt-linux-musl-gcc" --version | head -1)"
        echo "- musl $(sed -n 's/^LIBC_VERSION=//p' "$TC_DIR/info.mk" 2>/dev/null) (prplOS 5.1 staging: $STAGING)"
        echo "- $(cmake --version | head -1); $(rustc --version); $(cargo --version)"
        echo "- JRE for ANTLR: Temurin 17.0.20.1+1 (sha256 $JRE_SHA256)"
        echo "- build host: $(uname -srm)"
        echo
        echo "## Patches (musl/patches)"
        echo
        for d in "$HERE"/patches/0*; do echo "- \`${d##*/}\` sha256 $(sha256sum "$d" | cut -d' ' -f1)"; done
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
