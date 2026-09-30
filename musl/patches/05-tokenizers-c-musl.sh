#!/usr/bin/env bash
# ExternalProject step on tokenizers-cpp_external (wired by 07-musl-post-step-hooks.patch), after
# build. tokenizers-cpp picks no cargo --target for a generic Linux cross build, so
# libtokenizers_c.a (and the oniguruma the onig crate builds through the cc crate) comes out for
# the HOST glibc triple and later fails to link (undefined __memcpy_chk). Rebuild the same crate
# for x86_64-unknown-linux-musl with the prplOS musl gcc and replace the archive LiteRT-LM links.
# Args: <tokenizers-cpp source dir> <tokenizers-cpp build dir>
set -euo pipefail
. "$(dirname "$0")/musl-env.sh"
SRC=$1 BLD=$2
T=x86_64-unknown-linux-musl
die() { echo "05-tokenizers-c-musl: $*" >&2; exit 1; }
[ -f "$SRC/rust/Cargo.toml" ] || die "no $SRC/rust/Cargo.toml"
[ -f "$BLD/libtokenizers_c.a" ] || die "tokenizers-cpp did not produce $BLD/libtokenizers_c.a"
export CC_x86_64_unknown_linux_musl=$MUSL_CC
export CXX_x86_64_unknown_linux_musl=$MUSL_CXX
export AR_x86_64_unknown_linux_musl=$MUSL_AR
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=$MUSL_CC
export CARGO_BUILD_JOBS=${MUSL_JOBS:-4}
unset MAKEFLAGS MFLAGS MAKELEVEL CARGO_MAKEFLAGS
# tokenizers-cpp does not commit a Cargo.lock; pin the crate graph that was validated.
cp -f "$(dirname "$0")/tokenizers-c.Cargo.lock" "$SRC/rust/Cargo.lock"
cd "$SRC/rust"
CARGO_TARGET_DIR="$BLD/musl-cargo" cargo build --locked --release --target $T || die "cargo build --locked for $T failed"
NEW="$BLD/musl-cargo/$T/release/libtokenizers_c.a"
[ -f "$NEW" ] || die "cargo did not produce $NEW"
"$MUSL_NM" -u "$NEW" 2>/dev/null > "$BLD/musl-tokenizers-undef.txt" || true
if grep -q -E '__[a-z]+_chk$|@GLIBC_' "$BLD/musl-tokenizers-undef.txt"; then
    die "rebuilt $NEW still references glibc-only symbols (see $BLD/musl-tokenizers-undef.txt)"
fi
cp -f "$NEW" "$BLD/libtokenizers_c.a"
echo "05: libtokenizers_c.a replaced with the $T build"
