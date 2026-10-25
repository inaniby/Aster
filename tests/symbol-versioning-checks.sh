#!/bin/sh
# v0.23.51-dev structural + behavioral checks for ELF symbol versioning.
#
# Both shared-object writers now carry the GNU symbol-versioning triad:
#   * .gnu.version      (SHT_GNU_VERSYM) — one 16-bit index per .dynsym entry;
#   * .gnu.version_d    (SHT_GNU_VERDEF) — two VERDEFs: the BASE version
#                        (VER_FLG_BASE, hash 0) at index 1, and this object's
#                        default version, named "aster", at index 2;
#   * .gnu.version_r    (SHT_GNU_VERNEED) — one VERNEED for libc.so.6 at
#                        GLIBC_2.17 (index 3), the declared build baseline.
# Five .dynamic tags point at them: DT_VERDEF / DT_VERDEFNUM / DT_VERNEED /
# DT_VERNEEDNUM / DT_VERSYM. The static writers (writeElfBytes) are untouched:
# a static ET_EXEC / ET_REL / PIE has no .dynamic and therefore no versions.
#
# The index map is the part this round got wrong twice, so it is spelled out
# once here. glibc builds l_versions from the VERDEFs and VERNEEDs
# (elf/dl-version.c, _dl_check_map_versions) and then, for every relocation,
# reads the referencing symbol's versym index (elf/dl-runtime.c, _dl_fixup):
#     version = &l->l_versions[ndx];
#     if (version->hash == 0) version = NULL;   /* unversioned reference */
# _dl_check_map_versions *skips* VER_FLG_BASE verdefs when filling l_versions,
# so index 1 (BASE, hash 0) always means "no version". Hence:
#   * a defined symbol carries index 2 — it is versioned "aster";
#   * an undefined import carries index 1 — unversioned, so it binds the
#     defining object's *default* version: libc's default for a C symbol,
#     "aster" for a symbol another Aster .so exports. Pinning imports to the
#     libc VERNEED (index 3) is wrong here because the writer cannot tell a
#     libc import from a cross-.so one (`extern let counter` is satisfied by
#     libdyn.so, not by libc); a versioned reference that misses is fatal at
#     load ("undefined symbol: counter, version GLIBC_2.17"). The first cut of
#     this round pinned imports at index 2 and shipped, and the BASE form
#     below is what makes that map sound. The shape is exactly ld's own
#     (checked against gcc): BASE@1 + named@2 + verneed aux@3.
#
# The two writers differ in their imports, and so in which symbols exist:
#   * writeSharedObject   (SysV hash, no imports)   — every defined symbol is
#     index 2; no symbol ever takes index 1 or 3;
#   * writeSharedObjectDyn (GNU hash, with imports) — defined symbols are 2,
#     every undefined import (function or object) is 1.
#
# The round's own defect is pinned too: writeSharedObject's kDynEntries once
# counted ten tags, so the four new ones (and DT_VERSYM) were silently dropped
# from the written .dynamic. The count is now 15 and the python readers below
# would have caught the truncation.
#
# Layers (the project 9-layer shape): strict build, source guards, the SysV
# structure, the GNU structure, an independent readelf cross-check, dlopen
# witnesses through the real loader, static-image non-regression, the version
# hashes recomputed independently, and a mutation that proves the suite fails.
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-symbol-versioning-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
RUNNER=${RUNNER:-tests/run-aarch64.sh}
HOSTCC=${HOSTCC:-cc}
fail(){ echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. strict build
printf '%s\n' '[1/9] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
A="$OUT/aster"

# ---------------------------------------------------------------- 2. source guards
printf '%s\n' '[2/9] Source guards: the version triad, its five dynamic tags, the index map'
# The three sections must exist in *both* writers — the pins below name each
# writer's own spelling where they differ, and count the shared ones twice.
for lit in \
    'dyn.push_back({0x6ffffffc,(uint64_t)verDefOff});' \
    'dyn.push_back({0x6ffffffd,2});' \
    'dyn.push_back({0x6ffffffe,(uint64_t)verNeedOff});' \
    'dyn.push_back({0x6fffffff,1});' \
    'dyn.push_back({0x6ffffff0,(uint64_t)gnuVersionOff});' \
    'const uint64_t verDefSize=56;' \
    'const uint64_t verNeedSize=32;' \
    'pv16(verDef,2,1);' \
    'pv16(verDef,4,1);' \
    'pv32(verDef,8,0);' \
    'pv32(verDef,16,28);' \
    'pv16(verDef,32,2);' \
    'pv32(verDef,36,elfHash("aster"));' \
    'pv16(verNeed,22,3);' \
    'pv32(verNeed,16,elfHash("GLIBC_2.17"));'
do
    [ "$(grep -cF "$lit" src/aster.cpp)" = 2 ] \
        || fail "the version literal is not present in both writers (or moved): $lit"
done
# The SysV writer: its own section-table row, its own index loop, its own string
# pool helpers — and the kDynEntries count that must cover all fifteen tags.
grep -qF 'const uint32_t verBaseStr=addVerStr(baseName);' src/aster.cpp \
    || fail "the SysV writer no longer puts the BASE version name in .dynstr"
grep -qF 'const uint32_t verAsterStr=addVerStr("aster");' src/aster.cpp \
    || fail "the SysV writer no longer puts the version name in .dynstr"
grep -qF 'for(size_t i=1;i<dynsym.size();++i)gnuVersion[i*2]=2;' src/aster.cpp \
    || fail "the SysV writer no longer marks every defined symbol with index 2"
grep -qF 'setSh(kVerBase,nGnuVersion,0x6fffffff,0x2,gnuVersionOff,gnuVersionOff,gnuVersionSize,S_DYNSYM,0,2,2);' src/aster.cpp \
    || fail "the SysV writer no longer describes .gnu.version as SHT_GNU_VERSYM linked to .dynsym"
grep -qF 'setSh(kVerBase+1,nGnuVersionD,0x6ffffffd,0x2,verDefOff,verDefOff,verDefSize,S_DYNSTR,2,8,0);' src/aster.cpp \
    || fail "the SysV writer no longer describes .gnu.version_d with sh_info = two verdefs"
grep -qF 'const uint32_t kDynEntries=15u+(hasInit?2u:0u);' src/aster.cpp \
    || fail "kDynEntries lost the five version tags (the .dynamic truncation bug is back)"
# The GNU writer: its own section row, its own import mapping, its sized table.
grep -qF 'const uint32_t verBaseStr=addDynStr(baseName);' src/aster.cpp \
    || fail "the GNU writer no longer puts the BASE version name in .dynstr"
grep -qF 'const uint32_t verAsterStr=addDynStr("aster");' src/aster.cpp \
    || fail "the GNU writer no longer puts the version name in .dynstr"
grep -qF 'const uint64_t gnuVersionSize=nsym*2;' src/aster.cpp \
    || fail "the GNU writer no longer sizes .gnu.version at two bytes per dynamic symbol"
grep -qF 'gnuVersion[(gnuSymOffset+(uint32_t)j)*2]=2;' src/aster.cpp \
    || fail "the GNU writer no longer marks its defined symbols with index 2"
grep -qF 'gnuVersion[dynIndex.at(spec.importFuncs[i])*2]=1;' src/aster.cpp \
    || fail "the GNU writer no longer marks an imported function with index 1 (the BASE form)"
grep -qF 'gnuVersion[dynIndex.at(spec.importObjects[i])*2]=1;' src/aster.cpp \
    || fail "the GNU writer no longer marks an imported object with index 1 (the BASE form)"
grep -qF 'setSh(S_GNUVERSION,0x6fffffff,0x2,gnuVersionOff,gnuVersionOff,gnuVersionSize,S_DYNSYM,0,2,2);' src/aster.cpp \
    || fail "the GNU writer no longer describes .gnu.version as SHT_GNU_VERSYM linked to .dynsym"
grep -qF 'setSh(S_GNUVERSIOND,0x6ffffffd,0x2,verDefOff,verDefOff,verDefSize,S_DYNSTR,2,8,0);' src/aster.cpp \
    || fail "the GNU writer no longer describes .gnu.version_d with sh_info = two verdefs"
printf '  %-40s %s\n' 'both writers: triad, five DT tags, index maps' 'pinned'

# ---------------------------------------------------------------- 3. SysV structure
printf '%s\n' '[3/9] SysV writer: the triad, its tags, and the verdef/verneed bytes'
# writeSharedObject is the no-imports path (build-so with no soname/needed/
# imports), so its .gnu.version carries index 0 (the null symbol) and index 2
# (every defined symbol) — no symbol can take index 1 (BASE) or 3 (VERNEED).
"$A" build-so examples/so_math.ast -o "$OUT/math.so" >/dev/null
python3 - "$OUT/math.so" <<'PY' || exit 1
import struct, sys
b = open(sys.argv[1], 'rb').read()
assert b[:6] == b'\x7fELF\x02\x01'
shoff = struct.unpack_from('<Q', b, 40)[0]
ents, num, si = struct.unpack_from('<HHH', b, 58)
raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*ents) for i in range(num)]
names = b[raw[si][4]:raw[si][4]+raw[si][5]]
def nm(s): return names[s[0]:names.index(b'\0', s[0])].decode()
sec = {nm(s): s for s in raw}
idx_of = {nm(s): i for i, s in enumerate(raw)}
dynsym, dynstr = sec['.dynsym'], sec['.dynstr']
strs = b[dynstr[4]:dynstr[4]+dynstr[5]]
def cstr(off): return strs[off:strs.index(b'\0', off)].decode()
def elf_hash(s):
    h = 0
    for c in s.encode():
        h = ((h << 4) + c) & 0xffffffff
        g = h & 0xf0000000
        if g: h ^= g >> 24
        h &= ~g & 0xffffffff
    return h
# --- the three sections, by SysV type constants
SHT_GNU_VERSYM, SHT_GNU_VERDEF, SHT_GNU_VERNEED = 0x6fffffff, 0x6ffffffd, 0x6ffffffe
versym = sec['.gnu.version']; verdef = sec['.gnu.version_d']; verneed = sec['.gnu.version_r']
assert versym[1] == SHT_GNU_VERSYM, '.gnu.version must be SHT_GNU_VERSYM'
assert versym[6] == idx_of['.dynsym'], '.gnu.version must link to .dynsym'
assert versym[9] == 2, '.gnu.version entsize must be 2'
assert verdef[1] == SHT_GNU_VERDEF and verdef[6] == idx_of['.dynstr'], '.gnu.version_d must be SHT_GNU_VERDEF linked to .dynstr'
assert verneed[1] == SHT_GNU_VERNEED and verneed[6] == idx_of['.dynstr'], '.gnu.version_r must be SHT_GNU_VERNEED linked to .dynstr'
assert verdef[7] == 2 and verneed[7] == 1, 'sh_info must count two verdefs and one verneed entry'
# --- the five dynamic tags, each pointing at its section
d = sec['.dynamic']; dyn = {}
for i in range(d[5] // 16):
    tag, val = struct.unpack_from('<qQ', b, d[4] + i*16)
    if tag: dyn.setdefault(tag, []).append(val)
for tag in (0x6ffffffc, 0x6ffffffd, 0x6ffffffe, 0x6fffffff, 0x6ffffff0):
    assert tag in dyn, ('a version tag is missing from .dynamic', hex(tag))
assert dyn[0x6ffffffc][0] == verdef[3], 'DT_VERDEF must point at .gnu.version_d'
assert dyn[0x6ffffffe][0] == verneed[3], 'DT_VERNEED must point at .gnu.version_r'
assert dyn[0x6ffffff0][0] == versym[3], 'DT_VERSYM must point at .gnu.version'
assert dyn[0x6ffffffd] == [2] and dyn[0x6fffffff] == [1], 'VERDEFNUM must be 2 (BASE + aster), VERNEEDNUM 1'
assert dyn[0x6ffffffd][0] == verdef[7] and dyn[0x6fffffff][0] == verneed[7], 'the NUM tags must match sh_info'
# --- the VERDEF bytes: BASE first (VER_FLG_BASE, hash 0, name = the output
# file's basename, as ld does without -soname), then "aster" at index 2.
vd = b[verdef[4]:verdef[4]+verdef[5]]
ver, flags, ndx, cnt = struct.unpack_from('<HHHH', vd, 0)
vhash, vaux, vnext = struct.unpack_from('<III', vd, 8)
assert (ver, flags, ndx, cnt) == (1, 1, 1, 1), ('the BASE verdef must set VER_FLG_BASE', (ver, flags, ndx, cnt))
assert vhash == 0, ('the BASE verdef must hash to 0 — that is what makes versym 1 unversioned', hex(vhash))
assert vaux == 20 and vnext == 28, (vaux, vnext)
vda_name, vda_next = struct.unpack_from('<II', vd, 20)
base_name = cstr(vda_name)
assert base_name == 'math.so', ('the BASE name must be the output file basename', base_name)
assert vda_next == 0
ver, flags, ndx, cnt = struct.unpack_from('<HHHH', vd, 28)
vhash, vaux, vnext = struct.unpack_from('<III', vd, 36)
assert (ver, flags, ndx, cnt) == (1, 0, 2, 1), (ver, flags, ndx, cnt)
assert vhash == elf_hash('aster'), ('vd_hash is not the SysV hash of "aster"', hex(vhash))
assert vaux == 20 and vnext == 0, (vaux, vnext)
vda_name, vda_next = struct.unpack_from('<II', vd, 48)
assert cstr(vda_name) == 'aster' and vda_next == 0
# --- the VERNEED bytes: libc.so.6 needs GLIBC_2.17 at index 3
vn = b[verneed[4]:verneed[4]+verneed[5]]
vver, vcnt = struct.unpack_from('<HH', vn, 0)
vfile, vaux2, vnext2 = struct.unpack_from('<III', vn, 4)
assert (vver, vcnt) == (1, 1), (vver, vcnt)
assert cstr(vfile) == 'libc.so.6', cstr(vfile)
assert vaux2 == 16 and vnext2 == 0, (vaux2, vnext2)
vna_hash, vna_flags, vna_other, vna_name, vna_next = struct.unpack_from('<IHHII', vn, 16)
assert vna_hash == elf_hash('GLIBC_2.17'), ('vna_hash is not the SysV hash of "GLIBC_2.17"', hex(vna_hash))
assert vna_flags == 0 and vna_other == 3 and vna_next == 0
assert cstr(vna_name) == 'GLIBC_2.17', cstr(vna_name)
# --- .gnu.version: one 16-bit index per dynsym; 0 for the null symbol, 2 for
# every defined symbol, and — this writer has no imports — no 1 or 3 anywhere.
nsym = dynsym[5] // 24
idx = struct.unpack_from('<%dH' % nsym, b, versym[4])
assert idx[0] == 0, ('the null symbol must be VER_NDX_LOCAL', idx[0])
for i in range(1, nsym):
    shndx = struct.unpack_from('<H', b, dynsym[4] + i*24 + 6)[0]
    assert shndx != 0, ('every non-null dynsym in this import-free .so must be defined', i)
    assert idx[i] == 2, ('a defined symbol must carry the default index 2', i, idx[i])
assert 1 not in idx and 3 not in idx, ('the SysV writer has no imports; BASE/VERNEED indices must not appear', idx)
print('PASS: SysV triad, five DT tags, verdef BASE@1 + aster@2, verneed libc.so.6/GLIBC_2.17@3')
print('PASS: .gnu.version maps all %d defined symbols to index 2' % (nsym - 1))
PY

# ---------------------------------------------------------------- 4. GNU structure
printf '%s\n' '[4/9] GNU writer: the same triad, imports at index 1, GNU hash intact'
# --needed forces writeSharedObjectDyn (the dynamic path) and so_link_import.ast
# brings three imports (add, mul, counter): functions and an object.
"$A" build-so examples/so_link_import.ast -o "$OUT/import.so" --needed libdyn.so >/dev/null
python3 - "$OUT/import.so" <<'PY' || exit 1
import struct, sys
b = open(sys.argv[1], 'rb').read()
assert b[:6] == b'\x7fELF\x02\x01'
shoff = struct.unpack_from('<Q', b, 40)[0]
ents, num, si = struct.unpack_from('<HHH', b, 58)
raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*ents) for i in range(num)]
names = b[raw[si][4]:raw[si][4]+raw[si][5]]
def nm(s): return names[s[0]:names.index(b'\0', s[0])].decode()
sec = {nm(s): s for s in raw}
idx_of = {nm(s): i for i, s in enumerate(raw)}
dynsym, dynstr = sec['.dynsym'], sec['.dynstr']
strs = b[dynstr[4]:dynstr[4]+dynstr[5]]
def cstr(off): return strs[off:strs.index(b'\0', off)].decode()
def elf_hash(s):
    h = 0
    for c in s.encode():
        h = ((h << 4) + c) & 0xffffffff
        g = h & 0xf0000000
        if g: h ^= g >> 24
        h &= ~g & 0xffffffff
    return h
SHT_GNU_VERSYM, SHT_GNU_VERDEF, SHT_GNU_VERNEED = 0x6fffffff, 0x6ffffffd, 0x6ffffffe
versym, verdef, verneed = sec['.gnu.version'], sec['.gnu.version_d'], sec['.gnu.version_r']
assert versym[1] == SHT_GNU_VERSYM and versym[6] == idx_of['.dynsym'] and versym[9] == 2
assert verdef[1] == SHT_GNU_VERDEF and verdef[6] == idx_of['.dynstr'] and verdef[7] == 2
assert verneed[1] == SHT_GNU_VERNEED and verneed[6] == idx_of['.dynstr'] and verneed[7] == 1
d = sec['.dynamic']; dyn = {}
for i in range(d[5] // 16):
    tag, val = struct.unpack_from('<qQ', b, d[4] + i*16)
    if tag: dyn.setdefault(tag, []).append(val)
assert 0x6ffffef5 in dyn, 'DT_GNU_HASH must survive the version sections'
assert dyn[0x6ffffffc][0] == verdef[3] and dyn[0x6ffffffe][0] == verneed[3]
assert dyn[0x6ffffff0][0] == versym[3], 'DT_VERSYM must point at .gnu.version'
assert dyn[0x6ffffffd] == [2] and dyn[0x6fffffff] == [1]
# verdef bytes: BASE@1 then "aster"@2, as in the SysV layer. This path does
# carry a soname, so the BASE name is the soname, not the path basename.
vd = b[verdef[4]:verdef[4]+verdef[5]]
assert struct.unpack_from('<HHHH', vd, 0) == (1, 1, 1, 1), 'the BASE verdef must set VER_FLG_BASE'
assert struct.unpack_from('<I', vd, 8)[0] == 0, 'the BASE verdef must hash to 0'
assert struct.unpack_from('<I', vd, 16)[0] == 28, 'the BASE verdef must chain to the aster verdef'
assert struct.unpack_from('<HHHH', vd, 28) == (1, 0, 2, 1)
assert struct.unpack_from('<I', vd, 36)[0] == elf_hash('aster')
assert cstr(struct.unpack_from('<I', vd, 48)[0]) == 'aster'
base_name = cstr(struct.unpack_from('<I', vd, 20)[0])
assert base_name == 'import.so', ('the BASE name must be the soname', base_name)
soname = None
for i in range(d[5] // 16):
    tag, val = struct.unpack_from('<qQ', b, d[4] + i*16)
    if tag == 14: soname = cstr(val)
assert soname == base_name, ('the BASE name must equal DT_SONAME', soname, base_name)
vn = b[verneed[4]:verneed[4]+verneed[5]]
assert struct.unpack_from('<HH', vn, 0) == (1, 1)
assert cstr(struct.unpack_from('<I', vn, 4)[0]) == 'libc.so.6'
assert struct.unpack_from('<I', vn, 16)[0] == elf_hash('GLIBC_2.17')
assert struct.unpack_from('<H', vn, 22)[0] == 3, 'the VERNEED aux must take index 3'
assert cstr(struct.unpack_from('<I', vn, 24)[0]) == 'GLIBC_2.17'
# The index map: null 0, defined 2, every undefined import (function or
# object) 1 — the BASE form, so an import is an unversioned reference and
# binds the defining object's default version (libc's, or another Aster
# .so's "aster").
nsym = dynsym[5] // 24
idx = struct.unpack_from('<%dH' % nsym, b, versym[4])
assert idx[0] == 0
undef = 0
for i in range(1, nsym):
    shndx = struct.unpack_from('<H', b, dynsym[4] + i*24 + 6)[0]
    if shndx == 0:
        undef += 1
        assert idx[i] == 1, ('an undefined import must carry the BASE index 1', i, idx[i])
    else:
        assert idx[i] == 2, ('a defined symbol must carry the default index 2', i, idx[i])
assert undef == 3, ('so_link_import.ast imports add, mul and counter', undef)
assert sum(1 for x in idx if x == 1) == undef, 'only imports may carry index 1'
assert 3 not in idx, 'no symbol references the VERNEED aux (index 3)'
print('PASS: GNU triad with DT_GNU_HASH intact; %d defined at index 2, %d imports at index 1' % (nsym - 1 - undef, undef))
PY

# ---------------------------------------------------------------- 5. readelf cross-check
printf '%s\n' '[5/9] Independent reader (readelf -V / --dyn-syms) agrees'
if command -v readelf >/dev/null 2>&1 && readelf -h "$OUT/math.so" >/dev/null 2>&1; then
    for so in math import; do
        readelf -VW "$OUT/$so.so" > "$OUT/v.$so.txt"
        grep -q 'Version definition section .\.gnu\.version_d.' "$OUT/v.$so.txt" \
            || fail "readelf -V finds no version definition section in $so.so"
        grep -q 'Version needs section .\.gnu\.version_r.' "$OUT/v.$so.txt" \
            || fail "readelf -V finds no version needs section in $so.so"
        grep -Eq 'Flags: BASE +Index: 1 +Cnt: 1' "$OUT/v.$so.txt" \
            || fail "readelf -V does not show the BASE VERDEF at index 1 in $so.so"
        grep -Eq 'Index: 2 +Cnt: 1 +Name: aster' "$OUT/v.$so.txt" \
            || fail "readelf -V does not show the aster VERDEF at index 2 in $so.so"
        grep -Eq 'File: libc\.so\.6 +Cnt: 1' "$OUT/v.$so.txt" \
            || fail "readelf -V does not show the libc.so.6 VERNEED in $so.so"
        grep -Eq 'Name: GLIBC_2\.17 +Flags: none +Version: 3' "$OUT/v.$so.txt" \
            || fail "readelf -V does not show GLIBC_2.17 at version 3 in $so.so"
    done
    # Every defined symbol carries its version suffix: @@aster. This is
    # readelf applying .gnu.version itself.
    readelf --dyn-syms -W "$OUT/math.so" > "$OUT/ds.math.txt"
    [ "$(grep -c '@@aster' "$OUT/ds.math.txt")" -ge 5 ] \
        || fail "readelf --dyn-syms does not suffix the SysV exports with @@aster"
    readelf --dyn-syms -W "$OUT/import.so" > "$OUT/ds.import.txt"
    [ "$(grep -c '@@aster' "$OUT/ds.import.txt")" -ge 5 ] \
        || fail "readelf --dyn-syms does not suffix the GNU exports with @@aster"
    # The imports are unversioned references (versym 1 = BASE), so readelf
    # must show them with no version suffix at all.
    [ "$(grep -Ec ' UND [^[:space:]]+$' "$OUT/ds.import.txt")" = 3 ] \
        || fail "readelf --dyn-syms does not list the three named imports as undefined"
    grep -q '@GLIBC' "$OUT/ds.import.txt" \
        && fail "readelf --dyn-syms versions the imports — they must be unversioned (index 1)"
    printf '  %-40s %s\n' 'readelf: verdef BASE@1 + aster@2, verneed GLIBC_2.17@3' 'agree'
else
    printf '  %-40s %s\n' 'readelf' 'skipped (not usable); python readers above cover this'
fi

# ---------------------------------------------------------------- 6. dlopen witnesses
printf '%s\n' '[6/9] dlopen witnesses: the real loader accepts both versioned .so files'
can_run=no
if [ "$(uname -m)" = aarch64 ] || command -v qemu-aarch64 >/dev/null 2>&1; then
    can_run=yes
fi
host_ok=no
if [ "$can_run" = yes ] && command -v "$HOSTCC" >/dev/null 2>&1 \
   && echo 'int main(){return 0;}' | "$HOSTCC" -x c - -o "$OUT/probe" 2>/dev/null \
   && head -c 20 "$OUT/probe" | od -An -tx1 -v | tr -d ' \n' | grep -q 'b700$'; then
    host_ok=yes
fi
if [ "$host_ok" = yes ]; then
    # SysV path: legacy_math.so (no imports) — its exports live at version
    # "aster"; current() reads the initialised accumulator (7).
    "$HOSTCC" -O1 -o "$OUT/so-init-host" tests/so-init-host.c -ldl
    set +e
    out=$(LD_LIBRARY_PATH="$OUT" "$PWD/$RUNNER" "$OUT/so-init-host" "$OUT/math.so" current 7 2>&1); rc=$?
    set -e
    printf '  %s\n' "$out"
    [ "$rc" = 0 ] || fail "dlopen of the SysV versioned .so failed (rc=$rc): $out"
    # GNU path: link-so with --needed libc.so.6 so DT_NEEDED and the VERNEED
    # file agree; len() calls the unversioned strlen import (11 characters).
    "$A" build-obj --pic examples/so_verstrlen.ast -o "$OUT/verstrlen.o" >/dev/null
    "$A" link-so "$OUT/verstrlen.o" -o "$OUT/verstrlen.so" --needed libc.so.6 >/dev/null
    set +e
    out=$(LD_LIBRARY_PATH="$OUT" "$PWD/$RUNNER" "$OUT/so-init-host" "$OUT/verstrlen.so" len 11 2>&1); rc=$?
    set -e
    printf '  %s\n' "$out"
    [ "$rc" = 0 ] || fail "dlopen of the GNU versioned .so failed (rc=$rc): $out"
    printf '  %-40s %s\n' 'dlopen: SysV current()=7, GNU len()=11' 'ok'
else
    printf '  %-40s %s\n' 'dlopen witnesses' 'skipped (no AArch64 host toolchain/runner)'
fi

# ---------------------------------------------------------------- 7. static images
printf '%s\n' '[7/9] Static images are untouched: no .dynamic, no version sections'
cat > "$OUT/static.ast" <<'AST'
fn main() -> i32 { return 3; }
AST
for m in build-elf build-obj build-pie; do
    "$A" $m "$OUT/static.ast" -o "$OUT/static.$m" >/dev/null
    n=$(readelf -SW "$OUT/static.$m" | grep -Ec 'dynamic|gnu\.version' || true)
    [ "$n" = 0 ] || fail "$m emitted a .dynamic or .gnu.version* section (static images must not be versioned)"
done
printf '  %-40s %s\n' 'build-elf / build-obj / build-pie' 'clean'

# ---------------------------------------------------------------- 8. hashes recomputed
printf '%s\n' '[8/9] The version hashes are the SysV elf_hash, recomputed here'
# elfHash is the same function DT_HASH uses; a wrong hash makes the loader
# fail to match the VERNEED, so both tables' hashes are recomputed from the
# strings the sections themselves name (no copy of the writer's arithmetic
# beyond the algorithm definition). The verdef chain is walked the way the
# loader walks it: BASE first (hash must be 0), then the named version.
python3 - "$OUT/math.so" "$OUT/import.so" <<'PY' || exit 1
import struct, sys
def elf_hash(s):
    h = 0
    for c in s.encode():
        h = ((h << 4) + c) & 0xffffffff
        g = h & 0xf0000000
        if g: h ^= g >> 24
        h &= ~g & 0xffffffff
    return h
def sec_of(b, name):
    shoff = struct.unpack_from('<Q', b, 40)[0]
    ents, num, si = struct.unpack_from('<HHH', b, 58)
    raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*ents) for i in range(num)]
    names = b[raw[si][4]:raw[si][4]+raw[si][5]]
    for s in raw:
        if names[s[0]:names.index(b'\0', s[0])].decode() == name:
            return s
    return None
for path in sys.argv[1:]:
    b = open(path, 'rb').read()
    vd, vn = sec_of(b, '.gnu.version_d'), sec_of(b, '.gnu.version_r')
    assert vd is not None and vn is not None, path
    vdb = b[vd[4]:vd[4]+vd[5]]; vnb = b[vn[4]:vn[4]+vn[5]]
    dstr = sec_of(b, '.dynstr'); strs = b[dstr[4]:dstr[4]+dstr[5]]
    def cstr(o): return strs[o:strs.index(b'\0', o)].decode()
    # Walk the verdef chain: [BASE(1, flags 1, hash 0), aster(2, flags 0)].
    off, seen = 0, []
    while True:
        ver, flags, ndx, cnt = struct.unpack_from('<HHHH', vdb, off)
        vhash, vaux, vnext = struct.unpack_from('<III', vdb, off + 8)
        vda_name = struct.unpack_from('<I', vdb, off + vaux)[0]
        seen.append((ndx, flags, vhash, cstr(vda_name)))
        if vnext == 0: break
        off += vnext
    assert len(seen) == 2, (path, 'the verdef chain must hold exactly BASE + aster', seen)
    assert seen[0][0] == 1 and seen[0][1] == 1 and seen[0][2] == 0, (path, 'BASE', seen[0])
    assert seen[0][3], (path, 'the BASE verdef must still be named', seen[0])
    assert seen[1][0] == 2 and seen[1][1] == 0, (path, 'aster', seen[1])
    assert seen[1][2] == elf_hash(seen[1][3]), (path, 'vd_hash')
    assert seen[1][3] == 'aster', (path, seen[1])
    fname = cstr(struct.unpack_from('<I', vnb, 4)[0])
    assert fname == 'libc.so.6', (path, fname)
    vname = cstr(struct.unpack_from('<I', vnb, 24)[0])
    assert vname == 'GLIBC_2.17', (path, vname)
    assert struct.unpack_from('<I', vnb, 16)[0] == elf_hash(vname), (path, 'vna_hash')
    print('PASS: %s — elf_hash(%s)=%08x, elf_hash(%s)=%08x' % (
        path, seen[1][3], elf_hash(seen[1][3]), vname, elf_hash(vname)))
PY

# ---------------------------------------------------------------- 9. the suite can still fail
printf '%s\n' '[9/9] The suite can still fail (mutation)'
# Point the VERNEED's version index at the BASE verdef's index instead of its
# own: the aux then claims index 1, which glibc's l_versions keeps reserved for
# the unversioned form, so the VERNEED and the BASE form collide. The [4/9]
# reader asserts vna_other == 3, so it must fail.
sed 's|pv16(verNeed,22,3);|pv16(verNeed,22,1);|' src/aster.cpp > "$OUT/mutant.cpp"
[ "$(grep -cF 'pv16(verNeed,22,1);' "$OUT/mutant.cpp")" = 2 ] \
    || fail "the vna_other mutation stopped applying — the [9/9] guard is stale"
${CXX:-c++} -std=c++17 -O2 "$OUT/mutant.cpp" -o "$OUT/mutant" 2>/dev/null \
    || fail "the vna_other mutation no longer compiles"
"$OUT/mutant" build-so examples/so_link_import.ast -o "$OUT/mut.so" --needed libdyn.so >/dev/null 2>&1
# The mutant must be *rejected* by the same reader the suite uses: if the
# reader still accepts the broken VERNEED index, the suite is not really
# checking it and must fail here.
if python3 - "$OUT/mut.so" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
shoff = struct.unpack_from('<Q', b, 40)[0]
ents, num, si = struct.unpack_from('<HHH', b, 58)
raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*ents) for i in range(num)]
names = b[raw[si][4]:raw[si][4]+raw[si][5]]
for s in raw:
    if names[s[0]:names.index(b'\0', s[0])].decode() == '.gnu.version_r':
        vn = b[s[4]:s[4]+s[5]]
        assert struct.unpack_from('<H', vn, 22)[0] == 3, 'vna_other must be 3'
print('mutation NOT noticed')
PY
then
    fail "the vna_other mutation was not noticed — the suite is not really checking the VERNEED index"
else
    printf '  %-40s %s\n' 'mutation noticed (vna_other 3 -> 1 rejected)' 'ok'
fi
echo "PASS: all v0.23.51-dev symbol-versioning checks"
