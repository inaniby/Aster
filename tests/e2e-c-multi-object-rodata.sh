#!/bin/sh
set -eu
. tests/host-toolchain-probe.sh
cd "$(dirname "$0")/.."
# The test host is compiled for the target architecture; RUNNER executes it
# there (natively on AArch64, under qemu-user elsewhere).
RUNNER=${RUNNER:-tests/run-aarch64.sh}
run() { $RUNNER "$@"; }
OUT=${OUT:-tmp-multi-object-rodata}
mkdir -p "$OUT"
# DT_NEEDED carries the Android soname libc.so; make a real AArch64 libc
# visible under that name for the guest loader. On Android none of the paths
# exist and this is a no-op.
. tests/guest-libc-alias.sh
provide_guest_libc_alias "$OUT"
ABS_OUT=$(cd "$OUT" && pwd)
LD_LIBRARY_PATH="$ABS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
cleanup() {
    status=$?
    if [ "$status" -eq 0 ]; then rm -rf "$OUT"; else
        printf 'FAIL: preserving diagnostic artifacts in %s (exit %s)\n' "$OUT" "$status" >&2
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' '[1/5] Build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/5] Build five independent PIC objects'
for unit in a b c d e; do
  "$OUT/aster" build-obj --pic "examples/multi_object_rodata_${unit}.ast" -o "$OUT/multi-${unit}.o"
done
printf '%s\n' '[3/5] Link forward and reverse input orders'
"$OUT/aster" link-so --soname libaster_multi_object_rodata.so --needed libc.so \
  "$OUT/multi-a.o" "$OUT/multi-b.o" "$OUT/multi-c.o" "$OUT/multi-d.o" "$OUT/multi-e.o" \
  -o "$OUT/libaster_multi_object_rodata.so"
"$OUT/aster" link-so --soname libaster_multi_object_rodata_reverse.so --needed libc.so \
  "$OUT/multi-e.o" "$OUT/multi-d.o" "$OUT/multi-c.o" "$OUT/multi-b.o" "$OUT/multi-a.o" \
  -o "$OUT/libaster_multi_object_rodata_reverse.so"
printf '%s\n' '[4/5] Compile C ABI harness'
${HOSTCC:-cc} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-multi-object-rodata-host.c -ldl -o "$OUT/multi-object-rodata-host"
printf '%s\n' '[5/5] Run five-object ABI and object-order tests'
case "$OUT" in /*) SO_PATH="$OUT/libaster_multi_object_rodata.so"; REV_PATH="$OUT/libaster_multi_object_rodata_reverse.so";; *) SO_PATH="$PWD/$OUT/libaster_multi_object_rodata.so"; REV_PATH="$PWD/$OUT/libaster_multi_object_rodata_reverse.so";; esac
run "$OUT/multi-object-rodata-host" "$SO_PATH" "$REV_PATH"
