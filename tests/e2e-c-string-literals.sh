#!/bin/sh
set -eu
. tests/host-toolchain-probe.sh
cd "$(dirname "$0")/.."
# The test host is compiled for the target architecture; RUNNER executes it
# there (natively on AArch64, under qemu-user elsewhere). The Aster-linked
# ET_EXEC and static PIE outputs are AArch64 too, so they go through it as well.
RUNNER=${RUNNER:-tests/run-aarch64.sh}
run() { $RUNNER "$@"; }
OUT=${OUT:-tmp-c-string-literals}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
# DT_NEEDED carries the Android soname libc.so (explicitly and through Aster's
# auto-dependency for this example's libc import); make a real AArch64 libc
# visible under that name for the guest loader. On Android none of the paths
# exist and this is a no-op.
. tests/guest-libc-alias.sh
provide_guest_libc_alias "$OUT"
ABS_OUT=$(cd "$OUT" && pwd)
LD_LIBRARY_PATH="$ABS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
printf '%s\n' '[1/5] Build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/5] Build direct and ET_REL-linked shared objects plus executable outputs'
"$OUT/aster" build-so examples/string_literals.ast -o "$OUT/libaster_string_literals.so" --soname libaster_string_literals.so --needed libc.so
"$OUT/aster" build-obj --pic examples/string_literals.ast -o "$OUT/string-literals-pic.o"
"$OUT/aster" link-so --soname libaster_string_literals_obj.so --needed libc.so "$OUT/string-literals-pic.o" -o "$OUT/libaster_string_literals_obj.so"
"$OUT/aster" build-obj examples/string_literal_exec.ast -o "$OUT/string-literal-exec.o"
"$OUT/aster" link-obj "$OUT/string-literal-exec.o" -o "$OUT/string-literal-exec"
"$OUT/aster" link-pie "$OUT/string-literal-exec.o" -o "$OUT/string-literal-pie"
printf '%s\n' '[3/5] Compile C ABI harness'
${HOSTCC:-cc} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-string-literals-host.c -ldl -o "$OUT/c-string-literals-host"
printf '%s\n' '[4/5] Run direct build-so and ET_REL + link-so string-literal tests'
run "$OUT/c-string-literals-host" "$PWD/$OUT/libaster_string_literals.so"
run "$OUT/c-string-literals-host" "$PWD/$OUT/libaster_string_literals_obj.so"
printf '%s\n' '[5/5] Run linked ET_EXEC and static PIE literal-load tests'
set +e
run "$OUT/string-literal-exec"
exec_rc=$?
run "$OUT/string-literal-pie"
pie_rc=$?
set -e
[ "$exec_rc" -eq 74 ] || { echo "FAIL: linked ET_EXEC returned $exec_rc, expected 74" >&2; exit 1; }
[ "$pie_rc" -eq 74 ] || { echo "FAIL: linked static PIE returned $pie_rc, expected 74" >&2; exit 1; }
printf '%s\n' 'PASS: link-obj reads the first byte from read-only string literal data plus mutable global (74)'
printf '%s\n' 'PASS: link-pie reads the first byte from read-only string literal data plus mutable global (74)'
printf '%s\n' 'PASS: Aster v0.22.15-dev executable .rodata ABI test'
