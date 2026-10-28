#!/bin/sh
# v0.23.58-dev end-to-end: C hands Aster typed pointers and a struct pointer;
# Aster takes their addresses with `&` (via &p[k], &p[1], &pt.a, &pt.b — the new
# codegen paths) and returns the loaded values. The C harness checks they agree
# with its own pointer arithmetic, a gcc differential across the i32 (4-byte) and
# i64 (8-byte) strides, the typed-pointer base, and a struct field offset.
set -eu
. tests/host-toolchain-probe.sh
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-c-address-of}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/4] Build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/4] Build address-of shared object'
"$OUT/aster" build-so examples/address_of_abi.ast -o "$OUT/libaster_address_of.so" --soname libaster_address_of.so
printf '%s\n' '[3/4] Compile C ABI harness'
${HOSTCC:-cc} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-address-of-host.c -ldl -o "$OUT/c-address-of-host"
printf '%s\n' '[4/4] Run C -> Aster address-of tests'
# The C harness is an AArch64 ELF: run it through the repo runner so it works
# on AArch64 hosts natively and under qemu-user everywhere else.
./tests/run-aarch64.sh "$OUT/c-address-of-host" "$PWD/$OUT/libaster_address_of.so"
