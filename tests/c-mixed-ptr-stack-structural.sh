#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-c-mixed-ptr-stack-structural}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/4] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/4] Emit mixed ptr/i32 stack-ABI shared object'
"$OUT/aster" build-so examples/c_mixed_ptr_stack.ast -o "$OUT/libaster_mixed_ptr_stack.so" --soname libaster_mixed_ptr_stack.so
${READELF:-readelf} -Ws "$OUT/libaster_mixed_ptr_stack.so" > "$OUT/symbols.txt"
for sym in aster_mixed_sum10_forward aster_mixed_last_ptr_forward; do grep -q "$sym" "$OUT/symbols.txt"; done
printf '%s\n' 'PASS: ELF exports mixed ptr/i32 wrappers and pointer-return wrapper'
printf '%s\n' '[3/4] Strictly compile C ABI harness'
${HOSTCC:-cc} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-mixed-ptr-stack-host.c -ldl -o "$OUT/c-mixed-ptr-stack-host"
printf '%s\n' 'PASS: strict mixed-ABI C harness compile'
printf '%s\n' '[4/4] Structural validation complete (run e2e script on target device)'
