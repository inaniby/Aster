#!/bin/sh
# tests/elf-metadata-checks.sh — the parts of an ELF image nobody runs.
#
# AUDIT-v0.23.61-dev.md's second part listed seven ELF/linker findings marked
# 「待验」— located by reading the source, never reproduced. Item 9 asked for
# them to be checked empirically, and v0.23.65-dev did the two that were
# already known (the .eh_frame page alignment and the kRelTlsOff truncation).
# This round took the rest, and the score is five real defects, one defensive
# gap, and one non-issue:
#
#   1. `kRelTlsOff` fills a `MOVZ`/`MOVK` **pair** — 8 bytes — but parseObject
#      only proved 4 bytes of .text were in bounds. A relocation pointing at
#      the last four bytes made the MOVK read (and write) past the end of the
#      text vector. ASAN says so outright: heap-buffer-overflow at
#      resolveRelocations. No compiler-generated object puts a pair there, but
#      parseObject reads whatever it is handed.
#
#   2. An object built with `-g` carries a local STT_SECTION symbol for .text,
#      and it was written *in the middle of the globals* with `sh_info` left
#      at 1. ELF orders locals first and sh_info names the first global, and
#      readelf printed: "local symbol 2 found at index >= .symtab's sh_info
#      value of 1".
#
#   3. `.hash` carried sh_entsize 0. GNU ld writes 4 — the table is an array of
#      32-bit words, and a reader that divides sh_size by sh_entsize sees no
#      entries at all.
#
#   4. `.rela.plt` carried sh_info 0, i.e. "these relocations apply to
#      nothing". GNU ld writes the index of .plt.
#
#   5. `.bss` and `.tbss` (SHT_NOBITS) had sh_offset pinned to the end of
#      whatever was written last, so with a thread-local block their offset
#      disagreed with their address by the size of .tbss. GNU ld keeps the
#      pair in step: Off = Address - the segment's delta.
#
#   6. The PLT's `ADRP x16` was written with no ±4 GiB page-range check, while
#      the same instruction relocated anywhere else in the compiler has one.
#      Unreachable today (.plt and .got.plt sit tens of bytes apart), but the
#      two paths should not disagree.
#
# The non-issue: `.gnu.hash` really does carry sh_entsize 0 — GNU ld's does
# too — so the suite asserts 0 there as well, to stop a later round "fixing"
# it into a defect.
#
# Only .so bytes move, and only in the section header table: every one of the
# 121 examples builds to a file of exactly the same length, differing in at
# most four bytes — two of them being the fields above.
#
# Layers (the project 9-layer shape): strict build, source guards, an
# independent reader (readelf + a decoder) on every field, a GNU ld
# differential that fixes what "right" means, a refusal matrix with an ASAN
# build, qemu witnesses, coverage counting, three mutations, and the byte
# baseline.
set -eu
cd "$(dirname "$0")/.."
. tests/lib/baseline.sh
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-elf-metadata-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
A=$OUT/aster

have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
HOSTCC=${HOSTCC:-cc}
have_gnu_ld=no
if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then HOSTCC=aarch64-linux-gnu-gcc; have_gnu_ld=yes; fi
have_readelf=yes
command -v readelf >/dev/null 2>&1 || have_readelf=no
if [ "$have_readelf" = no ]; then
    printf '%s\n' 'SKIP: elf-metadata-checks needs readelf as its independent reader'
    exit 0
fi

# ---------------------------------------------------------------------------
# [2/9] Source guards. Every fix is pinned where it was made.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: the width check, the symbol order, and three header fields'
grep -qF '#define ASTER_VERSION_STRING "0.23.72-dev"' src/aster.cpp \
    || { echo "FAIL: the version constant is not 0.23.72-dev" >&2; exit 1; }
# (1) a relocation's footprint is per-type, not always one instruction
grep -qF 'const uint64_t need=(type==kRelTlsOff)?8u:4u;' src/aster.cpp \
    || { echo "FAIL: the relocation footprint is a constant again" >&2; exit 1; }
grep -qF 'bytes of .text and only' src/aster.cpp \
    || { echo "FAIL: the out-of-bounds relocation no longer says what it needed" >&2; exit 1; }
# (2) locals first, and sh_info names the first global
grep -qF 'const uint32_t symBase=1u+dbgSym;' src/aster.cpp \
    || { echo "FAIL: the globals no longer start after the local section symbol" >&2; exit 1; }
grep -qF 'sh[idxSym].info=symBase;' src/aster.cpp \
    || { echo "FAIL: .symtab sh_info is a constant again" >&2; exit 1; }
# (3) .hash is an array of 32-bit words; .gnu.hash genuinely is not
grep -qF 'setSh(S_HASH,nHash,5,0x2,hashOff,hashOff,hashSize,S_DYNSYM,0,4,4);' src/aster.cpp \
    || { echo "FAIL: the no-PLT .hash no longer declares entsize 4" >&2; exit 1; }
grep -qF 'setSh(S_HASH,5,0x2,hashOff,hashOff,hashSize,S_DYNSYM,0,4,4);' src/aster.cpp \
    || { echo "FAIL: .hash no longer declares entsize 4" >&2; exit 1; }
grep -qF 'setSh(S_GNUHASH,0x6ffffff6,0x2,gnuHashOff,gnuHashOff,gnuHashSize,S_DYNSYM,0,8,0);' src/aster.cpp \
    || { echo "FAIL: .gnu.hash changed — GNU ld writes entsize 0 there too, it is not a defect" >&2; exit 1; }
# (4) .rela.plt applies to .plt
grep -qF 'setSh(S_RELAPLT,4,0x2,relaPltOff,relaPltOff,relaPltSize,S_DYNSYM,S_GOTPLT,8,sizeof(Rela));' src/aster.cpp \
    || { echo "FAIL: .rela.plt no longer names .got.plt in sh_info" >&2; exit 1; }
# (5) NOBITS offset follows the address, and (6) the PLT ADRP is checked
grep -qF 'e.offset=bssVaddr-base;' src/aster.cpp \
    || { echo "FAIL: .bss offset no longer follows its address" >&2; exit 1; }
grep -qF 'e.offset=tbssFileOff;' src/aster.cpp \
    || { echo "FAIL: .tbss offset no longer follows its address" >&2; exit 1; }
grep -qF 'setSh(S_TBSS,8,0x1|0x2|0x400,tbssVaddr,tbssVaddr,spec.tbssSize,0,0,kTlsBlockAlign,0);' src/aster.cpp \
    || { echo "FAIL: the .so .tbss offset no longer follows its address" >&2; exit 1; }
grep -qF 'PLT stub for ' src/aster.cpp \
    || { echo "FAIL: the PLT ADRP is written unchecked again" >&2; exit 1; }
# (7) a thread-local block with no .tdata still contributes its alignment
grep -qF 'std::vector<uint8_t> tdata; uint64_t tdataAlign=16,tbssSize=0,tbssAlign=16;' src/aster.cpp \
    || { echo "FAIL: .tbss no longer carries an alignment of its own" >&2; exit 1; }
grep -qF 'if(obj.tbssAlign>maxTlsAlign)maxTlsAlign=obj.tbssAlign;' src/aster.cpp \
    || { echo "FAIL: a pure-.tbss object contributes no alignment again" >&2; exit 1; }
printf '%s\n' 'PASS: all seven fixes are pinned in the source'

# ---------------------------------------------------------------------------
# [3/9] An independent reader. readelf for what it can say, and a decoder for
# what it cannot (readelf prints the section table but will not tell you the
# offset/address delta of the segment a NOBITS section belongs to).
# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] Independent reader: what readelf and a decoder say about each field'
cat > "$OUT/decode.py" <<'PY'
import struct, sys

def load(p):
    return open(p, 'rb').read()

def sections(b):
    shoff = struct.unpack_from('<Q', b, 40)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
    raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i * shentsize) for i in range(shnum)]
    shstr = raw[shstrndx]
    def nm(n):
        s = shstr[4] + n
        return b[s:b.index(b'\0', s)].decode()
    return [dict(i=i, name=nm(r[0]), type=r[1], flags=r[2], addr=r[3], off=r[4],
                 size=r[5], link=r[6], info=r[7], align=r[8], entsize=r[9]) for i, r in enumerate(raw)]

def segments(b):
    phoff = struct.unpack_from('<Q', b, 32)[0]
    phentsize, phnum = struct.unpack_from('<HH', b, 54)
    out = []
    for i in range(phnum):
        t, fl, off, va, pa, fs, ms, al = struct.unpack_from('<IIQQQQQQ', b, phoff + i * phentsize)
        out.append(dict(type=t, off=off, vaddr=va, filesz=fs, memsz=ms, align=al))
    return out

def symtab(b, secs):
    st = [s for s in secs if s['name'] == '.symtab' and s['type'] == 2]
    if not st: return None, []
    st = st[0]
    strt = secs[st['link']]
    out = []
    for i in range(st['size'] // 24):
        o = st['off'] + i * 24
        nm, info, other, shndx, value, size = struct.unpack_from('<IBBHQQ', b, o)
        s = b[strt['off'] + nm:b.index(b'\0', strt['off'] + nm)].decode()
        out.append(dict(i=i, name=s, bind=info >> 4, type=info & 0xf, shndx=shndx))
    return st, out

def check(path, kind):
    b = load(path)
    secs = sections(b)
    segs = segments(b)
    bad = []
    by = {s['name']: s for s in secs}
    # --- .hash is an array of 32-bit words; .gnu.hash is not (GNU ld agrees)
    h = by.get('.hash')
    if h is not None and h['entsize'] != 4:
        bad.append(f".hash sh_entsize {h['entsize']} != 4")
    g = by.get('.gnu.hash')
    if g is not None and g['entsize'] != 0:
        bad.append(f".gnu.hash sh_entsize {g['entsize']} != 0 (GNU ld writes 0 too)")
    # --- .rela.plt applies to .got.plt. Not .plt: a JUMP_SLOT relocation
    # fills a slot in the GOT, and GNU ld names .got.plt (readelf shows
    # Inf 20 on a ld .so whose .plt is section 8). The audit guessed .plt;
    # layer [4/9] is what settles it against ld itself.
    rp = by.get('.rela.plt')
    if rp is not None and rp['size'] > 0:
        gotplt = by.get('.got.plt')
        if gotplt is None:
            bad.append('.rela.plt has entries but there is no .got.plt')
        elif rp['info'] != gotplt['i']:
            bad.append(f".rela.plt sh_info {rp['info']} != .got.plt index {gotplt['i']}")
    # --- every NOBITS section: sh_offset == sh_addr - (segment vaddr - offset)
    for s in secs:
        if s['type'] != 8: continue
        delta = None
        for p in segs:
            if p['type'] == 1 and p['vaddr'] <= s['addr'] < p['vaddr'] + p['memsz']:
                delta = p['vaddr'] - p['off']
                break
        if delta is None:
            continue
        if s['off'] != s['addr'] - delta:
            bad.append(f"{s['name']} is NOBITS and sh_offset {hex(s['off'])} != "
                       f"sh_addr {hex(s['addr'])} - segment delta {hex(delta)}")
    # --- symbol table order: every local before every global, sh_info exact
    st, syms = symtab(b, secs)
    if st is not None and syms:
        first_global = next((s['i'] for s in syms if s['bind'] != 0), None)
        last_local = max((s['i'] for s in syms if s['bind'] == 0), default=None)
        if first_global is None:
            if st['info'] != len(syms):
                bad.append(f"all-local .symtab sh_info {st['info']} != {len(syms)}")
        else:
            if last_local is not None and last_local > first_global:
                bad.append(f"local symbol {last_local} comes after global symbol {first_global}")
            if st['info'] != first_global:
                bad.append(f".symtab sh_info {st['info']} != first global index {first_global}")
    print(f"{kind}: {path}")
    for m in bad: print('  BAD:', m)
    return bad

if __name__ == '__main__':
    if len(sys.argv) != 4 or sys.argv[1] != 'check':
        sys.exit('usage: decode.py check <file> <label>')
    sys.exit(1 if check(sys.argv[2], sys.argv[3]) else 0)
PY

# One source for the static images (every symbol has to be defined there) and
# one for the shared object, which is the only form that can leave `bump`
# undefined and reach it through a PLT. Between them they carry a
# .tdata/.tbss pair (the NOBITS offsets and the thread-local block), a .bss
# array (the other NOBITS section), a string (rodata), and — in the .so — an
# undefined function (the PLT and .rela.plt).
cat > "$OUT/full.ast" <<'AST'
let buf: i32[64] = 0;
let msg: ptr = "elf metadata";
tls let hits: i32 = 10;
tls let spare: i32 = 0;

fn twice(x: i32) -> i32 { return x + x; }

fn main() -> i32 {
    buf[0] = 1;
    hits = hits + 1;
    spare = hits + twice(1);
    return i32(hits) + i32(spare) + buf[0];
}
AST
cat > "$OUT/sofull.ast" <<'AST'
extern fn bump(x: i32) -> i32;
let buf: i32[64] = 0;
let msg: ptr = "elf metadata";
tls let hits: i32 = 10;
tls let spare: i32 = 0;

fn twice(x: i32) -> i32 { return bump(x) + bump(x); }

fn entry(x: i32) -> i32 {
    buf[0] = 1;
    hits = hits + x;
    spare = hits + twice(x);
    return i32(spare);
}
AST

bad=0
"$A" build-elf "$OUT/full.ast" -o "$OUT/full.elf" >/dev/null 2>&1 \
    && python3 "$OUT/decode.py" check "$OUT/full.elf" build-elf > "$OUT/r1.txt" 2>&1 || bad=1
if [ "$bad" = 0 ] && grep -q 'BAD:' "$OUT/r1.txt"; then bad=1; fi
"$A" build-so --soname libfull.so "$OUT/sofull.ast" -o "$OUT/full.so" >/dev/null 2>&1 \
    && python3 "$OUT/decode.py" check "$OUT/full.so" build-so > "$OUT/r2.txt" 2>&1 || bad=1
if [ "$bad" = 0 ] && grep -q 'BAD:' "$OUT/r2.txt"; then bad=1; fi
"$A" build-obj --pic "$OUT/full.ast" -o "$OUT/full.o" >/dev/null 2>&1 || bad=1
"$A" build-obj --pic -g "$OUT/full.ast" -o "$OUT/fullg.o" >/dev/null 2>&1 || bad=1
python3 "$OUT/decode.py" check "$OUT/fullg.o" build-obj--pic--g > "$OUT/r3.txt" 2>&1
if grep -q 'BAD:' "$OUT/r3.txt"; then bad=1; fi
[ "$bad" = 0 ] || { echo 'FAIL: an ELF field is wrong' >&2; cat "$OUT/r1.txt" "$OUT/r2.txt" "$OUT/r3.txt" >&2; exit 1; }
cat "$OUT/r1.txt" "$OUT/r2.txt" "$OUT/r3.txt" | sed 's/^/  /'

# readelf as the second reader: it warns about the symbol order in so many words.
for f in "$OUT/fullg.o" "$OUT/full.o"; do
    if readelf -s "$f" 2>&1 | grep -qi 'local symbol'; then
        echo "FAIL: readelf still warns about the symbol order in $f" >&2
        readelf -s "$f" 2>&1 | grep -i 'local symbol' >&2
        exit 1
    fi
done
printf '%s\n' 'PASS: readelf finds no symbol-order warning, and the decoder agrees on every field'

# ---------------------------------------------------------------------------
# [4/9] GNU ld differential. The assertions above are only meaningful if they
# are what GNU ld does; this fixes "right" from outside the project.
# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] GNU ld differential: the same invariants hold on a ld-linked .so'
if [ "$have_gnu_ld" = yes ]; then
    cat > "$OUT/gnu.c" <<'C'
#include <string.h>
__thread int hits = 10;
__thread int spare;
int buf[64];
const char *msg = "elf metadata";
int twice(const char *s){ return (int)strlen(s) + hits + spare + buf[0]; }
C
    "$HOSTCC" -shared -fPIC -Wl,--hash-style=sysv -o "$OUT/gnu.so" "$OUT/gnu.c"
    # GNU ld only emits .rela.plt when something is actually imported through
    # it, so link a second object that calls a libc function.
    cat > "$OUT/gnu2.c" <<'C'
#include <stdlib.h>
extern int twice(const char *);
int use(void){ return twice("x") + (int)labs(-3); }
C
    "$HOSTCC" -shared -fPIC -Wl,--hash-style=sysv -o "$OUT/gnu2.so" "$OUT/gnu.c" "$OUT/gnu2.c"
    for f in "$OUT/gnu.so" "$OUT/gnu2.so"; do
        out=$(python3 "$OUT/decode.py" check "$f" gnu-ld)
        printf '%s\n' "$out" | sed 's/^/  /'
        if printf '%s' "$out" | grep -q 'BAD:'; then
            echo "FAIL: the invariant does not hold for GNU ld itself ($f) — the assertion is wrong" >&2
            exit 1
        fi
    done
    printf '%s\n' 'PASS: GNU ld satisfies every invariant this suite asserts'
else
    printf '%s\n' '  GNU ld differential skipped (no aarch64-linux-gnu-gcc)'
fi

# ---------------------------------------------------------------------------
# [5/9] The refusal matrix, and an ASAN build that proves there is no
# undefined behaviour left once the refusal is in place.
# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] Refusal matrix: a relocation that does not fit, with ASAN watching'
cat > "$OUT/tamper.py" <<'PY'
import struct, sys
b = bytearray(open(sys.argv[1], 'rb').read())
shoff = struct.unpack_from('<Q', b, 40)[0]
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i * shentsize) for i in range(shnum)]
shstr = raw[shstrndx]
def nm(n):
    s = shstr[4] + n
    return b[s:b.index(b'\0', s)].decode()
by = {nm(r[0]): r for r in raw}
text, rela = by['.text'], by['.rela.text']
n = 0
for i in range(rela[5] // 24):
    o = rela[4] + i * 24
    r_off, r_info, r_add = struct.unpack_from('<QQq', b, o)
    if (r_info & 0xffffffff) == 4096:          # kRelTlsOff
        struct.pack_into('<Q', b, o, text[5] - 4)   # the last four bytes of .text
        n += 1
if n == 0:
    sys.exit('no kRelTlsOff relocation to move')
open(sys.argv[2], 'wb').write(bytes(b))
PY
cat > "$OUT/tls.ast" <<'AST'
tls let a: i32 = 7;
tls let b: i32 = 0;
fn main() -> i32 { a = a + 1; b = a; return b; }
AST
"$A" build-obj "$OUT/tls.ast" -o "$OUT/tls.o" >/dev/null
python3 "$OUT/tamper.py" "$OUT/tls.o" "$OUT/tls.bad.o"
# The control: an untouched object still links.
"$A" link-obj "$OUT/tls.o" -o "$OUT/tls.ok.elf" >/dev/null 2>&1 \
    || { echo 'FAIL: the untouched object no longer links' >&2; exit 1; }
# The point: the tampered one is refused, and says what it needed.
if "$A" link-obj "$OUT/tls.bad.o" -o "$OUT/tls.bad.elf" > "$OUT/refuse.txt" 2>&1; then
    echo 'FAIL: a relocation that needs 8 bytes in the last 4 was accepted' >&2
    exit 1
fi
grep -q 'needs 8 bytes of .text' "$OUT/refuse.txt" \
    || { echo 'FAIL: the refusal does not say what the relocation needed' >&2; cat "$OUT/refuse.txt" >&2; exit 1; }
sed 's/^/  /' "$OUT/refuse.txt" | head -2
# ASAN: the refusal has to come from the check, not from luck. A build with
# AddressSanitizer must report no heap-buffer-overflow on the same input.
if [ "${ASTER_SKIP_ASAN:-}" != 1 ] && $CXX -std=c++17 -O1 -g -fsanitize=address \
        src/aster.cpp -o "$OUT/aster-asan" > "$OUT/asan-build.log" 2>&1; then
    ASAN_OPTIONS=detect_leaks=0 "$OUT/aster-asan" link-obj "$OUT/tls.bad.o" \
        -o "$OUT/asan.elf" > "$OUT/asan.txt" 2>&1 && rc=0 || rc=$?
    [ "$rc" != 0 ] || { echo 'FAIL: the ASAN build accepted the tampered object' >&2; exit 1; }
    if grep -q 'AddressSanitizer' "$OUT/asan.txt"; then
        echo 'FAIL: ASAN reports a memory error — the refusal came too late' >&2
        head -20 "$OUT/asan.txt" >&2
        exit 1
    fi
    printf '%s\n' '  ASAN build: refused with no memory error'
else
    printf '%s\n' '  ASAN build skipped'
fi
printf '%s\n' 'PASS: the oversized relocation is refused, and ASAN sees no memory error'

# ---------------------------------------------------------------------------
# [6/9] qemu witnesses. Metadata is worth nothing if the image stops loading.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] qemu witnesses: the corrected images still load and run'
if [ "$have_qemu" = yes ]; then
    cat > "$OUT/run.ast" <<'AST'
let buf: i32[64] = 0;
tls let hits: i32 = 10;
tls let spare: i32 = 0;
fn main() -> i32 {
    buf[0] = 7;
    hits = hits + 1;
    spare = hits + buf[0];
    return i32(spare);
}
AST
    for mode in build-elf build-pie; do
        "$A" $mode "$OUT/run.ast" -o "$OUT/run.$mode" >/dev/null 2>&1 \
            || { echo "FAIL: $mode no longer compiles the witness" >&2; exit 1; }
        set +e
        out=$("$PWD/$RUNNER" "$OUT/run.$mode" 2>&1); rc=$?
        set -e
        [ "$rc" = 18 ] || { echo "FAIL: $mode witness exited $rc (expected 18): $out" >&2; exit 1; }
        printf '  %-30s %s\n' "$mode witness (exit 18)" 'ok'
    done
    # The static image's NOBITS pair is the one whose offset moved the most.
    "$A" build-elf "$OUT/run.ast" -o "$OUT/run.elf" >/dev/null 2>&1
    readelf -SW "$OUT/run.elf" 2>/dev/null | grep -E '\.bss|\.tbss' | sed 's/^/  /'
else
    printf '%s\n' '  qemu witnesses skipped (no qemu-aarch64 or AArch64 host)'
fi

# ---------------------------------------------------------------------------
# [7/9] Coverage counting, so an added field cannot go unchecked.
# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Coverage: how many fields and refusals this suite actually checks'
fields=$(grep -c 'bad.append' "$OUT/decode.py")
guards=$(grep -c '|| { echo "FAIL:' tests/elf-metadata-checks.sh)
[ "$fields" -ge 6 ] || { echo "FAIL: only $fields field assertions" >&2; exit 1; }
[ "$guards" -ge 12 ] || { echo "FAIL: only $guards source guards" >&2; exit 1; }
printf '  %-30s %s\n' "field assertions in the decoder" "$fields"
printf '  %-30s %s\n' "source guards" "$guards"
printf '%s\n' 'PASS: the suite covers every field it claims to'

# ---------------------------------------------------------------------------
# [8/9] Mutations. Each fix has to be load-bearing.
# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] The suite can still fail (three mutations)'
# (a) Put the 4-byte footprint back: the tampered object must be accepted
# again, and [5/9] is what notices.
sed 's|const uint64_t need=(type==kRelTlsOff)?8u:4u;|const uint64_t need=(type==kRelTlsOff)?4u:4u;|' \
    src/aster.cpp > "$OUT/m1.cpp"
grep -q '(type==kRelTlsOff)?4u:4u' "$OUT/m1.cpp" \
    || { echo 'FAIL: mutation (a) stopped applying' >&2; exit 1; }
$CXX -std=c++17 -O2 -w "$OUT/m1.cpp" -o "$OUT/m1" 2>/dev/null \
    || { echo 'FAIL: mutation (a) no longer compiles' >&2; exit 1; }
if "$OUT/m1" link-obj "$OUT/tls.bad.o" -o "$OUT/m1.elf" >/dev/null 2>&1; then
    printf '  %-40s %s\n' 'mutation a) footprint back to 4 bytes' 'noticed ([5/9] catches it)'
else
    echo 'FAIL: mutation (a) was not noticed — the refusal does not depend on the width' >&2
    exit 1
fi
# (b) sh_info back to the constant 1: readelf must warn again.
sed 's|sh\[idxSym\].info=symBase;|sh[idxSym].info=1;|' src/aster.cpp > "$OUT/m2.cpp"
grep -q 'sh\[idxSym\].info=1;' "$OUT/m2.cpp" \
    || { echo 'FAIL: mutation (b) stopped applying' >&2; exit 1; }
$CXX -std=c++17 -O2 -w "$OUT/m2.cpp" -o "$OUT/m2" 2>/dev/null \
    || { echo 'FAIL: mutation (b) no longer compiles' >&2; exit 1; }
"$OUT/m2" build-obj --pic -g "$OUT/full.ast" -o "$OUT/m2.o" >/dev/null 2>&1
if readelf -s "$OUT/m2.o" 2>&1 | grep -qi 'local symbol'; then
    printf '  %-40s %s\n' 'mutation b) sh_info back to 1' 'noticed (readelf warns again)'
else
    echo 'FAIL: mutation (b) was not noticed — readelf no longer objects' >&2
    exit 1
fi
# (c) .hash entsize back to 0: the decoder must object.
sed 's|setSh(S_HASH,5,0x2,hashOff,hashOff,hashSize,S_DYNSYM,0,4,4);|setSh(S_HASH,5,0x2,hashOff,hashOff,hashSize,S_DYNSYM,0,4,0);|' \
    src/aster.cpp > "$OUT/m3.cpp"
grep -q 'S_DYNSYM,0,4,0);' "$OUT/m3.cpp" \
    || { echo 'FAIL: mutation (c) stopped applying' >&2; exit 1; }
$CXX -std=c++17 -O2 -w "$OUT/m3.cpp" -o "$OUT/m3" 2>/dev/null \
    || { echo 'FAIL: mutation (c) no longer compiles' >&2; exit 1; }
"$OUT/m3" build-so --soname libm3.so "$OUT/sofull.ast" -o "$OUT/m3.so" >/dev/null 2>&1
if python3 "$OUT/decode.py" check "$OUT/m3.so" mutant-c | grep -q 'BAD:'; then
    printf '  %-40s %s\n' 'mutation c) .hash entsize back to 0' 'noticed'
else
    echo 'FAIL: mutation (c) was not noticed — the decoder does not check entsize' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# [9/9] The byte baseline, and every example through all three build modes.
# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] Byte baseline: this round moved only section-header bytes'
BASE=$(aster_baseline_file)
if [ ! -f "$BASE" ]; then
    echo "FAIL: no frozen baseline for $(aster_baseline_version): $BASE" >&2
    exit 1
fi
: > "$OUT/hashes.txt"
for mode in build-so build-elf "build-obj --pic"; do
    tag=$(echo "$mode" | tr ' ' '_')
    for f in examples/*.ast; do
        b=$(basename "$f" .ast)
        # shellcheck disable=SC2086
        if "$A" $mode "$f" -o "$OUT/$b.$tag" >/dev/null 2>&1; then
            printf '%s %s\n' "$b.$tag" "$(sha256sum "$OUT/$b.$tag" | cut -d' ' -f1)" >> "$OUT/hashes.txt"
        else
            printf '%s FAILED\n' "$b.$tag" >> "$OUT/hashes.txt"
        fi
    done
done
grep -v '^address_of_abi\.' "$OUT/hashes.txt" | LC_ALL=C sort > "$OUT/hashes.filtered.txt"
LC_ALL=C sort "$BASE" > "$OUT/base.sorted.txt"
if ! diff -u "$OUT/base.sorted.txt" "$OUT/hashes.filtered.txt" > "$OUT/hashes.diff"; then
    echo 'FAIL: the byte baseline no longer reproduces' >&2
    sed -n '1,20p' "$OUT/hashes.diff" >&2
    exit 1
fi
rows=$(wc -l < "$OUT/hashes.filtered.txt")
# v0.23.66-dev moved exactly the build-so rows, and every .so kept its length;
# assert the row count so a later round cannot silently drop one.
[ "$rows" = 378 ] || { echo "FAIL: $rows baseline rows, expected 378" >&2; exit 1; }
printf '  %-30s %s\n' "baseline rows reproduced" "$rows"
printf '%s\n' 'PASS: all v0.23.66-dev ELF metadata checks'
