#!/bin/sh
# Verify data-section (.data/.bss), global-variable and cross-object support.
set -eu
[ -x ./aster ] || { echo "build ./aster first" >&2; exit 2; }

./aster build-obj examples/global_rw.ast -o tmp-g-rw.o
./aster build-obj examples/global_bss.ast -o tmp-g-bss.o
./aster build-obj examples/global_mixed.ast -o tmp-g-mixed.o
./aster build-obj examples/global_shared_main.ast -o tmp-g-main.o
./aster build-obj examples/global_shared_defs.ast -o tmp-g-defs.o

python3 - <<'PY'
import struct
def load(path):
    b = open(path, 'rb').read()
    shoff = struct.unpack_from('<Q', b, 40)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
    secs = [struct.unpack_from('<IIQQQQIIQQ', b, shoff+i*shentsize) for i in range(shnum)]
    names = secs[shstrndx]
    def cstr(off):
        end = b.index(b'\0', names[4]+off)
        return b[names[4]+off:end].decode()
    table = {}
    for i, s in enumerate(secs):
        n = cstr(s[0]) if s[0] < names[5] else ''
        table[n] = (i, s)
    return b, table
def syms(path):
    b, table = load(path)
    si, s = table['.symtab']
    st = table['.strtab'][1]
    out = []
    for off in range(24, s[5], 24):
        n, info, other, shndx, val, size = struct.unpack_from('<IBBHQQ', b, s[4]+off)
        end = b.index(b'\0', st[4]+n)
        out.append((b[st[4]+n:end].decode(), info, shndx, val, size))
    return b, table, out

# .data: non-zero initializer goes to a PROGBITS/WA section with a 4-byte STT_OBJECT symbol.
b, t = load('tmp-g-rw.o')
assert set(t) == {'', '.text', '.data', '.rela.text', '.symtab', '.strtab', '.shstrtab'}, t.keys()
di, d = t['.data']
assert d[1] == 1 and (d[2] & 0x3) == 0x3 and d[5] == 4 and d[8] == 4, d
b, t, ss = syms('tmp-g-rw.o')
assert [s for s in ss if s[0] == 'counter' and s[1] == 0x11 and s[2] == di and s[4] == 4], ss
print('PASS: v0.17.0 non-zero global emitted as STT_OBJECT in .data (WA, size 4)')

# .bss: zero initializer goes to a NOBITS/WA section with no file bytes.
b, t = load('tmp-g-bss.o')
assert '.data' not in t and '.bss' in t, t.keys()
bi, bs = t['.bss']
assert bs[1] == 8 and (bs[2] & 0x3) == 0x3 and bs[5] == 4, bs
b, t, ss = syms('tmp-g-bss.o')
assert [s for s in ss if s[0] == 'zero' and s[1] == 0x11 and s[2] == bi and s[4] == 4], ss
print('PASS: v0.17.0 zero global emitted as STT_OBJECT in .bss (NOBITS, size 4)')

# A single translation unit can carry both non-zero and zero-initialized globals.
b, t = load('tmp-g-mixed.o')
assert '.data' in t and '.bss' in t, t.keys()
b, t, ss = syms('tmp-g-mixed.o')
by = {s[0]: s for s in ss}
assert by['limit'][2] == t['.data'][0] and by['counter'][2] == t['.bss'][0], by
print('PASS: v0.17.0 .data and .bss coexist in one object')

# Global accesses use the ADRP + ADD page-relative pair (types 275/277).
def relocs(path):
    b, table = load(path)
    ri, r = table['.rela.text']
    out = []
    for off in range(0, r[5], 24):
        o, info, addend = struct.unpack_from('<QQq', b, r[4]+off)
        out.append((o, info >> 32, info & 0xffffffff, addend))
    return b, table, out
b, t, rr = relocs('tmp-g-main.o')
shared = [r for r in rr if r[2] in (275, 277)]
assert len(shared) == 4, rr
assert {r[2] for r in rr} == {275, 277, 283}, {r[2] for r in rr}
print('PASS: v0.17.0 global read and write each emit R_AARCH64_ADR_PREL_PG_HI21 + R_AARCH64_ADD_ABS_LO12_NC')

# Cross-object: the caller has an undefined STT_OBJECT and the provider defines it.
b, t, ss = syms('tmp-g-main.o')
u = [s for s in ss if s[0] == 'shared']
assert u and u[0][1] == 0x11 and u[0][2] == 0, u
b, t, ss = syms('tmp-g-defs.o')
d = [s for s in ss if s[0] == 'shared']
assert d and d[0][1] == 0x11 and d[0][2] == t['.data'][0] and d[0][4] == 4, ss
print('PASS: v0.17.0 cross-object global declared undefined in the caller and defined in the provider')
PY

# Cross-object link and execution: one object defines the global, another reads and writes it.
./aster build-obj examples/global_shared_main.ast -o tmp-g-main.o
./aster build-obj examples/global_shared_defs.ast -o tmp-g-defs.o
./aster link-obj tmp-g-main.o tmp-g-defs.o -o tmp-g-shared
chmod +x tmp-g-shared
python3 - <<'PY'
import struct
b = open('tmp-g-shared', 'rb').read()
assert struct.unpack_from('<HH', b, 16) == (2, 183), 'ET_EXEC/AArch64'
assert struct.unpack_from('<H', b, 56)[0] == 2, 'data programs need two PT_LOAD headers'
assert struct.unpack_from('<Q', b, 24)[0] == 0x401000, 'entry unchanged'
phoff = struct.unpack_from('<Q', b, 32)[0]
p = [struct.unpack_from('<IIQQQQQQ', b, phoff+i*56) for i in range(2)]
assert p[0][0] == 1 and p[0][1] == 5, p[0]
assert p[1][0] == 1 and p[1][1] == 6, p[1]
assert p[1][3] % 0x1000 == 0 and p[1][2] % 0x1000 == 0 and p[1][7] == 0x1000, p[1]
assert p[1][5] == 4 and p[1][6] == 4, p[1]
print('PASS: v0.17.0 ET_EXEC has R+X text and a page-aligned R+W PT_LOAD for .data')
PY
set +e
./tests/run-aarch64.sh ./tmp-g-shared
got=$?
set -e
[ "$got" -eq 42 ] || { echo "FAIL: cross-object global expected 42, got $got"; exit 1; }
echo "PASS: v0.17.0 cross-object global read/write exit=$got"

for name in global_rw global_bss global_mixed global_shadow; do
  ./aster build-elf "examples/$name.ast" -o "tmp-$name"
  chmod +x "tmp-$name"
  set +e
  "./tests/run-aarch64.sh" "./tmp-$name"
  got=$?
  set -e
  [ "$got" -eq 42 ] || { echo "FAIL: $name expected 42, got $got"; exit 1; }
  echo "PASS: v0.17.0 $name exit=$got"
done

# Diagnostic: duplicate global definition in one file.
cat > tmp-dup-global.ast <<'AST'
let x: i32 = 1;
let x: i32 = 2;
fn main() -> i32 { return x; }
AST
if ./aster build-elf tmp-dup-global.ast -o tmp-dup-global 2>tmp-dup-global.err; then
  echo 'FAIL: compiler accepted a duplicate global declaration' >&2; exit 1
fi
grep -F 'duplicate global variable: x' tmp-dup-global.err >/dev/null
echo 'PASS: v0.17.0 duplicate global declaration rejected'

# v0.17.0: a non-constant scalar initializer is a run-time initializer, not an error.
cat > tmp-global-nonconst.ast <<'AST'
fn seed() -> i32 { return 1; }
let g: i32 = seed();
fn main() -> i32 { return g; }
AST
./aster build-elf tmp-global-nonconst.ast -o tmp-global-nonconst
chmod +x tmp-global-nonconst
set +e
./tests/run-aarch64.sh ./tmp-global-nonconst
got=$?
set -e
[ "$got" -eq 1 ] || { echo "FAIL: run-time-initialized global expected 1, got $got"; exit 1; }
echo "PASS: v0.17.0 non-constant global initializer accepted as a run-time initializer (exit=$got)"

# Diagnostic: an unresolved global reference must fail at link time.
cat > tmp-global-unresolved.ast <<'AST'
extern let missing: i32;
fn main() -> i32 { return missing; }
AST
./aster build-obj tmp-global-unresolved.ast -o tmp-global-unresolved.o
if ./aster link-obj tmp-global-unresolved.o -o tmp-global-unresolved 2>tmp-global-unresolved.err; then
  echo 'FAIL: linker accepted an undefined global variable' >&2; exit 1
fi
grep -F "undefined global variable symbol 'missing'" tmp-global-unresolved.err >/dev/null
echo 'PASS: v0.17.0 unresolved global reference rejected at link time'

# Diagnostic: duplicate global definition across objects must fail.
if ./aster link-obj tmp-g-defs.o tmp-g-defs.o -o tmp-dup-global-obj 2>tmp-dup-global-obj.err; then
  echo 'FAIL: linker accepted a duplicate global across objects' >&2; exit 1
fi
grep -F 'duplicate global symbol' tmp-dup-global-obj.err >/dev/null
echo 'PASS: v0.17.0 duplicate global definition across objects rejected'

rm -f tmp-g-rw.o tmp-g-bss.o tmp-g-mixed.o tmp-g-main.o tmp-g-defs.o tmp-g-shared \
      tmp-global_rw tmp-global_bss tmp-global_mixed tmp-global_shadow \
      tmp-dup-global.ast tmp-dup-global.err tmp-dup-global tmp-global-nonconst.ast \
      tmp-global-nonconst.err tmp-global-nonconst tmp-global-unresolved.ast \
      tmp-global-unresolved.o tmp-global-unresolved.err tmp-global-unresolved \
      tmp-dup-global-obj tmp-dup-global-obj.err
echo 'PASS: all v0.17.0 data-section and global-variable checks'
