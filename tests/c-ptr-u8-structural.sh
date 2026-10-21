#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-c-ptr-u8-structural}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/4] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
printf '%s\n' '[2/4] Emit byte access shared object'
"$OUT/aster" build-so examples/c_ptr_u8.ast -o "$OUT/libaster_ptr_u8.so" --soname libaster_ptr_u8.so
printf '%s\n' '[3/4] Verify ELF exports and byte opcodes'
python3 - "$OUT/libaster_ptr_u8.so" <<'PYCODE'
import struct,sys
b=open(sys.argv[1],'rb').read()
assert b[:4]==b'\x7fELF' and b[4]==2 and b[5]==1, 'not ELF64 little-endian'
# AArch64 instruction words in executable code; these masks recognize unsigned-offset LDRB/STRB.
words=[struct.unpack_from('<I',b,i)[0] for i in range(0,len(b)-3,4)]
assert any((w & 0xffc00000)==0x39400000 for w in words), 'LDRB W instruction not found'
assert any((w & 0xffc00000)==0x39000000 for w in words), 'STRB W instruction not found'
print('PASS: AArch64 ELF64 contains LDRB/STRB byte access instructions')
PYCODE
strings "$OUT/libaster_ptr_u8.so" | grep -q aster_load_u8
strings "$OUT/libaster_ptr_u8.so" | grep -q aster_store_u8
printf '%s\n' 'PASS: AArch64 ELF exports byte load/store functions'
printf '%s\n' '[4/4] Strictly compile C ABI harness'
${HOSTCC:-cc} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror tests/c-ptr-u8-host.c -ldl -o "$OUT/c-ptr-u8-host"
printf '%s\n' 'PASS: strict byte-access C harness compile'
