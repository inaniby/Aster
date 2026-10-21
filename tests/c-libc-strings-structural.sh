#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-c-libc-strings-structural}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/5] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/5] Emit Bionic string-call shared object'
"$OUT/aster" build-so examples/c_libc_strings.ast -o "$OUT/libaster_libc_strings.so" --soname libaster_libc_strings.so --needed libc.so
printf '%s\n' '[3/5] Verify exported wrappers and PLT imports'
${READELF:-readelf} -Ws "$OUT/libaster_libc_strings.so" > "$OUT/symbols.txt"
grep -q 'aster_strlen' "$OUT/symbols.txt"
grep -q 'aster_memcmp' "$OUT/symbols.txt"
grep -q 'strlen' "$OUT/symbols.txt"
grep -q 'memcmp' "$OUT/symbols.txt"
${READELF:-readelf} -d "$OUT/libaster_libc_strings.so" | grep -q 'Shared library: \[libc.so\]'
printf '%s\n' 'PASS: AArch64 ELF exports wrappers and imports strlen/memcmp through PLT'
printf '%s\n' '[4/5] Strictly compile C ABI harness'
${HOSTCC:-cc} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-libc-strings-host.c -ldl -o "$OUT/c-libc-strings-host"
printf '%s\n' 'PASS: strict libc-string C harness compile'
cat > "$OUT/bad-pointer-arg.ast" <<'AST'
extern fn strlen(s: ptr) -> i32;
fn bad(value: i32) -> i32 { return strlen(value); }
AST
if "$OUT/aster" build-so "$OUT/bad-pointer-arg.ast" -o "$OUT/bad.so" >"$OUT/bad-pointer-arg.log" 2>&1; then
  echo 'FAIL: i32 passed to ptr parameter was accepted'; exit 10
fi
grep -F 'argument type mismatch calling strlen at argument 1: expected ptr' "$OUT/bad-pointer-arg.log" >/dev/null
printf '%s\n' 'PASS: pointer/i32 external argument mismatch rejected'
printf '%s\n' '[5/5] Structural validation complete (run e2e script on target device)'
