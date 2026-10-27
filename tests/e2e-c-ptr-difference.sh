#!/bin/sh
# v0.23.57-dev end-to-end: C hands Aster two pointers into the same array and
# Aster returns the signed element count between them (`p - q`), striding at
# each pointer's element width. The C harness computes the same count with its
# own pointer arithmetic and asserts Aster agrees — a gcc differential across
# the i32/u8/i64/struct strides.
set -eu
. tests/host-toolchain-probe.sh
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-c-ptr-difference}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/4] Build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/4] Build pointer-difference shared object'
"$OUT/aster" build-so examples/c_ptr_difference.ast -o "$OUT/libaster_ptr_difference.so" --soname libaster_ptr_difference.so
printf '%s\n' '[3/4] Compile C ABI harness'
${HOSTCC:-cc} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-ptr-difference-host.c -ldl -o "$OUT/c-ptr-difference-host"
printf '%s\n' '[4/4] Run C -> Aster pointer difference tests'
# The C harness is an AArch64 ELF: run it through the repo runner so it works
# on AArch64 hosts natively and under qemu-user everywhere else.
./tests/run-aarch64.sh "$OUT/c-ptr-difference-host" "$PWD/$OUT/libaster_ptr_difference.so"
