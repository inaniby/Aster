#!/bin/sh
set -eu
. tests/host-toolchain-probe.sh
cd "$(dirname "$0")/.."
# The test host is compiled for the target architecture; RUNNER executes it
# there (natively on AArch64, under qemu-user elsewhere).
RUNNER=${RUNNER:-tests/run-aarch64.sh}
run() { $RUNNER "$@"; }
OUT=${OUT:-tmp-c-mixed-ptr-stack}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/4] Build Aster compiler'
${CXX:-clang++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/4] Build mixed ptr/i32 stack-ABI shared object'
"$OUT/aster" build-so examples/c_mixed_ptr_stack.ast -o "$OUT/libaster_mixed_ptr_stack.so" --soname libaster_mixed_ptr_stack.so
printf '%s\n' '[3/4] Compile C ABI harness'
${HOSTCC:-clang} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-mixed-ptr-stack-host.c -ldl -o "$OUT/c-mixed-ptr-stack-host"
printf '%s\n' '[4/4] Run mixed ABI tests'
run "$OUT/c-mixed-ptr-stack-host" "$PWD/$OUT/libaster_mixed_ptr_stack.so"
