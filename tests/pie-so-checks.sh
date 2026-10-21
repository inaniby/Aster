#!/bin/sh
# Verify the v0.17.0 static-PIE (ET_DYN executable) and shared-object (ET_DYN .so) outputs, plus
# the diagnostics of the new modes. Nothing here executes a generated image; see e2e-pie-so.sh
# and run-on-device.sh for the end-to-end assertions.
set -eu
[ -x ./aster ] || { echo "build ./aster first" >&2; exit 2; }

./aster build-pie examples/pie_global_rw.ast -o tmp-pie-global
./aster build-pie examples/hello.ast -o tmp-pie-hello
./aster build-so examples/so_math.ast -o tmp-so-math.so

python3 - <<'PY'
import struct

def elf_hash(name):
    h = 0
    for c in name:
        h = ((h << 4) + c) & 0xffffffff
        g = h & 0xf0000000
        if g:
            h ^= g >> 24
        h &= ~g
    return h

def read_sections(b):
    shoff = struct.unpack_from('<Q', b, 40)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
    assert shentsize == 64, shentsize
    raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*shentsize) for i in range(shnum)]
    names = b[raw[shstrndx][4]:raw[shstrndx][4]+raw[shstrndx][5]]
    out = {}
    for i, s in enumerate(raw):
        out[names[s[0]:names.index(b'\0', s[0])].decode()] = (i, s)
    return out
# Shdr tuple: 0 name, 1 type, 2 flags, 3 addr, 4 offset, 5 size, 6 link, 7 info, 8 addralign, 9 entsize

# ---------------------------------------------------------------- static PIE
for path, has_data in (('tmp-pie-global', True), ('tmp-pie-hello', False)):
    b = open(path, 'rb').read()
    assert b[:6] == b'\x7fELF\x02\x01', path
    etype, machine = struct.unpack_from('<HH', b, 16)
    assert (etype, machine) == (3, 183), (path, etype, machine)   # ET_DYN, EM_AARCH64
    entry, phoff, shoff = struct.unpack_from('<QQQ', b, 24)
    phentsize, phnum = struct.unpack_from('<HH', b, 54)
    shentsize = struct.unpack_from('<H', b, 58)[0]
    shnum = struct.unpack_from('<H', b, 60)[0]
    assert phentsize == 56, path
    assert entry == 0x1000, (path, hex(entry))       # e_entry is an offset; text is at file offset 0x1000
    # v0.17.0 appends a source-level .symtab/.strtab and the section header table that carries them,
    # so the image is no longer headerless. The v0.15.0 property that mattered -- no relocation
    # record anywhere -- is now asserted directly on the section table: only the image's own
    # sections plus the symbol table may exist, and no .rela*/.debug* section is among them.
    assert shoff != 0 and shnum > 0 and shentsize == 64, (path, shoff, shnum, shentsize)
    pie_secs = read_sections(b)
    expected_pie_secs = {'', '.text', '.symtab', '.strtab', '.shstrtab'}
    if has_data:
        expected_pie_secs |= {'.data', '.bss'}
    assert set(pie_secs) == expected_pie_secs, sorted(pie_secs)
    assert not any(n.startswith('.rela') or n.startswith('.debug') for n in pie_secs), sorted(pie_secs)
    loads = []
    for i in range(phnum):
        p = struct.unpack_from('<IIQQQQQQ', b, phoff + i*phentsize)
        assert p[0] == 1, (path, 'only PT_LOAD segments expected, got type', p[0])  # no PT_INTERP/PT_DYNAMIC
        assert p[7] == 0x1000 and p[2] % 0x1000 == 0, (path, hex(p[7]))
        assert p[3] == p[2], (path, 'p_vaddr must equal p_offset for a base-0 image', hex(p[2]), hex(p[3]))
        loads.append(p)
    assert len(loads) == (2 if has_data else 1), (path, len(loads))
    assert loads[0][1] == 5, path                    # R+X text segment
    if has_data:
        assert loads[1][1] == 6, path                # R+W data segment
        assert loads[1][5] == 4 and loads[1][6] == 8, (path, loads[1][5], loads[1][6])  # .data 4 bytes + .bss 4
    # Every ADRP in .text must be page-relative into the loaded image. An absolute text address
    # would instead show up as a relocation record or a MOVZ/MOVK pair; there are none.
    # Scan exactly the .text section (v0.17.0 used p_filesz as a stand-in for it; with a real
    # section table the range is exact, which keeps the appended symbol table out of the scan).
    text_i, textsec = pie_secs['.text']
    assert textsec[3] == 0x1000 and textsec[4] == 0x1000 and textsec[5] == loads[0][5] - 0x1000, (path, textsec, loads[0][5])
    textbytes = b[textsec[4]:textsec[4] + textsec[5]]
    adrp_targets = set()
    for off in range(0, len(textbytes), 4):
        w = struct.unpack_from('<I', textbytes, off)[0]
        if (w & 0x9f000000) == 0x90000000:
            imm = (((w >> 5) & 0x7ffff) << 2) | ((w >> 29) & 3)
            if imm & (1 << 20):
                imm -= (1 << 21)
            adrp_targets.add(((0x1000 + off) & ~0xfff) + (imm << 12))
    if has_data:
        assert adrp_targets == {loads[1][2] & ~0xfff}, (path, sorted(hex(t) for t in adrp_targets))
    else:
        assert not adrp_targets, path
    print(f'PASS: {path}: ELF64 AArch64 ET_DYN static PIE, entry=0x{entry:x}, {len(loads)} PT_LOAD, '
          f'no PT_INTERP, no PT_DYNAMIC, no relocation sections')

# ---------------------------------------------------------------- shared object
b = open('tmp-so-math.so', 'rb').read()
assert b[:6] == b'\x7fELF\x02\x01', 'so'
etype, machine = struct.unpack_from('<HH', b, 16)
assert (etype, machine) == (3, 183), (etype, machine)
entry, phoff, shoff = struct.unpack_from('<QQQ', b, 24)
ehsize, phentsize, phnum, shentsize, shnum, shstrndx = struct.unpack_from('<HHHHHH', b, 52)
assert ehsize == 64 and shentsize == 64, (ehsize, shentsize)
assert entry == 0, ('shared objects have no entry point', hex(entry))
ph = [struct.unpack_from('<IIQQQQQQ', b, phoff + i*phentsize) for i in range(phnum)]
assert [p[0] for p in ph] == [1, 1, 2, 0x6474e552], ('segment types', [p[0] for p in ph])  # 2 PT_LOAD + PT_DYNAMIC + PT_GNU_RELRO
relro = ph[3]
assert relro[3] % 0x1000 == 0 and relro[6] > 0 and relro[6] % 0x1000 == 0, ('RELRO page bounds', relro)
assert relro[2] == relro[3], ('RELRO file/vaddr mismatch', relro)
sec = read_sections(b)
for name in ('.text', '.dynsym', '.dynstr', '.hash', '.rela.dyn', '.data', '.got', '.dynamic', '.bss', '.shstrtab'):
    assert name in sec, (name, sorted(sec))
text_i, text = sec['.text']
dynsym_i, symsec = sec['.dynsym']
dynstr_i, strsec = sec['.dynstr']
hash_i, hashsec = sec['.hash']
rela_i, relasec = sec['.rela.dyn']
data_i, datasec = sec['.data']
got_i, gotsec = sec['.got']
bss_i, bsssec = sec['.bss']
dyn_i, dynsec = sec['.dynamic']
assert (symsec[1], symsec[6], symsec[7], symsec[9]) == (11, dynstr_i, 1, 24), ('dynsym header', symsec[1::])
assert (strsec[1], strsec[2]) == (3, 0x2), ('dynstr header', strsec[1], strsec[2])
assert (hashsec[1], hashsec[6]) == (5, dynsym_i), ('hash header', hashsec[1], hashsec[6])
assert (relasec[1], relasec[6], relasec[7], relasec[9]) == (4, dynsym_i, 0, 24), ('rela header', relasec[1::])
assert (dynsec[1], dynsec[6], dynsec[9]) == (6, dynstr_i, 16), ('dynamic header', dynsec[1], dynsec[6], dynsec[9])
assert (datasec[1], datasec[2]) == (1, 0x3) and (gotsec[1], gotsec[2]) == (1, 0x3), 'data/.got flags'
assert (bsssec[1], bsssec[2], bsssec[5]) == (8, 0x3, 4), ('bss header', bsssec[1], bsssec[2], bsssec[5])
assert datasec[3] + datasec[5] <= relro[3], ('ordinary .data must remain outside RELRO', datasec, relro)
assert relro[3] <= gotsec[3] and gotsec[3] + gotsec[5] <= relro[3] + relro[6], ('GOT must be inside RELRO', gotsec, relro)
assert relro[3] <= dynsec[3] and dynsec[3] + dynsec[5] <= relro[3] + relro[6], ('dynamic section must be inside RELRO', dynsec, relro)

tags = {}
for off in range(0, dynsec[5], 16):
    tag, val = struct.unpack_from('<qQ', b, dynsec[4] + off)
    if tag == 0:
        break
    tags[tag] = val
for tag, name in ((4, 'DT_HASH'), (5, 'DT_STRTAB'), (6, 'DT_SYMTAB'), (10, 'DT_STRSZ'), (11, 'DT_SYMENT'),
                  (7, 'DT_RELA'), (8, 'DT_RELASZ'), (9, 'DT_RELAENT'), (1879048185, 'DT_RELACOUNT')):
    assert tag in tags, name
assert (tags[4], tags[5], tags[6]) == (hashsec[4], strsec[4], symsec[4]), tags
assert (tags[10], tags[11]) == (strsec[5], 24), tags
assert (tags[7], tags[8], tags[9]) == (relasec[4], relasec[5], 24), tags

strtab = b[strsec[4]:strsec[4]+strsec[5]]
syms = [struct.unpack_from('<IBBHQQ', b, symsec[4] + i*24) for i in range(symsec[5]//24)]
def symname(s):
    return strtab[s[0]:strtab.index(b'\0', s[0])].decode()
names = {symname(s): s for s in syms if s[0]}
for want in ('add', 'mul', 'accumulate', 'current', 'untouched_value'):
    assert want in names, (want, sorted(names))
    s = names[want]
    assert (s[1] >> 4, s[1] & 0xf, s[3]) == (1, 2, text_i), (want, hex(s[1]), s[3])   # GLOBAL FUNC in .text
    assert text[3] <= s[4] < text[3] + text[5] and s[5] > 0, (want, hex(s[4]), s[5])

# DT_HASH must resolve every exported name through the SysV hash function.
words = struct.unpack_from('<%dI' % (hashsec[5]//4), b, hashsec[4])
nbucket, nchain = words[0], words[1]
buckets, chains = words[2:2+nbucket], words[2+nbucket:2+nbucket+nchain]
assert nchain == len(syms), (nchain, len(syms))
for name in names:
    idx = buckets[elf_hash(name.encode()) % nbucket]
    while idx != 0 and symname(syms[idx]) != name:
        idx = chains[idx]
    assert idx != 0, ('DT_HASH lookup failed for', name)

# .rela.dyn: one R_AARCH64_RELATIVE per defined global, targeting a .got slot, with the slot
# already holding the same link-time address as the addend.
assert relasec[5] == 48, ('expected two relative relocations', relasec[5])
relocs = [struct.unpack_from('<QQq', b, relasec[4] + i*24) for i in range(relasec[5]//24)]
slots = {}
for r_off, r_info, r_addend in relocs:
    assert (r_info >> 32) == 0 and (r_info & 0xffffffff) == 1027, (hex(r_info), 'expected R_AARCH64_RELATIVE')
    assert gotsec[3] <= r_off < gotsec[3] + gotsec[5], (hex(r_off), 'relocation must target .got')
    assert struct.unpack_from('<Q', b, r_off)[0] == r_addend, (hex(r_off), 'slot content must equal the addend')
    slots[r_off] = r_addend
assert sorted(slots.values()) == [datasec[3], bsssec[3]], [hex(v) for v in slots.values()]
print(f'PASS: tmp-so-math.so: ELF64 AArch64 ET_DYN shared object, {len(names)} exported functions, '
      f'{len(relocs)} R_AARCH64_RELATIVE relocations into .got, DT_HASH resolves every export')
PY

# ---------------------------------------------------------------- new-mode diagnostics
check_error() {
  cmd=$1; source=$2; expected=$3; out=$4
  output=$(./aster "$cmd" "$source" -o "$out" 2>&1 && { echo "expected compiler failure for $source"; exit 1; } || true)
  printf '%s\n' "$output" | grep -F "$expected" >/dev/null || { echo "wrong diagnostic for $source: $output"; exit 1; }
  echo "PASS: $cmd diagnostic: $source"
}
# v0.18.0 semantic change: a shared object may now reach a symbol it does not define. The same
# three sources v0.17.0 rejected with "shared object mode cannot ..." must now compile and carry
# real import metadata -- an external function through a .plt stub with an R_AARCH64_JUMP_SLOT
# relocation, an external global through a .got slot with an R_AARCH64_GLOB_DAT relocation. The
# number of assertions below is unchanged (3); only what they assert changed, because keeping the
# old diagnostics would mean v0.18.0 could not support cross-.so imports at all.
cat > tmp-so-extern-call.ast <<'AST'
extern fn helper(x: i32) -> i32;
fn exported(x: i32) -> i32 { return helper(x); }
AST
cat > tmp-so-extern-read.ast <<'AST'
extern let shared: i32;
fn exported() -> i32 { return shared; }
AST
cat > tmp-so-extern-write.ast <<'AST'
extern let shared: i32;
fn exported() -> i32 { shared = 1; return shared; }
AST
./aster build-so tmp-so-extern-call.ast  -o tmp-x-import-call.so >/dev/null
./aster build-so tmp-so-extern-read.ast  -o tmp-x-import-read.so >/dev/null
./aster build-so tmp-so-extern-write.ast -o tmp-x-import-write.so >/dev/null
python3 - <<'PYX'
import struct

def sections(path):
    b = open(path, 'rb').read()
    shoff = struct.unpack_from('<Q', b, 40)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
    raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*shentsize) for i in range(shnum)]
    names = b[raw[shstrndx][4]:raw[shstrndx][4]+raw[shstrndx][5]]
    out = {}
    for s in raw:
        out[names[s[0]:names.index(b'\0', s[0])].decode()] = s
    return b, out

def imports(path):
    b, sec = sections(path)
    sym, st = sec['.dynsym'], sec['.dynstr']
    strs = b[st[4]:st[4]+st[5]]
    undef = {}
    for i in range(1, sym[5]//24):
        nm = struct.unpack_from('<I', b, sym[4]+i*24)[0]
        shndx = struct.unpack_from('<H', b, sym[4]+i*24+6)[0]
        if shndx == 0:
            undef[i] = strs[nm:].split(b'\0')[0].decode()
    def relocs(name):
        if name not in sec:
            return []
        r = sec[name]
        out = []
        for i in range(r[5]//24):
            off = struct.unpack_from('<Q', b, r[4]+i*24)[0]
            info = struct.unpack_from('<Q', b, r[4]+i*24+8)[0]
            out.append((off, info >> 32, info & 0xffffffff))
        return out
    return undef, relocs('.rela.plt'), relocs('.rela.dyn'), sec

def check(path, kind, name):
    undef, plt, dyn, sec = imports(path)
    hit = [i for i, n in undef.items() if n == name]
    assert hit, (path, 'no undefined dynamic symbol', name)
    i = hit[0]
    if kind == 'fn':
        assert [r for r in plt if r[1] == i and r[2] == 1026], (path, 'missing R_AARCH64_JUMP_SLOT for', name)
        assert '.plt' in sec, (path, 'missing .plt')
        print('PASS: %s imports function %s through .plt (R_AARCH64_JUMP_SLOT)' % (path, name))
    else:
        assert [r for r in dyn if r[1] == i and r[2] == 1025], (path, 'missing R_AARCH64_GLOB_DAT for', name)
        print('PASS: %s imports object %s through .got (R_AARCH64_GLOB_DAT)' % (path, name))

check('tmp-x-import-call.so', 'fn', 'helper')
check('tmp-x-import-read.so', 'obj', 'shared')
check('tmp-x-import-write.so', 'obj', 'shared')
PYX
cat > tmp-so-no-functions.ast <<'AST'
let lonely: i32 = 1;
AST
check_error build-so tmp-so-no-functions.ast 'shared object must define at least one function' tmp-x.so
cat > tmp-pie-unresolved.ast <<'AST'
extern fn helper(x: i32) -> i32;
fn main() -> i32 { return helper(1); }
AST
check_error build-pie tmp-pie-unresolved.ast "undefined function symbol 'helper'" tmp-x
cat > tmp-main-args.ast <<'AST'
fn main(a: i32) -> i32 { return a; }
AST
check_error build-pie tmp-main-args.ast 'main must not have parameters' tmp-x
check_error build-elf tmp-main-args.ast 'main must not have parameters' tmp-x
./aster build-obj examples/pie_modular_helper.ast -o tmp-pie-helper.o
check_error link-pie tmp-pie-helper.o 'no input object defines global _start' tmp-x

# A shared object has no entry point, so main is an ordinary exported function and may take parameters.
./aster build-so tmp-main-args.ast -o tmp-so-main-args.so
python3 - <<'PY'
import struct
b = open('tmp-so-main-args.so', 'rb').read()
assert struct.unpack_from('<H', b, 16)[0] == 3
shoff = struct.unpack_from('<Q', b, 40)[0]
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*shentsize) for i in range(shnum)]
names = b[raw[shstrndx][4]:raw[shstrndx][4]+raw[shstrndx][5]]
def section(n):
    for s in raw:
        if names[s[0]:names.index(b'\0', s[0])].decode() == n:
            return s
dynsym, dynstr = section('.dynsym'), section('.dynstr')
st = b[dynstr[4]:dynstr[4]+dynstr[5]]
exported = [st[struct.unpack_from('<I', b, dynsym[4]+i*24)[0]:].split(b'\0')[0].decode()
            for i in range(1, dynsym[5]//24)]
assert exported == ['main'], exported
print('PASS: shared-object mode exports main as an ordinary function (no entry-point restriction)')
PY
rm -f tmp-pie-global tmp-pie-hello tmp-so-math.so tmp-so-extern-call.ast tmp-so-extern-read.ast \
      tmp-so-extern-write.ast tmp-so-no-functions.ast tmp-pie-unresolved.ast tmp-main-args.ast \
      tmp-so-main-args.so tmp-pie-helper.o tmp-x tmp-x.so \
      tmp-x-import-call.so tmp-x-import-read.so tmp-x-import-write.so
echo "PASS: all v0.17.0 static-PIE and shared-object checks"
