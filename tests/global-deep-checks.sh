#!/bin/sh
# v0.17.0 structural checks for the deeper global features: fixed-length arrays, run-time global
# initializers and @align alignment control. Nothing here executes a generated image; see
# e2e-global-deep.sh (and run-on-device.sh) for the end-to-end exit-code assertions.
set -eu
[ -x ./aster ] || { echo "build ./aster first" >&2; exit 2; }

./aster build-obj examples/array_rw.ast -o tmp-arr-rw.o
./aster build-obj examples/array_sum.ast -o tmp-arr-sum.o
./aster build-obj examples/array_bss.ast -o tmp-arr-bss.o
./aster build-obj examples/align_global.ast -o tmp-arr-align.o
./aster build-obj examples/runtime_init.ast -o tmp-rt-init.o
./aster build-obj examples/array_extern_main.ast -o tmp-arr-extern-main.o
./aster build-obj examples/array_extern_defs.ast -o tmp-arr-extern-defs.o
./aster build-obj examples/hello.ast -o tmp-hello.o

python3 - <<'PY'
import struct

def load(path):
    b = open(path, 'rb').read()
    shoff = struct.unpack_from('<Q', b, 40)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
    secs = [struct.unpack_from('<IIQQQQIIQQ', b, shoff+i*shentsize) for i in range(shnum)]
    names = secs[shstrndx]
    table = {}
    for i, s in enumerate(secs):
        end = b.index(b'\0', names[4]+s[0]) if s[0] < names[5] else names[4]
        table[b[names[4]+s[0]:end].decode()] = (i, s)
    return b, table

def syms(path):
    b, table = load(path)
    si, s = table['.symtab']; st = table['.strtab'][1]
    out = []
    for off in range(24, s[5], 24):
        n, info, other, shndx, val, size = struct.unpack_from('<IBBHQQ', b, s[4]+off)
        end = b.index(b'\0', st[4]+n)
        out.append((b[st[4]+n:end].decode(), info, shndx, val, size))
    return b, table, out

def relocs(path):
    b, table = load(path)
    ri, r = table['.rela.text']
    out = []
    for off in range(0, r[5], 24):
        o, info, addend = struct.unpack_from('<QQq', b, r[4]+off)
        out.append((o, info >> 32, info & 0xffffffff, addend))
    return b, table, out

# --- .bss array ---------------------------------------------------------------------
b, t, ss = syms('tmp-arr-rw.o')
s = {x[0]: x for x in ss}['a']
bi, bs = t['.bss']
assert '.data' not in t, t.keys()
assert s[1] == 0x11 and s[2] == bi and s[3] == 0 and s[4] == 32, ss
assert bs[1] == 8 and bs[5] == 32 and bs[8] >= 4, bs
print('PASS: zero-initialized i32[8] array is a 32-byte STT_OBJECT at the start of .bss')

# --- .data array with a broadcast constant initializer ------------------------------
b, t, ss = syms('tmp-arr-sum.o')
s = {x[0]: x for x in ss}['v']
di, d = t['.data']
assert s[1] == 0x11 and s[2] == di and s[3] == 0 and s[4] == 20, ss
assert d[1] == 1 and (d[2] & 0x3) == 0x3 and d[5] == 20 and d[8] >= 4, d
assert b[d[4]:d[4]+20] == struct.pack('<5I', 9, 9, 9, 9, 9), b[d[4]:d[4]+20]
print('PASS: non-zero constant i32[5] array is 20 bytes in .data with every element filled')

# --- run-time initializer routine ---------------------------------------------------
b, t, ss = syms('tmp-rt-init.o')
by = {x[0]: x for x in ss}
assert '__aster_init' in by and by['__aster_init'][1] == 0x12 and by['__aster_init'][2] == t['.text'][0], by.keys()
assert '__aster_init_next' in by and by['__aster_init_next'][1] == 0x12 and by['__aster_init_next'][2] == 0, by.keys()
b, t, rr = relocs('tmp-rt-init.o')
called = [r[1] for r in rr if r[2] == 283]
assert ss is not None
# scaled goes to .bss until the initializer writes it, base stays constant in .data.
assert by['scaled'][2] == t['.bss'][0] and by['scaled'][4] == 4, by['scaled']
assert by['base'][2] == t['.data'][0] and by['base'][4] == 4, by['base']
print('PASS: run-time global initializer emits __aster_init (defined) chained through __aster_init_next (undefined)')

# --- no run-time initializers -> none of that machinery is emitted -------------------
b, t, ss = syms('tmp-hello.o')
names = [x[0] for x in ss if (x[1] >> 4) == 1 and x[0]]
assert '__aster_init' not in names and '__aster_init_next' not in names, names
assert names == ['_start'], names
print('PASS: a program with no run-time initializers emits no initializer routine at all')

# --- @align reaches the section alignment, the symbol value and the .bss layout -------
b, t, ss = syms('tmp-arr-align.o')
by = {x[0]: x for x in ss}
di, d = t['.data']; bi, bs = t['.bss']
assert bs[8] == 64, bs          # .bss section alignment
assert d[8] == 32, d            # .data section alignment
assert by['aligned_array'][2] == bi and by['aligned_array'][3] == 0 and by['aligned_array'][4] == 32, by['aligned_array']
assert by['data_array'][2] == di and by['data_array'][3] == 0 and by['data_array'][4] == 12, by['data_array']
assert by['aligned_scalar'][2] == di and by['aligned_scalar'][3] == 32 and by['aligned_scalar'][4] == 4, by['aligned_scalar']
print('PASS: @align(64)/@align(32) show up as section alignment, symbol offset and .bss layout')

# --- cross-object array -----------------------------------------------------------------
b, t, ss = syms('tmp-arr-extern-main.o')
u = {x[0]: x for x in ss}['table']
assert u[1] == 0x11 and u[2] == 0, ss
b, t, ss = syms('tmp-arr-extern-defs.o')
d = {x[0]: x for x in ss}['table']
assert d[1] == 0x11 and d[2] == t['.data'][0] and d[4] == 16, ss
print('PASS: cross-object extern i32[4] array is undefined in the caller and defined in the provider')
PY

# --- diagnostics --------------------------------------------------------------------
cat > tmp-align-odd.ast <<'AST'
let x: i32 @align(24) = 1;
fn main() -> i32 { return x; }
AST
if ./aster build-elf tmp-align-odd.ast -o tmp-align-odd 2>tmp-align-odd.err; then
  echo 'FAIL: compiler accepted a non-power-of-two alignment' >&2; exit 1
fi
grep -F 'alignment must be a power of two: x' tmp-align-odd.err >/dev/null
echo 'PASS: diagnostic non-power-of-two alignment rejected'

cat > tmp-align-huge.ast <<'AST'
let x: i32 @align(8192) = 1;
fn main() -> i32 { return x; }
AST
if ./aster build-elf tmp-align-huge.ast -o tmp-align-huge 2>tmp-align-huge.err; then
  echo 'FAIL: compiler accepted an alignment above 4096' >&2; exit 1
fi
grep -F 'alignment must not exceed 4096 bytes: x' tmp-align-huge.err >/dev/null
echo 'PASS: diagnostic over-large alignment rejected'

cat > tmp-array-zero.ast <<'AST'
let x: i32[0] = 0;
fn main() -> i32 { return 0; }
AST
if ./aster build-elf tmp-array-zero.ast -o tmp-array-zero 2>tmp-array-zero.err; then
  echo 'FAIL: compiler accepted a zero-length array' >&2; exit 1
fi
grep -F 'array length must be between 1 and 1048576: x' tmp-array-zero.err >/dev/null
echo 'PASS: diagnostic zero-length array rejected'

cat > tmp-array-nonconst.ast <<'AST'
fn seed() -> i32 { return 1; }
let x: i32[4] = seed();
fn main() -> i32 { return x[0]; }
AST
if ./aster build-elf tmp-array-nonconst.ast -o tmp-array-nonconst 2>tmp-array-nonconst.err; then
  echo 'FAIL: compiler accepted a non-constant array initializer' >&2; exit 1
fi
grep -F 'array initializer must be a constant expression: x' tmp-array-nonconst.err >/dev/null
echo 'PASS: diagnostic non-constant array initializer rejected'

cat > tmp-index-scalar.ast <<'AST'
let x: i32 = 1;
fn main() -> i32 { return x[0]; }
AST
if ./aster build-elf tmp-index-scalar.ast -o tmp-index-scalar 2>tmp-index-scalar.err; then
  echo 'FAIL: compiler indexed a scalar global' >&2; exit 1
fi
grep -F 'cannot index non-array global: x' tmp-index-scalar.err >/dev/null
echo 'PASS: diagnostic indexing a scalar global rejected'

cat > tmp-array-value.ast <<'AST'
let x: i32[4] = 0;
fn main() -> i32 { return x; }
AST
if ./aster build-elf tmp-array-value.ast -o tmp-array-value 2>tmp-array-value.err; then
  echo 'FAIL: compiler used an array as a scalar value' >&2; exit 1
fi
# An array name decays to a ptr, so returning it from an i32 function is a type
# mismatch (the v0.22.49 run refreshed this assertion: the old
# "array 'x' must be indexed" diagnostic no longer exists in the compiler).
grep -F "return type mismatch in function main" tmp-array-value.err >/dev/null
echo 'PASS: diagnostic using an array as a value rejected'

cat > tmp-array-whole.ast <<'AST'
let x: i32[4] = 0;
fn main() -> i32 { x = 1; return x[0]; }
AST
if ./aster build-elf tmp-array-whole.ast -o tmp-array-whole 2>tmp-array-whole.err; then
  echo 'FAIL: compiler accepted a whole-array assignment' >&2; exit 1
fi
grep -F 'cannot assign to an array as a whole: x' tmp-array-whole.err >/dev/null
echo 'PASS: diagnostic whole-array assignment rejected'

cat > tmp-local-array.ast <<'AST'
fn main() -> i32 {
    let x: i32[4] = 0;
    x[0] = 41;
    x[1] = x[0] + 1;
    if (x[0] + x[1] == 83) { return 0; } else { return 1; }
}
AST
if ! ./aster build-elf tmp-local-array.ast -o tmp-local-array 2>tmp-local-array.err; then
  echo 'FAIL: compiler rejected a local array declaration' >&2; cat tmp-local-array.err >&2; exit 1
fi
./tests/run-aarch64.sh tmp-local-array
echo 'PASS: local i32[4] array accepted, indexed, and executed correctly (v0.22.49)'

# --- shared object: DT_INIT_ARRAY is added only when an initializer exists -----------
./aster build-so examples/runtime_init.ast -o tmp-rt-init.so
./aster build-so examples/so_math.ast -o tmp-so-math.so
python3 - <<'PY'
import struct
def tags(path):
    b = open(path, 'rb').read()
    phoff = struct.unpack_from('<Q', b, 32)[0]
    phnum = struct.unpack_from('<H', b, 56)[0]
    for i in range(phnum):
        t, fl, off, va, pa, fsz, msz, al = struct.unpack_from('<IIQQQQQQ', b, phoff+i*56)
        if t == 2:                              # PT_DYNAMIC
            out = {}
            for j in range(fsz // 16):
                tag, val = struct.unpack_from('<qQ', b, off+j*16)
                out[tag] = val
            return out
    return {}
init = tags('tmp-rt-init.so')
plain = tags('tmp-so-math.so')
assert 25 in init and 27 in init and init[27] == 8, init
assert init[1879048185] == 3, init         # DT_RELACOUNT counts two .got slots plus the .init_array slot
assert 25 not in plain, plain
print('PASS: DT_INIT_ARRAY/DT_INIT_ARRAYSZ appear only for shared objects with run-time initializers')
PY

rm -f tmp-arr-rw.o tmp-arr-sum.o tmp-arr-bss.o tmp-arr-align.o tmp-rt-init.o \
      tmp-arr-extern-main.o tmp-arr-extern-defs.o tmp-hello.o tmp-rt-init.so tmp-so-math.so \
      tmp-align-odd.ast tmp-align-odd.err tmp-align-huge.ast tmp-align-huge.err \
      tmp-array-zero.ast tmp-array-zero.err tmp-array-nonconst.ast tmp-array-nonconst.err \
      tmp-index-scalar.ast tmp-index-scalar.err tmp-array-value.ast tmp-array-value.err \
      tmp-array-whole.ast tmp-array-whole.err tmp-local-array.ast tmp-local-array.err
echo 'PASS: all v0.17.0 deep global-variable checks'
