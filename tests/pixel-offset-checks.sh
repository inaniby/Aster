#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-pixel-offset-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/4] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

printf '%s\n' '[2/4] Source guard: native_render.ast must scale the row term by bpp'
# v0.22.46 bug: px = y * stride + x * 4 (and x * 2). stride counts pixels, so
# the byte offset is (y * stride + x) * bpp; the row term must be scaled too.
if grep -nE 'y \* stride \+ x \* [24]' examples/native_render.ast; then
    echo 'FAIL: unscaled row offset (y * stride + x * bpp) in examples/native_render.ast' >&2
    exit 1
fi
grep -qF '(y * stride + x) * 4' examples/native_render.ast \
    || { echo 'FAIL: missing 4-byte path (y * stride + x) * 4' >&2; exit 1; }
grep -qF '(y * stride + x) * 2' examples/native_render.ast \
    || { echo 'FAIL: missing 2-byte path (y * stride + x) * 2' >&2; exit 1; }
printf '%s\n' 'PASS: native_render.ast scales both pixel paths by bytes-per-pixel'

printf '%s\n' '[3/4] Emit self-checking framebuffer program'
"$OUT/aster" build-elf examples/pixel_offset_selfcheck.ast -o "$OUT/pixel_offset_selfcheck"

printf '%s\n' '[4/4] Run byte-for-byte self-check (qemu when cross-running)'
./tests/run-aarch64.sh "$OUT/pixel_offset_selfcheck"
printf '%s\n' 'PASS: 4-byte and 2-byte pixel layouts verified byte-for-byte; old formula still detected'
