#!/bin/sh
# v0.23.18-dev (round 2) checks for WIDE-INTEGER LITERAL AND LEAF correctness.
#
# Round 2 fixed two defects in how i64 values meet 32-bit consumers:
#   A. An i64 arithmetic literal was narrowed back to 32 bits by the consumer.
#      exprType(Num) is always I32, while gen(Num, want=I64) materializes the
#      literal at full width (emitMov64); the arithmetic sites then extended
#      the result register with an unconditional SXTW, cutting the literal's
#      high word off again. `let q: i64 = 1000000000000 + 1000000000000` was
#      computed in 32 bits and stored 2000000000.
#   B. The width of an operation was derived from the consumer alone
#      (`wide = tyIs64(want)`), so an i64 operand was truncated whenever the
#      result was consumed as i32: `let x: i64 = 4294967297; return x % 7`
#      returned 1 instead of 5.
# The fix rests on three rules (see the comment block above wideOp in
# src/aster.cpp):
#   (1) a constant operand whose value does not fit in 32 bits forces the
#       operation to 64 bits (constExceedsI32, sign peeled off first);
#   (2) widening an operand is the operand's own job, never the consumer's —
#       every leaf (Num/Neg/Var/global/Field/Index/Deref/Call/Cond) widens
#       itself when asked for i64, and no consumer re-extends afterwards;
#   (3) the operation width is tyIs64(want) || tyIs64(operands) || the
#       constant rule, with each operand generated at that width.
# A third defect surfaced while testing the first two: slotElemTypes was
# declared and read but never written, so every local array's elements were
# typed i32 — `let c: i64[2]` was laid out and addressed as i32[2].
#
# Layers:
#   [1] strict compiler build (-Werror)
#   [2] source guards pinning the three rules, the per-leaf widening, the
#       slotElemTypes write and the absence of any post-hoc SXTW helper
#   [3] rejection matrix: the width rules must not have loosened typing
#   [4] qemu positive matrix, 54 cases in 8 groups (below)
#   [5] C differential: the same expressions compiled by aarch64 gcc must
#       return the same exit codes (skipped cleanly without an AArch64 cc)
#   [6] mutation layer: 16 single-rule mutants of the round's own diff, each
#       of which must be caught by a named discriminator case
#   [7] the documented blind spots, and why the discriminators avoid them
#
# Every case returns a DISTINCT non-zero code on success, so a silent
# wrong-value cannot masquerade as a clean run; the harness captures the code
# and asserts it equals the expected value (set -e is never tripped by the
# intentional non-zero success codes).
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-wide-int-literal-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
CASES="$OUT/cases.txt"

# ---------------------------------------------------------------------------
# The 54-case matrix. Format: <code>~<expected exit code>, one blank-line-free
# record per case, records separated by a line containing only @@@.
#
# Discriminator design (the "consistent truncation" trap): a case whose
# EXPECTED value and the BUGGY computation both truncate to the same 32-bit
# pattern passes under the bug — both suites green, both wrong. Case 39
# (`8589934593 == 8589934593`) is exactly that: a 32-bit comparison sees 1 == 1
# and "passes". So every discriminator below either compares a LARGE POSITIVE
# constant at full width (36/37/38/47/60/65) or never compares against a large
# constant at all; 39 stays in the matrix as a forward guard only.
# ---------------------------------------------------------------------------
cat > "$CASES" <<'CASE_EOF'
11~11
fn main() -> i32 { let q: i64 = 1000000000000 + 1000000000000; if (q == 2000000000000) { return 11; } else { return 0; } }
@@@
12~12
fn main() -> i32 { let q: i64 = 1000000000000 - 100000000000; if (q == 900000000000) { return 12; } else { return 0; } }
@@@
13~13
fn main() -> i32 { let q: i64 = 1000000 * 3000000000; if (q == 3000000000000000) { return 13; } else { return 0; } }
@@@
14~14
fn main() -> i32 { let q: i64 = 1000000000000 / 7; if (q == 142857142857) { return 14; } else { return 0; } }
@@@
15~15
fn main() -> i32 { let q: i64 = 1000000000000 % 999999999999; if (q == 1) { return 15; } else { return 0; } }
@@@
16~16
fn main() -> i32 { let q: i64 = 1000000000000 << 1; if (q == 2000000000000) { return 16; } else { return 0; } }
@@@
17~17
fn main() -> i32 { let q: i64 = 1000000000000 >> 20; if (q == 953674) { return 17; } else { return 0; } }
@@@
18~18
fn main() -> i32 { let q: i64 = 1000000000000 & 549755813888; if (q == 549755813888) { return 18; } else { return 0; } }
@@@
19~19
fn main() -> i32 { let q: i64 = 1000000000000 | 4294967296; if (q == 1004294967296) { return 19; } else { return 0; } }
@@@
20~20
fn main() -> i32 { let q: i64 = 1000000000000 ^ 4294967296; if (q == 1004294967296) { return 20; } else { return 0; } }
@@@
21~21
fn main() -> i32 { let q: i64 = ~1000000000000; if (q == -1000000000001) { return 21; } else { return 0; } }
@@@
31~5
fn main() -> i32 { let x: i64 = 4294967297; return x % 7; }
@@@
32~4
fn main() -> i32 { let x: i64 = 4294967297; return x / 1000000000; }
@@@
33~1
fn main() -> i32 { let x: i64 = 1000000000000; return x % 7; }
@@@
34~34
fn main() -> i32 { let x: i64 = 4294967297; if ((x & 7) == 1) { return 34; } else { return 0; } }
@@@
35~35
fn main() -> i32 { let x: i64 = 4294967297; if ((x | 1) == 4294967297) { return 35; } else { return 0; } }
@@@
36~1
fn main() -> i32 { return 1000000000000 % 7; }
@@@
37~4
fn main() -> i32 { return 4294967297 / 1000000000; }
@@@
38~0
fn main() -> i32 { return 8589934593 == 4294967297 ? 1 : 0; }
@@@
39~1
fn main() -> i32 { return 8589934593 == 8589934593 ? 1 : 0; }
@@@
41~41
fn main() -> i32 { let q: i64 = -900000000000 / 3; if (q / -1000000000 == 300) { return 41; } else { return 0; } }
@@@
42~42
fn main() -> i32 { let x: i64 = -900000000000; if (x == -900000000000) { return 42; } else { return 0; } }
@@@
43~43
fn main() -> i32 { let q: i64 = -9223372036854775807 - 1; return q == -9223372036854775807 - 1 ? 43 : 0; }
@@@
44~0
fn main() -> i32 { let x: i64 = 4294967297; return x == -900000000000 ? 1 : 0; }
@@@
47~47
fn main() -> i32 { if (!(8589934593 == 4294967297)) { return 47; } else { return 0; } }
@@@
51~51
fn get() -> i32 { return -5; }
fn main() -> i32 { let q: i64 = get(); if (q == -5) { return 51; } else { return 0; } }
@@@
52~52
fn getu() -> u32 { return 4000000000; }
fn main() -> i32 { let q: i64 = getu(); if (q == 4000000000) { return 52; } else { return 0; } }
@@@
53~53
struct P { x: i32 }
fn main() -> i32 { let p: P = P { -5 }; let q: i64 = p.x; if (q == -5) { return 53; } else { return 0; } }
@@@
54~54
fn main() -> i32 { let a: i32[2] = 0; a[0] = -5; let q: i64 = a[0]; if (q == -5) { return 54; } else { return 0; } }
@@@
55~55
fn main() -> i32 { let a: i32[2] = 0; a[0] = -5; let p: ptr = a; let q: i64 = *p; if (q == -5) { return 55; } else { return 0; } }
@@@
56~56
let g: i32 = -5;
fn main() -> i32 { let q: i64 = g; if (q == -5) { return 56; } else { return 0; } }
@@@
57~57
let g: i32[2] = 0;
fn main() -> i32 { g[0] = -5; let q: i64 = g[0]; if (q == -5) { return 57; } else { return 0; } }
@@@
58~58
fn main() -> i32 { let a: i32[2] = 0; a[0] = -5; let p: ptr = a; let q: i64 = p[0]; if (q == -5) { return 58; } else { return 0; } }
@@@
59~59
fn main() -> i32 { let a: i32 = -5; let q: i64 = -a; if (q == 5) { return 59; } else { return 0; } }
@@@
60~2
fn main() -> i32 { return 2147483648 % 7; }
@@@
61~61
fn main() -> i32 { let q: i64 = (1 == 2) ? 0 : -5; if (q == -5) { return 61; } else { return 0; } }
@@@
62~62
fn main() -> i32 { let q: i64 = (1 == 2) ? 0 : 4294967297; if (q == 4294967297) { return 62; } else { return 0; } }
@@@
63~63
fn main() -> i32 { let a: i32 = -5; let q: i64 = (1 == 2) ? 0 : a; if (q == -5) { return 63; } else { return 0; } }
@@@
64~64
fn main() -> i32 { let q: i64 = (1 == 1) ? 1000000000000 : 2000000000000; if (q == 1000000000000) { return 64; } else { return 0; } }
@@@
65~65
fn main() -> i32 { if (-4294967297 % 7 == -5) { return 65; } else { return 0; } }
@@@
66~66
fn main() -> i32 { let a: i32 = -5; let q: i64 = a; if (q == -5) { return 66; } else { return 0; } }
@@@
81~81
fn main() -> i32 { let c: i64[2] = 0; c[0] = 1000000000000; c[1] = 2000000000000; if (c[0] + c[1] == 3000000000000) { return 81; } else { return 0; } }
@@@
82~82
fn main() -> i32 { let c: i64[1] = 1000000000000; if (c[0] == 1000000000000) { return 82; } else { return 0; } }
@@@
83~83
fn main() -> i32 { let c: u32[2] = 0; c[0] = 4000000000; if (c[0] == 4000000000) { return 83; } else { return 0; } }
@@@
84~84
fn main() -> i32 { let c: u16[3] = 0; c[0] = 1; c[1] = 2; c[2] = 3; if (c[0] + c[1] + c[2] == 6) { return 84; } else { return 0; } }
@@@
85~85
fn main() -> i32 { let c: u8[3] = 0; c[0] = 1; c[1] = 2; c[2] = 3; if (c[0] + c[1] + c[2] == 6) { return 85; } else { return 0; } }
@@@
86~86
fn main() -> i32 { let c: i64[2] = 0; let z: i64 = 99; c[0] = 1; c[1] = 2; if (c[0] == 1 && c[1] == 2 && z == 99) { return 86; } else { return 0; } }
@@@
87~87
fn main() -> i32 { let c: i64[3] = 0; c[0] = 1000000000000; c[1] = 2000000000000; c[2] = 3000000000000; if (c[0] + c[1] + c[2] == 6000000000000) { return 87; } else { return 0; } }
@@@
91~91
fn main() -> i32 { let a: i32 = 2147483647; if (a + 1 == -2147483648) { return 91; } else { return 0; } }
@@@
92~92
fn main() -> i32 { let a: u32 = 4000000000; if (a / 1000000000 == 4) { return 92; } else { return 0; } }
@@@
93~93
fn main() -> i32 { let x: i64 = 5; if (x + 1 == 6) { return 93; } else { return 0; } }
@@@
94~94
fn main() -> i32 { let a: i32 = -3; if (a * 2 == -6) { return 94; } else { return 0; } }
@@@
95~95
fn main() -> i32 { let a: u32 = 4294967295; if (a + 1 == 0) { return 95; } else { return 0; } }
@@@
96~96
fn main() -> i32 { let x: i64 = -5; if (x * 3 == -15) { return 96; } else { return 0; } }
CASE_EOF

# ---------------------------------------------------------------------------
# [1] Strict build: any warning is a hard error.
# ---------------------------------------------------------------------------
printf '%s\n' '[1/7] Strictly build Aster compiler (-Wall -Wextra -pedantic -Werror)'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
# [2] Source guards: pin the three width rules, the per-leaf widening, the
#     slotElemTypes write, and the absence of any post-hoc widening helper.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/7] Source guards: the three width rules and the leaf widening'
guard() { # $1 = description, $2 = pattern, $3 = expected count
    n=$(grep -cF -- "$2" src/aster.cpp || true)
    if [ "$n" != "$3" ]; then
        echo "FAIL: $1: expected $3 occurrence(s) of '$2', found $n" >&2; exit 1
    fi
}
guard 'constExceedsI32 helper'            'static bool constExceedsI32(const Expr& e){'                1
guard 'constExceedsI32 peels Neg'         'if(p->k==Expr::Neg){ neg=true; p=p->a.get(); }'             1
guard 'constExceedsI32 thresholds'        'return neg ? (p->n>0x80000000ull) : (p->n>0x7fffffffull);'  1
guard 'wideOp helper'                     'static bool wideOp(Ty want,Ty ta,Ty tb,const Expr& a,const Expr& b){' 1
guard 'wideOp combines all four inputs'   'return tyIs64(want)||tyIs64(ta)||tyIs64(tb)||constExceedsI32(a)||constExceedsI32(b);' 1
guard 'wideOp arithmetic sites'           'const bool wide=wideOp(want,ta,tb,*e.a,*e.b);'               3
guard 'shift/bitnot width sites'          'const bool wide=tyIs64(want)||tyIs64(ta)||constExceedsI32(*e.a);' 2
guard 'genBool comparison width'          'const bool wide=tyIs64(ta)||tyIs64(tb)||constExceedsI32(*e.a)||constExceedsI32(*e.b);' 1
guard 'emitCondition comparison width'    'const bool wide=tyIs64(ta)||tyIs64(tb)||constExceedsI32(*c.a)||constExceedsI32(*c.b);' 1
guard 'local Var leaf SXTW'               'if(tyIs64(want)&&slotType(slot)==Ty::I32)emit(0x93407c00u'  1
guard 'global Var leaf SXTW'              'if(tyIs64(want)&&globalTypeOf(e.name)==Ty::I32)emit(0x93407c00u' 1
# v0.23.37-dev: a typed indirect call gained the same leaf — its rt is the
# signature's return type (i32 for a bare ptr, which is the old rule), so the
# sign-extension a direct call's i32 result has always had now covers a typed
# fn-pointer's i32 result too. Two sites, one rule.
guard 'Call leaf SXTW'                    'if(tyIs64(want)&&rt==Ty::I32)emit(0x93407c00u'              2
guard 'Deref leaf SXTW'                   'if(tyIs64(want))emit(0x93407c00u|(uint32_t(a)<<5)|uint32_t(a));' 1
guard 'Field leaf SXTW'                   'if(tyIs64(want)&&f->ty==Ty::I32)emit(0x93407c00u'           1
# v0.23.28-dev: the local, global and ptr index paths compute their address in
# one place (emitElemAddr) and read it through one leaf, so the three SXTW
# sites this guard used to count are now one statement — a ptr local indexes
# at the one-i32 stride, which is the same element type the leaf tests.
# v0.23.31-dev: a subscript *chain* (`a[i][j]`) computes its address in the new
# emitIndexAddr and reads through its own leaf, which is the twin of the
# one-dimensional statement below it — two now, and the one-dimensional path is
# untouched, so the count is 3 with the chain's leaf named rather than merged.
# v0.23.34-dev: an array *parameter* decays to a strided ptr<T>, and `(&arr)[i]`
# takes the address of an array and subscripts it in one expression — both read
# an i32 element through a ptr-to-elem base whose address emitPtrElemAddr
# materializes, so that read sign-extends through its own copy of the same leaf.
# The count is 4 with this third shape named rather than merged.
guard 'Index leaf SXTW (named+chain+field+ptrToElem)' 'if(tyIs64(want)&&elem==Ty::I32)emit(0x93407c00u'  4
guard 'Index leaf SXTW (chain read)'      'const Ty elem=ch.elem;'                                          1
# v0.23.37-dev: the indirect leaf gained the rt test — its rt is the
# signature's return type for a typed callee and i32 for a bare ptr, which is
# the old rule — so its text is now the direct call's, one rule at two sites.
guard 'indirect-call leaf SXTW'          'if(tyIs64(want)&&rt==Ty::I32)emit(0x93407c00u'              2
# v0.23.34-dev: the ptr-index path no longer hard-codes i32 — it derives the
# element from the slot's pointer type and reaches the shared emitElemIndex leaf
# with it, so a typed pointer strides at its real width while an untyped ptr
# keeps the one-i32 stride. The old pin was the literal `emitElemIndex(r,Ty::I32);`.
guard 'ptr index derives ptr<T> element'  'if(tyIsPtrToElem(st))pe=ptrElemType(st);'                          1
guard 'ptr index derives ptr<S> element'  'else if(tyIsPtrToStruct(st))pe=Ty::ofStruct(st.sid);'              1
guard 'ptr index reaches the shared leaf' 'emitElemIndex(r,pe);'                                                1
guard 'Cond arm width'                    'const Ty armTy=tyIs64(want)?Ty::I64:exprType(e);'           1
guard 'Neg passes want through'           'int a=gen(*e.a,want);'                                      1
# v0.23.28-dev: three paths allocate a local array now — a struct element
# (one store per element), a ptr element (an address per element) and the
# constant fill every element type before this round used — and each one
# has to record the element type, or a later a[i] reads it at i32 width.
guard 'slotElemTypes is written'          'slotElemTypes[slot]=elem;'                                  3
guard 'array slot size from element type' 'const uint32_t esz=tySize(elem);'                           1
guard 'array init store width by esz'     'const uint32_t strBase=esz==1?0x39000000u:esz==2?0x79000000u:esz==8?0xf9000000u:0xb9000000u;' 1
# Rule (2) says no consumer widens after the fact, so the SXTW instruction may
# appear at the leaf sites above and NOWHERE else — in particular not in a
# shared helper that an arithmetic site could call. v0.23.24-dev added a leaf
# for an indirect call: its result is i32 by contract (there is no signature to
# say otherwise), so the Call rule applied to the untyped callee gives a
# 64-bit consumer the same SXTW the direct call's leaf gives — the leaf
# widening itself from its own type, not a post-hoc consumer widening.
# v0.23.28-dev then merged the three index leaves — local array, global array
# and the ptr local indexed at one i32 stride — into the single leaf above,
# because all three now read through emitElemAddr.
# v0.23.31-dev added the ninth: a subscript chain (`a[i][j]`) reads its element
# through its own leaf, the twin of the one-dimensional statement two arms
# below it, because the chain computes its address in emitIndexAddr rather than
# emitElemAddr. A leaf widening itself from its own type — rule (2) again — not
# a consumer widening after the fact.
# v0.23.34-dev added the tenth: an array parameter's decayed ptr<T>, and
# `(&arr)[i]`, read an i32 element through emitPtrElemAddr and sign-extend it
# with the same leaf — the fourth copy of the index-leaf statement.
# v0.23.38-dev added the eleventh: a call through a struct field of function
# type (`h.cb(x)`) reads its i32 result at the declared return width, the same
# leaf a call through a typed fn-pointer variable already used.
guard 'total SXTW sites'                  '0x93407c00u'                                                11
if grep -qF 'extendTo64' src/aster.cpp; then
    echo 'FAIL: extendTo64 (the post-hoc widening helper) must stay deleted' >&2; exit 1
fi
printf '%s\n' 'PASS: three width rules, ten leaf SXTW sites, slotElemTypes write and no post-hoc widening'

# ---------------------------------------------------------------------------
# [3] Rejection matrix: the width rules must not have loosened typing.
# ---------------------------------------------------------------------------
printf '%s\n' '[3/7] Rejection: width discipline unchanged (negative layer)'
cat > "$W/narrow-arg.ast" <<'AST'
fn f(x: i32) -> i32 { return 0; }
fn main() -> i32 { let y: i64 = 5; return f(y); }
AST
if out=$("$OUT/aster" build-elf "$W/narrow-arg.ast" -o "$W/narrow-arg" 2>&1); then
    echo 'FAIL: compiler accepted an i64 argument for an i32 parameter' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF "argument type mismatch calling f at argument 1: expected i32, got i64" \
    || { echo "FAIL: wrong diagnostic for i64->i32 argument: $out" >&2; exit 1; }

cat > "$W/lit-range.ast" <<'AST'
fn main() -> i32 { let x: i64 = 10000000000000000000; return 0; }
AST
if out=$("$OUT/aster" build-elf "$W/lit-range.ast" -o "$W/lit-range" 2>&1); then
    echo 'FAIL: compiler accepted a literal wider than i64' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF "integer literal exceeds i64 range" \
    || { echo "FAIL: wrong diagnostic for over-wide literal: $out" >&2; exit 1; }
printf '%s\n' 'PASS: i64->i32 argument and over-wide literal still rejected with the same diagnostics'

# ---------------------------------------------------------------------------
# [4] qemu positive matrix. run_case: build one case and assert its exit code.
# ---------------------------------------------------------------------------
printf '%s\n' '[4/7] Acceptance: 54 qemu cases in 8 groups'
run_case() { # $1 = binary-under-test, $2 = code; uses $CASES/$W
    bin=$1; code=$2
    awk -v c="$code" 'BEGIN{RS="@@@\n"} $1~("^"c"~"){printf "%s",$0}' "$CASES" > "$W/one.txt"
    want=$(head -1 "$W/one.txt" | cut -d'~' -f2)
    tail -n +2 "$W/one.txt" > "$W/p.ast"
    if ! "$bin" build-elf "$W/p.ast" -o "$W/p.a64" >"$W/build.log" 2>&1; then
        echo "FAIL: case $code did not compile:" >&2; cat "$W/build.log" >&2; return 1
    fi
    got=0; sh tests/run-aarch64.sh "$W/p.a64" >/dev/null 2>&1 || got=$?
    if [ "$got" != "$want" ]; then
        # The mutation layer calls run_case expecting failure (a caught mutant);
        # QUIET keeps its stderr free of diagnostics that look like real faults.
        if [ -z "${QUIET:-}" ]; then
            echo "FAIL: case $code expected exit $want, got $got" >&2
            echo "----- source -----" >&2; cat "$W/p.ast" >&2
        fi
        return 1
    fi
    return 0
}
run_group() { # $1 = group name, rest = case codes
    gname=$1; shift
    gok=0; gbad=0
    for code in "$@"; do
        if run_case "$OUT/aster" "$code"; then gok=$((gok+1)); else gbad=$((gbad+1)); fi
    done
    if [ "$gbad" -ne 0 ]; then
        echo "FAIL: group '$gname': $gbad of $((gok+gbad)) cases wrong" >&2; exit 1
    fi
    printf 'PASS: %-52s %2d cases\n' "$gname" "$gok"
}
run_group 'A wide literals consumed as i32 + comparison width' 36 37 38 39 47 60 65
run_group 'B i64 local, full operator spectrum'               11 12 13 14 15 16 17 18 19 20 21
run_group 'C i64 operand, i32 consumer'                       31 32 33 34 35
run_group 'D negative constants and INT64_MIN'                41 42 43 44
run_group 'E leaf widening: call/field/index/deref/neg/var'   51 52 53 54 55 56 57 58 59 66
run_group 'F conditional arms generated at the result width'  61 62 63 64
run_group 'G local array element types'                       81 82 83 84 85 86 87
run_group 'H must stay 32-bit (regression guards)'            91 92 93 94 95 96

# ---------------------------------------------------------------------------
# [5] C differential: an independent oracle. The same expressions compiled by
#     an AArch64 C compiler must return the same exit codes. Skipped cleanly
#     when no AArch64-emitting cc is available (e.g. an x86-only runner).
# ---------------------------------------------------------------------------
printf '%s\n' '[5/7] C differential cross-check (independent oracle)'
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
hostcc_flags=""
if [ -n "$HOSTCC" ]; then
    printf 'int main(){return 0;}\n' > "$W/hostprobe.c"
    for f in "-static" ""; do
        if "$HOSTCC" -O2 -fwrapv $f "$W/hostprobe.c" -o "$W/hostprobe" 2>/dev/null; then
            if readelf -h "$W/hostprobe" 2>/dev/null | grep -q 'AArch64'; then hostcc_flags=$f; break; fi
        fi
    done
fi
if [ -z "$hostcc_flags" ] && [ -n "$HOSTCC" ]; then
    # HOSTCC was given but cannot emit AArch64 (e.g. ci.sh's plain cc fallback
    # on an x86 host): the differential has no oracle to compare against.
    echo "SKIP: C differential needs an AArch64 C compiler ($HOSTCC is not one)"
elif [ -z "$HOSTCC" ]; then
    echo "SKIP: C differential needs an AArch64 C compiler (none found)"
else
    diffok=0
    while IFS='@' read -r code csrc; do
        [ -n "$code" ] || continue
        printf '%s\n' "$csrc" > "$W/c$code.c"
        if ! "$HOSTCC" -O2 -fwrapv $hostcc_flags "$W/c$code.c" -o "$W/c$code" 2>"$W/c$code.log"; then
            echo "FAIL: C host for case $code did not compile:" >&2; cat "$W/c$code.log" >&2; exit 1
        fi
        crc=0; sh tests/run-aarch64.sh "$W/c$code" >/dev/null 2>&1 || crc=$?
        if ! run_case "$OUT/aster" "$code"; then exit 1; fi
        awk -v c="$code" 'BEGIN{RS="@@@\n"} $1~("^"c"~"){printf "%s",$0}' "$CASES" > "$W/one.txt"
        want=$(head -1 "$W/one.txt" | cut -d'~' -f2)
        if [ "$crc" != "$want" ]; then
            echo "FAIL: case $code: C oracle returned $crc, expected $want" >&2; exit 1
        fi
        diffok=$((diffok+1))
    done <<'CDIFF_EOF'
13@int main(){ if (1000000 * 3000000000 == 3000000000000000LL) return 13; return 0; }
14@int main(){ if (1000000000000 / 7 == 142857142857) return 14; return 0; }
16@int main(){ if (1000000000000 << 1 == 2000000000000) return 16; return 0; }
17@int main(){ if (1000000000000 >> 20 == 953674) return 17; return 0; }
21@int main(){ if (~1000000000000 == -1000000000001) return 21; return 0; }
31@int main(){ long x = 4294967297; return x % 7; }
36@int main(){ return 1000000000000 % 7; }
37@int main(){ return 4294967297 / 1000000000; }
38@int main(){ return 8589934593 == 4294967297 ? 1 : 0; }
43@int main(){ long q = -9223372036854775807LL - 1; return q == -9223372036854775807LL - 1 ? 43 : 0; }
62@int main(){ long long q = (1==2) ? 0 : 4294967297; if (q == 4294967297) return 62; return 0; }
81@int main(){ long long c[2]; c[0]=1000000000000; c[1]=2000000000000; if (c[0] + c[1] == 3000000000000) return 81; return 0; }
91@int main(){ int a = 2147483647; if (a + 1 == -2147483647 - 1) return 91; return 0; }
95@int main(){ unsigned a = 4294967295u; if (a + 1 == 0) return 95; return 0; }
CDIFF_EOF
    printf 'PASS: Aster and %s agree on %d wide-integer expressions\n' "$HOSTCC" "$diffok"
fi

# ---------------------------------------------------------------------------
# [6] Mutation layer: revert one rule of the round's own diff at a time and
#     require the matrix to catch it. A mutant that compiles but passes its
#     discriminators means the suite cannot see that rule — the same blind
#     spot that let defect B ship. Mutants build in small batches: all sixteen
#     at once starved each other into uninterruptible I/O waits on a busy box
#     (measured: 20 minutes without finishing), so four at a time is the
#     compromise that stays predictable. Discriminator cases run serially.
# ---------------------------------------------------------------------------
# v0.23.28-dev: two entries changed shape. M6a/M6b (the local- and global-index
# SXTW, peeled apart by the base materialization that preceded them) are one
# mutant now, because the three index paths share a leaf — and it has to be
# caught once per shape (54/57/58) or the merge would be hiding a shape it no
# longer covers. M11, which used to peel the ptr index's own SXTW, takes the
# other half of an element read instead: its WIDTH. An i64 element loaded with
# LDR W is sign-extended garbage at 64 bits (81/82/87).
printf '%s\n' '[6/7] Mutation layer: 16 single-rule mutants, each must be caught'
cp src/aster.cpp "$W/orig.cpp"
n=0; pids=""
drain() { for p in $pids; do wait "$p" || true; done; pids=""; }
while IFS='~' read -r label kind program codes; do
    [ -n "$label" ] || continue
    n=$((n+1))
    printf '%s\n' "$label"  > "$W/m$n.label"
    printf '%s\n' "$codes"  > "$W/m$n.codes"
    if [ "$kind" = sed ]; then
        cp "$W/orig.cpp" "$W/m$n.cpp"
        sed -i "$program" "$W/m$n.cpp"
    else
        awk "$program" "$W/orig.cpp" > "$W/m$n.cpp"
    fi
    if diff -q "$W/orig.cpp" "$W/m$n.cpp" >/dev/null; then
        echo "FAIL: mutation '$label' did not apply (sed/awk matched nothing)" >&2; exit 1
    fi
    # shellcheck disable=SC2086
    c++ -std=c++17 -O2 -w "$W/m$n.cpp" -o "$W/m$n-aster" 2>"$W/m$n.build.log" &
    pids="$pids $!"
    if [ $((n % 4)) -eq 0 ]; then drain; fi
done <<'MUT_EOF'
M1 wideOp drops const~sed~s/||constExceedsI32(a)||constExceedsI32(b)//~36 37
M2a genBool cmp drops const~sed~s/constExceedsI32(\*e\.a)||constExceedsI32(\*e\.b)/false/~47
M2b cond cmp drops const~sed~s/constExceedsI32(\*c\.a)||constExceedsI32(\*c\.b)/false/~38
M3 call leaf SXTW removed~sed~/if(tyIs64(want)&&rt==Ty::I32)emit(0x93407c00u/d~51
M4 deref leaf SXTW removed~sed~/if(tyIs64(want))emit(0x93407c00u|(uint32_t(a)<<5)|uint32_t(a));/d~55
M5 field leaf SXTW removed~sed~/if(tyIs64(want)&&f->ty==Ty::I32)emit(0x93407c00u/d~53
M6 idx leaf SXTW removed~sed~/if(tyIs64(want)&&elem==Ty::I32)emit(0x93407c00u/d~54 57 58
M7 slotElemTypes removed~sed~s/slotElemTypes\[slot\]=elem;//~81 82 83
M8 cond armTy reverted~sed~s/const Ty armTy=tyIs64(want)?Ty::I64:exprType(e);/const Ty armTy=exprType(e);/~61 62 63 64
M9 array esz forced to 4~sed~s/const uint32_t esz=tySize(elem);/const uint32_t esz=4u;/~82 86
M10 global var SXTW removed~sed~/if(tyIs64(want)&&globalTypeOf(e.name)==Ty::I32)emit(0x93407c00u/d~56
M11 element load width ignored~sed~s/emit(loadGlobalT(d,elem));/emit(loadGlobalT(d,Ty::I32));/~81 82 87
M12 Neg want passthrough~sed~s/int a=gen(\*e.a,want);/int a=gen(*e.a);/~59
M13 pos threshold raised~sed~s/(p->n>0x7fffffffull)/(p->n>0x80000000ull)/~60
M14 neg peel removed~sed~s/if(p->k==Expr::Neg){ neg=true; p=p->a.get(); }//~65
M15 local var SXTW removed~sed~/if(tyIs64(want)&&slotType(slot)==Ty::I32)emit(0x93407c00u/d~66 59
MUT_EOF
drain
i=0; missing=""
while [ "$i" -lt "$n" ]; do
    i=$((i+1))
    if [ ! -x "$W/m$i-aster" ]; then
        missing="$missing $i:$(cat "$W/m$i.label")"
        echo "----- build log of mutant $i ($(cat "$W/m$i.label")) -----" >&2
        tail -n 5 "$W/m$i.build.log" >&2 || true
    fi
done
if [ -n "$missing" ]; then
    echo "FAIL: mutant build(s) failed:$missing" >&2
    exit 1
fi
mutbad=0
i=0
while [ "$i" -lt "$n" ]; do
    i=$((i+1))
    label=$(cat "$W/m$i.label"); codes=$(cat "$W/m$i.codes")
    caught=""; missed=""
    for code in $codes; do
        if QUIET=1 run_case "$W/m$i-aster" "$code"; then missed="$missed $code"; else caught="$caught $code"; fi
    done
    if [ -n "$missed" ]; then
        echo "FAIL: mutation '$label' NOT CAUGHT by:$missed" >&2; mutbad=$((mutbad+1))
    else
        printf 'PASS: %-30s caught by:%s\n' "$label" "$caught"
    fi
done
if [ "$mutbad" -ne 0 ]; then
    echo "FAIL: $mutbad mutation(s) survived — the suite is blind to them" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# [7] Blind spots, stated plainly. These are properties of the test space, not
#     failures; the mutation layer above is what keeps them honest.
# ---------------------------------------------------------------------------
printf '%s\n' '[7/7] Documented blind spots (why some cases are guards, not discriminators)'
cat <<'BLIND'
  (a) Consistent truncation. A case whose expected value and the buggy
      computation both truncate to the same 32-bit pattern passes under the
      bug: case 39 (8589934593 == 8589934593) compares 1 == 1 at 32 bits and
      "passes" although the comparison was wrong. Rule applied: a discriminator
      either compares a large positive constant at full width (36/37/38/47/60/
      65) or does not compare against a large constant at all. Case 39 is kept
      as a forward guard only, and the mutation layer uses 47/38 instead.
  (b) AND cannot see a missing sign-extension. `x & 7` discards the upper bits,
      so a value that was zero-extended instead of sign-extended yields the
      same low bits: case 34 (x & 7 == 1) cannot discriminate the Var/leaf
      SXTW mutations. It stays as a forward guard; the leaf mutations are
      pinned by cases that compare the widened value itself (51/53/54/55/
      56/57/58/59/66).
  (c) u32 returns must NOT be extended. Case 52 pins that a u32 call result
      consumed as i64 keeps its zero-extended value (no SXTW): the mutation
      layer's M3 removes the SXTW for i32 returns only, so 52 is the guard
      that an over-eager fix would break.
BLIND
printf '%s\n' 'PASS: blind spots documented; mutation layer proves the discriminators avoid them'
printf '%s\n' 'ALL CHECKS PASSED'
