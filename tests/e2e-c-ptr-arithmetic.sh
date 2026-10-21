#!/bin/sh
set -eu
. tests/host-toolchain-probe.sh
cd "$(dirname "$0")/.."
# The test host is compiled for the target architecture; RUNNER executes it
# there (natively on AArch64, under qemu-user elsewhere).
RUNNER=${RUNNER:-tests/run-aarch64.sh}
run() { $RUNNER "$@"; }
CXX=${CXX:-c++}; HOSTCC=${HOSTCC:-cc}; OUT=${OUT:-tmp-c-ptr-arithmetic}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/4] Build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/4] Build pointer arithmetic shared object'
"$OUT/aster" build-so examples/c_ptr_arithmetic.ast -o "$OUT/libaster_ptr_arithmetic.so" --soname libaster_ptr_arithmetic.so
printf '%s\n' '[3/4] Compile C ABI harness'
$HOSTCC -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-ptr-arithmetic-host.c -ldl -o "$OUT/c-ptr-arithmetic-host"
printf '%s\n' '[4/4] Run C -> Aster pointer arithmetic tests'
run "$OUT/c-ptr-arithmetic-host" "$PWD/$OUT/libaster_ptr_arithmetic.so"
