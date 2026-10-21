#!/bin/sh
set -eu
. tests/host-toolchain-probe.sh
cd "$(dirname "$0")/.."
# The test host is compiled for the target architecture; RUNNER executes it
# there (natively on AArch64, under qemu-user elsewhere).
RUNNER=${RUNNER:-tests/run-aarch64.sh}
run() { $RUNNER "$@"; }
OUT=${OUT:-tmp-c-abi-32-external}
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT HUP INT TERM
# DT_NEEDED carries the Android soname libc.so through Aster's auto-dependency
# for this example's libc import; make a real AArch64 libc visible under that
# name for the guest loader. On Android none of the paths exist and this is a
# no-op.
. tests/guest-libc-alias.sh
provide_guest_libc_alias "$OUT"
ABS_OUT=$(cd "$OUT" && pwd)
LD_LIBRARY_PATH="$ABS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
printf '%s\n' '[1/4] Build Aster compiler strictly'
${CXX:-clang++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/4] Emit Aster-to-C 32-argument import shared object'
"$OUT/aster" build-so examples/c_abi_32_external_call.ast -o "$OUT/libaster_c_abi_32_external.so" --soname libaster_c_abi_32_external.so
printf '%s\n' '[3/4] Compile strict callback harness with exported executable symbols'
${HOSTCC:-clang} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror -Wl,--export-dynamic tests/c-abi-32-external-host.c -ldl -o "$OUT/c-abi-32-external-host"
printf '%s\n' '[4/4] Execute Aster-to-C 32-argument ABI test'
run "$OUT/c-abi-32-external-host" "$PWD/$OUT/libaster_c_abi_32_external.so"
echo 'PASS: Aster v0.22.38-dev Aster-to-C 32-argument mixed AAPCS64 runtime test'
