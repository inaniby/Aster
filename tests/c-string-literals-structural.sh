#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-c-string-literals-structural}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/8] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/8] Emit shared object containing Aster string literals'
"$OUT/aster" build-so examples/string_literals.ast -o "$OUT/libaster_string_literals.so" --soname libaster_string_literals.so --needed libc.so
printf '%s\n' '[3/8] Verify direct shared-object imports and read-only literal data'
readelf -d "$OUT/libaster_string_literals.so" | grep -q 'Shared library: \[libc.so\]'
readelf -Ws "$OUT/libaster_string_literals.so" | grep -q 'aster_literal_strlen'
readelf -Ws "$OUT/libaster_string_literals.so" | grep -q 'strlen'
readelf -Ws "$OUT/libaster_string_literals.so" | grep -q 'memcmp'
readelf -Ws "$OUT/libaster_string_literals.so" | grep -q 'aster_identity'
readelf -Ws "$OUT/libaster_string_literals.so" | grep -q 'aster_literal_strlen_internal'
readelf -SW "$OUT/libaster_string_literals.so" | grep '\.rodata' | grep -Eq 'PROGBITS.* A '
if readelf -SW "$OUT/libaster_string_literals.so" | grep '\.rodata' | grep -Eq ' A[[:space:]]+[^[:space:]]*W'; then
  echo 'FAIL: .rodata is writable' >&2; exit 1
fi
readelf -lW "$OUT/libaster_string_literals.so" | grep -Eq 'LOAD[[:space:]].* R[[:space:]]+0x1000'
printf '%s\n' 'PASS: direct build-so keeps literals in read-only, non-executable .rodata'
printf '%s\n' '[4/8] Build PIC ET_REL object and link it into a shared object'
"$OUT/aster" build-obj --pic examples/string_literals.ast -o "$OUT/string-literals-pic.o"
readelf -SW "$OUT/string-literals-pic.o" | grep '\.rodata' | grep -Eq 'PROGBITS.* A '
"$OUT/aster" link-so --soname libaster_string_literals_obj.so --needed libc.so "$OUT/string-literals-pic.o" -o "$OUT/libaster_string_literals_obj.so"
readelf -SW "$OUT/libaster_string_literals_obj.so" | grep '\.rodata' | grep -Eq 'PROGBITS.* A '
readelf -lW "$OUT/libaster_string_literals_obj.so" | grep -Eq 'LOAD[[:space:]].* R[[:space:]]+0x1000'
printf '%s\n' 'PASS: ET_REL .rodata survives PIC object emission and link-so'
printf '%s\n' '[5/8] Link non-PIC .rodata object into ET_EXEC and static PIE'
"$OUT/aster" build-obj examples/string_literal_exec.ast -o "$OUT/string-literal-exec.o"
readelf -SW "$OUT/string-literal-exec.o" | grep '\.rodata' | grep -Eq 'PROGBITS.* A '
"$OUT/aster" link-obj "$OUT/string-literal-exec.o" -o "$OUT/string-literal-exec"
"$OUT/aster" link-pie "$OUT/string-literal-exec.o" -o "$OUT/string-literal-pie"
for image in "$OUT/string-literal-exec" "$OUT/string-literal-pie"; do
  test -x "$image" || { echo "FAIL: linked executable lacks execute permission: $image" >&2; exit 1; }
  readelf -SW "$image" | grep '\.rodata' | grep -Eq 'PROGBITS.* A '
  readelf -lW "$image" | grep -Eq 'LOAD[[:space:]].* R[[:space:]]+0x1000'
  if readelf -SW "$image" | grep '\.rodata' | grep -Eq ' A[[:space:]]+[^[:space:]]*W'; then
    echo "FAIL: .rodata is writable in $image" >&2; exit 1
  fi
done
readelf -h "$OUT/string-literal-exec" | grep -q 'Type:.*EXEC'
readelf -h "$OUT/string-literal-pie" | grep -q 'Type:.*DYN'
readelf -SW "$OUT/string-literal-exec" | grep '\.data' | grep -Eq 'PROGBITS.* WA '
readelf -lW "$OUT/string-literal-exec" | grep -Eq 'LOAD[[:space:]].* RW[[:space:]]+0x1000'
printf '%s\n' 'PASS: link-obj and link-pie map .rodata read-only while mutable .data stays writable'
printf '%s\n' 'PASS: linked ET_EXEC and static PIE outputs have executable file permissions'
printf '%s\n' '[6/8] Strictly compile C ABI harness'
${HOSTCC:-cc} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-string-literals-host.c -ldl -o "$OUT/c-string-literals-host"
printf '%s\n' 'PASS: strict string-literal C harness compile'
printf '%s\n' '[7/8] Verify all generated ELF files are AArch64'
for image in "$OUT/libaster_string_literals.so" "$OUT/libaster_string_literals_obj.so" "$OUT/string-literal-exec" "$OUT/string-literal-pie"; do
  readelf -h "$image" | grep -q 'Machine:.*AArch64'
done
printf '%s\n' 'PASS: shared objects, ET_EXEC and static PIE are AArch64 ELF'
printf '%s\n' '[8/8] Structural validation complete (run e2e script on target device)'
