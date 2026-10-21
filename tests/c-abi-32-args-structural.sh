#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-c-abi-32-args-structural}
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/5] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/5] Emit 32-argument mixed-ABI shared object'
"$OUT/aster" build-so examples/c_abi_32_args.ast -o "$OUT/libaster_c_abi_32_args.so" --soname libaster_c_abi_32_args.so
printf '%s\n' '[3/5] Verify exported boundary-test symbols'
${READELF:-readelf} -Ws "$OUT/libaster_c_abi_32_args.so" > "$OUT/symbols.txt"
for sym in aster_sum32_mixed aster_sum32_mixed_forward aster_last_stack_ptr32 aster_last_stack_ptr32_forward; do
  grep -q "$sym" "$OUT/symbols.txt" || { echo "FAIL: missing export $sym"; exit 10; }
done
echo 'PASS: all 32-argument exports are present'
printf '%s\n' '[4/5] Strictly compile C harness'
${HOSTCC:-cc} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-abi-32-args-host.c -ldl -o "$OUT/c-abi-32-args-host"
echo 'PASS: strict 32-argument C harness compile'
printf '%s\n' '[5/5] Inspect shared-object architecture and dynamic metadata'
${READELF:-readelf} -h "$OUT/libaster_c_abi_32_args.so" | grep -q 'AArch64' || { echo 'FAIL: output is not AArch64'; exit 11; }
${READELF:-readelf} -d "$OUT/libaster_c_abi_32_args.so" > "$OUT/dynamic.txt"
grep -q 'SONAME.*libaster_c_abi_32_args.so' "$OUT/dynamic.txt" || { echo 'FAIL: SONAME missing'; exit 12; }
echo 'PASS: AArch64 ELF64 shared object and SONAME verified'
echo 'NOTE: execute tests/e2e-c-abi-32-args.sh on AArch64 Android/Termux for runtime validation'
