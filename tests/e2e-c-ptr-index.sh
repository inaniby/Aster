#!/bin/sh
# v0.22.49-dev end-to-end: C hands Aster a pointer to an int32 array and Aster
# indexes it with p[i] (4-byte element stride), reading and writing. Verifies
# the AAPCS64 pointer argument, the scaled-index addressing, and that stores
# through the pointer are visible to the C caller.
set -eu
. tests/host-toolchain-probe.sh
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-c-ptr-index}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/4] Build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/4] Build pointer-index shared object'
"$OUT/aster" build-so examples/c_ptr_index.ast -o "$OUT/libaster_ptr_index.so" --soname libaster_ptr_index.so
printf '%s\n' '[3/4] Compile C ABI harness'
${HOSTCC:-cc} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-ptr-index-host.c -ldl -o "$OUT/c-ptr-index-host"
printf '%s\n' '[4/4] Run C -> Aster pointer index tests'
# The C harness is an AArch64 ELF: run it through the repo runner so it works
# on AArch64 hosts natively and under qemu-user everywhere else.
./tests/run-aarch64.sh "$OUT/c-ptr-index-host" "$PWD/$OUT/libaster_ptr_index.so"
