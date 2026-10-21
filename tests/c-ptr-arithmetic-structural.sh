#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}; HOSTCC=${HOSTCC:-cc}; OUT=${OUT:-tmp-c-ptr-arithmetic}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/4] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/4] Emit pointer arithmetic shared object'
"$OUT/aster" build-so examples/c_ptr_arithmetic.ast -o "$OUT/libaster_ptr_arithmetic.so" --soname libaster_ptr_arithmetic.so
printf '%s\n' '[3/4] Verify AArch64 ELF exports and pointer arithmetic opcodes'
python3 - "$OUT/libaster_ptr_arithmetic.so" <<'PY'
import struct,sys
p=sys.argv[1]; b=open(p,'rb').read()
assert b[:4]==b'\x7fELF' and b[4]==2 and b[5]==1, 'not ELF64 little endian'
assert struct.unpack_from('<H',b,18)[0]==183, 'not AArch64'
# ADD/SUB Xd, Xn, Wm, SXTW, shift #0: mask out register fields.
words=struct.unpack('<'+'I'*((len(b)//4)),b[:len(b)//4*4])
add=any((w & 0xffe0fc00)==0x8b20c000 for w in words)
sub=any((w & 0xffe0fc00)==0xcb20c000 for w in words)
assert add and sub, 'missing ADD/SUB extended-register pointer arithmetic opcodes'
print('PASS: AArch64 ELF64 contains ADD/SUB X, W, SXTW pointer arithmetic')
PY
if command -v readelf >/dev/null 2>&1; then
  readelf -Ws "$OUT/libaster_ptr_arithmetic.so" | grep -E 'GLOBAL.*aster_ptr_add$' >/dev/null
  readelf -Ws "$OUT/libaster_ptr_arithmetic.so" | grep -E 'GLOBAL.*aster_ptr_sub$' >/dev/null
  readelf -Ws "$OUT/libaster_ptr_arithmetic.so" | grep -E 'GLOBAL.*aster_ptr_add_reversed$' >/dev/null
  echo 'PASS: AArch64 ELF exports pointer arithmetic functions'
fi
printf '%s\n' '[4/4] Strictly compile C ABI harness'
$HOSTCC -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-ptr-arithmetic-host.c -ldl -o "$OUT/c-ptr-arithmetic-host"
echo 'PASS: strict pointer arithmetic C harness compile'
cat > "$OUT/invalid_ptr_add.ast" <<'AST'
fn invalid(a: ptr, b: ptr) -> ptr { return a + b; }
AST
if "$OUT/aster" build-so "$OUT/invalid_ptr_add.ast" -o "$OUT/invalid.so" >"$OUT/invalid.log" 2>&1; then
  echo 'FAIL: ptr + ptr was accepted' >&2; exit 1
fi
grep -F 'invalid pointer arithmetic' "$OUT/invalid.log" >/dev/null
echo 'PASS: ptr + ptr rejected with a diagnostic'
