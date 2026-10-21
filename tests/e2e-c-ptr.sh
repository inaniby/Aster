#!/bin/sh
# AArch64 Android/Termux runtime test for C <-> Aster pointer ABI.
set -eu
. tests/host-toolchain-probe.sh
cd "$(dirname "$0")/.."
# The test host is compiled for the target architecture; RUNNER executes it
# there (natively on AArch64, under qemu-user elsewhere).
RUNNER=${RUNNER:-tests/run-aarch64.sh}
run() { $RUNNER "$@"; }
CXX=${CXX:-c++}
HOSTCC=${HOSTCC:-cc}
OUT=${OUT:-tmp-c-ptr}
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/4] Build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/4] Build Aster pointer round-trip shared object'
"$OUT/aster" build-so examples/c_ptr_echo.ast -o "$OUT/libaster_ptr.so" --soname libaster_ptr.so
printf '%s\n' '[3/4] Verify AArch64 ELF and exported symbol'
if command -v readelf >/dev/null 2>&1; then
  readelf -h "$OUT/libaster_ptr.so" | grep -F 'AArch64' >/dev/null
  readelf -Ws "$OUT/libaster_ptr.so" | grep -E 'GLOBAL.*aster_ptr_echo$' >/dev/null
  echo 'PASS: AArch64 ELF exports aster_ptr_echo'
else
  echo 'SKIP: readelf unavailable; runtime load remains mandatory'
fi
printf '%s\n' '[4/4] C harness verifies 64-bit and null pointer round trips'
$HOSTCC -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-ptr-host.c -ldl -o "$OUT/c-ptr-host"
run "$OUT/c-ptr-host" "$PWD/$OUT/libaster_ptr.so"
echo 'PASS: Aster v0.22.3-dev C pointer ABI test'
