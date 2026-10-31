#!/bin/sh
# v0.23.52-dev structural + behavioral checks for thread-local storage (`tls`).
#
# There are two models this round, and the split is the whole point:
#
#   * a STATIC image (build-elf / build-pie / link-obj / link-pie) owns one
#     PT_TLS block for the process. main's entry stub points TPIDR_EL0 at its
#     base (ADRP/ADD __aster_tls_block -> MSR TPIDR_EL0), so an access is
#     LOCAL-EXEC: `MRS X16,TPIDR_EL0` then `ADD X16,X16,X17`, where X17 holds a
#     link-time constant the linker fills into a MOVZ/MOVK pair (kRelTlsOff).
#
#   * a SHARED OBJECT (build-so / link-so) has no base of its own — the loader
#     decides where this module's block sits. So an access is INITIAL-EXEC:
#     `MRS X16,TPIDR_EL0` / `ADRP X17,slot` / `ADD X17,X17,#lo12` / `LDR X17,
#     [X17]` / `ADD X16,X16,X17`, and the slot is filled at load time by one
#     R_AARCH64_TLS_TPREL64 (1030) per variable, with the block offset in its
#     addend and STN_UNDEF as its symbol — the form GNU ld emits for a local
#     `static __thread` under -ftls-model=initial-exec (read off this machine).
#     The slot holds an offset from TP, never an address: the ADD is what proves
#     it, and it is what makes each dlopen'd thread get its own copy.
#
# The block is two sections now, not one: non-zero initializers go in .tdata
# (SHT_PROGBITS), zero-initialized ones in .tbss (SHT_NOBITS), and .tbss starts
# at the first block-aligned offset past .tdata — the .data/.bss split applied
# to the per-thread block, which is what GNU ld does. PT_TLS reports
# p_filesz = .tdata and p_memsz = the whole block; the difference is .tbss, and
# a loader zeroes it per thread. There is **no compile-time cap** on the block
# size: glibc 2.35+ allocates a dlopen'd module's block dynamically (a megabyte
# dlopens cleanly here), and the loader still reports "cannot allocate memory in
# static TLS block" at load time if it genuinely cannot — a fixed surplus
# constant would only reject modules that load fine, while staying blind to the
# host process's own TLS footprint at compile time.
#
# `tls` is a *context keyword* — only special at the start of a top-level
# declaration — so it stays a usable identifier elsewhere and is absent from the
# reserved-word list. The reserved-word count is 27 since v0.23.61-dev added
# `enum` as a genuine reserved word; see docs/language-reference.md §2.
#
# Layers (the project 9-layer shape): strict build, source guards, parse
# acceptance, static-image ELF structure, the two access models' relocations,
# independent readers, the rejection matrix, qemu self-checks plus a dlopen
# witness from three threads (scalars AND tls arrays), and mutations that prove
# the suite can still fail.
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-tls-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
RUNNER=${RUNNER:-tests/run-aarch64.sh}
# The dlopen witness needs a C compiler that emits AArch64 for the *target*,
# not the host: the host program is executed through RUNNER.
if [ -n "${HOSTCC:-}" ]; then :
elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then HOSTCC=aarch64-linux-gnu-gcc
else HOSTCC=cc; fi
if [ -n "${OBJDUMP:-}" ]; then :
elif command -v aarch64-linux-gnu-objdump >/dev/null 2>&1; then OBJDUMP=aarch64-linux-gnu-objdump
else OBJDUMP=objdump; fi
fail(){ echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. strict build
printf '%s\n' '[1/9] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
A="$OUT/aster"

# ---------------------------------------------------------------- 2. source guards
printf '%s\n' '[2/9] Source guard: both access models, .tbss, PT_TLS'
# A regression that drops the `tls` context keyword, either access shape, the
# .tdata/.tbss split, or the PT_TLS segment must fail here first, before any
# behavioral check runs.
grep -qF 'if(cur().k==TK::Ident&&cur().s=="tls"){' src/aster.cpp \
    || fail "the tls context keyword is missing from the top-level declaration parser"
grep -qF 'need(TK::Let,"expected '"'"'let'"'"' after '"'"'tls'"'"'");' src/aster.cpp \
    || fail "tls no longer requires a following let"
# kRelTlsOff must be 4096 — the internal relocation type. 1024 collides with the
# ELF-standard R_AARCH64_COPY and made readelf mislabel the fill.
grep -qF 'static constexpr uint32_t kRelTlsOff=4096;' src/aster.cpp \
    || fail "kRelTlsOff is not 4096 (a collision with R_AARCH64_COPY crept back in)"
# Local-exec: MRS X16,TPIDR_EL0 (0xd53bd050) then ADD X16,X16,X17.
grep -qF 'emit(0xd53bd050u);' src/aster.cpp \
    || fail "the TPIDR_EL0 read (MRS X16,TPIDR_EL0) is missing from a TLS access"
grep -qF 'emit(0x8b110210u);' src/aster.cpp \
    || fail "the ADD X16,X16,X17 that both models end with is missing"
# The entry stub: ADRP X17,__aster_tls_block / ADD / MSR TPIDR_EL0,X17 (0xd51bd051).
grep -qF 'emit(0xd51bd051u);' src/aster.cpp \
    || fail "the entry stub does not set TPIDR_EL0 (MSR TPIDR_EL0,X17 missing)"
grep -qF 'relocations.push_back({uint64_t(adrp)*4,"__aster_tls_block",kRelAdrp});' src/aster.cpp \
    || fail "the entry stub no longer addresses __aster_tls_block"
# Initial-exec: ADRP/ADD/#lo12 into X17, LDR X17,[X17] — the GOT slot the loader fills.
grep -qF 'emit(0x90000011u);' src/aster.cpp \
    || fail "the initial-exec ADRP X17,slot is missing from the shared-object access"
grep -qF 'emit(0x91000231u);' src/aster.cpp \
    || fail "the initial-exec ADD X17,X17,#lo12:slot is missing"
grep -qF 'emit(0xf9400231u);' src/aster.cpp \
    || fail "the initial-exec LDR X17,[X17] is missing (the slot holds an offset, not an address)"
grep -qF 'static constexpr uint32_t kRelTlsTprel=1030;' src/aster.cpp \
    || fail "R_AARCH64_TLS_TPREL64 (1030) is no longer a named relocation type"
grep -qF 'static constexpr uint64_t kTlsBlockAlign=16;' src/aster.cpp \
    || fail "kTlsBlockAlign is not 16 — .tbss no longer starts at the block-aligned end of .tdata"
# The static writer's PT_TLS and the shared writers' PT_TLS, and the two sections.
grep -qF 'Phdr tl{};if(hasTlsSection){tl.type=7;' src/aster.cpp \
    || fail "writeElfBytes no longer emits a PT_TLS program header (type 7)"
grep -qF 'Phdr ptls{};if(hasTls){ptls.type=7;' src/aster.cpp \
    || fail "the shared-object writers no longer emit a PT_TLS program header (type 7)"
grep -qF 'e.type=1;e.flags=0x1|0x2|0x400;e.addr=tlsVaddr;' src/aster.cpp \
    || fail "the .tdata section is not SHF_WRITE|SHF_ALLOC|SHF_TLS (0x1|0x2|0x400)"
grep -qF 'e.type=8;e.flags=0x1|0x2|0x400;' src/aster.cpp \
    || fail "the .tbss section is not SHT_NOBITS with SHF_WRITE|SHF_ALLOC|SHF_TLS"
# The kRelTlsOff fill must subtract the PT_TLS base (block-relative offset).
grep -qF 'const uint32_t val=uint32_t((target-tlsVaddr)&0xffffffffu);' src/aster.cpp \
    || fail "kRelTlsOff no longer fills the block-relative offset (target-tlsVaddr)"
# What a shared object still refuses: an `extern tls let`, which has no way to
# name another module's thread-local through .dynsym.
grep -qF 'is not supported in a shared object: global' src/aster.cpp \
    || fail "build-so no longer rejects an external tls global with a clear diagnostic"

# ---------------------------------------------------------------- 3. parse acceptance
printf '%s\n' '[3/9] Parse acceptance: tls globals, and tls stays a usable identifier'
cat > "$OUT/ok.ast" <<'AST'
tls let counter: i32 = 7;
tls let table: i32[4] = 0;
tls let flag: i32 = 0;
fn main() -> i32 {
    let tls: i32 = 5;      // `tls` is a context keyword: still an ordinary name here
    counter = counter + tls;
    table[3] = counter;
    return counter + table[3] + flag;
}
AST
"$A" build-elf "$OUT/ok.ast" -o "$OUT/ok" >/dev/null \
    || fail "a tls global (scalar and array, initialized and not) plus a local named tls must compile"
# `tls` must still be absent from the reserved-word list: it is a context
# keyword, not a reserved word. The authoritative list is
# bootstrap/gen_lexer_names.py's KEYWORDS (the generator asserts its own length
# is 27 since v0.23.61-dev added `enum`); `tls` must be absent from it.
python3 - <<'PY' || exit 1
import re
src = open('bootstrap/gen_lexer_names.py').read()
m = re.search(r'KEYWORDS = \[(.*?)\]', src, re.S)
entries = re.findall(r'\("([^"]+)",', m.group(1))
assert len(entries) == 27, ('reserved-word count moved', len(entries), entries)
assert 'tls' not in entries, 'tls became a reserved word — it must stay a context keyword'
print('PASS: 27 reserved words, tls absent (context keyword)')
PY

# ---------------------------------------------------------------- 4. static structure
printf '%s\n' '[4/9] Static image: PT_TLS filesz/memsz, .tdata WAT, .tbss NOBITS WAT'
# a=10 and b=20 are initialized, so they land in .tdata; `zero` is not, so it
# lands in .tbss — which starts at the first 16-byte-aligned offset past .tdata.
cat > "$OUT/split.ast" <<'AST'
tls let a: i32 = 10;
tls let b: i32 = 20;
tls let zero: i32 = 0;
fn main() -> i32 {
    a = a + 5;
    b = b * 2;
    return a + b + zero;
}
AST
"$A" build-elf "$OUT/split.ast" -o "$OUT/split.elf" >/dev/null
python3 - "$OUT/split.elf" <<'PY' || exit 1
import struct, sys
b = open(sys.argv[1], 'rb').read()
assert b[:6] == b'\x7fELF\x02\x01'
phoff = struct.unpack_from('<Q', b, 32)[0]
phentsize, phnum = struct.unpack_from('<HH', b, 54)
segs = [struct.unpack_from('<IIQQQQQQ', b, phoff + i*phentsize) for i in range(phnum)]
tls = [s for s in segs if s[0] == 7]
assert len(tls) == 1, ('expected exactly one PT_TLS segment', [hex(s[0]) for s in segs])
t = tls[0]
assert t[1] & 0x6 == 0x6, ('PT_TLS must be RW', hex(t[1]))
# 8 bytes of initializers, then .tbss to a 16-byte-aligned 0x10, so the block is 0x14.
assert t[5] == 8, ('PT_TLS filesz must be the .tdata part', t[5])
assert t[6] == 0x14, ('PT_TLS memsz must be the whole block (.tdata + .tbss)', hex(t[6]))
assert t[6] > t[5], 'a .tbss part must make memsz exceed filesz'
shoff = struct.unpack_from('<Q', b, 40)[0]
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*shentsize) for i in range(shnum)]
shstr = raw[shstrndx]; names = b[shstr[4]:shstr[4]+shstr[5]]
def nm(s): return names[s[0]:names.index(b'\0', s[0])].decode()
sec = {nm(s): s for s in raw}
td, tb = sec['.tdata'], sec['.tbss']
assert td[1] == 1, '.tdata must be SHT_PROGBITS'
assert td[2] == (0x1 | 0x2 | 0x400), ('.tdata must be WAT', hex(td[2]))
assert td[3] == t[3], ('.tdata addr must equal PT_TLS vaddr', hex(td[3]), hex(t[3]))
assert td[5] == t[5], '.tdata size must equal PT_TLS filesz'
assert tb[1] == 8, '.tbss must be SHT_NOBITS'
assert tb[2] == (0x1 | 0x2 | 0x400), ('.tbss must be WAT', hex(tb[2]))
assert tb[3] == td[3] + 0x10, ('.tbss must start at the block-aligned end of .tdata', hex(tb[3]))
assert tb[5] == 4, ('.tbss holds `zero` alone', tb[5])
blob = b[td[4]:td[4]+td[5]]
vals = struct.unpack_from('<%di' % (td[5]//4), blob, 0)
assert vals == (10, 20), ('the tls initializers are missing from .tdata', vals)
print('PASS: PT_TLS 0x8/0x14, .tdata WAT (a=10,b=20), .tbss NOBITS WAT at +0x10')
PY

# A TLS block followed by an ordinary .bss: the .bss section and its symbols
# must land inside the same RW PT_LOAD, past p_filesz. A units mistake in the
# static writer (treating a file offset as an address) puts them at 0x2004
# instead of 0x402004: still mapped by luck in one test, but outside the
# segment's declared range and wrong for every symbol consumer.
cat > "$OUT/tlsbss.ast" <<'AST'
tls let t: i32 = 3;
let big: i32[1000] = 0;
fn main() -> i32 {
    big[123] = 7;
    return t + big[123] - 7;
}
AST
"$A" build-elf "$OUT/tlsbss.ast" -o "$OUT/tlsbss.elf" >/dev/null
python3 - "$OUT/tlsbss.elf" <<'PY' || exit 1
import struct, sys
b = open(sys.argv[1], 'rb').read()
phoff = struct.unpack_from('<Q', b, 32)[0]
phentsize, phnum = struct.unpack_from('<HH', b, 54)
segs = [struct.unpack_from('<IIQQQQQQ', b, phoff + i*phentsize) for i in range(phnum)]
loads = [s for s in segs if s[0] == 1 and (s[1] & 0x2)]
assert len(loads) == 1, ('expected one RW PT_LOAD', loads)
rw = loads[0]
shoff = struct.unpack_from('<Q', b, 40)[0]
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*shentsize) for i in range(shnum)]
shstr = raw[shstrndx]; names = b[shstr[4]:shstr[4]+shstr[5]]
def nm(s): return names[s[0]:names.index(b'\0', s[0])].decode()
sec = {nm(s): s for s in raw}
bs = sec['.bss']
assert bs[5] == 4000, ('expected 1000 i32 of .bss', bs[5])
assert rw[3] <= bs[3] and bs[3] + bs[5] <= rw[3] + rw[6], \
    ('the .bss must be inside the RW PT_LOAD', hex(bs[3]), hex(rw[3]), hex(rw[6]))
# The symbol's address must agree with the section it lives in, not with a
# file offset that happens to look plausible.
sym = sec['.symtab']; strs = sec['.strtab']
for off in range(24, sym[5], 24):
    n, info, other, shndx, val, size = struct.unpack_from('<IBBHQQ', b, sym[4] + off)
    end = b.index(b'\0', strs[4] + n)
    if b[strs[4]+n:end].decode() == 'big':
        assert raw[shndx][0] == bs[0], ('symbol big must live in .bss', shndx)
        assert val == bs[3], ('symbol big must name the .bss address', hex(val), hex(bs[3]))
        break
else:
    raise SystemExit('symbol big is missing')
print('PASS: a TLS block plus 4000-byte .bss keeps .bss and its symbols inside the RW PT_LOAD')
PY

# ---------------------------------------------------------------- 5. the two models
printf '%s\n' '[5/9] The relocations: kRelTlsOff (local-exec) and TLS_TPREL64 (initial-exec)'
"$A" build-obj "$OUT/split.ast" -o "$OUT/split.o" >/dev/null
python3 - "$OUT/split.o" <<'PY' || exit 1
import struct, sys
b = open(sys.argv[1], 'rb').read()
assert b[:6] == b'\x7fELF\x02\x01'
shoff = struct.unpack_from('<Q', b, 40)[0]
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*shentsize) for i in range(shnum)]
shstr = raw[shstrndx]; names = b[shstr[4]:shstr[4]+shstr[5]]
def nm(s): return names[s[0]:names.index(b'\0', s[0])].decode()
sec = {nm(s): s for s in raw}
sym, st = sec['.symtab'], sec['.strtab']
strs = b[st[4]:st[4]+st[5]]
def symname(i):
    o = struct.unpack_from('<I', b, sym[4]+i*24)[0]
    return strs[o:].split(b'\0')[0].decode()
# A relocatable object stores a symbol's value relative to its own section, the
# way gcc does (`__thread int a = 7; __thread int b;` gives a at 0 in .tdata and
# b at 0 in .tbss) — so `zero`, the only .tbss variable, sits at 0 here.
tlsvals = {}
for i in range(sym[5] // 24):
    base = sym[4] + i*24
    n = struct.unpack_from('<I', b, base)[0]
    shndx = struct.unpack_from('<H', b, base + 6)[0]
    val = struct.unpack_from('<Q', b, base + 8)[0]
    name = strs[n:].split(b'\0')[0].decode()
    if name.startswith('__aster_tls_'): tlsvals[name] = (shndx, val)
assert tlsvals['__aster_tls_zero'][1] == 0, ('.tbss offsets must be section-relative', tlsvals)
KRELTLSOFF = 4096
seen = {}
for off in range(sec['.rela.text'][4], sec['.rela.text'][4]+sec['.rela.text'][5], 24):
    r_off, r_info, r_add = struct.unpack_from('<QQq', b, off)
    if (r_info & 0xffffffff) == KRELTLSOFF:
        seen[symname(r_info >> 32)] = r_off
for want in ('__aster_tls_a', '__aster_tls_b', '__aster_tls_zero'):
    assert want in seen, ('no kRelTlsOff relocation for', want, sorted(seen))
print('PASS: kRelTlsOff names __aster_tls_a/b/zero; .tbss offsets are section-relative')
PY
# The shared object: one TPREL64 per thread-local, sym 0 (STN_UNDEF), addend the
# block offset — and .tbss's 0x10 is what proves the addend is a block offset.
"$A" build-so examples/so_tls_demo.ast -o "$OUT/demo.so" >/dev/null
"$A" build-obj --pic examples/so_tls_demo.ast -o "$OUT/demo.o" >/dev/null
"$A" link-so "$OUT/demo.o" -o "$OUT/demo-linked.so" >/dev/null
python3 - "$OUT/demo.so" "$OUT/demo-linked.so" <<'PY' || exit 1
import struct, sys
for path in sys.argv[1:]:
    b = open(path, 'rb').read()
    assert b[:6] == b'\x7fELF\x02\x01'
    phoff = struct.unpack_from('<Q', b, 32)[0]
    phentsize, phnum = struct.unpack_from('<HH', b, 54)
    segs = [struct.unpack_from('<IIQQQQQQ', b, phoff + i*phentsize) for i in range(phnum)]
    tls = [s for s in segs if s[0] == 7]
    assert len(tls) == 1, ('expected exactly one PT_TLS per .so', path)
    t = tls[0]
    assert t[5] == 16 and t[6] == 0x20, ('PT_TLS must be 0x10/0x20', path, t[5], hex(t[6]))
    shoff = struct.unpack_from('<Q', b, 40)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
    raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*shentsize) for i in range(shnum)]
    shstr = raw[shstrndx]; names = b[shstr[4]:shstr[4]+shstr[5]]
    def nm(s): return names[s[0]:names.index(b'\0', s[0])].decode()
    sec = {nm(s): s for s in raw}
    assert sec['.tdata'][1] == 1 and sec['.tdata'][2] == (0x1|0x2|0x400), ('.tdata', path)
    assert sec['.tbss'][1] == 8 and sec['.tbss'][2] == (0x1|0x2|0x400) and sec['.tbss'][5] == 16, ('.tbss', path)
    assert sec['.tbss'][3] == sec['.tdata'][3] + 0x10, ('.tbss must follow .tdata', path)
    rela = sec['.rela.dyn']
    tp = []
    for off in range(rela[4], rela[4]+rela[5], 24):
        r_off, r_info, r_add = struct.unpack_from('<QQq', b, off)
        if (r_info & 0xffffffff) == 1030: tp.append((r_info >> 32, r_add))
    assert len(tp) == 5, ('expected one TPREL64 per thread-local (scalars + 2 arrays)', path, len(tp))
    assert all(sym == 0 for sym, _ in tp), ('TPREL64 must reference STN_UNDEF', path, tp)
    # hits at 0, total at 4, acc (i32[2] base) at 8, spare at 0x10, zeros
    # (i32[3] base) at 0x14 — each TPREL is the array's base, not per element.
    assert sorted(a for _, a in tp) == [0, 4, 8, 0x10, 0x14], ('addends must be block offsets', path, tp)
print('PASS: both .so writers carry 5 TPREL64 (sym 0, addends 0 / 4 / 8 / 0x10 / 0x14)')
PY

# ---------------------------------------------------------------- 6. independent readers
printf '%s\n' '[6/9] Independent readers (readelf, objdump) agree on the segments and the code'
if command -v readelf >/dev/null 2>&1 && readelf -h "$OUT/split.elf" >/dev/null 2>&1; then
    readelf -lW "$OUT/split.elf" > "$OUT/ph.txt"
    [ "$(grep -Ec '^[[:space:]]*TLS[[:space:]]+0x' "$OUT/ph.txt")" = 1 ] \
        || fail "readelf -l does not show exactly one TLS segment"
    readelf -SW "$OUT/split.elf" > "$OUT/sh.txt"
    grep -Eq '\.tdata[[:space:]]+PROGBITS.*[[:space:]]WAT([[:space:]]|$)' "$OUT/sh.txt" \
        || fail "readelf -S does not show .tdata as WAT (write, alloc, TLS)"
    grep -Eq '\.tbss[[:space:]]+NOBITS.*[[:space:]]WAT([[:space:]]|$)' "$OUT/sh.txt" \
        || fail "readelf -S does not show .tbss as NOBITS WAT"
    readelf -sW "$OUT/split.o" > "$OUT/sym.txt"
    for s in __aster_tls_block __aster_tls_a __aster_tls_b __aster_tls_zero; do
        grep -q "$s" "$OUT/sym.txt" || fail "readelf -s is missing $s"
    done
    printf '  %-40s %s\n' 'readelf: TLS segment, WAT .tdata/.tbss, symbols' 'agree'
else
    printf '  %-40s %s\n' 'readelf' 'skipped (not usable); python readers above cover this'
fi
if "$OBJDUMP" -d "$OUT/demo.so" >/dev/null 2>&1; then
    "$OBJDUMP" -d "$OUT/demo.so" > "$OUT/dis.txt"
    # The initial-exec shape, in order: MRS, ADRP, ADD (lo12), LDR, ADD — the
    # last ADD is what says the slot holds an offset from TP, not an address.
    python3 - "$OUT/dis.txt" <<'PY' || exit 1
import re, sys
rows = re.findall(r'^\s*[0-9a-f]+:\s+([0-9a-f]{8})\s+(\S+)', open(sys.argv[1]).read(), re.M)
ops = [o for _, o in rows]
want = ['mrs', 'adrp', 'add', 'ldr', 'add']
found = any(ops[i:i+5] == want for i in range(len(ops) - 4))
assert found, 'the initial-exec sequence (mrs/adrp/add/ldr/add) is not in the .so text'
print('PASS: objdump shows the initial-exec sequence (MRS, ADRP, ADD, LDR, ADD)')
PY
    printf '  %-40s %s\n' 'objdump: initial-exec instruction sequence' 'agree'
else
    printf '  %-40s %s\n' 'objdump' 'skipped (no AArch64 objdump)'
fi

# ---------------------------------------------------------------- 7. rejection matrix
printf '%s\n' '[7/9] Rejection matrix: extern tls still refused; a large block builds and stays well-formed'
# `extern tls let` — a shared object has no way to name another module's
# thread-local, so it is still refused (a plain `tls let` is not).
cat > "$OUT/ext.ast" <<'AST'
tls extern let other: i32;
fn use() -> i32 { return other; }
AST
if "$A" build-so "$OUT/ext.ast" -o "$OUT/ext.so" >"$OUT/rej1.txt" 2>&1; then
    fail "build-so accepted an external tls global; it must reject it"
fi
grep -q 'external thread-local (`extern tls let`) is not supported in a shared object' "$OUT/rej1.txt" \
    || fail "build-so's rejection message is not the documented one: $(cat "$OUT/rej1.txt")"
# There is no compile-time cap on the block size (glibc allocates a dlopen'd
# module's block dynamically), so a large block must BUILD and stay well-formed
# — its PT_TLS segment present and its PT_TLS memsz covering the whole block
# (.tdata + .tbss). 500 i32 = 2000 bytes is the writer-exercise case.
cat > "$OUT/big.ast" <<'AST'
tls let big: i32[500] = 0;
fn bump() -> i32 { big[0] = big[0] + 1; return big[0]; }
AST
"$A" build-so "$OUT/big.ast" -o "$OUT/big.so" >/dev/null \
    || fail "a 2000-byte TLS block must still build (no compile-time surplus cap)"
python3 - "$OUT/big.so" <<'PY' || exit 1
import struct, sys
b = open(sys.argv[1], 'rb').read()
phoff = struct.unpack_from('<Q', b, 32)[0]
phentsize, phnum = struct.unpack_from('<HH', b, 54)
segs = [struct.unpack_from('<IIQQQQQQ', b, phoff + i*phentsize) for i in range(phnum)]
tls = [s for s in segs if s[0] == 7]
assert len(tls) == 1 and tls[0][6] >= 2000, ('large block PT_TLS missing/short', tls)
print('PASS: a 2000-byte TLS block builds with a full-size PT_TLS')
PY
# A plain (non-tls) program is unaffected and still builds as a .so.
cat > "$OUT/plain.ast" <<'AST'
let g: i32 = 3;
fn bump() -> i32 { g = g + 1; return g; }
AST
"$A" build-so "$OUT/plain.ast" -o "$OUT/plain.so" >/dev/null \
    || fail "a non-tls program must still build as a shared object"
printf '  %-40s %s\n' 'extern tls refused; large block builds + well-formed; plain .so fine' 'ok'

# ---------------------------------------------------------------- 8. qemu self-check
printf '%s\n' '[8/9] qemu self-check: the static block, and a dlopen witness from 3 threads'
can_run=no
if [ "$(uname -m)" = aarch64 ] || command -v qemu-aarch64 >/dev/null 2>&1; then
    can_run=yes
fi
if [ "$can_run" = yes ]; then
    # a = 10+5 = 15, b = 20*2 = 40, zero = 0, exit = 55 — every value round-trips
    # through the per-thread block, so a wrong TPIDR_EL0 base is caught, and a
    # .tbss that was not zeroed would add to it.
    for m in build-elf build-pie "build-elf -g"; do
        tag=$(echo "$m" | tr ' ' '_')
        "$A" $m "$OUT/split.ast" -o "$OUT/tls.$tag" >/dev/null
        set +e
        "$PWD/$RUNNER" "$OUT/tls.$tag" >"$OUT/out.$tag" 2>&1; rc=$?
        set -e
        [ "$rc" = 55 ] || fail "$m: the TLS program exited $rc, expected 55 (a=15,b=40,zero=0)"
    done
    printf '  %-40s %s\n' 'qemu: build-elf/build-pie/-g all exit 55' 'ok'
else
    printf '  %-40s %s\n' 'qemu: read/write the TLS block' 'skipped (no runner)'
fi
if [ "$can_run" = yes ] && command -v "$HOSTCC" >/dev/null 2>&1 \
   && echo 'int main(){return 0;}' | "$HOSTCC" -x c - -o "$OUT/probe" 2>/dev/null; then
    "$HOSTCC" -O2 -o "$OUT/so-tls-host" tests/so-tls-host.c -ldl -lpthread
    # The dlopen trio, three times over: a scalar (bump: 33 then 36), a mutable
    # .tdata array (accsum: 13 then 16) and a mutable .tbss array (zerosum: 1
    # then 2). Each runs on the main thread twice and on each of two pthreads;
    # every one of those six calls must match, so the block is per-thread for
    # scalars AND arrays alike. A shared block would make the later threads
    # continue where the main thread left off (39, 42, ... or 19, 22, ...).
    for lib in "$OUT/demo.so" "$OUT/demo-linked.so"; do
        for trip in "bump 33 36" "accsum 13 16" "zerosum 1 2"; do
            set +e
            out=$("$PWD/$RUNNER" "$OUT/so-tls-host" "$lib" $trip 2>&1); rc=$?
            set -e
            [ "$rc" = 0 ] || fail "dlopen witness failed for $lib $trip (rc=$rc): $out"
            printf '%s\n' "$out" | grep -q 'PASS: every thread got its own block' \
                || fail "the dlopen witness did not report per-thread state for $lib $trip: $out"
        done
    done
    printf '  %-40s %s\n' 'dlopen: scalars + tls arrays per-thread (3 syms x 2 libs)' 'ok'
else
    printf '  %-40s %s\n' 'dlopen witness' 'skipped (no AArch64 host toolchain)'
fi

# ---------------------------------------------------------------- 9. the suite can still fail
printf '%s\n' '[9/9] The suite can still fail (two mutations)'
# (a) Halve the local-exec offset fill: layer 8 must notice (wrong value ->
# wrong exit code), and so must the static structural layers.
sed 's|const uint32_t val=uint32_t((target-tlsVaddr)\&0xffffffffu);|const uint32_t val=uint32_t(((target-tlsVaddr)/2)\&0xffffffffu);|' \
    src/aster.cpp > "$OUT/mutant.cpp"
grep -q '((target-tlsVaddr)/2)' "$OUT/mutant.cpp" \
    || fail "the local-exec mutation stopped applying — the [9/9] guard is stale"
${CXX:-c++} -std=c++17 -O2 "$OUT/mutant.cpp" -o "$OUT/mutant" 2>/dev/null \
    || fail "the local-exec mutation no longer compiles"
if [ "$can_run" = yes ]; then
    "$OUT/mutant" build-elf "$OUT/split.ast" -o "$OUT/mut.elf" >/dev/null 2>&1
    set +e
    "$PWD/$RUNNER" "$OUT/mut.elf" >/dev/null 2>&1; mrc=$?
    set -e
    [ "$mrc" != 55 ] || fail "the halved-offset mutation still exited 55 — the suite is not really checking the offset"
    printf '  %-40s %s\n' "mutation a) local-exec offset halved (exited $mrc)" 'noticed'
else
    printf '  %-40s %s\n' 'mutation a) local-exec offset halved' 'skipped (no runner)'
fi
# (b) Drop the TCB/block distinction the other way round: make the initial-exec
# addend a plain 0 for every thread-local, so all three slots hold the same
# offset. Layer 5 catches it exactly (sorted addends 0/0/0, not 0/4/0x10).
sed 's|r.info=kRelTlsTprel;r.addend=(int64_t)tlsGlobals\[i\].offset;|r.info=kRelTlsTprel;r.addend=0;|' \
    src/aster.cpp > "$OUT/mutant2.cpp"
grep -q 'r.info=kRelTlsTprel;r.addend=0;' "$OUT/mutant2.cpp" \
    || fail "the initial-exec mutation stopped applying — the [9/9] guard is stale"
${CXX:-c++} -std=c++17 -O2 "$OUT/mutant2.cpp" -o "$OUT/mutant2" 2>/dev/null \
    || fail "the initial-exec mutation no longer compiles"
"$OUT/mutant2" build-so examples/so_tls_demo.ast -o "$OUT/mut2.so" >/dev/null 2>&1
if python3 - "$OUT/mut2.so" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
shoff = struct.unpack_from('<Q', b, 40)[0]
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*shentsize) for i in range(shnum)]
shstr = raw[shstrndx]; names = b[shstr[4]:shstr[4]+shstr[5]]
def nm(s): return names[s[0]:names.index(b'\0', s[0])].decode()
rela = [s for s in raw if nm(s) == '.rela.dyn'][0]
adds = []
for off in range(rela[4], rela[4]+rela[5], 24):
    r_off, r_info, r_add = struct.unpack_from('<QQq', b, off)
    if (r_info & 0xffffffff) == 1030: adds.append(r_add)
sys.exit(0 if sorted(adds) == [0, 4, 8, 0x10, 0x14] else 1)
PY
then
    fail "the zeroed-addend mutation still wrote block offsets — layer 5 is not really checking it"
fi
printf '  %-40s %s\n' 'mutation b) every TPREL64 addend zeroed' 'noticed'
echo "PASS: all v0.23.52-dev thread-local-storage checks"
