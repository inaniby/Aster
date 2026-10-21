#!/bin/sh
# v0.22.2 C ABI stack-argument + Android Bionic libc integration check.
# Run on an AArch64 Android/Termux device. The C compiler builds only the test harness;
# Aster itself builds the shared object and owns all Aster code generation/linking.
set -eu
. tests/host-toolchain-probe.sh
cd "$(dirname "$0")/.."
# The test host is compiled for the target architecture; RUNNER executes it
# there (natively on AArch64, under qemu-user elsewhere).
RUNNER=${RUNNER:-tests/run-aarch64.sh}
run() { $RUNNER "$@"; }
CXX=${CXX:-c++}
HOSTCC=${HOSTCC:-cc}
OUT=${OUT:-tmp-c-abi}
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT HUP INT TERM
# DT_NEEDED carries the Android soname libc.so (explicitly and through Aster's
# auto-dependency for the abs import); make a real AArch64 libc visible under
# that name for the guest loader. On Android none of the paths exist and this
# is a no-op.
. tests/guest-libc-alias.sh
provide_guest_libc_alias "$OUT"
ABS_OUT=$(cd "$OUT" && pwd)
LD_LIBRARY_PATH="$ABS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH

printf '%s\n' '[1/4] Build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/4] Build Aster shared object with libc.so dependency'
"$OUT/aster" build-so examples/libc_abs.ast -o "$OUT/libaster_cabi.so" --soname libaster_cabi.so --needed libc.so
printf '%s\n' '[3/4] Verify ELF dynamic dependency and imported symbol'
if command -v readelf >/dev/null 2>&1; then
  readelf -d "$OUT/libaster_cabi.so" | grep -F 'libc.so' >/dev/null || { echo 'FAIL: DT_NEEDED libc.so missing'; exit 10; }
  readelf -Ws "$OUT/libaster_cabi.so" | grep -E 'UND.*abs(@|$|[[:space:]])' >/dev/null || { echo 'FAIL: undefined abs import missing'; exit 11; }
  echo 'PASS: ELF contains DT_NEEDED libc.so and undefined abs import'
else
  echo 'SKIP: readelf unavailable; runtime load remains mandatory'
fi
printf '%s\n' '[4/4] C harness calls exported Aster function on this device'
$HOSTCC -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-abi-host.c -ldl -o "$OUT/c-abi-host"
run "$OUT/c-abi-host" "$PWD/$OUT/libaster_cabi.so"
echo 'PASS: Aster v0.22.2 C ABI stack-argument + Bionic libc test'
