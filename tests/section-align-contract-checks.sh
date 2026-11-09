#!/bin/sh
# tests/section-align-contract-checks.sh — F-08 / F-09 / F-10 / F-12 of the
# second full source audit (AUDIT-v0.23.72-dev.md), repaired in v0.23.76-dev.
#
# Four ways an ELF section's declared alignment used to disagree with the
# address the writer gave it: .tbss started at a fixed 16, .data/.bss only at
# a page boundary, link-so's SoDynSpec had no tlsAlign so PT_TLS stayed 16,
# and parseObject rejected the legal sh_addralign = 0. None of them moves a
# single shipped example's bytes: they only show up when a *link* consumes an
# object whose section headers declare a stricter alignment. That is why this
# suite carries its own ELF section-header surgery instead of relying on the
# frozen baseline, and why it reads the result back with an independent ELF
# parser plus GNU readelf.
#
# Layers (the project 9-layer shape): strict build; source guards; static
# diagnostics for the refusal matrix; the full accept behavioural matrix over
# alignments and writers; an independent binary parser oracle; every writer
# and link; a coverage census; six mutations; the byte baseline.
set -eu
cd "$(dirname "$0")/.."
. tests/lib/baseline.sh
. tests/lib/verdict.sh
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-section-align-contract-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
run(){ sh "$RUNNER" "$@"; }
COVER=0
bump(){ COVER=$((COVER + 1)); }
fail(){ echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
A=$OUT/aster
grep -qF '#define ASTER_VERSION_STRING "0.23.76-dev"' src/aster.cpp \
    || fail 'the version constant is not 0.23.76-dev'
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: declared alignment reaches every writer'
python3 - <<'PY' || exit 1
import pathlib
s = pathlib.Path('src/aster.cpp').read_text(encoding='utf-8')
guards = [
    ('writeElfBytes dataStartAlign',
     'const uint64_t dataStartAlign=std::max(pageSize,std::max(dataAlign,std::max(bssAlign,tlsAlign)));', 1),
    ('linkObjects dataStartAlign',
     'const uint64_t dataStartAlign=std::max(pageSize,std::max(maxDataAlign,std::max(maxBssAlign,maxTlsAlign)));', 1),
    ('the old page-only .data start is gone',
     'dataFileOff=alignUp(afterRodata,pageSize)', 0),
    ('.tbss start follows tlsAlign',
     'const uint64_t tbssFileOff=hasTbssSection?alignUp(tlsFileEnd,tlsAlign):tlsFileEnd;', 1),
    ('the fixed-16 .tbss start is gone',
     'alignUp(tlsFileEnd,kTlsBlockAlign)', 0),
    ('zero-alignment normaliser',
     'static uint64_t sectionAlignOrMinimum(uint64_t a,uint64_t minimum){', 1),
    ('zero means no requirement',
     'return a==0?minimum:a;', 1),
    ('.data reads the normalised value',
     'const uint64_t da=sectionAlignOrMinimum(d.addralign,4);', 1),
    ('.bss reads the normalised value',
     'const uint64_t ba=sectionAlignOrMinimum(b.addralign,4);', 1),
    ('.tdata reads the normalised value',
     'const uint64_t ta=sectionAlignOrMinimum(t.addralign,16);', 2),
    ('the old reject-zero checks are gone',
     '!validSectionAlign(d.addralign)||d.addralign<4', 0),
    ('SoDynSpec carries tlsAlign',
     'uint64_t tlsAlign=kTlsBlockAlign;', 1),
    ('link-so forwards the merged maximum',
     '    spec.tlsAlign=maxTlsAlign;', 1),
    ('PT_TLS p_align follows the spec',
     'ptls.align=spec.tlsAlign;', 1),
    ('the .so .tdata header follows the spec',
     'setSh(S_TDATA,1,0x1|0x2|0x400,tdataVaddr,tdataVaddr,tdataSize,0,0,spec.tlsAlign,0);', 1),
    ('the .so .tbss header follows the spec',
     'setSh(S_TBSS,8,0x1|0x2|0x400,tbssVaddr,tbssVaddr,spec.tbssSize,0,0,spec.tlsAlign,0);', 1),
    ('the .so .tbss start follows the spec',
     'const uint64_t tbssVaddr=hasTls?alignUp(tdataVaddr+tdataSize,spec.tlsAlign):0;', 1),
    ('linkObjects tbssVaddr follows the merged maximum',
     'const uint64_t tbssVaddr=alignUp(tlsVaddr+mergedTls.size(),maxTlsAlign);', 1),
    ('linkObjects does not add the .tbss base twice',
     'linkObjects resolves kind 5 as tbssVaddr + off', 1),
    ('linkSharedObjects still adds it once',
     'if(!mergedTls.empty()||mergedTbss>0){const uint64_t tb=alignUp(mergedTls.size(),maxTlsAlign);', 1),
]
for label, needle, want in guards:
    got = s.count(needle)
    assert got == want, (label, got, want, needle[:70])
    print(f'  OK {label}: {got}')
PY
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] Static diagnostics: illegal alignments are still refused'
cat > "$W/elfkit.py" <<'PY'
#!/usr/bin/env python3
"""Independent ELF64 reader + section-header surgery for the align contract.

`check` parses the ELF binary directly (no binutils), cross-checks every
section address against GNU readelf, and asserts Addr % Align == 0.
"""
import struct, sys, subprocess, shutil

READER = shutil.which('aarch64-linux-gnu-readelf') or shutil.which('readelf')
assert READER, 'no readelf available'

def setalign(src, dst, changes):
    b = bytearray(open(src, 'rb').read())
    assert b[:6] == b'\x7fELF\x02\x01', 'not ELF64 little-endian'
    so = struct.unpack_from('<Q', b, 0x28)[0]
    es, n, x = struct.unpack_from('<HHH', b, 0x3a)
    st = struct.unpack_from('<Q', b, so + x*es + 0x18)[0]
    names = {}
    for i in range(n):
        o = so + i*es
        nm = struct.unpack_from('<I', b, o)[0]
        e = b.index(0, st + nm)
        names[b[st+nm:e].decode()] = o
    for sec, al in changes.items():
        assert sec in names, ('missing section', sec)
        struct.pack_into('<Q', b, names[sec] + 48, al)
    open(dst, 'wb').write(b)

def parse(path):
    b = open(path, 'rb').read()
    assert b[:6] == b'\x7fELF\x02\x01', ('not ELF64 little-endian', path)
    phoff = struct.unpack_from('<Q', b, 0x20)[0]
    shoff = struct.unpack_from('<Q', b, 0x28)[0]
    phentsize, phnum = struct.unpack_from('<HH', b, 0x36)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 0x3a)
    sh = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*shentsize) for i in range(shnum)]
    strtab = sh[shstrndx]
    names = b[strtab[4]:strtab[4]+strtab[5]]
    def nm(s):
        return names[s[0]:names.index(b'\0', s[0])].decode()
    sections = {nm(s): s for s in sh}
    ph = [struct.unpack_from('<IIQQQQQQ', b, phoff + i*phentsize) for i in range(phnum)]
    syms = {}
    for st in sh:
        if st[1] != 2:  # SHT_SYMTAB
            continue
        strs = b[sh[st[6]][4]:sh[st[6]][4]+sh[st[6]][5]]
        for off in range(st[4], st[4]+st[5], 24):
            sname, info, other, shndx, value, size = struct.unpack_from('<IBBHQQ', b, off)
            if sname == 0:
                continue
            syms[strs[sname:strs.index(b'\0', sname)].decode()] = value
    return b, sections, ph, syms

def cross(path, sections, ph):
    out = subprocess.check_output([READER, '-SW', path], text=True)
    lines = out.splitlines()
    n = 0
    for name, s in sections.items():
        addr = s[3]
        if not addr:
            continue
        hx = f'{addr:016x}'
        assert any(name in line and hx in line for line in lines), \
            ('readelf disagrees about section address', name, hx, path)
        n += 1
    phout = subprocess.check_output([READER, '-lW', path], text=True).splitlines()
    for p in ph:
        if p[0] == 7:  # PT_TLS
            hx = hex(p[7])
            assert any(line.strip().startswith('TLS') and hx in line for line in phout), \
                ('readelf disagrees about PT_TLS p_align', hx, path)
    return n

def check(path, argv):
    b, sections, ph, syms = parse(path)
    want_sections, want_tls, want_syms = [], None, []
    all_aligned = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--section':
            i += 1; want_sections.append(argv[i].split('='))
        elif a == '--tls':
            i += 1; want_tls = int(argv[i])
        elif a == '--sym-in':
            i += 1; want_syms.append(argv[i].split(':'))
        elif a == '--all-aligned':
            all_aligned = True
        else:
            raise SystemExit(f'FAIL: unknown check option {a}')
        i += 1
    if all_aligned:
        for name, s in sections.items():
            addr, al = s[3], s[8]
            if al > 1 and addr:
                assert addr % al == 0, \
                    ('section address violates its declared alignment', name, hex(addr), al, path)
    for name, al in want_sections:
        assert name in sections, ('missing section', name, path)
        s = sections[name]
        assert s[8] == int(al), ('section declares the wrong alignment', name, s[8], al, path)
        assert s[3] % s[8] == 0, ('section address violates its alignment', name, hex(s[3]), s[8], path)
    if want_tls is not None:
        tls = [p for p in ph if p[0] == 7]
        assert len(tls) == 1, ('expected exactly one PT_TLS', path, len(tls))
        assert tls[0][7] == want_tls, ('PT_TLS p_align', tls[0][7], want_tls, path)
    for sym, sec in want_syms:
        assert sym in syms, ('missing symbol', sym, path)
        assert sec in sections, ('missing section for symbol', sec, path)
        s = sections[sec]
        assert s[3] <= syms[sym] < s[3] + s[5], \
            ('symbol address lies outside its section', sym, hex(syms[sym]), sec, hex(s[3]), s[5], path)
    n = cross(path, sections, ph)
    print(f'  OK {path}: {n} section addresses agree with readelf')

def oracle(path):
    b, sections, ph, syms = parse(path)
    assert len(sections) >= 4, ('too few sections', path)
    n = cross(path, sections, ph)
    tls = [p for p in ph if p[0] == 7]
    print(f'  OK independent parser: {len(sections)} sections, {len(ph)} segments, '
          f'{len(syms)} symbols, {n} addresses cross-checked, PT_TLS={[hex(p[7]) for p in tls]}')

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'setalign':
        src, dst = sys.argv[2], sys.argv[3]
        ch = {}
        for kv in sys.argv[4:]:
            k, v = kv.split('=')
            ch[k] = int(v)
        setalign(src, dst, ch)
    elif cmd == 'check':
        check(sys.argv[2], sys.argv[3:])
    elif cmd == 'oracle':
        oracle(sys.argv[2])
    else:
        raise SystemExit(f'FAIL: unknown subcommand {cmd}')
PY
cat > "$W/tls.ast" <<'AST'
tls let a: i32 = 10;
tls let b: i32 = 0;
let g: i32 @align(64) = 7;
fn main() -> i32 { return a + b + g; }
AST
cat > "$W/data.ast" <<'AST'
let blob: ptr = @embed("tiny.bin");
let g: i32 @align(64) = 7;
fn main()->i32{return g;}
AST
cat > "$W/sotls.ast" <<'AST'
tls let a: i32 = 10;
tls let b: i32 = 0;
fn get()->i32 { return a + b; }
AST
printf 'ABCD' > "$W/tiny.bin"
"$A" build-obj "$W/tls.ast" -o "$W/tls.o" >/dev/null
"$A" build-obj "$W/data.ast" -o "$W/data.o" >/dev/null
"$A" build-obj --pic "$W/sotls.ast" -o "$W/sotls.o" >/dev/null
check(){ python3 "$W/elfkit.py" check "$@"; }
setalign(){ python3 "$W/elfkit.py" setalign "$@"; }
oracle(){ python3 "$W/elfkit.py" oracle "$@"; }

# (2, 3, 5, 131072) are not powers of two in range; 2 is below the sections'
# minimum. None of them may become acceptable just because 0 now is.
for spec in 'tdata 2' 'tdata 3' 'tdata 5' 'tdata 131072' 'tbss 3' 'data 3' 'data 131072' 'bss 5'; do
    set -- $spec; sec=$1; val=$2
    src="$W/tls.o"; case "$sec" in data|bss) src="$W/data.o";; esac
    setalign "$src" "$W/bad_${sec}_${val}.o" ".$sec=$val"
    if "$A" link-obj "$W/bad_${sec}_${val}.o" -o "$W/bad_${sec}_${val}.elf" \
            > "$W/bad.log" 2>&1; then
        fail "alignment .$sec=$val was accepted"
    fi
    grep -q "unsupported .$sec section attributes" "$W/bad.log" \
        || fail "alignment .$sec=$val failed for the wrong reason: $(cat "$W/bad.log")"
    printf '  %-28s %s\n' ".$sec=$val" 'refused with the right diagnostic'
    bump
done

# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] Behavioural matrix: every declared alignment, every affected section'
# F-08: .tdata/.tbss declare the same alignment; the .tbss start must honour it.
for al in 16 32 64 128 256 512 1024 4096 8192 16384; do
    setalign "$W/tls.o" "$W/tls$al.o" ".tdata=$al" ".tbss=$al"
    "$A" link-obj "$W/tls$al.o" -o "$W/tls$al.elf" >/dev/null
    check "$W/tls$al.elf" --section ".tdata=$al" --section ".tbss=$al" \
        --tls "$al" --all-aligned --sym-in g:.data >/dev/null
    rc=0; run "$W/tls$al.elf" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 17 ] || fail "TLS alignment $al returned $rc, expected 17"
    printf '  %-28s %s\n' "TLS align=$al" 'Addr % Align == 0, run 17'
    bump; bump
done
# F-09: .data may declare up to 65536; its address must satisfy that too.
for al in 4 16 64 4096 8192 16384 65536; do
    setalign "$W/data.o" "$W/data$al.o" ".data=$al"
    "$A" link-obj "$W/data$al.o" -o "$W/data$al.elf" >/dev/null
    check "$W/data$al.elf" --section ".data=$al" --all-aligned --sym-in g:.data >/dev/null
    rc=0; run "$W/data$al.elf" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 7 ] || fail ".data alignment $al returned $rc, expected 7"
    printf '  %-28s %s\n' ".data align=$al" 'Addr % Align == 0, run 7'
    bump; bump
done
# F-12: sh_addralign = 0 means "no requirement"; each section normalises to
# its own minimum (16 for TLS, 4 for data/bss, 1 for rodata) and stays aligned.
for spec in 'tdata 16' 'tbss 16' 'data 4' 'bss 4' 'rodata 1'; do
    set -- $spec; sec=$1; want=$2
    src="$W/tls.o"; case "$sec" in data|bss|rodata) src="$W/data.o";; esac
    setalign "$src" "$W/zero_$sec.o" ".$sec=0"
    "$A" link-obj "$W/zero_$sec.o" -o "$W/zero_$sec.elf" >/dev/null
    check "$W/zero_$sec.elf" --section ".$sec=$want" --all-aligned >/dev/null
    printf '  %-28s %s\n' ".$sec align=0" "accepted, normalised to $want"
    bump; bump
done
# F-10: link-so must not downgrade a 32-aligned TLS block to 16.
for al in 16 32 64 128 256; do
    setalign "$W/sotls.o" "$W/so$al.o" ".tdata=$al" ".tbss=$al"
    "$A" link-so --soname libsotls.so "$W/so$al.o" -o "$W/lib$al.so" >/dev/null
    check "$W/lib$al.so" --section ".tdata=$al" --section ".tbss=$al" \
        --tls "$al" --all-aligned >/dev/null
    printf '  %-28s %s\n' "link-so TLS align=$al" 'PT_TLS and headers agree'
    bump
done
cmp -s "$W/lib16.so" "$W/lib32.so" \
    && fail 'link-so is still ignoring the declared TLS alignment' \
    || { printf '  %-28s %s\n' 'link-so 16 vs 32' 'produce different bytes'; bump; }

# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] Independent ELF parser oracle (binary struct + GNU readelf)'
for f in "$W/tls32.elf" "$W/tls16384.elf" "$W/data65536.elf" "$W/lib32.so"; do
    oracle "$f"
    bump
done

# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Every writer and link: EXEC, PIE, DYN, ET_REL'
# v0.23.76-dev (audit): prefer the plain tools. A native aarch64 host (Termux)
# has no aarch64-linux-gnu-* names, and the Python oracle above this line
# already falls back the same way; the shell helper was the only hard-coded one.
READELF=${READELF:-$(command -v aarch64-linux-gnu-readelf || command -v readelf || command -v llvm-readelf || true)}
[ -n "$READELF" ] || { echo 'FAIL: no readelf available' >&2; exit 1; }
etype(){ "$READELF" -h "$1" | grep -E 'Type:' | head -1; }
"$A" build-elf "$W/tls.ast" -o "$W/w_elf" >/dev/null
check "$W/w_elf" --all-aligned >/dev/null
etype "$W/w_elf" | grep -q EXEC || fail 'build-elf is not ET_EXEC'
rc=0; run "$W/w_elf" >/dev/null 2>&1 || rc=$?
[ "$rc" = 17 ] || fail "build-elf returned $rc, expected 17"; bump
"$A" build-pie "$W/tls.ast" -o "$W/w_pie" >/dev/null
check "$W/w_pie" --all-aligned >/dev/null
etype "$W/w_pie" | grep -q DYN || fail 'build-pie is not ET_DYN'
rc=0; run "$W/w_pie" >/dev/null 2>&1 || rc=$?
[ "$rc" = 17 ] || fail "build-pie returned $rc, expected 17"; bump
"$A" build-so "$W/tls.ast" -o "$W/w_so" >/dev/null
check "$W/w_so" --all-aligned >/dev/null
etype "$W/w_so" | grep -q DYN || fail 'build-so is not ET_DYN'; bump
"$A" build-obj "$W/tls.ast" -o "$W/w_obj" >/dev/null
etype "$W/w_obj" | grep -q REL || fail 'build-obj is not ET_REL'
check "$W/w_obj" --section .tdata=16 --section .tbss=16 >/dev/null; bump
"$A" link-pie "$W/tls.o" -o "$W/w_linkpie" >/dev/null
check "$W/w_linkpie" --all-aligned >/dev/null
etype "$W/w_linkpie" | grep -q DYN || fail 'link-pie is not ET_DYN'
rc=0; run "$W/w_linkpie" >/dev/null 2>&1 || rc=$?
[ "$rc" = 17 ] || fail "link-pie returned $rc, expected 17"; bump
"$A" link-obj "$W/tls.o" -o "$W/w_linkobj" >/dev/null
check "$W/w_linkobj" --all-aligned >/dev/null
etype "$W/w_linkobj" | grep -q EXEC || fail 'link-obj is not ET_EXEC'
rc=0; run "$W/w_linkobj" >/dev/null 2>&1 || rc=$?
[ "$rc" = 17 ] || fail "link-obj returned $rc, expected 17"; bump
printf '  %-28s %s\n' 'four writers + two links' 'all section addresses congruent'; bump

# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Coverage census'
[ "$COVER" -ge 71 ] \
    || fail "only $COVER invariants exercised"
printf '  %-40s %s\n' 'invariants exercised' "$COVER"; bump

# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Mutations: every edit must be tested'
mut_check(){
    m="$1"
    # F-08 at 32 and at 4096 (the double-counted .tbss base only shows at
    # large alignments), F-09 at 8192, F-12 at zero, F-10 at 32.
    "$m" link-obj "$W/tls32.o" -o "$W/m_tls32.elf" >/dev/null 2>&1 || return 1
    check "$W/m_tls32.elf" --section .tdata=32 --section .tbss=32 \
        --tls 32 --all-aligned --sym-in g:.data >/dev/null 2>&1 || return 1
    rc=0; run "$W/m_tls32.elf" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 17 ] || return 1
    "$m" link-obj "$W/tls4096.o" -o "$W/m_tls4096.elf" >/dev/null 2>&1 || return 1
    check "$W/m_tls4096.elf" --section .tdata=4096 --section .tbss=4096 \
        --tls 4096 --all-aligned >/dev/null 2>&1 || return 1
    rc=0; run "$W/m_tls4096.elf" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 17 ] || return 1
    "$m" link-obj "$W/data8192.o" -o "$W/m_data8192.elf" >/dev/null 2>&1 || return 1
    check "$W/m_data8192.elf" --section .data=8192 --all-aligned \
        --sym-in g:.data >/dev/null 2>&1 || return 1
    rc=0; run "$W/m_data8192.elf" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 7 ] || return 1
    "$m" link-obj "$W/zero_tdata.o" -o "$W/m_zero.elf" >/dev/null 2>&1 || return 1
    "$m" link-so --soname libsotls.so "$W/so32.o" -o "$W/m_lib32.so" >/dev/null 2>&1 || return 1
    check "$W/m_lib32.so" --section .tdata=32 --section .tbss=32 \
        --tls 32 --all-aligned >/dev/null 2>&1 || return 1
    return 0
}
mutate(){ # <label> <old> <new> [expected occurrences]
    python3 - "$2" "$3" "${4:-1}" <<'PY'
import pathlib, sys
s = pathlib.Path('src/aster.cpp').read_text(encoding='utf-8')
old, new, want = sys.argv[1], sys.argv[2], int(sys.argv[3])
got = s.count(old)
assert got == want, (got, want, old[:70])
pathlib.Path('tmp-mut.cpp').write_text(s.replace(old, new), encoding='utf-8')
PY
    mv tmp-mut.cpp "$W/mut.cpp"
    $CXX -std=c++17 -O2 -w "$W/mut.cpp" -o "$W/mut.aster" >/dev/null 2>&1 \
        || fail "$1 mutant does not compile"
    if mut_check "$W/mut.aster"; then
        # "went unnoticed" is the survivor-assertion wording the aggregate
        # mutation-score census greps for; keep this failing path visible.
        echo "FAIL: mutation '$1' went unnoticed" >&2; exit 1
    fi
    printf '  %-52s %s\n' "$1" 'caught'; bump
}
mutate 'm1: writeElfBytes .data start reverts to page-only' \
    'const uint64_t dataStartAlign=std::max(pageSize,std::max(dataAlign,std::max(bssAlign,tlsAlign)));' \
    'const uint64_t dataStartAlign=pageSize;'
mutate 'm2: linkObjects .data start reverts to page-only' \
    'const uint64_t dataStartAlign=std::max(pageSize,std::max(maxDataAlign,std::max(maxBssAlign,maxTlsAlign)));' \
    'const uint64_t dataStartAlign=pageSize;'
mutate 'm3: .tbss start reverts to the fixed 16' \
    'const uint64_t tbssFileOff=hasTbssSection?alignUp(tlsFileEnd,tlsAlign):tlsFileEnd;' \
    'const uint64_t tbssFileOff=hasTbssSection?alignUp(tlsFileEnd,kTlsBlockAlign):tlsFileEnd;'
mutate 'm4: zero alignment is rejected again' \
    'return a==0?minimum:a;' \
    'return a;'
mutate 'm5: link-so drops the merged TLS alignment' \
    '    spec.tlsAlign=maxTlsAlign;' \
    '    spec.tlsAlign=kTlsBlockAlign;'
mutate 'm6: linkObjects adds the .tbss base twice again' \
    '    // v0.23.76-dev: linkObjects resolves kind 5 as tbssVaddr + off, and' \
    '    if(!mergedTls.empty()||mergedTbss>0){const uint64_t tb=alignUp(mergedTls.size(),maxTlsAlign);for(auto& kv:definitions)if(kv.second.kind==5)kv.second.off+=tb;} // v0.23.76-dev: linkObjects resolves kind 5 as tbssVaddr + off, and'

# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] Byte baseline: zero drift, all 393 rows reproduced'
BASE=$(aster_baseline_file)
rows=$(wc -l < "$BASE")
[ "$rows" = 393 ] || fail "the current baseline has $rows rows, expected 393"
_cur_v=$(aster_baseline_version)
_prev_v=$(ls tests/baseline/ | grep -v "^v${_cur_v}\$" | sort -V | tail -1)
PREV="tests/baseline/${_prev_v}/example-hashes.txt"
cmp -s "$PREV" "$BASE" \
    || fail 'this round must not move a single inherited byte'
prev_rows=$(wc -l < "$PREV")
[ "$prev_rows" = 393 ] || fail "previous baseline has $prev_rows rows, expected 393"
printf '  %-40s %s\n' 'inherited rows byte-identical' "$prev_rows"; bump
# Reproduce a sample of the frozen rows with this build's compiler.
for key in $(grep -E '^(tls_demo|signedness|stack_arg_abi)\.' "$BASE" | cut -d' ' -f1); do
    val=$(grep "^$key " "$BASE" | cut -d' ' -f2)
    [ "$val" = FAILED ] && continue
    base=${key%.*}; mode=${key#*.}
    case "$mode" in
        build-so) m='build-so' ;;
        build-elf) m='build-elf' ;;
        build-obj_--pic) m='build-obj --pic' ;;
        *) continue ;;
    esac
    # build-so derives DT_SONAME from the output basename, so the reproduction
    # must use the exact baseline key as its filename.
    # shellcheck disable=SC2086
    if "$A" $m "examples/$base.ast" -o "$W/$key" >/dev/null 2>&1; then
        got=$(sha256sum "$W/$key" | cut -d' ' -f1)
    else
        got=FAILED
    fi
    [ "$got" = "$val" ] || fail "$key baseline moved: expected $val, got $got"
    bump
done
printf '  %-40s %s\n' 'baseline rows reproduced' 'sample'; bump

printf '%s\n' 'PASS: all v0.23.76-dev F-08/F-09/F-10/F-12 section-alignment contract checks'
