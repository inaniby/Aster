#!/bin/sh
# Host-safe structural checks for the initial AArch64 pointer ABI slice.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aster-ptr-structural.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$WORK/aster"
"$WORK/aster" build-so examples/c_ptr_echo.ast -o "$WORK/libaster_ptr.so" --soname libaster_ptr.so
command -v readelf >/dev/null 2>&1 || { echo 'SKIP: readelf unavailable'; exit 0; }
readelf -h "$WORK/libaster_ptr.so" | grep -F 'AArch64' >/dev/null
readelf -Ws "$WORK/libaster_ptr.so" | grep -E 'GLOBAL.*aster_ptr_echo$' >/dev/null
readelf -x .text "$WORK/libaster_ptr.so" >"$WORK/text.hex"
grep -F 'e00300f9' "$WORK/text.hex" >/dev/null
grep -F 'e00340f9' "$WORK/text.hex" >/dev/null
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -c src/aster.cpp -o "$WORK/aster.o"
${HOSTCC:-cc} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-ptr-host.c -ldl -o "$WORK/c-ptr-host"
cat > "$WORK/bad-return.ast" <<'AST'
fn bad(p: ptr) -> i32 { return p; }
AST
if "$WORK/aster" build-so "$WORK/bad-return.ast" -o "$WORK/bad.so" >"$WORK/bad-return.log" 2>&1; then
  echo 'FAIL: pointer-to-i32 return mismatch was accepted'; exit 10
fi
grep -F 'return type mismatch' "$WORK/bad-return.log" >/dev/null
cat > "$WORK/internal-call.ast" <<'AST'
fn echo(p: ptr) -> ptr { return p; }
fn caller(p: ptr) -> ptr { return echo(p); }
AST
"$WORK/aster" build-so "$WORK/internal-call.ast" -o "$WORK/internal-call.so" --soname libaster_internal_call.so
readelf -Ws "$WORK/internal-call.so" | grep -E 'GLOBAL.*caller$' >/dev/null
echo 'PASS: AArch64 ELF exports aster_ptr_echo'
echo 'PASS: pointer/i32 return mismatch rejected'
echo 'PASS: Aster-to-Aster pointer argument and return call accepted'
echo 'PASS: strict C harness compile'
