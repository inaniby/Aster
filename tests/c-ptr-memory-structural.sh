#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}; HOSTCC=${HOSTCC:-cc}; WORK=$(mktemp -d "${TMPDIR:-/tmp}/aster-ptr-memory.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$WORK/aster"
"$WORK/aster" build-so examples/c_ptr_memory.ast -o "$WORK/libaster_ptr_memory.so" --soname libaster_ptr_memory.so
if command -v readelf >/dev/null 2>&1; then
  readelf -h "$WORK/libaster_ptr_memory.so" | grep -F AArch64 >/dev/null
  readelf -Ws "$WORK/libaster_ptr_memory.so" | grep -E 'GLOBAL.*aster_ptr_load$' >/dev/null
  readelf -Ws "$WORK/libaster_ptr_memory.so" | grep -E 'GLOBAL.*aster_ptr_store$' >/dev/null
  readelf -x .text "$WORK/libaster_ptr_memory.so" > "$WORK/text.hex"
  grep -F '000040b9' "$WORK/text.hex" >/dev/null
  grep -F '010000b9' "$WORK/text.hex" >/dev/null
  echo 'PASS: AArch64 ELF exports pointer load/store and contains LDR/STR W instructions'
else echo 'SKIP: readelf unavailable'; fi
$HOSTCC -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror -c tests/c-ptr-memory-host.c -o "$WORK/harness.o"
echo 'PASS: strict pointer memory C harness compile'
cat > "$WORK/bad-deref.ast" <<'AST'
fn bad(x: i32) -> i32 { return *x; }
AST
if "$WORK/aster" build-so "$WORK/bad-deref.ast" -o "$WORK/bad.so" >"$WORK/bad.log" 2>&1; then echo 'FAIL: non-pointer dereference accepted'; exit 10; fi
grep -F 'dereference requires a ptr expression' "$WORK/bad.log" >/dev/null
echo 'PASS: non-pointer dereference rejected'
