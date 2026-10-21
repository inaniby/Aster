#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-c-abi-32-external-structural}
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/5] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/5] Emit Aster-to-C 32-argument import shared object'
"$OUT/aster" build-so examples/c_abi_32_external_call.ast -o "$OUT/libaster_c_abi_32_external.so" --soname libaster_c_abi_32_external.so
printf '%s\n' '[3/5] Verify exported wrapper and imported C symbol'
${READELF:-readelf} -Ws "$OUT/libaster_c_abi_32_external.so" > "$OUT/symbols.txt"
grep -q 'aster_call_c_sum32_mixed' "$OUT/symbols.txt" || { echo 'FAIL: wrapper export missing'; exit 10; }
grep -q 'aster_c_sum32_mixed' "$OUT/symbols.txt" || { echo 'FAIL: external C import missing'; exit 11; }
printf '%s\n' '[4/5] Verify PLT relocation and AArch64 ELF metadata'
${READELF:-readelf} -r "$OUT/libaster_c_abi_32_external.so" > "$OUT/relocs.txt"
grep -q 'aster_c_sum32_mixed' "$OUT/relocs.txt" || { echo 'FAIL: external C PLT relocation missing'; exit 12; }
${READELF:-readelf} -h "$OUT/libaster_c_abi_32_external.so" | grep -q 'AArch64' || { echo 'FAIL: not AArch64'; exit 13; }
${READELF:-readelf} -d "$OUT/libaster_c_abi_32_external.so" | grep -q 'SONAME.*libaster_c_abi_32_external.so' || { echo 'FAIL: SONAME missing'; exit 14; }
printf '%s\n' '[5/5] Strictly compile host callback harness'
${HOSTCC:-cc} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror -Wl,--export-dynamic tests/c-abi-32-external-host.c -ldl -o "$OUT/c-abi-32-external-host"
echo 'PASS: Aster-to-C external 32-argument structural checks'
echo 'NOTE: run tests/e2e-c-abi-32-external.sh on AArch64 Android/Termux for runtime validation'
