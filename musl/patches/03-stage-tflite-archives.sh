#!/usr/bin/env bash
# ExternalProject step on tflite_external (wired by 07-musl-post-step-hooks.patch), after install.
# tflite_target_map.cmake points LiteRT at TFLite dependency archives that tflite_external never
# puts in install/lib: TFLITE_ENABLE_INSTALL=OFF installs only a handful, and several _deps
# archives (fft2d_shrtdct/fft4f2d/fftsg3d/alloc, cpuinfo_internals, ruy_profiler_profiler) belong to
# no default target. Build those explicitly, symlink every archive the map names into install/lib,
# and create an empty archive only for kleidiai, which is not a target on x86_64.
# Args: <tflite build dir> <install lib dir> <tflite_target_map.cmake>
set -euo pipefail
. "$(dirname "$0")/musl-env.sh"
BLD=$1 LIB=$2 MAP=$3
die() { echo "03-stage-tflite-archives: $*" >&2; exit 1; }
[ -d "$BLD" ] || die "no tflite build dir $BLD"
[ -f "$MAP" ] || die "no target map $MAP"
mkdir -p "$LIB"
unset MAKEFLAGS MFLAGS MAKELEVEL
cmake --build "$BLD" --parallel 2 --target fft2d_shrtdct fft2d_fft4f2d fft2d_fftsg3d fft2d_alloc \
    cpuinfo_internals ruy_profiler_profiler || die "building the extra TFLite dependency targets failed"
grep -o 'LITERTLM_TFLITE_LIB_DIR}/[A-Za-z0-9_.+-]*\.a' "$MAP" | sed 's#.*}/##' | sort -u > "$BLD/musl-staged-archives.txt"
[ -s "$BLD/musl-staged-archives.txt" ] || die "no archives parsed from $MAP"
empty=0
while read -r f; do
    if [ -s "$LIB/$f" ] && [ "$(stat -Lc %s "$LIB/$f")" -gt 8 ]; then continue; fi
    rm -f "$LIB/$f"
    src=$(find "$BLD" -name "$f" -type f -print -quit)
    if [ -n "$src" ]; then
        ln -s "$src" "$LIB/$f"; echo "03: linked $f"
    else
        case "$f" in
            libkleidiai.a) "$MUSL_AR" rc "$LIB/$f"; echo "03: empty  $f"; empty=$((empty+1)) ;;
            *) die "archive $f named by the target map was not produced by the TFLite build" ;;
        esac
    fi
done < "$BLD/musl-staged-archives.txt"
echo "03: staged archives OK ($empty empty)"
