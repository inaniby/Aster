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
#   * `link-so` stores a defined function's address (a callback table entry) as
#     R_AARCH64_RELATIVE, never as a GLOB_DAT import of an UND OBJECT duplicate
#     of the same name (v0.23.81-dev H-2; the build-so path already did this).
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
# v0.23.81-dev (H-2): a callback table that stores the addresses of functions
# defined in the same link. The table TU defines the callbacks and takes their
# addresses; the second TU only calls through the table. Taking the address of
# an extern function is refused by the language itself, so the GLOB_DAT
# self-reference this guards against is always a same-link definition.
cat > tmp-dyn-funcaddr-a.ast <<'AST'
fn cb_add(x: i32) : i32 { return x + 1; }
fn cb_mul(x: i32) : i32 { return x * 2; }
let table: ptr[2] = 0;
fn install() : i32 {
    table[0] = cb_add;
    table[1] = cb_mul;
    return 0;
}
fn call_first(x: i32) : i32 {
    let f: fn(i32) : i32 = table[0];
    return f(x);
}
AST
cat > tmp-dyn-funcaddr-b.ast <<'AST'
extern fn install() : i32;
extern fn call_first(x: i32) : i32;
fn run() : i32 {
    install();
    return call_first(41);
}
AST
./aster build-obj --pic tmp-dyn-funcaddr-a.ast -o tmp-dyn-funcaddr-a.o
./aster build-obj --pic tmp-dyn-funcaddr-b.ast -o tmp-dyn-funcaddr-b.o
./aster link-so tmp-dyn-funcaddr-a.o tmp-dyn-funcaddr-b.o -o tmp-dyn-funcaddr.so --soname libfuncaddr.so
# v0.23.81-dev (ELF-P2-1): the same callback table, but with no --soname and
# no imports at all, takes the non-Dyn writer — which used to die with
# "undefined global variable symbol '__aster_gat_cb_add'".
./aster build-so tmp-dyn-funcaddr-a.ast -o tmp-dyn-funcaddr-nodyn.so
# v0.23.81-dev (ELF-P2-2): one TU calls `extern fn f`, another reads
# `extern let f` — the same name lands in importFuncs and importObjects.
cat > tmp-dyn-dupimp-call.ast <<'AST'
extern fn f() : i32;
fn run() : i32 { return f(); }
AST
cat > tmp-dyn-dupimp-data.ast <<'AST'
extern let f: i32;
fn getf() : i32 { return f; }
AST
./aster build-obj --pic tmp-dyn-dupimp-call.ast -o tmp-dyn-dupimp-call.o
./aster build-obj --pic tmp-dyn-dupimp-data.ast -o tmp-dyn-dupimp-data.o
./aster link-so tmp-dyn-dupimp-call.o tmp-dyn-dupimp-data.o -o tmp-dyn-dupimp.so --soname libdupimp.so
# v0.23.81-dev (ELF-P2-2): a kind conflict between TUs — one defines `f` as
# data, another calls it as a function — must fail loudly, never emit a .so
# whose .dynsym holds a defined OBJECT `f` and an UND FUNC `f` at once.
cat > tmp-dyn-kindconf-def.ast <<'AST'
let f: i32 = 7;
fn getf() : i32 { return f; }
AST
cat > tmp-dyn-kindconf-call.ast <<'AST'
extern fn f() : i32;
fn run() : i32 { return f(); }
AST
./aster build-obj --pic tmp-dyn-kindconf-def.ast -o tmp-dyn-kindconf-def.o
./aster build-obj --pic tmp-dyn-kindconf-call.ast -o tmp-dyn-kindconf-call.o
if ./aster link-so tmp-dyn-kindconf-def.o tmp-dyn-kindconf-call.o -o tmp-dyn-kindconf.so --soname libkindconf.so 2>tmp-dyn-kindconf.err; then
    echo 'FAIL: link-so accepted a call to a symbol defined as data'
    exit 1
fi
grep -q "defined as a global but called as a function" tmp-dyn-kindconf.err || { echo 'FAIL: kind-conflict error message missing'; exit 1; }
echo 'PASS: link-so refuses a call to a symbol defined as data (kind conflict between TUs)'

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
# v0.23.82-dev: link-so now derives DT_NEEDED from imports the same way
# build-so does (449ad2a), so the libc.so fallback for non-NDK imports
# appears here too, matching the build-so expectation above.
assert lneeded == ['libdyn.so', 'libc.so'], lneeded
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

# ---------------------------------------------------------------- link-so: defined-function addresses are RELATIVE, not GLOB_DAT
# v0.23.81-dev (H-2): before the fix the GAT loop pushed every defined
# function whose address was taken into spec.importObjects, so the .so
# carried an UND OBJECT duplicate of cb_add/cb_mul and a GLOB_DAT relocation
# pointing at it (the reference check_so.py gate failed 30/30 on libuihello).
# The writer already emitted RELATIVE for funcAddrRefs; only the link-so
# feeder was missing the classification build-so has.
b = load('tmp-dyn-funcaddr.so'); sec = sections(b); dyn = dynamic(b, sec)
syms = dynsyms(b, sec)
defs = {n for i, (n, info, sh, v, s) in enumerate(syms) if sh != 0}
undef = {n for i, (n, info, sh, v, s) in enumerate(syms) if i and sh == 0}
assert 'cb_add' in defs and 'cb_mul' in defs, sorted(defs)
assert 'cb_add' not in undef and 'cb_mul' not in undef, sorted(undef)
glob = [r for r in relocs(b, sec, '.rela.dyn') if r[2] == 1025]
assert not glob, [(r, syms[r[1]][0]) for r in glob]
rel = [r for r in relocs(b, sec, '.rela.dyn') if r[2] == 1027]
export_vaddr = {n: v for n, info, sh, v, s in syms if sh != 0}
cb_rel = sorted(r[3] for r in rel if r[3] in (export_vaddr['cb_add'], export_vaddr['cb_mul']))
assert cb_rel == sorted([export_vaddr['cb_add'], export_vaddr['cb_mul']]), cb_rel
print('PASS: link-so stores defined-function addresses as R_AARCH64_RELATIVE (no GLOB_DAT self-reference for cb_add/cb_mul)')

# ---------------------------------------------------------------- build-so without --soname: defined-function addresses in the non-Dyn writer
# v0.23.81-dev (ELF-P2-1): the non-Dyn writer had no GOT slot for a defined
# function, so this build used to fail outright. Now it must look exactly like
# the Dyn-writer shape: no undefined imports, RELATIVE relocations whose
# addends are the two callback addresses (plus the table global), and a
# DT_RELACOUNT that counts all three.
b = load('tmp-dyn-funcaddr-nodyn.so'); sec = sections(b); dyn = dynamic(b, sec)
syms = dynsyms(b, sec)
assert not [n for n, info, sh, v, s in syms if n and sh == 0], syms
assert 'cb_add' in [n for n, info, sh, v, s in syms if sh != 0]
# The non-Dyn writer lists only exported functions in .dynsym, so the table
# global's address is read off the Dyn-writer twin of the same source (the
# two writers lay .text out identically — the twin's cb_add/cb_mul values
# must match this file's too).
tb = load('tmp-dyn-funcaddr.so'); tsec = sections(tb)
twin_vaddr = {n: v for n, info, sh, v, s in dynsyms(tb, tsec) if sh != 0}
own_vaddr = {n: v for n, info, sh, v, s in syms if sh != 0}
assert own_vaddr['cb_add'] == twin_vaddr['cb_add'] and own_vaddr['cb_mul'] == twin_vaddr['cb_mul']
rel = [r for r in relocs(b, sec, '.rela.dyn') if r[2] == 1027]
assert sorted(r[3] for r in rel) == sorted([twin_vaddr['cb_add'], twin_vaddr['cb_mul'], twin_vaddr['table']]), rel
assert dyn[1879048185][0] == 3, ('DT_RELACOUNT', dyn[1879048185])
assert not [r for r in relocs(b, sec, '.rela.dyn') if r[2] == 1025], 'no GLOB_DAT expected'
print('PASS: build-so without --soname stores defined-function addresses as R_AARCH64_RELATIVE (non-Dyn writer)')

# ---------------------------------------------------------------- link-so: one name imported as both function and object
# v0.23.81-dev (ELF-P2-2): before the fix .dynsym held an empty-named NOTYPE
# slot (the orphaned FUNC import) plus an UND OBJECT `f`, and both the
# GLOB_DAT and the JUMP_SLOT pointed at the OBJECT slot. Now `f` appears
# exactly once, as UND FUNC, and both relocations reference that one entry.
b = load('tmp-dyn-dupimp.so'); sec = sections(b); dyn = dynamic(b, sec)
syms = dynsyms(b, sec)
assert all(syms[i][0] for i in range(1, len(syms))), syms
assert [n for n, info, sh, v, s in syms].count('f') == 1, syms
fidx = [i for i, (n, info, sh, v, s) in enumerate(syms) if n == 'f'][0]
assert syms[fidx][1] == 0x12 and syms[fidx][2] == 0, syms[fidx]
glob = [r for r in relocs(b, sec, '.rela.dyn') if r[2] == 1025]
jump = [r for r in relocs(b, sec, '.rela.plt') if r[2] == 1026]
assert [r[1] for r in glob] == [fidx] and [r[1] for r in jump] == [fidx], (glob, jump)
assert hash_lookup(b, sec, 'f'), 'DT_HASH lookup failed for f'
print('PASS: a name imported as both function and object gets one UND FUNC .dynsym entry serving both JUMP_SLOT and GLOB_DAT')

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
