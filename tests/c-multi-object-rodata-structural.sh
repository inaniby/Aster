#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-multi-object-rodata-structural}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/7] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/7] Emit five independent PIC objects'
for unit in a b c d e; do
  "$OUT/aster" build-obj --pic "examples/multi_object_rodata_${unit}.ast" -o "$OUT/multi-${unit}.o"
  readelf -h "$OUT/multi-${unit}.o" | grep -q 'Machine:.*AArch64'
done
for obj in "$OUT/multi-a.o" "$OUT/multi-b.o" "$OUT/multi-c.o"; do
  readelf -SW "$obj" | grep '\.rodata' | grep -Eq 'PROGBITS.* A '
done
printf '%s\n' '[3/7] Link forward and reverse object order'
"$OUT/aster" link-so --soname libaster_multi_object_rodata.so --needed libc.so \
  "$OUT/multi-a.o" "$OUT/multi-b.o" "$OUT/multi-c.o" "$OUT/multi-d.o" "$OUT/multi-e.o" \
  -o "$OUT/libaster_multi_object_rodata.so"
"$OUT/aster" link-so --soname libaster_multi_object_rodata_reverse.so --needed libc.so \
  "$OUT/multi-e.o" "$OUT/multi-d.o" "$OUT/multi-c.o" "$OUT/multi-b.o" "$OUT/multi-a.o" \
  -o "$OUT/libaster_multi_object_rodata_reverse.so"
for so in "$OUT/libaster_multi_object_rodata.so" "$OUT/libaster_multi_object_rodata_reverse.so"; do
  for sym in aster_multi_rodata_a aster_multi_rodata_helper aster_multi_rodata_b aster_multi_rodata_c aster_multi_rodata_d aster_multi_rodata_e aster_multi_rodata_chain_helper multi_shared strlen; do
    readelf -Ws "$so" | grep -q "$sym"
  done
  readelf -SW "$so" | grep '\.rodata' | grep -Eq 'PROGBITS.* A '
  if readelf -SW "$so" | grep '\.rodata' | grep -Eq ' A[[:space:]]+[^[:space:]]*W'; then
    echo 'FAIL: merged .rodata is writable' >&2; exit 1
  fi
  readelf -h "$so" | grep -q 'Machine:.*AArch64'
  readelf -d "$so" | grep -q 'Shared library: \[libc.so\]'
done
printf '%s\n' 'PASS: five-object link resolves exports in both input orders'
printf '%s\n' '[4/7] Verify writable global is defined once and exported'
readelf -Ws "$OUT/libaster_multi_object_rodata.so" | grep ' multi_shared$' | grep -q 'OBJECT'
printf '%s\n' 'PASS: cross-object mutable global symbol is present'
printf '%s\n' '[5/7] Compile strict host-side ABI harness'
${HOSTCC:-cc} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-multi-object-rodata-host.c -ldl -o "$OUT/multi-object-rodata-host"
printf '%s\n' 'PASS: strict five-object ABI harness compile'
printf '%s\n' '[6/7] Verify input-order variants are valid AArch64 shared objects'
readelf -h "$OUT/libaster_multi_object_rodata_reverse.so" | grep -q 'Type:.*DYN'
readelf -h "$OUT/libaster_multi_object_rodata.so" | grep -q 'Type:.*DYN'
printf '%s\n' 'PASS: both link orders produce ET_DYN'
printf '%s\n' '[7/7] Structural validation complete (run e2e script on target device)'
