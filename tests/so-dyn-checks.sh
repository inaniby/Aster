#!/bin/sh
# v0.18.0 structural verification of the dynamic shared-object outputs.
#
# Nothing here executes an image; see tests/e2e-so-import.sh and tests/run-bionic.sh for the
# dlopen/dlsym execution evidence. This script checks, with an independent ELF reader (python3)
# and, when available, real binutils (`readelf`):
#   * `build-obj --pic` really produces a position-independent ET_REL object for link-so;
#   * `build-so --soname/--needed` records DT_SONAME and DT_NEEDED;
#   * every imported function has a .plt stub and a .got.plt slot with R_AARCH64_JUMP_SLOT, and
#     DT_JMPREL/DT_PLTRELSZ/DT_PLTREL/DT_PLTGOT describe them;
#   * every imported object has a .got slot with R_AARCH64_GLOB_DAT inside the DT_RELA range;
#   * DT_HASH resolves the exported and the imported names;
#   * `link-so` merges several objects and resolves their mutual references inside the .so.
set -eu
[ -x ./aster ] || { echo "build ./aster first" >&2; exit 2; }
READELF=${READELF:-readelf}

./aster build-obj --pic examples/link_so_part_a.ast -o tmp-dyn-a.o
./aster build-obj --pic examples/link_so_part_b.ast -o tmp-dyn-b.o
./aster build-so examples/so_link_lib.ast -o tmp-dyn-lib.so --soname libdyn.so
./aster build-so examples/so_link_import.ast -o tmp-dyn-import.so --needed libdyn.so
./aster build-obj --pic examples/so_link_import.ast -o tmp-dyn-import.o
./aster link-so tmp-dyn-import.o -o tmp-dyn-import-linked.so --soname libdyn-import-linked.so --needed libdyn.so
./aster link-so tmp-dyn-a.o tmp-dyn-b.o -o tmp-dyn-linked.so --soname liblinked.so
./aster build-so examples/link_so_client.ast -o tmp-dyn-client.so --needed liblinked.so

python3 - <<'PY'
import struct

def load(path):
    b = open(path, 'rb').read()
    assert b[:6] == b'\x7fELF\x02\x01', path
    return b

def sections(b):
    shoff = struct.unpack_from('<Q', b, 40)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
    raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*shentsize) for i in range(shnum)]
    names = b[raw[shstrndx][4]:raw[shstrndx][4]+raw[shstrndx][5]]
    out = {}
    for s in raw:
        out[names[s[0]:names.index(b'\0', s[0])].decode()] = s
    return out

def dynamic(b, sec):
    d = sec['.dynamic']
    out = {}
    for i in range(d[5]//16):
        tag, val = struct.unpack_from('<qQ', b, d[4]+i*16)
        out.setdefault(tag, []).append(val)
    return out

def dynsyms(b, sec):
    sym, st = sec['.dynsym'], sec['.dynstr']
    strs = b[st[4]:st[4]+st[5]]
    out = []
    for i in range(sym[5]//24):
        nm, info, other, shndx, val, size = struct.unpack_from('<IBBHQQ', b, sym[4]+i*24)
        out.append((strs[nm:].split(b'\0')[0].decode(), info, shndx, val, size))
    return out

def relocs(b, sec, name):
    if name not in sec:
        return []
    r = sec[name]
    out = []
    for i in range(r[5]//24):
        off = struct.unpack_from('<Q', b, r[4]+i*24)[0]
        info = struct.unpack_from('<Q', b, r[4]+i*24+8)[0]
        add = struct.unpack_from('<q', b, r[4]+i*24+16)[0]
        out.append((off, info >> 32, info & 0xffffffff, add))
    return out

def elfhash(name):
    h = 0
    for c in name.encode():
        h = ((h << 4) + c) & 0xffffffff
        g = h & 0xf0000000
        if g:
            h ^= g >> 24
        h &= ~g
    return h

def hash_lookup(b, sec, name):
    h = sec['.hash']
    words = struct.unpack_from('<%dI' % (h[5]//4), b, h[4])
    nb, nc = words[0], words[1]
    buckets, chains = words[2:2+nb], words[2+nb:2+nb+nc]
    i = buckets[elfhash(name) % nb]
    while i:
        if dynsyms(b, sec)[i][0] == name:
            return True
        i = chains[i]
    return False

# ---------------------------------------------------------------- PIC objects for link-so
def symtab_syms(b, sec):
    sym, st = sec['.symtab'], sec['.strtab']
    strs = b[st[4]:st[4]+st[5]]
    out = []
    for i in range(sym[5]//24):
        nm, info, other, shndx, val, size = struct.unpack_from('<IBBHQQ', b, sym[4]+i*24)
        out.append((strs[nm:].split(b'\0')[0].decode(), info, shndx, val, size))
    return out

b = load('tmp-dyn-a.o'); sec = sections(b)
assert struct.unpack_from('<H', b, 16)[0] == 1, 'PIC object must be ET_REL'
assert struct.unpack_from('<H', b, 18)[0] == 183, 'PIC object must be AArch64'
names = symtab_syms(b, sec)
assert not [n for n, i, sh, v, s in names if n == '_start'], 'a PIC object must not define _start'
gat = sorted(n for n, i, sh, v, s in names if n.startswith('__aster_gat_') and sh == 0)
assert gat == ['__aster_gat_base'], gat
assert 'add' in [n for n, i, sh, v, s in names if sh != 0], names
print('PASS: build-obj --pic emits a position-independent ET_REL object (GOT-slot references, no _start)')

# ---------------------------------------------------------------- DT_SONAME / DT_NEEDED
b = load('tmp-dyn-lib.so'); sec = sections(b); dyn = dynamic(b, sec)
assert struct.unpack_from('<H', b, 16)[0] == 3, 'shared object must be ET_DYN'
assert [s for s in ('.text','.plt','.dynsym','.dynstr','.hash','.rela.dyn','.rela.plt','.data','.got.plt','.got','.dynamic','.bss') if s not in sec] == []
strtab = sec['.dynstr']; strs = b[strtab[4]:strtab[4]+strtab[5]]
soname = [strs[v:].split(b'\0')[0].decode() for v in dyn.get(14, [])]
assert soname == ['libdyn.so'], soname
print('PASS: build-so --soname records DT_SONAME=%r' % soname[0])

b = load('tmp-dyn-import.so'); sec = sections(b); dyn = dynamic(b, sec)
strtab = sec['.dynstr']; strs = b[strtab[4]:strtab[4]+strtab[5]]
needed = [strs[v:].split(b'\0')[0].decode() for v in dyn.get(1, [])]
# v0.22.40 auto-DT_NEEDED: explicit --needed entries are preserved, and extern
# imports that match no NDK library fall back to libc.so, so both appear.
assert needed == ['libdyn.so', 'libc.so'], needed
print('PASS: build-so --needed records DT_NEEDED=%r (plus auto libc.so fallback)' % needed[0])

# ---------------------------------------------------------------- exported global in .dynsym
lb = load('tmp-dyn-lib.so'); lsec = sections(lb)
syms = dynsyms(lb, lsec)
assert ('counter', 0x11, 8, 0x2000, 4) in syms, [s for s in syms if s[0] == 'counter']
print('PASS: the exporting .so lists its global %s in .dynsym as a defined STT_OBJECT' % 'counter')

# ---------------------------------------------------------------- PLT / GOT imports
syms = dynsyms(b, sec)
undef = {n: i for i, (n, info, sh, v, s) in enumerate(syms) if i and sh == 0}
assert undef.get('add') and undef.get('mul') and undef.get('counter'), undef
plt = relocs(b, sec, '.rela.plt'); rdy = relocs(b, sec, '.rela.dyn')
jump = [r for r in plt if r[2] == 1026]
glob = [r for r in rdy if r[2] == 1025]
gotp = sec['.got.plt']; got = sec['.got']
assert sorted(r[1] for r in jump) == sorted([undef['add'], undef['mul']]), jump
assert all(gotp[3] <= r[0] < gotp[3] + gotp[5] for r in jump), jump
print('PASS: imported functions add/mul have R_AARCH64_JUMP_SLOT relocations into .got.plt')

assert [(r[1], syms[r[1]][0]) for r in glob] == [(undef['counter'], 'counter')], glob
assert all(got[3] <= r[0] < got[3] + got[5] for r in glob), glob
print('PASS: imported global counter has an R_AARCH64_GLOB_DAT relocation into .got')

# ---------------------------------------------------------------- ET_REL -> link-so cross-DSO imports must preserve GOT/PLT relocations
lb = load('tmp-dyn-import-linked.so'); lsec = sections(lb); ldyn = dynamic(lb, lsec)
lstrsec = lsec['.dynstr']; lstrs = lb[lstrsec[4]:lstrsec[4]+lstrsec[5]]
lneeded = [lstrs[v:].split(b'\0')[0].decode() for v in ldyn.get(1, [])]
assert lneeded == ['libdyn.so'], lneeded
lsyms = dynsyms(lb, lsec)
lundef = {n: i for i, (n, info, sh, v, z) in enumerate(lsyms) if i and sh == 0}
assert all(n in lundef for n in ('add', 'mul', 'counter')), lundef
ljump = [r for r in relocs(lb, lsec, '.rela.plt') if r[2] == 1026]
lglob = [r for r in relocs(lb, lsec, '.rela.dyn') if r[2] == 1025]
assert sorted(r[1] for r in ljump) == sorted([lundef['add'], lundef['mul']]), ljump
assert [(r[1], lsyms[r[1]][0]) for r in lglob] == [(lundef['counter'], 'counter')], lglob
lgotp, lgot = lsec['.got.plt'], lsec['.got']
assert all(lgotp[3] <= r[0] < lgotp[3] + lgotp[5] for r in ljump), ljump
assert all(lgot[3] <= r[0] < lgot[3] + lgot[5] for r in lglob), lglob
print('PASS: PIC ET_REL -> link-so retains external add/mul JUMP_SLOT and counter GLOB_DAT imports')

# ---------------------------------------------------------------- dynamic tags self-consistency
assert dyn[23][0] == sec['.rela.plt'][4], ('DT_JMPREL', hex(dyn[23][0]))
assert dyn[2][0] == sec['.rela.plt'][5], ('DT_PLTRELSZ', dyn[2][0])
assert dyn[20][0] == 7, ('DT_PLTREL must be DT_RELA', dyn[20][0])
assert dyn[3][0] == gotp[3], ('DT_PLTGOT', hex(dyn[3][0]))
assert dyn.get(24) is not None and dyn.get(30) == [0x8], 'DT_BIND_NOW / DF_BIND_NOW expected'
print('PASS: DT_JMPREL/DT_PLTRELSZ/DT_PLTREL(=DT_RELA)/DT_PLTGOT are consistent with .rela.plt and .got.plt')

assert dyn[7][0] == sec['.rela.dyn'][4] and dyn[8][0] == sec['.rela.dyn'][5] and dyn[9][0] == 24
assert dyn[1879048185][0] == 1, ('DT_RELACOUNT', dyn[1879048185])
print('PASS: DT_RELA/DT_RELASZ/DT_RELAENT/DT_RELACOUNT agree with .rela.dyn')

assert dyn[5][0] == sec['.dynstr'][4] and dyn[6][0] == sec['.dynsym'][4]
assert dyn[10][0] == sec['.dynstr'][5] and dyn[11][0] == 24 and dyn[4][0] == sec['.hash'][4]
print('PASS: DT_STRTAB/DT_SYMTAB/DT_STRSZ/DT_SYMENT/DT_HASH point at the matching sections')

for n in ('add', 'mul', 'counter', 'call_add', 'bump_counter'):
    assert hash_lookup(b, sec, n), ('DT_HASH lookup failed for', n)
print('PASS: DT_HASH resolves every exported and every imported name')

# ---------------------------------------------------------------- .plt stub encoding
gotp_addr = gotp[3]
stub = b[sec['.plt'][4]:sec['.plt'][4]+sec['.plt'][5]]
assert len(stub) == 16*len(jump), len(stub)
ok = 0
for k, r in enumerate(sorted(jump, key=lambda r: r[0])):
    slot = r[0]
    ins = sec['.plt'][3] + 16*k
    w0, w1, w2, w3 = struct.unpack_from('<4I', stub, 16*k)
    page = (slot & ~0xfff) - (ins & ~0xfff)
    imm = (page >> 12) & 0x1fffff
    want0 = 0x90000000 | ((imm & 3) << 29) | (((imm >> 2) & 0x7ffff) << 5) | 16
    want1 = 0xF9400000 | (((slot & 0xfff) >> 3) << 10) | (16 << 5) | 17
    assert (w0, w1, w2, w3) == (want0, want1, 0xD61F0220, 0xD503201F), (hex(w0), hex(want0))
    ok += 1
print('PASS: each .plt stub is ADRP x16,page(slot) / LDR x17,[x16,#lo12(slot)] / BR x17 / NOP')

# ---------------------------------------------------------------- link-so: merging and local resolution
b = load('tmp-dyn-linked.so'); sec = sections(b); dyn = dynamic(b, sec)
syms = dynsyms(b, sec)
defs = {n: i for i, (n, info, sh, v, s) in enumerate(syms) if sh != 0}
undef = {n for i, (n, info, sh, v, s) in enumerate(syms) if i and sh == 0}
assert {'add', 'scaled', 'sum_base', 'base'} <= set(defs), sorted(defs)
print('PASS: link-so merged 2 objects and exports %s' % ', '.join(sorted(k for k in defs if k in ('add','scaled','sum_base','base'))))
assert 'add' not in undef and '__aster_gat_base' not in undef, undef
assert not relocs(b, sec, '.rela.plt'), 'part B calls add(), defined by part A: no PLT import expected'
print('PASS: references resolved inside the same .so stay local (no PLT/GOT import for part A symbols)')
strs = b[sec['.dynstr'][4]:sec['.dynstr'][4]+sec['.dynstr'][5]]
sonames = [strs[v:].split(b'\0')[0].decode() for v in dyn.get(14, [])]
assert sonames == ['liblinked.so'], sonames
print('PASS: link-so sets DT_SONAME from --soname')

# ---------------------------------------------------------------- link-so client: real imports
b = load('tmp-dyn-client.so'); sec = sections(b); dyn = dynamic(b, sec)
strs = b[sec['.dynstr'][4]:sec['.dynstr'][4]+sec['.dynstr'][5]]
# v0.22.40 auto-DT_NEEDED: the explicit --needed stays first, and the two
# extern imports (not in the NDK map) fall back to libc.so.
assert [strs[v:].split(b'\0')[0].decode() for v in dyn.get(1, [])] == ['liblinked.so', 'libc.so']
syms = dynsyms(b, sec)
undef = {n: i for i, (n, info, sh, v, s) in enumerate(syms) if i and sh == 0}
jump = [r for r in relocs(b, sec, '.rela.plt') if r[2] == 1026]
glob = [r for r in relocs(b, sec, '.rela.dyn') if r[2] == 1025]
assert sorted(syms[r[1]][0] for r in jump) == ['scaled', 'sum_base'], [syms[r[1]][0] for r in jump]
assert [syms[r[1]][0] for r in glob] == ['base'], [syms[r[1]][0] for r in glob]
print('PASS: a .so that imports from a link-so output gets PLT stubs for its functions and a GOT slot for its global')
PY

# ---------------------------------------------------------------- built-in readelf cross-check
if command -v "$READELF" >/dev/null 2>&1 && "$READELF" -h tmp-dyn-import.so >/dev/null 2>&1; then
    "$READELF" -dW tmp-dyn-import.so > tmp-dyn-d.txt
    "$READELF" -rW tmp-dyn-import.so > tmp-dyn-r.txt
    grep -q 'SONAME' tmp-dyn-d.txt || { echo 'FAIL: readelf -d lacks DT_SONAME'; exit 1; }
    grep -q 'NEEDED.*libdyn.so' tmp-dyn-d.txt || { echo 'FAIL: readelf -d lacks DT_NEEDED'; exit 1; }
    grep -q 'PLTREL.*RELA'      tmp-dyn-d.txt || { echo 'FAIL: readelf -d lacks DT_PLTREL'; exit 1; }
    grep -q 'JUMP_SLOT'         tmp-dyn-r.txt || { echo 'FAIL: readelf -r lacks JUMP_SLOT'; exit 1; }
    grep -q 'GLOB_DAT'          tmp-dyn-r.txt || { echo 'FAIL: readelf -r lacks GLOB_DAT'; exit 1; }
    echo "PASS: real binutils readelf -d/-r reads back DT_SONAME/DT_NEEDED/PLTREL, JUMP_SLOT and GLOB_DAT"
else
    echo "SKIP: readelf not usable; python-only checks above already cover this"
fi
echo "PASS: all v0.22.21-dev dynamic shared-object structural checks"
