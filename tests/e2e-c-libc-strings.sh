#!/bin/sh
set -eu
. tests/host-toolchain-probe.sh
cd "$(dirname "$0")/.."
# The test host is compiled for the target architecture; RUNNER executes it
# there (natively on AArch64, under qemu-user elsewhere).
RUNNER=${RUNNER:-tests/run-aarch64.sh}
run() { $RUNNER "$@"; }
OUT=${OUT:-tmp-c-libc-strings}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
# DT_NEEDED carries the Android soname libc.so (explicitly and through Aster's
# auto-dependency for the strlen/memcmp imports); make a real AArch64 libc
# visible under that name for the guest loader. On Android none of the paths
# exist and this is a no-op.
. tests/guest-libc-alias.sh
provide_guest_libc_alias "$OUT"
ABS_OUT=$(cd "$OUT" && pwd)
LD_LIBRARY_PATH="$ABS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
printf '%s\n' '[1/4] Build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/4] Build Aster wrappers calling Bionic strlen/memcmp'
"$OUT/aster" build-so examples/c_libc_strings.ast -o "$OUT/libaster_libc_strings.so" --soname libaster_libc_strings.so --needed libc.so
printf '%s\n' '[3/4] Compile C ABI harness'
${HOSTCC:-cc} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-libc-strings-host.c -ldl -o "$OUT/c-libc-strings-host"
printf '%s\n' '[4/4] Run C -> Aster -> Bionic tests'
run "$OUT/c-libc-strings-host" "$PWD/$OUT/libaster_libc_strings.so"
