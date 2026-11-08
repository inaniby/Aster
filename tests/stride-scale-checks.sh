#!/bin/sh
# tests/stride-scale-checks.sh — F-02 of the second full source audit:
# AArch64 `ADD Xd, Xn, Wm, UXTW #sh` has a three-bit imm3, and UXTW is defined
# only for sh = 0..4. v0.23.72-dev's emitElemIndex and emitElemStride emitted
# it for every power-of-two scale: sh=5..7 are reserved (SIGILL under qemu),
# sh>=8 carries into the option field and silently becomes LSL/UXTX, dropping
# the scale entirely. A 2x64 i32 grid therefore wrote a[1][0] at base+1.
#
# v0.23.73-dev routes both callers through one emitScaledAdd: only sh<=4 keeps
# the folded add; every other scale uses UMADDL with an explicit 32-bit
# multiplier (MOVZ/MOVK so strides above 16 bits stay exact).
#
# Layers (the project 9-layer shape): strict build; source guards; a static
# instruction-encoding sweep over 2^0..2^12; the full behavioural stride
# spectrum; a gcc twin; every addressing path that shares the helper; coverage
# counting; six mutations; and the byte baseline.
set -eu
cd "$(dirname "$0")/.."
. tests/lib/baseline.sh
. tests/lib/verdict.sh
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-stride-scale-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
run(){ sh "$RUNNER" "$@"; }
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
COVER=0
bump(){ COVER=$((COVER + 1)); }

# ---------------------------------------------------------------------------
printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
A=$OUT/aster
grep -qF '#define ASTER_VERSION_STRING "0.23.75-dev"' src/aster.cpp \
    || { echo 'FAIL: the version constant is not 0.23.75-dev' >&2; exit 1; }
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: one scaling rule, two callers'
python3 - <<'PY'
import pathlib
s = pathlib.Path('src/aster.cpp').read_text(encoding='utf-8')
guards = [
    ('the imm3 ceiling comment', 'UXTW\'s imm3 is three bits'),
    ('folded only for sh<=4', 'if(pow2&&sh<=4){'),
    ('explicit 32-bit multiplier', 'emit(0x9ba00000u|(uint32_t(idxReg)<<16)'),
    ('high half of the multiplier', 'if(scale>>16)emit(0x72a00000u'),
    ('innermost element index', 'emitScaledAdd(idxReg,tySize(elem));'),
    ('outer row stride', 'emitScaledAdd(idxReg,stride);'),
    ('the old unconditional fold is gone', 'if((stride&(stride-1))==0){'),
]
for label, text in guards:
    n = s.count(text)
    if label.startswith('the old'):
        assert n == 0, f'{label}: still present {n} times'
    else:
        assert n == 1, f'{label}: found {n} times'
    print(f'  {label:44s} {"absent" if label.startswith("the old") else "pinned"}')
PY
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] Static encoding sweep: 2^0 .. 2^12'
# One global u8[2][2^k] per shift. Globals keep the widest 8192-byte row out
# of the fixed 8 KiB stack frame; a variable index stops constant folding.
for k in 0 1 2 3 4 5 6 7 8 9 10 11 12; do
    dim=$(python3 -c "print(2**$k)")
    cat > "$W/s$k.ast" <<AST
let g: u8[2][$dim] = 0;
fn main()->i32 {
    let i: i32 = 1;
    g[i][0] = 42;
    if (g[0][0] == 0 && g[i][0] == 42) { return 0; }
    return 1;
}
AST
    "$A" build-elf "$W/s$k.ast" -o "$W/s$k.elf" >/dev/null 2>&1 \
        || { echo "FAIL: stride 2^$k does not build" >&2; exit 1; }
    bump
done
# A stride past 16 bits exercises the MOVK half of the multiplier.
cat > "$W/big.ast" <<'AST'
let g: u8[2][100000] = 0;
fn main()->i32 {
    let i: i32 = 1;
    g[i][0] = 42;
    // 100000 = 0x186A0 needs MOVZ #0x86A0 plus MOVK #1. Dropping the high
    // half leaves a scale of 34464, and a write-then-read through that same
    // wrong scale would agree with itself; row 0 byte 34464 must stay zero.
    if (g[0][0] == 0 && g[i][0] == 42 && g[0][34464] == 0) { return 0; }
    return 1;
}
AST
"$A" build-elf "$W/big.ast" -o "$W/big.elf" >/dev/null 2>&1 \
    || { echo 'FAIL: the 100000-byte row stride does not build' >&2; exit 1; }
bump
python3 - "$W" <<'PY'
import re, subprocess, sys, pathlib
w = pathlib.Path(sys.argv[1])
# ADD (extended register), 64-bit: 0x8b200000 | Rm<<16 | option<<13 |
# imm3<<10 | Rn<<5 | Rd. UXTW is option 010 and its imm3 must be 0..4.
ADD_EXT = 0x8b200000
pat = re.compile(r'^\s*[0-9a-f]+:\s+([0-9a-f]{8})\s', re.M)
for k in range(13):
    dis = subprocess.check_output(
        ['aarch64-linux-gnu-objdump', '-d', str(w / f's{k}.elf')], text=True)
    words = [int(x, 16) for x in pat.findall(dis)]
    exts = [i for i in words if (i & 0xffe00000) == ADD_EXT]
    for i in exts:
        option, imm3 = (i >> 13) & 7, (i >> 10) & 7
        assert option == 2, f'2^{k}: unexpected extend option {option} in {i:08x}'
        assert imm3 <= 4, f'2^{k}: UXTW #{imm3} is not encodable ({i:08x})'
        assert option != 3, f'2^{k}: scaled add became LSL/UXTX'
    assert 'undefined' not in dis, f'2^{k}: a reserved encoding is still emitted'
    umaddl = any((i & 0xffe00000) == 0x9ba00000 for i in words)
    if k <= 4:
        assert any(((i >> 10) & 7) == k for i in exts), \
            f'2^{k}: the folded UXTW #{k} form was lost'
        assert not umaddl, f'2^{k}: a small stride needlessly takes UMADDL'
    else:
        assert umaddl, f'2^{k}: no UMADDL for a stride past the imm3 ceiling'
    print(f'  2^{k:<2d} {"uxtw #" + str(k) if k <= 4 else "umaddl":12s} clean')
dis = subprocess.check_output(
    ['aarch64-linux-gnu-objdump', '-d', str(w / 'big.elf')], text=True)
assert 'movk' in dis or 'mov\t' in dis, 'the 17-bit multiplier has no high half'
print('  2^17  movz/movk multiplier                    clean')
PY
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] Behavioural spectrum: every stride, variable index, write-then-read'
cases=0
for k in 0 1 2 3 4 5 6 7 8 9 10 11 12; do
    if run "$W/s$k.elf" >/dev/null 2>&1; then
        cases=$((cases + 1)); bump
    else
        echo "FAIL: stride 2^$k wrote or read the wrong element" >&2; exit 1
    fi
done
run "$W/big.elf" >/dev/null 2>&1 \
    || { echo 'FAIL: the 100000-byte row stride is wrong' >&2; exit 1; }
cases=$((cases + 1)); bump
# Non-power-of-two strides, the path that was already correct, and struct
# elements of 32 / 64 / 128 bytes — the emitElemIndex half of the rule.
cat > "$W/nonpow2.ast" <<'AST'
let g: u8[2][7] = 0;
fn main()->i32 {
    let i: i32 = 1;
    g[i][0] = 42;
    // The third read is deliberately asymmetric: a wrong stride of 8 would
    // put 42 in g[1][1] instead of g[1][0], and a write-then-read through the
    // same wrong scale would otherwise agree with itself.
    if (g[0][0] == 0 && g[i][0] == 42 && g[1][1] == 0) { return 0; }
    return 1;
}
AST
cat > "$W/elem32.ast" <<'AST'
struct E { a:i32,b:i32,c:i32,d:i32,e:i32,f:i32,g:i32,h:i32 }
let g: E[2] = E{1,2,3,4,5,6,7,8};
fn main()->i32 {
    let i: i32 = 1;
    g[i].a = 42;
    if (g[0].a == 1 && g[i].a == 42) { return 0; }
    return 1;
}
AST
cat > "$W/elem64.ast" <<'AST'
struct E { a:i32,b:i32,c:i32,d:i32,e:i32,f:i32,g:i32,h:i32,
           i:i32,j:i32,k:i32,l:i32,m:i32,n:i32,o:i32,p:i32 }
let g: E[2] = E{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16};
fn main()->i32 {
    let i: i32 = 1;
    g[i].a = 42;
    if (g[0].a == 1 && g[i].a == 42) { return 0; }
    return 1;
}
AST
for n in nonpow2 elem32 elem64; do
    "$A" build-elf "$W/$n.ast" -o "$W/$n.elf" >/dev/null 2>&1 \
        || { echo "FAIL: $n does not build" >&2; exit 1; }
    run "$W/$n.elf" >/dev/null 2>&1 \
        || { echo "FAIL: $n is wrong" >&2; exit 1; }
    cases=$((cases + 1)); bump
done
[ "$cases" = 17 ] || { echo "FAIL: $cases behavioural cases, expected 17" >&2; exit 1; }
printf '  %-40s %s\n' 'stride and element cases correct' "$cases"
# Shipped example: six independent witnesses in one program.
"$A" build-elf examples/stride_scale.ast -o "$W/example.elf" >/dev/null 2>&1 \
    || { echo 'FAIL: cannot build examples/stride_scale.ast' >&2; exit 1; }
rc=0; run "$W/example.elf" >/dev/null 2>&1 || rc=$?
[ "$rc" = 63 ] || { echo "FAIL: shipped example returned $rc, expected 63" >&2; exit 1; }
printf '  %-40s %s\n' 'shipped example (6 witnesses)' 'correct'
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] C twin: gcc computes the same write-then-read answers'
if [ -n "$HOSTCC" ]; then
    cat > "$W/twin.c" <<'C'
#include <stdint.h>
static uint8_t a1[2][1], a16[2][16], a32[2][32], a256[2][256], a4096[2][4096];
struct Big { int32_t a,b,c,d,e,f,g,h; };
static struct Big big[2] = {{1,2,3,4,5,6,7,8},{1,2,3,4,5,6,7,8}};
int main(void) {
    volatile int i = 1;
    int r = 0;
    a1[i][0]=42;    if (a1[0][0]==0    && a1[i][0]==42)    r += 1;
    a16[i][0]=42;   if (a16[0][0]==0   && a16[i][0]==42)   r += 2;
    a32[i][0]=42;   if (a32[0][0]==0   && a32[i][0]==42)   r += 4;
    a256[i][0]=42;  if (a256[0][0]==0  && a256[i][0]==42)  r += 8;
    a4096[i][0]=42; if (a4096[0][0]==0 && a4096[i][0]==42) r += 16;
    big[i].a=42;    if (big[0].a==1    && big[i].a==42)    r += 32;
    return r;
}
C
    $HOSTCC -static -O2 "$W/twin.c" -o "$W/twin" >/dev/null 2>&1 \
        || { echo 'FAIL: cannot build the C twin' >&2; exit 1; }
    rc=0; run "$W/twin" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 63 ] \
        || { echo "FAIL: the C twin returned $rc, Aster returned 63" >&2; exit 1; }
    printf '  %-40s %s\n' 'gcc twin agrees on all six witnesses' 'yes'
    bump
else
    printf '%s\n' 'SKIP: no cross gcc; the C twin did not run'
fi

# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Every addressing path that shares emitScaledAdd'
cat > "$W/local.ast" <<'AST'
fn main()->i32 {
    let a: i32[2][64] = 0;
    let i: i32 = 1;
    a[i][0] = 42;
    if (a[0][0] == 0 && a[i][0] == 42) { return 0; }
    return 1;
}
AST
cat > "$W/field.ast" <<'AST'
struct Grid { cells: u8[2][64] }
fn main()->i32 {
    let g: Grid;
    let i: i32 = 1;
    g.cells[0][0] = 7;                 // a local is not zero-initialised
    g.cells[i][0] = 42;
    if (g.cells[0][0] == 7 && g.cells[i][0] == 42) { return 0; }
    return 1;
}
AST
cat > "$W/three.ast" <<'AST'
let g: i32[2][2][64] = 0;
fn main()->i32 {
    let i: i32 = 1;
    let j: i32 = 1;
    g[i][j][0] = 42;
    if (g[0][0][0] == 0 && g[i][j][0] == 42) { return 0; }
    return 1;
}
AST
cat > "$W/param.ast" <<'AST'
fn row(p: ptr)->i32 {
    let i: i32 = 1;
    return p[i];
}
fn main()->i32 {
    let a: i32[2][8] = 0;
    a[1][1] = 9;
    if (row(a[1]) == 9) { return 0; }
    return 1;
}
AST
cat > "$W/typedptr.ast" <<'AST'
struct E { a:i32,b:i32,c:i32,d:i32,e:i32,f:i32,g:i32,h:i32 }
let g: E[4] = E{1,2,3,4,5,6,7,8};
fn main()->i32 {
    let p: ptr<E> = &g[0];
    let i: i32 = 1;
    p[i].a = 42;                          // 32-byte element stride through a pointer
    if (g[0].a == 1 && g[1].a == 42 && p[i].a == 42) { return 0; }
    return 1;
}
AST
paths=0
for n in local field three param typedptr; do
    "$A" build-elf "$W/$n.ast" -o "$W/$n.elf" >"$W/$n.log" 2>&1 \
        || { echo "FAIL: $n does not build: $(head -c 200 "$W/$n.log")" >&2; exit 1; }
    run "$W/$n.elf" >/dev/null 2>&1 \
        || { echo "FAIL: $n is wrong" >&2; exit 1; }
    printf '  %-40s %s\n' "$n" 'correct'
    paths=$((paths + 1)); bump
done
[ "$paths" = 5 ] || { echo "FAIL: $paths paths, expected 5" >&2; exit 1; }

# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Coverage census'
# 1 strict build, 7 source guards, 14 static sweeps, 18 behavioural cases,
# 1 C twin, 5 addressing paths.
[ "$COVER" -ge 38 ] \
    || { echo "FAIL: only $COVER invariants exercised" >&2; exit 1; }
printf '  %-40s %s\n' 'invariants exercised' "$COVER"
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Mutations: every edit must be tested'
# A mutation that only changes the encoding of a small stride is still caught:
# the frozen bytes are as much an invariant as the runtime answer.
ref_hash=$(sha256sum "$W/example.elf" | cut -d' ' -f1)
mut_check(){ # $1 mutant binary -> 0 when the damaged compiler still behaves
    "$1" build-elf examples/stride_scale.ast -o "$W/m.elf" >/dev/null 2>&1 || return 1
    rc=0; sh "$RUNNER" "$W/m.elf" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 63 ] || return 1
    [ "$(sha256sum "$W/m.elf" | cut -d' ' -f1)" = "$ref_hash" ] || return 1
    for n in s5 s8 s12 big elem32 nonpow2; do
        "$1" build-elf "$W/$n.ast" -o "$W/m_$n.elf" >/dev/null 2>&1 || return 1
        sh "$RUNNER" "$W/m_$n.elf" >/dev/null 2>&1 || return 1
    done
    # A non-power-of-two stride must still be scaled by a multiply, not by a
    # rounded-up UXTW shift. Without this, a mutation that declares every
    # stride a power of two can pass every behavioural probe by writing and
    # reading through the same (wrong) scale.
    aarch64-linux-gnu-objdump -d "$W/m_nonpow2.elf" 2>/dev/null \
        | grep -q 'umaddl' || return 1
    # A stride above 16 bits needs the MOVK half of its multiplier; without
    # it the scale silently collapses to its low 16 bits.
    aarch64-linux-gnu-objdump -d "$W/m_big.elf" 2>/dev/null \
        | grep -q 'movk' || return 1
    return 0
}
mutate(){ # $1 label, $2 old text, $3 new text
    python3 - "$2" "$3" <<'PY'
import pathlib, sys
s = pathlib.Path('src/aster.cpp').read_text(encoding='utf-8')
old, new = sys.argv[1], sys.argv[2]
assert s.count(old) == 1, (s.count(old), old[:70])
pathlib.Path('tmp-mut.cpp').write_text(s.replace(old, new), encoding='utf-8')
PY
    mv tmp-mut.cpp "$W/mut.cpp"
    $CXX -std=c++17 -O2 -w "$W/mut.cpp" -o "$W/mut.aster" >/dev/null 2>&1 \
        || { echo "FAIL: $1 mutant does not compile" >&2; exit 1; }
    if mut_check "$W/mut.aster"; then
        # "went unnoticed" is the survivor-assertion wording the aggregate
        # mutation-score census greps for; keep this failing path visible.
        echo "FAIL: mutation '$1' went unnoticed" >&2; exit 1
    fi
    printf '  %-34s %s\n' "$1" 'caught'; bump
}
mutate 'm1: fold every power of two again' \
    'if(pow2&&sh<=4){' 'if(pow2){'
mutate 'm2: allow the reserved shifts 5..7' \
    'if(pow2&&sh<=4){' 'if(pow2&&sh<=7){'
mutate 'm3: treat every stride as a power of two' \
    'const bool pow2=(scale&(scale-1))==0;' 'const bool pow2=true;'
mutate 'm4: element index loses its element size' \
    'emitScaledAdd(idxReg,tySize(elem));' 'emitScaledAdd(idxReg,1);'
mutate 'm5: row stride is discarded' \
    'emitScaledAdd(idxReg,stride);' 'emitScaledAdd(idxReg,0);'
mutate 'm6: high half of the multiplier is dropped' \
    'if(scale>>16)emit(0x72a00000u' 'if(false)emit(0x72a00000u'
[ "$COVER" -ge 44 ] || { echo "FAIL: only $COVER invariants" >&2; exit 1; }

# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] Byte baseline: the new example reproduces'
BASE=$(aster_baseline_file)
rows=$(grep '^stride_scale\.' "$BASE" | LC_ALL=C sort)
[ "$(printf '%s\n' "$rows" | wc -l)" = 3 ] \
    || { echo 'FAIL: the baseline must pin exactly three stride_scale rows' >&2; exit 1; }
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
done < "$W/ours.rows"
printf '  %-30s %s\n' "stride_scale rows reproduced" '3'
_cur_v=$(aster_baseline_version)
_prev_v=$(ls tests/baseline/ | grep -v "^v${_cur_v}\$" | sort -V | tail -1)
PREV="tests/baseline/${_prev_v}/example-hashes.txt"
moved=$(awk 'NR==FNR{a[$1]=$2;next} ($1 in a) && a[$1]!=$2 {print $1}' "$PREV" "$BASE")
[ -z "$moved" ] \
    || { echo "FAIL: this round moved bytes of an older program: $moved" >&2; exit 1; }
prev_rows=$(wc -l < "$PREV")
[ "$prev_rows" = 390 ] \
    || { echo "FAIL: previous baseline has $prev_rows rows, expected 390" >&2; exit 1; }
printf '  %-30s %s\n' "pre-existing rows unchanged" "$prev_rows"
bump
printf '%s\n' 'PASS: all stride-scale checks'
