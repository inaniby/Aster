#!/bin/sh
# Runtime boundary test; run on AArch64 Android/Termux or a suitable AArch64 environment.
set -eu
. tests/host-toolchain-probe.sh
cd "$(dirname "$0")/.."
# The test host is compiled for the target architecture; RUNNER executes it
# there (natively on AArch64, under qemu-user elsewhere).
RUNNER=${RUNNER:-tests/run-aarch64.sh}
run() { $RUNNER "$@"; }
OUT=${OUT:-tmp-c-abi-32-args}
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/4] Build Aster compiler'
${CXX:-clang++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/4] Emit 32-argument mixed-ABI shared object'
"$OUT/aster" build-so examples/c_abi_32_args.ast -o "$OUT/libaster_c_abi_32_args.so" --soname libaster_c_abi_32_args.so
printf '%s\n' '[3/4] Compile strict C ABI harness'
${HOSTCC:-clang} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-abi-32-args-host.c -ldl -o "$OUT/c-abi-32-args-host"
printf '%s\n' '[4/4] Execute 32-argument ABI boundary checks'
run "$OUT/c-abi-32-args-host" "$PWD/$OUT/libaster_c_abi_32_args.so"
echo 'PASS: Aster v0.22.37-dev 32-argument mixed AAPCS64 runtime test'
