#!/bin/sh
set -eu
. tests/host-toolchain-probe.sh
cd "$(dirname "$0")/.."
# The test host is compiled for the target architecture; RUNNER executes it
# there (natively on AArch64, under qemu-user elsewhere).
RUNNER=${RUNNER:-tests/run-aarch64.sh}
run() { $RUNNER "$@"; }
CXX=${CXX:-c++}; HOSTCC=${HOSTCC:-cc}; OUT=${OUT:-tmp-c-ptr-memory}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/4] Build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/4] Build pointer-memory shared object'
"$OUT/aster" build-so examples/c_ptr_memory.ast -o "$OUT/libaster_ptr_memory.so" --soname libaster_ptr_memory.so
printf '%s\n' '[3/4] Verify AArch64 exports'
if command -v readelf >/dev/null 2>&1; then readelf -h "$OUT/libaster_ptr_memory.so" | grep -F AArch64 >/dev/null; readelf -Ws "$OUT/libaster_ptr_memory.so" | grep -E 'GLOBAL.*aster_ptr_load$' >/dev/null; readelf -Ws "$OUT/libaster_ptr_memory.so" | grep -E 'GLOBAL.*aster_ptr_store$' >/dev/null; echo 'PASS: AArch64 ELF exports aster_ptr_load and aster_ptr_store'; else echo 'SKIP: readelf unavailable'; fi
printf '%s\n' '[4/4] Run C -> Aster pointer memory tests'
$HOSTCC -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-ptr-memory-host.c -ldl -o "$OUT/c-ptr-memory-host"
run "$OUT/c-ptr-memory-host" "$PWD/$OUT/libaster_ptr_memory.so"
echo 'PASS: Aster v0.22.4-dev pointer memory ABI test'
