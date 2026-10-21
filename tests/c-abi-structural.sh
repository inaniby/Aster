#!/bin/sh
# Host-safe structural validation: output is AArch64 ELF and is not executed here.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aster-cabi-structural.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$WORK/aster"
"$WORK/aster" build-so examples/libc_abs.ast -o "$WORK/libaster_cabi.so" --soname libaster_cabi.so --needed libc.so
command -v readelf >/dev/null 2>&1 || { echo 'SKIP: readelf unavailable'; exit 0; }
readelf -h "$WORK/libaster_cabi.so" | grep -F 'AArch64' >/dev/null
readelf -d "$WORK/libaster_cabi.so" | grep -F 'Shared library: [libc.so]' >/dev/null
readelf -Ws "$WORK/libaster_cabi.so" | grep -E 'GLOBAL.*aster_abs$' >/dev/null
readelf -Ws "$WORK/libaster_cabi.so" | grep -E 'GLOBAL.*aster_sum8$' >/dev/null
readelf -Ws "$WORK/libaster_cabi.so" | grep -E 'GLOBAL.*aster_mix8$' >/dev/null
readelf -Ws "$WORK/libaster_cabi.so" | grep -E 'GLOBAL.*aster_sum12$' >/dev/null
readelf -Ws "$WORK/libaster_cabi.so" | grep -E 'GLOBAL.*aster_mix12$' >/dev/null
readelf -Ws "$WORK/libaster_cabi.so" | grep -E 'GLOBAL.*aster_call_sum12$' >/dev/null
readelf -Ws "$WORK/libaster_cabi.so" | grep -E 'UND.*abs$' >/dev/null
echo 'PASS: AArch64 ELF exports aster_abs/aster_sum8/aster_mix8/aster_sum12/aster_mix12/aster_call_sum12 and imports libc abs with DT_NEEDED libc.so'
