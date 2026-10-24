#!/bin/sh
# v0.23.51-dev structural + behavioral checks for thread-local storage (`tls`).
#
# `tls let x: T = …;` places a global in a per-thread block. The static image
# (build-elf / build-pie / link-obj / link-pie) carries the block as a PT_TLS
# segment plus a SHF_TLS .tdata section, and main's entry stub points TPIDR_EL0
# at its base (ADRP/ADD __aster_tls_block → MSR TPIDR_EL0) so a single-threaded
# program can read and write it. Accesses are local-exec: MRS Xt,TPIDR_EL0 then
# ADD Xt,Xt,#offset, where the offset is a link-time constant the linker fills
# into the MOVZ/MOVK pair (kRelTlsOff). A shared object (glibc-backed, no
# TLSDESC this round) rejects `tls` with a clear diagnostic.
#
# `tls` is a *context keyword* — only special at the start of a top-level
# declaration — so it stays a usable identifier elsewhere and the reserved-word
# count does not move (still 26).
#
# Layers (the project 9-layer shape): strict build, source guards, parse
# acceptance, ELF structure (PT_TLS/.tdata/symbols), the local-exec relocation,
# independent readers, the rejection matrix, qemu self-checks of the real code
# shape, and a mutation that proves the suite can still fail.
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-tls-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
RUNNER=${RUNNER:-tests/run-aarch64.sh}
fail(){ echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. strict build
printf '%s\n' '[1/9] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
A="$OUT/aster"

# ---------------------------------------------------------------- 2. source guards
printf '%s\n' '[2/9] Source guard: the tls context keyword, the TLS block, local-exec, PT_TLS'
# A regression that drops the `tls` context keyword, the per-thread block layout,
# the TPIDR_EL0 access shape, the entry stub, the kRelTlsOff relocation, or the
# PT_TLS segment must fail here first, before any behavioral check runs.
grep -qF 'if(cur().k==TK::Ident&&cur().s=="tls"){' src/aster.cpp \
    || fail "the tls context keyword is missing from the top-level declaration parser"
grep -qF 'need(TK::Let,"expected '"'"'let'"'"' after '"'"'tls'"'"'");' src/aster.cpp \
    || fail "tls no longer requires a following let"
# kRelTlsOff must be 4096 — the internal relocation type. 1024 collides with the
# ELF-standard R_AARCH64_COPY and made readelf mislabel the fill.
grep -qF 'static constexpr uint32_t kRelTlsOff=4096;' src/aster.cpp \
    || fail "kRelTlsOff is not 4096 (a collision with R_AARCH64_COPY crept back in)"
# The access: MRS X16,TPIDR_EL0 (0xd53bd050) then ADD X16,X16,X17 (local-exec).
grep -qF 'emit(0xd53bd050u);' src/aster.cpp \
    || fail "the TPIDR_EL0 read (MRS X16,TPIDR_EL0) is missing from a TLS access"
grep -qF 'emit(0x8b110210u);' src/aster.cpp \
    || fail "the local-exec ADD X16,X16,X17 is missing from a TLS access"
# The entry stub: ADRP X17,__aster_tls_block / ADD / MSR TPIDR_EL0,X17 (0xd51bd051).
grep -qF 'emit(0xd51bd051u);' src/aster.cpp \
    || fail "the entry stub does not set TPIDR_EL0 (MSR TPIDR_EL0,X17 missing)"
grep -qF 'relocations.push_back({uint64_t(adrp)*4,"__aster_tls_block",kRelAdrp});' src/aster.cpp \
    || fail "the entry stub no longer addresses __aster_tls_block"
# The PT_TLS program header (type 7) and the SHF_TLS .tdata section (0x2|0x400).
grep -qF 'Phdr tl{};if(hasTlsSection){tl.type=7;' src/aster.cpp \
    || fail "writeElfBytes no longer emits a PT_TLS program header (type 7)"
grep -qF 'e.type=1;e.flags=0x2|0x400;e.addr=tlsVaddr;' src/aster.cpp \
    || fail "the .tdata section is not SHF_TLS (0x2|0x400)"
# The kRelTlsOff fill must subtract the PT_TLS base (block-relative offset).
grep -qF 'const uint32_t val=uint32_t((target-tlsVaddr)&0xffffffffu);' src/aster.cpp \
    || fail "kRelTlsOff no longer fills the block-relative offset (target-tlsVaddr)"
# A shared object must refuse `tls`, from both writers' input paths.
grep -qF 'is not supported in shared objects: global' src/aster.cpp \
    || fail "build-so no longer rejects a tls global with a clear diagnostic"
grep -qF 'is not supported in shared objects; use a plain `let`' src/aster.cpp \
    || fail "link-so no longer rejects a tls object with a clear diagnostic"

# ---------------------------------------------------------------- 3. parse acceptance
printf '%s\n' '[3/9] Parse acceptance: tls globals, and tls stays a usable identifier'
cat > "$OUT/ok.ast" <<'AST'
tls let counter: i32 = 7;
tls let table: i32[4] = 0;
fn main() -> i32 {
    let tls: i32 = 5;      // `tls` is a context keyword: still an ordinary name here
    counter = counter + tls;
    table[3] = counter;
    return counter + table[3];
}
AST
"$A" build-elf "$OUT/ok.ast" -o "$OUT/ok" >/dev/null \
    || fail "a tls global (scalar and array) plus a local named tls must compile"
# The reserved-word count must not have moved: `tls` is a context keyword, not a
# keyword. The authoritative list is bootstrap/gen_lexer_names.py's KEYWORDS
# (the generator asserts its own length is 26); `tls` must be absent from it.
python3 - <<'PY' || exit 1
import re
src = open('bootstrap/gen_lexer_names.py').read()
m = re.search(r'KEYWORDS = \[(.*?)\]', src, re.S)
entries = re.findall(r'\("([^"]+)",', m.group(1))
assert len(entries) == 26, ('reserved-word count moved', len(entries), entries)
assert 'tls' not in entries, 'tls became a reserved word — it must stay a context keyword'
print('PASS: 26 reserved words, tls absent (context keyword)')
PY

# ---------------------------------------------------------------- 4. ELF structure
printf '%s\n' '[4/9] ELF structure: PT_TLS segment, SHF_TLS .tdata, the block symbol'
"$A" build-elf examples/tls_demo.ast -o "$OUT/tls.elf" >/dev/null
python3 - "$OUT/tls.elf" <<'PY' || exit 1
import struct, sys
b = open(sys.argv[1], 'rb').read()
assert b[:6] == b'\x7fELF\x02\x01'
phoff = struct.unpack_from('<Q', b, 32)[0]
phentsize, phnum = struct.unpack_from('<HH', b, 54)
segs = [struct.unpack_from('<IIQQQQQQ', b, phoff + i*phentsize) for i in range(phnum)]
PT_TLS = 7
tls = [s for s in segs if s[0] == PT_TLS]
assert len(tls) == 1, ('expected exactly one PT_TLS segment', [hex(s[0]) for s in segs])
t = tls[0]
assert t[1] & 0x6 == 0x6, ('PT_TLS must be RW', hex(t[1]))          # p_flags
assert t[5] == t[6], ('PT_TLS filesz must equal memsz (no .tbss yet)', t[5], t[6])
assert t[5] > 0 and t[5] % 4 == 0, ('PT_TLS size must be a positive multiple of 4', t[5])
# Section headers: a SHF_TLS (0x400) SHT_PROGBITS .tdata at the PT_TLS address.
shoff = struct.unpack_from('<Q', b, 40)[0]
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*shentsize) for i in range(shnum)]
shstr = raw[shstrndx]
names = b[shstr[4]:shstr[4]+shstr[5]]
def nm(s): return names[s[0]:names.index(b'\0', s[0])].decode()
tdata = [s for s in raw if nm(s) == '.tdata']
assert len(tdata) == 1, 'no .tdata section'
td = tdata[0]
assert td[1] == 1, '.tdata must be SHT_PROGBITS'
assert td[2] == (0x2 | 0x400), ('.tdata must be SHF_ALLOC|SHF_TLS', hex(td[2]))
assert td[3] == t[3], ('.tdata addr must equal PT_TLS vaddr', hex(td[3]), hex(t[3]))
assert td[5] == t[5], '.tdata size must equal PT_TLS size'
# .tdata holds the two initialisers in layout order: a=10 (0x0a), b=20 (0x14).
blob = b[td[4]:td[4]+td[5]]
vals = struct.unpack_from('<%di' % (td[5]//4), blob, 0)
assert 10 in vals and 20 in vals, ('the tls initialisers are missing from .tdata', vals)
print('PASS: PT_TLS + SHF_TLS .tdata carry the block (a=10, b=20 initialised)')
PY

# ---------------------------------------------------------------- 5. local-exec relocation
printf '%s\n' '[5/9] The local-exec relocation: kRelTlsOff fills a block-relative offset'
"$A" build-obj examples/tls_demo.ast -o "$OUT/tls.o" >/dev/null
python3 - "$OUT/tls.o" <<'PY' || exit 1
import struct, sys
b = open(sys.argv[1], 'rb').read()
assert b[:6] == b'\x7fELF\x02\x01'
shoff = struct.unpack_from('<Q', b, 40)[0]
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*shentsize) for i in range(shnum)]
shstr = raw[shstrndx]; names = b[shstr[4]:shstr[4]+shstr[5]]
def nm(s): return names[s[0]:names.index(b'\0', s[0])].decode()
sec = {nm(s): s for s in raw}
rela = sec['.rela.text']; sym = sec['.symtab']; st = sec['.strtab']
strs = b[st[4]:st[4]+st[5]]
def symname(i):
    o = struct.unpack_from('<I', b, sym[4]+i*24)[0]
    return strs[o:].split(b'\0')[0].decode()
KRELTLSOFF = 4096
seen = {}
for off in range(rela[4], rela[4]+rela[5], 24):
    r_off, r_info, r_add = struct.unpack_from('<QQq', b, off)
    if (r_info & 0xffffffff) == KRELTLSOFF:
        seen[symname(r_info >> 32)] = r_off
# Each tls global is reached through its __aster_tls_<name> symbol; the block base
# __aster_tls_block is what the entry stub's ADRP/ADD target.
for want in ('__aster_tls_a', '__aster_tls_b'):
    assert want in seen, ('no kRelTlsOff relocation for', want, sorted(seen))
print('PASS: kRelTlsOff relocations name __aster_tls_a and __aster_tls_b (local-exec)')
PY

# ---------------------------------------------------------------- 6. independent readers
printf '%s\n' '[6/9] Independent readers (readelf) agree on PT_TLS, .tdata, the tls symbols'
if command -v readelf >/dev/null 2>&1 && readelf -h "$OUT/tls.elf" >/dev/null 2>&1; then
    # The final ET_EXEC carries the segment; readelf spells the type "TLS".
    readelf -lW "$OUT/tls.elf" > "$OUT/ph.txt"
    [ "$(grep -Ec '^[[:space:]]*TLS[[:space:]]+0x' "$OUT/ph.txt")" = 1 ] \
        || fail "readelf -l does not show exactly one TLS segment"
    readelf -SW "$OUT/tls.elf" > "$OUT/sh.txt"
    grep -Eq '\.tdata[[:space:]]+PROGBITS.*[[:space:]]AT([[:space:]]|$)' "$OUT/sh.txt" \
        || fail "readelf -S does not show .tdata as a TLS section (flags AT)"
    # The ET_EXEC writer keeps only source-level function symbols; the synthetic
    # __aster_tls_* symbols live in the ET_REL object's .symtab — that is where a
    # linker meets them, so that is the file to read.
    readelf -sW "$OUT/tls.o" > "$OUT/sym.txt"
    grep -q '__aster_tls_block' "$OUT/sym.txt" || fail "readelf -s is missing __aster_tls_block"
    grep -q '__aster_tls_a' "$OUT/sym.txt"     || fail "readelf -s is missing __aster_tls_a"
    grep -q '__aster_tls_b' "$OUT/sym.txt"     || fail "readelf -s is missing __aster_tls_b"
    printf '  %-40s %s\n' 'readelf: TLS segment, .tdata AT, block+global symbols' 'agree'
else
    printf '  %-40s %s\n' 'readelf' 'skipped (not usable); python reader above covers this'
fi

# ---------------------------------------------------------------- 7. rejection matrix
printf '%s\n' '[7/9] Rejection matrix: a shared object refuses tls (both .so writers)'
# build-so (standalone) — the buildSoFromSource path.
if "$A" build-so examples/tls_demo.ast -o "$OUT/tls.so" >"$OUT/rej1.txt" 2>&1; then
    fail "build-so accepted a tls global; it must reject it"
fi
grep -q 'thread-local storage (`tls`) is not supported in shared objects' "$OUT/rej1.txt" \
    || fail "build-so's rejection message is not the documented one: $(cat "$OUT/rej1.txt")"
# link-so — the linkSharedObjects path (a PIC object carrying .tdata).
"$A" build-obj --pic examples/tls_demo.ast -o "$OUT/tlspic.o" >/dev/null
if "$A" link-so "$OUT/tlspic.o" -o "$OUT/tls-linked.so" >"$OUT/rej2.txt" 2>&1; then
    fail "link-so accepted a tls object; it must reject it"
fi
grep -q 'thread-local storage (`tls`) is not supported in shared objects' "$OUT/rej2.txt" \
    || fail "link-so's rejection message is not the documented one: $(cat "$OUT/rej2.txt")"
# A plain (non-tls) program is unaffected and still builds as a .so.
cat > "$OUT/plain.ast" <<'AST'
let g: i32 = 3;
fn bump() -> i32 { g = g + 1; return g; }
AST
"$A" build-so "$OUT/plain.ast" -o "$OUT/plain.so" >/dev/null \
    || fail "a non-tls program must still build as a shared object"
printf '  %-40s %s\n' 'build-so + link-so reject tls; plain .so unaffected' 'ok'

# ---------------------------------------------------------------- 8. qemu self-check
printf '%s\n' '[8/9] qemu self-check: read/write the TLS block, exit code carries the value'
can_run=no
if [ "$(uname -m)" = aarch64 ] || command -v qemu-aarch64 >/dev/null 2>&1; then
    can_run=yes
fi
if [ "$can_run" = yes ]; then
    # a = 10+5 = 15, b = 20*2 = 40, exit = 15+40 = 55 — every value round-trips
    # through the per-thread block, so a wrong TPIDR_EL0 base is caught.
    for m in build-elf build-pie "build-elf -g"; do
        tag=$(echo "$m" | tr ' ' '_')
        "$A" $m examples/tls_demo.ast -o "$OUT/tls.$tag" >/dev/null
        set +e
        "$PWD/$RUNNER" "$OUT/tls.$tag" >"$OUT/out.$tag" 2>&1; rc=$?
        set -e
        [ "$rc" = 55 ] || fail "$m: the TLS program exited $rc, expected 55 (a=15,b=40)"
    done
    printf '  %-40s %s\n' 'qemu: build-elf/build-pie/-g all exit 55' 'ok'
else
    printf '  %-40s %s\n' 'qemu: read/write the TLS block' 'skipped (no runner)'
fi

# ---------------------------------------------------------------- 9. the suite can still fail
printf '%s\n' '[9/9] The suite can still fail (mutation)'
# Halve the local-exec offset fill: read the block base but add only half the
# variable's offset. Layer 4/8 must notice (wrong value → wrong exit code).
sed 's|const uint32_t val=uint32_t((target-tlsVaddr)\&0xffffffffu);|const uint32_t val=uint32_t(((target-tlsVaddr)/2)\&0xffffffffu);|' \
    src/aster.cpp > "$OUT/mutant.cpp"
grep -q '((target-tlsVaddr)/2)' "$OUT/mutant.cpp" \
    || fail "the local-exec mutation stopped applying — the [9/9] guard is stale"
${CXX:-c++} -std=c++17 -O2 "$OUT/mutant.cpp" -o "$OUT/mutant" 2>/dev/null \
    || fail "the local-exec mutation no longer compiles"
if [ "$can_run" = yes ]; then
    "$OUT/mutant" build-elf examples/tls_demo.ast -o "$OUT/mut.elf" >/dev/null 2>&1
    set +e
    "$PWD/$RUNNER" "$OUT/mut.elf" >/dev/null 2>&1; mrc=$?
    set -e
    [ "$mrc" != 55 ] || fail "the halved-offset mutation still exited 55 — the suite is not really checking the offset"
    printf '  %-40s %s\n' "mutation noticed (exited $mrc, not 55)" 'ok'
else
    printf '  %-40s %s\n' 'mutation' 'skipped (no runner)'
fi
echo "PASS: all v0.23.51-dev thread-local-storage checks"
