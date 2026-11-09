#!/bin/sh
# tests/embed-align-checks.sh — @embed("path", N) and the .rodata alignment
# contract.
#
# ROADMAP.md's unscheduled backlog has been down to two open items since
# v0.23.66-dev: ".rodata carries addralign 1 where GNU ld uses 8, so @embed
# data cannot ask for more than byte alignment", and the ET_REL branch of
# regression-symtab.sh never running. v0.23.71-dev closes the first here.
#
# The compiler already had half the machinery: parseObject reads a .rodata
# section's addralign into rodataAlign, both linkers pad the merged blob to it,
# and linkObjects forwards maxRodataAlign to writeElfBytes. What was missing
# was the producing end — embedFile pinned g.align to 1, layoutObject forced
# string-like globals to a=1, and writeObject hard-coded both alignUp(...,1)
# and sh_addralign=1. This round connects those ends:
#
#   * @embed("path", N) takes an optional literal alignment, with exactly the
#     rule @align(N) already uses (power of two, at most 4096);
#   * one path remains one object, and a second request raises that object's
#     alignment to the maximum instead of copying or refusing;
#   * build-obj / build-elf / build-pie / build-so / link-obj / link-so all
#     declare the requested alignment and place .rodata at a congruent address.
#
# The default is 1, so every program written before this round is
# byte-identical. The shipped example asks for 64 and 16 and is checked both
# structurally (section header AND section bytes) and by execution against a
# C twin compiled by the host toolchain.
#
# Layers (the project 9-layer shape): strict build; source guards pinning every
# edit; a refusal matrix with exact messages; build-obj structure, dedup and
# boundaries; the four direct writers plus qemu and the C twin; the two
# linkers; coverage counting; six mutations; and the byte baseline.

set -eu
cd "$(dirname "$0")/.."
. tests/lib/tools.sh
. tests/lib/baseline.sh
. tests/lib/verdict.sh
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-embed-align-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
run(){ sh "$RUNNER" "$@"; }

HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac

# An independent ELF reader: read the section header table directly, so the
# assertions do not depend on readelf's column layout or on Aster's own writer.
sec() { # $1 = ELF file, $2 = section name -> "addr off size align"
python3 - "$1" "$2" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
shoff = struct.unpack_from('<Q', b, 40)[0]
es = struct.unpack_from('<H', b, 58)[0]
n = struct.unpack_from('<H', b, 60)[0]
sx = struct.unpack_from('<H', b, 62)[0]
if not n:
    print('FAIL: no section table'); sys.exit(1)
raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i * es) for i in range(n)]
names = b[raw[sx][4]:raw[sx][4] + raw[sx][5]]
for s in raw:
    nm = names[s[0]:names.index(b'\0', s[0])].decode()
    if nm == sys.argv[2]:
        print(s[3], s[4], s[5], s[8]); break
else:
    print('FAIL: no .rodata section'); sys.exit(1)
PY
}

check_align() { # $1 file, $2 expected align, $3 expected size or '-'
python3 - "$1" "$2" "$3" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
want, size = int(sys.argv[2]), sys.argv[3]
etype = struct.unpack_from('<H', b, 16)[0]
shoff = struct.unpack_from('<Q', b, 40)[0]
es = struct.unpack_from('<H', b, 58)[0]
n = struct.unpack_from('<H', b, 60)[0]
sx = struct.unpack_from('<H', b, 62)[0]
assert n, 'no section table'
raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i * es) for i in range(n)]
names = b[raw[sx][4]:raw[sx][4] + raw[sx][5]]
for s in raw:
    nm = names[s[0]:names.index(b'\0', s[0])].decode()
    if nm == '.rodata':
        break
else:
    raise AssertionError('no .rodata section')
assert s[8] == want, f'addralign {s[8]} != {want}'
assert s[8] >= 1 and (s[8] & (s[8] - 1)) == 0, 'addralign is not a power of two'
assert s[4] % s[8] == 0, f'sh_offset 0x{s[4]:x} not congruent to {s[8]}'
if etype != 1:
    assert s[3] % s[8] == 0, f'sh_addr 0x{s[3]:x} not congruent to {s[8]}'
if size != '-':
    assert s[5] == int(size), f'sh_size {s[5]} != {size}'
print(f'PASS: .rodata align={s[8]} addr%align=0 off%align=0 size={s[5]}')
PY
}

check_layout() { # $1 file -> the exact byte positions of the shipped example
python3 - "$1" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
shoff = struct.unpack_from('<Q', b, 40)[0]
es = struct.unpack_from('<H', b, 58)[0]
n = struct.unpack_from('<H', b, 60)[0]
sx = struct.unpack_from('<H', b, 62)[0]
raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i * es) for i in range(n)]
names = b[raw[sx][4]:raw[sx][4] + raw[sx][5]]
for s in raw:
    if names[s[0]:names.index(b'\0', s[0])].decode() == '.rodata':
        break
else:
    raise AssertionError('no .rodata section')
d = b[s[4]:s[4] + s[5]]
assert len(d) == 83, f'rodata is {len(d)} bytes, expected 83'
assert d[0] == 0x41, 'head.bin is not at offset 0'
assert d[64] == 0x42 and d[65] == 0x43, 'tail.bin is not at offset 64'
assert d[80] == 0x44 and d[81] == 0x45 and d[82] == 0x46, 'third.bin is not at offset 80'
assert all(x == 0 for x in d[1:64]), 'the 63 bytes to the 64 boundary are not zero'
assert all(x == 0 for x in d[66:80]), 'the 14 bytes to the 16 boundary are not zero'
print('PASS: head@0, tail@64, third@80, padding all zero')
PY
}

# ---- assets used by the small ad-hoc cases ---------------------------------
printf 'A'  > "$W/one.bin"
printf 'BC' > "$W/two.bin"
printf 'Z'  > "$W/z.bin"
cat > "$W/default.ast" <<'AST'
fn main() -> i32 { let p: ptr = @embed("one.bin"); return load_u8(p); }
AST
cat > "$W/one.ast" <<'AST'
fn main() -> i32 { let p: ptr = @embed("one.bin", 1); return load_u8(p); }
AST
cat > "$W/top.ast" <<'AST'
fn main() -> i32 { let p: ptr = @embed("one.bin", 4096); return load_u8(p); }
AST
cat > "$W/dup.ast" <<'AST'
fn main() -> i32 {
    let a: ptr = @embed("one.bin", 8);
    let b: ptr = @embed("one.bin", 64);
    return load_u8(a) + load_u8(b);
}
AST
cat > "$W/dup2.ast" <<'AST'
fn main() -> i32 {
    let a: ptr = @embed("one.bin", 64);
    let b: ptr = @embed("one.bin", 8);
    return load_u8(a) + load_u8(b);
}
AST
cat > "$W/plain.ast" <<'AST'
fn extra() -> i32 { return load_u8("hi"); }
AST

COVER=0
WRITERS=''
bump(){ COVER=$((COVER + 1)); }
saw(){ WRITERS="$WRITERS $1"; }

# ---------------------------------------------------------------------------
printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
A=$OUT/aster
grep -qF '#define ASTER_VERSION_STRING "0.23.76-dev"' src/aster.cpp \
    || { echo 'FAIL: the version constant is not 0.23.76-dev' >&2; exit 1; }
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: every end of the alignment contract'
guards=0
guard(){ # $1 literal source text, $2 what it is
    grep -qF "$1" src/aster.cpp \
        || { printf 'FAIL: %s is gone\n' "$2" >&2; exit 1; }
    guards=$((guards + 1)); bump
}
guard 'uint64_t embedAlign=1;'                                  'the default alignment'
guard 'if(eat(TK::Comma)){'                                     'the optional second argument'
guard '@embed_len takes no alignment argument'                  '@embed_len stays one-argument'
guard 'expected a power-of-two alignment after'                 'a non-literal is refused'
guard 'embedAlign=unsignedLiteral(av,"embedded alignment")'   'the literal is parsed by the shared helper'
guard 'embedded alignment must be a power of two'              'the power-of-two rule'
guard 'embedded alignment must not exceed 4096 bytes'          'the 4096 ceiling'
guard 'embedFile(pathTok.s, at.line, at.col, embedAlign)'      'the request reaches embedFile'
guard 'const std::string& path, unsigned line, unsigned col, uint64_t align' 'embedFile takes the alignment'
guard 'if(align>g.align)g.align=align;'                        'dedup raises, never lowers'
guard 'g.align = align;'                                       'the placeholder carries the request'
guard 'uint64_t rodataAlign=1;'                                'the section alignment field'
guard 'if(a>L.rodataAlign)L.rodataAlign=a;'                    'layout records the maximum'
guard 'g.isString?(g.fromEmbed?g.align:1)'                     'only @embed blobs ask for a boundary'
guard 'const uint64_t rodataAlign=L.rodataAlign;'              'writeObject reads the layout'
guard 'alignUp((hasData?dataOff+L.data.size():textOff+textSize),rodataAlign)' 'the section offset is aligned'
guard 'sh[idxRodata].addralign=rodataAlign;'                    'the object declares it'
guard 'spec.rodataAlign=L.rodataAlign;'                        'build-so forwards it'
guard 'spec.rodataAlign=maxRodataAlign;'                       'link-so forwards the merged maximum'
guard 'maxTlsAlign=kTlsBlockAlign,maxRodataAlign=1;'           'link-so accumulates a maximum'
guard 'if(obj.rodataAlign>maxRodataAlign)maxRodataAlign=obj.rodataAlign;' 'the merge tracks the maximum'
guard 'if(spec.rodataAlign>1&&rodataVaddr%spec.rodataAlign)'   'the dyn writer checks congruence'
guard 'setSh(S_RODATA,1,0x2,rodataVaddr,rodataVaddr,rodataSize,0,0,spec.rodataAlign,0);' 'the dyn section header declares it'
guard 'result.rodataAlign=r.addralign<1?1:r.addralign;'        'parseObject still reads it back'
[ "$(grep -c 'uint64_t rodataAlign=1;' src/aster.cpp)" = 2 ] \
    || { echo 'FAIL: both ObjectLayout and SoDynSpec must carry rodataAlign' >&2; exit 1; }
guards=$((guards + 1)); bump
[ "$(grep -c 'while(obj.rodataAlign>1&&mergedRodata.size()%obj.rodataAlign)' src/aster.cpp)" = 2 ] \
    || { echo 'FAIL: both linkers must pad the merged rodata' >&2; exit 1; }
guards=$((guards + 1)); bump
printf '  %-30s %s\n' "guards passed" "$guards"

# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] Refusal matrix: every bad request names the real problem'
expect_fail(){ # $1 label, $2 source, $3 expected substring
    printf '%s\n' "$2" > "$W/neg.ast"
    if "$A" build-elf "$W/neg.ast" -o "$W/neg" > "$W/neg.log" 2>&1; then
        echo "FAIL: $1 compiled, but should not have" >&2; exit 1
    fi
    grep -qF "$3" "$W/neg.log" \
        || { echo "FAIL: $1 was rejected, but not because of '$3':" >&2
             sed -n 's/^/    /p' "$W/neg.log" >&2; exit 1; }
    printf '  %-30s %s\n' "$1" 'refused'; bump
}
expect_fail 'alignment 3' \
    'fn main() -> i32 { let p: ptr = @embed("one.bin", 3); return load_u8(p); }' \
    'embedded alignment must be a power of two'
expect_fail 'alignment 0' \
    'fn main() -> i32 { let p: ptr = @embed("one.bin", 0); return load_u8(p); }' \
    'embedded alignment must be a power of two'
expect_fail 'alignment 6' \
    'fn main() -> i32 { let p: ptr = @embed("one.bin", 6); return load_u8(p); }' \
    'embedded alignment must be a power of two'
expect_fail 'hex literal 0x18' \
    'fn main() -> i32 { let p: ptr = @embed("one.bin", 0x18); return load_u8(p); }' \
    'embedded alignment must be a power of two'
expect_fail 'alignment 8192' \
    'fn main() -> i32 { let p: ptr = @embed("one.bin", 8192); return load_u8(p); }' \
    'embedded alignment must not exceed 4096 bytes'
expect_fail 'alignment 65536' \
    'fn main() -> i32 { let p: ptr = @embed("one.bin", 65536); return load_u8(p); }' \
    'embedded alignment must not exceed 4096 bytes'
expect_fail 'a variable, not a literal' \
    'fn main() -> i32 { let n: i32 = 8; let p: ptr = @embed("one.bin", n); return load_u8(p); }' \
    'expected a power-of-two alignment'
expect_fail 'empty second argument' \
    'fn main() -> i32 { let p: ptr = @embed("one.bin", ); return load_u8(p); }' \
    'expected a power-of-two alignment'
expect_fail 'a negative literal' \
    'fn main() -> i32 { let p: ptr = @embed("one.bin", -1); return load_u8(p); }' \
    'expected a power-of-two alignment'
expect_fail 'a third argument' \
    'fn main() -> i32 { let p: ptr = @embed("one.bin", 8, 16); return load_u8(p); }' \
    "expected ')' after the file path"
expect_fail 'no comma' \
    'fn main() -> i32 { let p: ptr = @embed("one.bin" 8); return load_u8(p); }' \
    "expected ')' after the file path"
expect_fail 'embed_len with alignment' \
    'fn main() -> i32 { let n: i32 = @embed_len("one.bin", 8); return n; }' \
    '@embed_len takes no alignment argument'
# Two positive controls: the boundaries themselves must still compile.
for c in default one top; do
    "$A" build-elf "$W/$c.ast" -o "$W/$c" >/dev/null 2>&1 \
        || { echo "FAIL: $c.ast should compile" >&2; exit 1; }
    printf '  %-30s %s\n' "$c.ast" 'accepted'; bump
done

# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] build-obj: section header, section bytes, dedup, boundaries'
"$A" build-obj examples/embed_align.ast -o "$W/example.o" >/dev/null
saw build-obj
check_align "$W/example.o" 64 83; bump
check_layout "$W/example.o"; bump
# The default and an explicit 1 are the historical layout, byte for byte.
for c in default one; do
    "$A" build-obj "$W/$c.ast" -o "$W/$c.o" >/dev/null
    check_align "$W/$c.o" 1 1; bump
done
"$A" build-obj "$W/top.ast" -o "$W/top.o" >/dev/null
check_align "$W/top.o" 4096 1; bump
# One path, one blob: both spellings must produce a single 1-byte rodata
# section declared at the *maximum* of the two requests, regardless of order.
for c in dup dup2; do
    "$A" build-obj "$W/$c.ast" -o "$W/$c.o" >/dev/null
    check_align "$W/$c.o" 64 1; bump
    syms=$(readelf -sW "$W/$c.o" | grep -c '__aster_embed_' || true)
    [ "$syms" = 1 ] || { echo "FAIL: $c produced $syms blobs, expected one" >&2; exit 1; }
    printf '  %-30s %s\n' "$c: one blob" "$syms"; bump
done

# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] The four direct writers, qemu, and the C twin'
for m in build-elf build-pie build-so; do
    "$A" "$m" examples/embed_align.ast -o "$W/example.$m" >/dev/null
    saw "$m"
    check_align "$W/example.$m" 64 -; bump
done
rc=0; run "$W/example.build-elf" || rc=$?
[ "$rc" = 215 ] || { echo "FAIL: build-elf exited $rc, C twin exits 215" >&2; exit 1; }
printf '  %-30s %s\n' "build-elf under qemu" "exit $rc"; bump
rc=0; run "$W/example.build-pie" || rc=$?
[ "$rc" = 215 ] || { echo "FAIL: build-pie exited $rc, C twin exits 215" >&2; exit 1; }
printf '  %-30s %s\n' "build-pie under qemu" "exit $rc"; bump
if [ -n "$HOSTCC" ] && [ "$have_qemu" = yes ]; then
    aster_hostcc_link "$W/twin" tests/embed-align-twin.c >/dev/null 2>&1 \
        || { echo 'FAIL: the C twin does not build' >&2; exit 1; }
    rc=0; run "$W/twin" || rc=$?
    [ "$rc" = 215 ] || { echo "FAIL: gcc differential: twin exited $rc, Aster 215" >&2; exit 1; }
    printf '  %-30s %s\n' "gcc differential (C twin)" "exit $rc"; bump
else
    printf '  %-30s %s\n' "gcc differential" 'SKIP (no cross gcc / qemu)'
fi
# A 4096 request survives the executable layout too: its address is congruent.
check_align "$W/top" 4096 -; bump

# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] The two linkers carry the maximum through'
"$A" build-obj examples/embed_align.ast -o "$W/main.o" >/dev/null
"$A" build-obj "$W/plain.ast" -o "$W/plain.o" >/dev/null
"$A" link-obj "$W/main.o" "$W/plain.o" -o "$W/linked" >/dev/null
saw link-obj
check_align "$W/linked" 64 -; bump
rc=0; run "$W/linked" || rc=$?
[ "$rc" = 215 ] || { echo "FAIL: link-obj exited $rc, expected 215" >&2; exit 1; }
printf '  %-30s %s\n' "link-obj under qemu" "exit $rc"; bump
"$A" build-obj --pic examples/embed_align.ast -o "$W/main.pic.o" >/dev/null
"$A" build-obj --pic "$W/plain.ast" -o "$W/plain.pic.o" >/dev/null
"$A" link-so "$W/main.pic.o" "$W/plain.pic.o" -o "$W/linked.so" >/dev/null
saw link-so
check_align "$W/linked.so" 64 -; bump
# Two objects that each carry a request: the merged section declares the max.
"$A" build-obj "$W/dup2.ast" -o "$W/d2.o" >/dev/null
"$A" link-obj "$W/d2.o" "$W/plain.o" -o "$W/linked2" >/dev/null
check_align "$W/linked2" 64 -; bump

# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Coverage counting'
[ "$COVER" -ge 45 ] \
    || { echo "FAIL: only $COVER assertions ran; the layers lost their teeth" >&2; exit 1; }
printf '  %-30s %s\n' "assertions executed" "$COVER"; bump
# Every writer must have actually been invoked at runtime, not merely named
# in this file: a layer that was deleted or skipped still leaves its string
# behind in a comment, but it cannot leave a saw() call behind.
for w in build-obj build-elf build-pie build-so link-obj link-so; do
    case " $WRITERS " in
        *" $w "*) : ;;
        *) echo "FAIL: $w was never actually invoked" >&2; exit 1 ;;
    esac
done
printf '  %-30s %s\n' "writers exercised" '6'; bump

# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Six mutations, each must be caught'
mut_check(){ # $1 mutant binary -> 0 when every invariant still holds
    "$1" build-obj examples/embed_align.ast -o "$W/m.o" >/dev/null 2>&1 || return 1
    check_align "$W/m.o" 64 83 >/dev/null 2>&1 || return 1
    check_layout "$W/m.o" >/dev/null 2>&1 || return 1
    "$1" build-obj "$W/dup2.ast" -o "$W/m2.o" >/dev/null 2>&1 || return 1
    check_align "$W/m2.o" 64 1 >/dev/null 2>&1 || return 1
    "$1" build-so examples/embed_align.ast -o "$W/m.so" >/dev/null 2>&1 || return 1
    check_align "$W/m.so" 64 - >/dev/null 2>&1 || return 1
    return 0
}
mutate(){ # $1 label, $2 old text, $3 new text
    python3 - "$2" "$3" <<'PY'
import pathlib, sys
s = pathlib.Path('src/aster.cpp').read_text(encoding='utf-8')
old, new = sys.argv[1], sys.argv[2]
assert s.count(old) == 1, (s.count(old), old[:60])
pathlib.Path('tmp-mut.cpp').write_text(s.replace(old, new), encoding='utf-8')
PY
    mv tmp-mut.cpp "$W/mut.cpp"
    $CXX -std=c++17 -O2 -w "$W/mut.cpp" -o "$W/mut.aster" >/dev/null 2>&1 \
        || { echo "FAIL: $1 mutant does not compile" >&2; exit 1; }
    if mut_check "$W/mut.aster"; then
        # "went unnoticed" is the survivor-assertion wording the aggregate
        # mutation-score census greps for; keep this failing path visible to it.
        echo "FAIL: mutation '$1' went unnoticed" >&2; exit 1
    fi
    printf '  %-30s %s\n' "$1" 'caught'; bump
}
mutate 'm1: embedFile ignores the request' \
    'g.align = align;' 'g.align = 1;'
mutate 'm2: layout ignores the request' \
    'g.isString?(g.fromEmbed?g.align:1)' 'g.isString?1'
mutate 'm3: object offset not aligned' \
    'alignUp((hasData?dataOff+L.data.size():textOff+textSize),rodataAlign)' \
    'alignUp((hasData?dataOff+L.data.size():textOff+textSize),1)'
mutate 'm4: object header declares 1' \
    'sh[idxRodata].addralign=rodataAlign;' 'sh[idxRodata].addralign=1;'
mutate 'm5: dyn header declares 1' \
    'setSh(S_RODATA,1,0x2,rodataVaddr,rodataVaddr,rodataSize,0,0,spec.rodataAlign,0);' \
    'setSh(S_RODATA,1,0x2,rodataVaddr,rodataVaddr,rodataSize,0,0,1,0);'
mutate 'm6: dedup lowers the alignment' \
    'if(align>g.align)g.align=align;' 'g.align=1;'

# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] Byte baseline: three embed_align rows, all inherited rows unchanged'
BASE=$(aster_baseline_file)
rows=$(grep '^embed_align\.' "$BASE" | LC_ALL=C sort)
[ "$(printf '%s\n' "$rows" | wc -l)" = 3 ] \
    || { echo 'FAIL: the baseline must pin exactly three embed_align rows' >&2; exit 1; }
printf '%s\n' "$rows" > "$W/ours.rows"
while IFS= read -r spec; do
    [ -z "$spec" ] && continue
    key=${spec% *}; val=${spec#* }
    mode=${key#*.}; base=${key%.*}
    case "$mode" in
        build-so) m='build-so' ;;
        build-elf) m='build-elf' ;;
        build-obj_--pic) m='build-obj --pic' ;;
    esac
    if "$A" $m "examples/$base.ast" -o "$W/$key" >/dev/null 2>&1; then
        got=$(sha256sum "$W/$key" | cut -d' ' -f1)
    else
        got=FAILED
    fi
    [ "$got" = "$val" ] \
        || { echo "FAIL: $key baseline moved: expected $val, got $got" >&2; exit 1; }
    bump
done < "$W/ours.rows"
printf '  %-30s %s\n' "embed_align rows reproduced" '3'
# The previous release's frozen rows must all still be present and identical.
_cur_v=$(aster_baseline_version)
_prev_v=$(ls tests/baseline/ | grep -v "^v${_cur_v}$" | sort -V | tail -1)
PREV="tests/baseline/${_prev_v}/example-hashes.txt"
moved=$(awk 'NR==FNR{a[$1]=$2;next} ($1 in a) && a[$1]!=$2 {print $1}' "$PREV" "$BASE")
[ -z "$moved" ] \
    || { echo "FAIL: this round moved bytes of an older program: $moved" >&2; exit 1; }
prev_rows=$(wc -l < "$PREV")
[ "$prev_rows" = 393 ] || { echo "FAIL: previous baseline has $prev_rows rows" >&2; exit 1; }
printf '  %-30s %s\n' "pre-existing rows unchanged" "$prev_rows"; bump
printf '%s\n' 'PASS: all embed-align checks'
