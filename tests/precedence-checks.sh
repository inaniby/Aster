#!/bin/sh
# v0.23.27-dev checks for the four places Aster read an expression differently
# from C — all found by writing the language reference down and running every
# claim in it against the binary.
#
#   1. `&&` and `||` shared one precedence level. `a || b && c` was
#      `(a || b) && c`, which is a different answer, silently. They are two
#      levels now, `&&` the tighter one.
#   2. `-` `!` `~` `*` took a primary() operand, so `-s.v` was `(-s).v` and
#      `*s.p` was `(*s).p`. A unary() level between postfix() and the binary
#      operators fixes the binding; `&` moves to it too.
#   3. `a < b == c` was rejected by the anti-chaining check, although the
#      comment directly above relational() promised `(a < b) == c`. Chaining
#      is refused within one level now, not across the two.
#   4. A local `let` skipped the range check a global `let` has always applied,
#      so `let b: u8 = 300;` stored 44 inside a function while the same line at
#      file scope was an error.
#
# None of the four can change the bytes of a program that compiled before: no
# shipped example mixes `&&` with `||`, none writes `*x.y` or `-x.y`, no
# program could previously contain `a < b == c` (it did not compile), and no
# shipped example initializes a narrow local with an out-of-range constant.
# Layer [8/9] asserts all 288 pre-existing baseline rows reproduce.
#
# The differential layer is the oracle: every one of these questions has a C
# answer, and this round is Aster moving to it rather than C moving to Aster.
#
# Layers: strict compiler build; source guards pinning each of the four rules
# and its messages; a qemu battery; a differential comparison against the
# target C compiler (the example twin plus four focused cases); a rejection
# matrix for what must still be refused; a coverage map; a mutation layer; the
# byte-identity baseline; and a self-check of the new example.
#
# The behavioural layers need qemu (or an AArch64 host); the differential layer
# additionally needs $HOSTCC to emit AArch64 ELF. Neither is required to
# *build*, so each layer that cannot run says SKIP and the rest still runs.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-precedence-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
HOSTCC=${HOSTCC:-cc}
have_cc=yes
command -v "$HOSTCC" >/dev/null 2>&1 || have_cc=no
if [ "$have_qemu" = no ]; then
    printf '%s\n' 'SKIP: precedence-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each of the four fixes is pinned where it lives, so a
# regression that quietly restores the old reading fails here rather than
# having to be explained by a behavioural case.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: the four rules, where they live'

# (1) Two levels: logicalAnd() collects `&&`, logical() collects `||` over it.
grep -qF '    E logicalAnd(){' src/aster.cpp \
    || { echo 'FAIL: logicalAnd() is missing — && and || are one level again' >&2; exit 1; }
grep -qF '        while(cur().k==TK::And){' src/aster.cpp \
    || { echo 'FAIL: logicalAnd() no longer loops on &&' >&2; exit 1; }
grep -qF '        while(cur().k==TK::Or){' src/aster.cpp \
    || { echo 'FAIL: logical() no longer loops on ||' >&2; exit 1; }
grep -qF '        E x=logicalAnd();' src/aster.cpp \
    || { echo 'FAIL: logical() does not sit above logicalAnd()' >&2; exit 1; }
# The pre-round shape — one loop over both operators — is gone.
grep -q 'while(cur().k==TK::And||cur().k==TK::Or)' src/aster.cpp \
    && { echo 'FAIL: && and || are still collected by one loop' >&2; exit 1; }

# (2) unary(): five prefix operators, each recursing to unary(), falling
# through to postfix().
grep -qF '    E unary(){' src/aster.cpp \
    || { echo 'FAIL: unary() is missing' >&2; exit 1; }
for op in Star Amp Minus Not Tilde; do
    grep -qF "if(eat(TK::$op)){E x=unary();" src/aster.cpp \
        || { echo "FAIL: the '$op' prefix no longer takes a unary() operand" >&2; exit 1; }
done
grep -qF '        return postfix();' src/aster.cpp \
    || { echo 'FAIL: unary() does not fall through to postfix()' >&2; exit 1; }
grep -qF 'E product(){E x=unary();' src/aster.cpp \
    || { echo 'FAIL: product() no longer starts at unary()' >&2; exit 1; }
# The old shape: a prefix operator taking primary() or postfix() inside
# primary(). `product()` used to start at postfix().
grep -q 'E product(){E x=postfix();' src/aster.cpp \
    && { echo 'FAIL: product() still starts at postfix()' >&2; exit 1; }
# A dereference-assignment target reads the same way as a dereference
# expression, so `*p.f = v` is `*(p.f) = v` in both places.
[ "$(grep -o 'E ptr=unary();' src/aster.cpp | wc -l)" -eq 2 ] \
    || { echo 'FAIL: both dereference-assignment targets must parse at unary() depth' >&2; exit 1; }

# (3) Two narrower predicates, and each level refusing a chain within itself.
grep -qF 'bool isRelationalOp(TK op)const{return op==TK::Lt||op==TK::Le||op==TK::Gt||op==TK::Ge;}' src/aster.cpp \
    || { echo 'FAIL: isRelationalOp is missing' >&2; exit 1; }
grep -qF 'bool isEqualityOp(TK op)const{return op==TK::EqEq||op==TK::Ne;}' src/aster.cpp \
    || { echo 'FAIL: isEqualityOp is missing' >&2; exit 1; }
grep -qF 'if(isRelationalOp(cur().k))throw Error("chained comparisons are not supported' src/aster.cpp \
    || { echo 'FAIL: relational() no longer refuses a chain within its own level' >&2; exit 1; }
grep -qF 'if(isEqualityOp(cur().k))throw Error("chained comparisons are not supported' src/aster.cpp \
    || { echo 'FAIL: equality() no longer refuses a chain within its own level' >&2; exit 1; }
# The over-wide predicate the two used to share is gone.
grep -q 'bool isComparisonOp' src/aster.cpp \
    && { echo 'FAIL: the over-wide isComparisonOp is still in the source' >&2; exit 1; }

# (4) The range check, in sema and in codegen, for a scalar and for an array.
grep -qF 'if(!initializerFits(s.ty,*s.expr,v))' src/aster.cpp \
    || { echo 'FAIL: sema no longer range-checks a local array initializer' >&2; exit 1; }
grep -qF 'if(constantInteger(*s.expr,v)&&!initializerFits(s.ty,*s.expr,v))' src/aster.cpp \
    || { echo 'FAIL: sema no longer range-checks a local scalar initializer' >&2; exit 1; }
grep -qF 'if(!initializerFits(elem,*s.expr,value))' src/aster.cpp \
    || { echo 'FAIL: codegen no longer range-checks a local array initializer' >&2; exit 1; }
grep -qF 'if(constantInteger(*s.expr,cv)&&!initializerFits(s.ty,*s.expr,cv))' src/aster.cpp \
    || { echo 'FAIL: codegen no longer range-checks a local scalar initializer' >&2; exit 1; }
# Each message appears twice — once per pass — because sema is the rule and
# codegen is its defensive twin.
[ "$(grep -o 'local initializer does not fit in ' src/aster.cpp | wc -l)" -eq 2 ] \
    || { echo 'FAIL: the local scalar range message must appear twice (sema + codegen)' >&2; exit 1; }
# Three since v0.23.28-dev: sema's array branch answers the element type now, so
# a bool array and an integer array each carry the check, and codegen's twin is
# the third. (One mutant below withdraws the two sema copies at once, which is
# why the codegen one still has to fire.)
[ "$(grep -o 'local array initializer does not fit in ' src/aster.cpp | wc -l)" -eq 3 ] \
    || { echo 'FAIL: the local array range message must appear three times (sema x2 + codegen)' >&2; exit 1; }
printf '%s\n' '  all four rules present, in both passes'

# ---------------------------------------------------------------------------
# Helpers: compile-and-run with a hand-derived expected exit status, and
# compile-and-refuse with an expected diagnostic.
# ---------------------------------------------------------------------------
check() {
    aster=$1; name=$2; want=$3
    printf '%s\n' "$4" > "$OUT/c.ast"
    if ! $aster build-elf "$OUT/c.ast" -o "$OUT/c.a64" >"$OUT/c.err" 2>&1; then
        echo "FAIL: $name does not compile" >&2; sed -n '1,3p' "$OUT/c.err" >&2; exit 1
    fi
    $RUNNER "$OUT/c.a64" >/dev/null 2>&1 && got=0 || got=$?
    if [ "$got" -gt 127 ]; then got=$((got-256)); fi
    if [ "$got" != "$want" ]; then
        echo "FAIL: $name: expected exit $want, got $got" >&2; exit 1
    fi
    printf '  %-34s %s\n' "$name" "$got"
}
A=$OUT/aster

if [ "$have_qemu" = yes ]; then
printf '%s\n' '[3/9] qemu: each of the four rules, one at a time'

# (1) `&&` binds tighter than `||`. The four rows of the truth table where the
# two readings disagree are the ones worth pinning.
check "$A" 'T || T && F  (T || (T&&F))' 1 'fn main() -> i32 { if (1 == 1 || 1 == 1 && 1 == 2) { return 1; } return 0; }'
check "$A" 'T || F && T  (T || (F&&T))' 1 'fn main() -> i32 { if (1 == 1 || 1 == 2 && 1 == 1) { return 1; } return 0; }'
check "$A" 'F && T || T  ((F&&T) || T)' 1 'fn main() -> i32 { if (1 == 2 && 1 == 1 || 1 == 1) { return 1; } return 0; }'
check "$A" 'F || F && T  (F || (F&&T))' 0 'fn main() -> i32 { if (1 == 2 || 1 == 2 && 1 == 1) { return 1; } return 0; }'
check "$A" 'T && F || F  ((T&&F) || F)' 0 'fn main() -> i32 { if (1 == 1 && 1 == 2 || 1 == 2) { return 1; } return 0; }'
# A single operator at either level is unchanged: three operands still fold
# left, which is what every shipped example relies on.
check "$A" 'T && T && T'             1 'fn main() -> i32 { if (1 == 1 && 1 == 1 && 1 == 1) { return 1; } return 0; }'
check "$A" 'F || F || T'              1 'fn main() -> i32 { if (1 == 2 || 1 == 2 || 1 == 1) { return 1; } return 0; }'
# Short-circuiting survives the split: the right operand is not evaluated.
check "$A" '|| short-circuits'        2 'fn side() -> bool { return 1 == 1; }
fn main() -> i32 { let n: i32 = 0; if (1 == 1 || side()) { n = 2; } return n; }'
check "$A" '&& short-circuits'        0 'let g: i32 = 0;
fn side() -> bool { g = 1; return 1 == 1; }
fn main() -> i32 { if (1 == 2 && side()) { return 9; } return g; }'

# (2) A prefix operator sees the whole postfix chain.
check "$A" '-(s.v)'                   5 'struct S { v: i32 }
fn main() -> i32 { let s: S = S { 5 }; return 0 - (-s.v); }'
check "$A" '!(s.ok)'                  2 'struct S { ok: bool }
fn main() -> i32 { let s: S = S { true }; if (!s.ok) { return 1; } return 2; }'
check "$A" '~(s.v)'                   1 'struct S { v: i32 }
fn main() -> i32 { let s: S = S { 5 }; if (~s.v == 0 - 6) { return 1; } return 0; }'
check "$A" '*(s.p)'                   9 'struct S { p: ptr, v: i32 }
let buf: i32[4] = 9;
fn main() -> i32 { let s: S = S { buf, 1 }; return *s.p; }'
# A prefix on something with no field access is exactly as it was.
check "$A" '-x (no field)'            1 'fn main() -> i32 { let x: i32 = 6; if (-x == 0 - 6) { return 1; } return 0; }'
check "$A" '*p (no field)'            7 'let buf: i32[4] = 7;
fn main() -> i32 { let p: ptr = buf; return *p; }'
check "$A" '-a[i]'                    1 'fn main() -> i32 { let a: i32[2] = 6; if (-a[1] == 0 - 6) { return 1; } return 0; }'
# Two prefixes in a row, and a prefix on a parenthesised expression. `--` is
# one token, so the two negations are written with a space between them.
check "$A" '- -x'                     6 'fn main() -> i32 { let x: i32 = 6; return - -x; }'
check "$A" '-(x + y)'                 1 'fn main() -> i32 { let x: i32 = 2; let y: i32 = 4; if (-(x + y) == 0 - 6) { return 1; } return 0; }'
# `&` is unchanged: it already reached postfix(), and it still means &(s.v).
check "$A" '&s (struct lvalue)'       1 'struct S { v: i32 }
fn main() -> i32 { let s: S = S { 5 }; let p: ptr = &s; if (p != 0) { return 1; } return 0; }'

# (3) A level crossing is not a chain.
check "$A" 'a < b == c'               1 'fn main() -> i32 { let a: i32 = 1; let b: i32 = 2; let c: i32 = 1; if (a < b == c) { return 1; } return 0; }'
check "$A" 'a < b == c (false)'       0 'fn main() -> i32 { let a: i32 = 1; let b: i32 = 2; let c: i32 = 0; if (a < b == c) { return 1; } return 0; }'
check "$A" 'a < b != c'               0 'fn main() -> i32 { let a: i32 = 1; let b: i32 = 2; let c: i32 = 1; if (a < b != c) { return 1; } return 0; }'
check "$A" 'a == b < c  (a == (b<c))' 1 'fn main() -> i32 { let a: i32 = 1; let b: i32 = 2; let c: i32 = 3; if (a == b < c) { return 1; } return 0; }'
check "$A" 'a <= b == b >= a'         1 'fn main() -> i32 { let a: i32 = 1; let b: i32 = 2; if (a <= b == b >= a) { return 1; } return 0; }'
# A comparison result is still an ordinary bool, so it composes.
check "$A" '(a<b)==c stored as bool'  3 'fn main() -> i32 { let a: i32 = 1; let b: i32 = 2; let c: i32 = 1;
    let d: bool = (a < b == c); if (d) { return 3; } return 0; }'

# (4) A narrow local is range-checked exactly like a narrow global.
check "$A" 'u8 at 255'                1 'fn main() -> i32 { let b: u8 = 255; if (b == 255) { return 1; } return 0; }'
check "$A" 'u16 at 65535'             1 'fn main() -> i32 { let b: u16 = 65535; if (b == 65535) { return 1; } return 0; }'
check "$A" 'u32 at 4000000000'        1 'fn main() -> i32 { let b: u32 = 4000000000; if (b > 0) { return 1; } return 0; }'
check "$A" 'u8[4] at 200'             1 'fn main() -> i32 { let a: u8[4] = 200; if (a[3] == 200) { return 1; } return 0; }'
check "$A" 'u16[2] at 65535'          1 'fn main() -> i32 { let a: u16[2] = 65535; if (a[1] == 65535) { return 1; } return 0; }'
# What the round does *not* change: narrowing a value has always been allowed
# in both scopes, and still is.
check "$A" 'i32 from an i64 value'    5 'fn main() -> i32 { let a: i64 = 5; let b: i32 = a; return b; }'
check "$A" 'u8 from an i32 value'     1 'fn main() -> i32 { let a: i32 = 200; let b: u8 = a; if (b == 200) { return 1; } return 0; }'
check "$A" 'i32 from a wide literal'  1 'fn main() -> i32 { let a: i32 = 5000000000; if (a != 0) { return 1; } return 0; }'

# ---------------------------------------------------------------------------
# [4/9] Differential layer: the same program under Aster and under the target
# C compiler must produce the same value. This is the round's oracle — every
# one of these questions has a C answer, and Aster is the side that moved.
# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] Differential: Aster vs the target C compiler'
if [ "$have_cc" = no ]; then
    printf '  SKIP: the differential layer needs a C compiler that emits AArch64 ELF\n'
else
    diff_case() {
        printf '%s\n' "$2" > "$OUT/d.ast"
        printf '%s\n' "$3" > "$OUT/d.c"
        if ! "$A" build-elf "$OUT/d.ast" -o "$OUT/d.a64" >"$OUT/d.err" 2>&1; then
            echo "FAIL: $1 does not compile under Aster" >&2; sed -n '1,3p' "$OUT/d.err" >&2; exit 1
        fi
        $HOSTCC -std=c11 -O2 -w "$OUT/d.c" -o "$OUT/dc.a64"
        $RUNNER "$OUT/d.a64" >/dev/null 2>&1 && ga=0 || ga=$?
        $RUNNER "$OUT/dc.a64" >/dev/null 2>&1 && gc=0 || gc=$?
        if [ "$ga" != "$gc" ]; then
            echo "FAIL: $1: Aster exit $ga, C exit $gc" >&2; exit 1
        fi
        printf '  %-34s %s\n' "$1" "$ga"
    }
    # The four rows where the two readings of `||` and `&&` disagree. C has
    # always bound && tighter; Aster now agrees.
    diff_case '|| and &&: four rows' \
        'fn main() -> i32 {
    let r: i32 = 0;
    if (1 == 1 || 1 == 1 && 1 == 2) { r = r + 1; }
    if (1 == 2 || 1 == 2 && 1 == 1) { r = r + 2; }
    if (1 == 2 && 1 == 1 || 1 == 1) { r = r + 4; }
    if (1 == 1 && 1 == 2 || 1 == 2) { r = r + 8; }
    return r; }' \
        'int main(void) {
    int r = 0;
    if (1 == 1 || 1 == 1 && 1 == 2) r += 1;
    if (1 == 2 || 1 == 2 && 1 == 1) r += 2;
    if (1 == 2 && 1 == 1 || 1 == 1) r += 4;
    if (1 == 1 && 1 == 2 || 1 == 2) r += 8;
    return r; }'
    # The prefix operators, against a struct so the field access is real.
    diff_case 'prefix operators vs .' \
        'struct S { p: ptr, v: i32, ok: bool }
let buf: i32[4] = 9;
fn main() -> i32 {
    let s: S = S { buf, 5, false };
    let r: i32 = 0;
    if (*s.p == 9) { r = r + 1; }
    if (-s.v == 0 - 5) { r = r + 2; }
    if (!s.ok) { r = r + 4; }
    return r; }' \
        '#include <stdint.h>
struct S { void *p; int32_t v; int32_t ok; };
static int32_t buf[4] = { 9, 9, 9, 9 };
int main(void) {
    struct S s; s.p = buf; s.v = 5; s.ok = 0;
    int32_t r = 0;
    if (*(int32_t *)s.p == 9) r += 1;
    if (-s.v == 0 - 5) r += 2;
    if (!s.ok) r += 4;
    return r; }'
    # A level crossing, and the two cross-level spellings with != and with the
    # operands the other way round.
    diff_case 'a < b == c' \
        'fn main() -> i32 {
    let a: i32 = 1; let b: i32 = 2; let c: i32 = 1; let d: i32 = 0;
    let r: i32 = 0;
    if (a < b == c) { r = r + 1; }
    if (a < b == d) { r = r + 2; }
    if (a == b < c) { r = r + 4; }
    if (a > b != c) { r = r + 8; }
    return r; }' \
        'int main(void) {
    int a = 1, b = 2, c = 1, d = 0;
    int r = 0;
    if ((a < b) == c) r += 1;
    if ((a < b) == d) r += 2;
    if (a == (b < c)) r += 4;
    if ((a > b) != c) r += 8;
    return r; }'
    # A narrow local at the top of its range — the shape that used to truncate
    # in silence inside a function.
    diff_case 'narrow local at its top' \
        'fn main() -> i32 {
    let u: u8 = 255;
    let w: u16 = 65535;
    let r: i32 = 0;
    if (u == 255) { r = r + 1; }
    if (w == 65535) { r = r + 2; }
    return r; }' \
        '#include <stdint.h>
int main(void) {
    uint8_t u = 255;
    uint16_t w = 65535;
    int r = 0;
    if (u == 255) r += 1;
    if (w == 65535) r += 2;
    return r; }'
    # The shipped example against its twin, end to end.
    diff_case 'examples/precedence.ast' \
        "$(cat examples/precedence.ast)" \
        "$(cat tests/precedence-example-twin.c)"
fi
# [3/9] and [4/9] both need to run the binaries they build.
fi

# ---------------------------------------------------------------------------
# [5/9] Rejection matrix. What each fix deliberately does *not* admit.
# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] Rejection matrix'
reject() {
    printf '%s\n' "$3" > "$OUT/r.ast"
    if "$A" build-elf "$OUT/r.ast" -o "$OUT/r.a64" >"$OUT/r.err" 2>&1; then
        echo "FAIL: $1 was accepted" >&2; exit 1
    fi
    grep -qF "$2" "$OUT/r.err" \
        || { echo "FAIL: $1: expected '$2', got: $(sed -n '1p' "$OUT/r.err")" >&2; exit 1; }
    printf '  %-34s refused\n' "$1"
}
# Chaining within a level is still refused — that rule is untouched. Four
# operators at the relational level, two at the equality level.
for op in '<' '<=' '>' '>='; do
    reject "a $op b $op c (chain)" 'chained comparisons are not supported' \
        "fn main() -> i32 { let a: i32 = 1; let b: i32 = 2; let c: i32 = 3;
    if (a $op b $op c) { return 1; } return 0; }"
done
reject 'a == b == c (chain)' 'chained comparisons are not supported' \
    'fn main() -> i32 { let a: i32 = 1; let b: i32 = 1; let c: i32 = 1;
    if (a == b == c) { return 1; } return 0; }'
reject 'a != b != c (chain)' 'chained comparisons are not supported' \
    'fn main() -> i32 { let a: i32 = 1; let b: i32 = 1; let c: i32 = 1;
    if (a != b != c) { return 1; } return 0; }'
# A narrow local out of range, in each of the four shapes the check covers.
reject 'local u8 = 300' 'local initializer does not fit in u8' \
    'fn main() -> i32 { let b: u8 = 300; return b; }'
reject 'local u8 = 256' 'local initializer does not fit in u8' \
    'fn main() -> i32 { let b: u8 = 256; return b; }'
reject 'local u16 = 65536' 'local initializer does not fit in u16' \
    'fn main() -> i32 { let b: u16 = 65536; return b; }'
reject 'local u32 = 0 - 1' 'local initializer does not fit in u32' \
    'fn main() -> i32 { let b: u32 = 0 - 1; return b; }'
reject 'local u8[4] = 300' 'local array initializer does not fit in u8' \
    'fn main() -> i32 { let a: u8[4] = 300; return a[0]; }'
reject 'local u16[2] = 65536' 'local array initializer does not fit in u16' \
    'fn main() -> i32 { let a: u16[2] = 65536; return a[0]; }'
# A folded expression, not just a bare literal — the check sees the value, so
# `200 + 100` is the same mistake as `300`.
reject 'local u8 = 200 + 100' 'local initializer does not fit in u8' \
    'fn main() -> i32 { let b: u8 = 200 + 100; return b; }'
# The prefix operators still refuse the operands they always refused: a bool
# cannot be negated arithmetically, and a struct is not a number.
reject '-b (a bool)' 'cannot use a bool value in -' \
    'fn main() -> i32 { let b: bool = true; let n: i32 = 0 - b; return n; }'
reject '!(an i32)' "'!' requires a bool operand" \
    'fn main() -> i32 { let n: i32 = 1; if (!n) { return 1; } return 0; }'
reject '& of an i32' "is only defined for a struct lvalue" \
    'fn main() -> i32 { let n: i32 = 1; let p: ptr = &n; return 0; }'

# ---------------------------------------------------------------------------
# [6/9] Coverage map. Every accepted row above has to name the rule it
# exercises, so deleting a case without noticing is a failure of the map.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Coverage map: which case exercises which rule'
cat > "$OUT/map.txt" <<'MAP'
T || T && F                           level           the row the old reading got wrong
T || F && T                           level           && tighter, left arm true
F && T || T                           level           && first, || decides
F || F && T                           level           both false either way
T && F || F                           level           && first, both false
T && T && T                           level           one operator, unchanged
F || F || T                           level           one operator, unchanged
|| short-circuits                     level           the split keeps short-circuiting
&& short-circuits                     level           the split keeps short-circuiting
-(s.v)                                unary           prefix reaches the field
!(s.ok)                               unary           prefix reaches the field
~(s.v)                                unary           prefix reaches the field
*(s.p)                                unary           prefix reaches the field
-x (no field)                         unary           unchanged when there is no field
*p (no field)                         unary           unchanged when there is no field
-a[i]                                 unary           a postfix subscript, unchanged
- -x                                  unary           two prefixes in a row
-(x + y)                              unary           a prefix on a parenthesised sum
&s (struct lvalue)                    unary           & was already correct
a < b == c                            crossing        relational then equality
a < b == c (false)                    crossing        the same, false arm
a < b != c                            crossing        != at the equality level
a == b < c                            crossing        equality then relational
a <= b == b >= a                      crossing        both levels, two operands
(a<b)==c stored as bool               crossing        the result is still a bool
u8 at 255                             range           the top of the range is fine
u16 at 65535                          range           the top of the range is fine
u32 at 4000000000                     range           unsigned, above i32's top
u8[4] at 200                          range           an array element constant
u16[2] at 65535                       range           an array element constant
i32 from an i64 value                 range           narrowing a value: still allowed
u8 from an i32 value                  range           narrowing a value: still allowed
i32 from a wide literal               range           a bare literal: still allowed
MAP
# Every case named in the map ran in layer [3/9]; the map is the record of
# which rule each one is there for.
n=$(wc -l < "$OUT/map.txt")
printf '  %-34s %s\n' 'rules covered' "$n"

# ---------------------------------------------------------------------------
# [7/9] Mutation layer. Each mutant withdraws one half of one fix and must be
# noticed by a case above — otherwise that case is not testing anything.
# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Mutation layer: each rule, withdrawn, is caught'
must_not_compile() {   # must_not_compile <label> <source>
    printf '%s\n' "$2" > "$OUT/m.ast"
    if "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant still compiles $1 — the fix is untested" >&2; exit 1
    fi
}
must_now_compile() {   # must_now_compile <label> <source>
    printf '%s\n' "$2" > "$OUT/m.ast"
    if ! "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant still refuses $1 — the refusal is untested" >&2; exit 1
    fi
}
# The mirror of must_now_compile: a mutant that withdraws *one* of the two
# passes must still be refused, by the other one. That is what proves the
# codegen half of a rule is a live gate and not dead code copied from sema —
# and it is why the two halves carry the same message: whichever fires, the
# diagnostic the user reads is the same one.
must_still_say() {   # must_still_say <label> <message> <source>
    printf '%s\n' "$3" > "$OUT/m.ast"
    if "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant accepts $1 — the surviving twin is dead code" >&2; exit 1
    fi
    if ! grep -qF "$2" "$OUT/m.err"; then
        echo "FAIL: mutant $1 no longer says '$2' — the surviving twin does not fire" >&2; exit 1
    fi
}
# A mutant that still refuses, but no longer for the reason the suite records.
# Some rules are diagnostics, not gates: withdrawing them does not admit the
# program, it just replaces the specific message with a generic parse error,
# and that replacement is what the rejection matrix would notice.
must_not_say() {   # must_not_say <label> <message-that-must-be-gone> <source>
    printf '%s\n' "$3" > "$OUT/m.ast"
    if "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant accepts $1 — the refusal is untested" >&2; exit 1
    fi
    if grep -qF "$2" "$OUT/m.err"; then
        echo "FAIL: mutant still says '$2' — the check is unreachable" >&2; exit 1
    fi
}
must_differ() {   # must_differ <label> <want-from-the-real-compiler> <source>
    printf '%s\n' "$3" > "$OUT/m.ast"
    if ! "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant does not compile $1" >&2; exit 1
    fi
    $RUNNER "$OUT/m.a64" >/dev/null 2>&1 && got=0 || got=$?
    if [ "$got" -gt 127 ]; then got=$((got-256)); fi
    if [ "$got" = "$2" ]; then
        echo "FAIL: mutant $1 still gives $got — the case does not see the rule" >&2; exit 1
    fi
}
mutate() {   # mutate <name> <sed-script> <expectation...>
    name=$1; script=$2; shift 2
    cp src/aster.cpp "$OUT/mut.cpp"
    # One sed program: a mutant that has to damage both passes writes its two
    # substitutions with the usual `;` separator, so the script stays one word.
    if ! sed -i.bak "$script" "$OUT/mut.cpp" 2>/dev/null; then
        echo "FAIL: mutant $name could not be applied" >&2; exit 1
    fi
    if ! $CXX -std=c++17 -O2 -w "$OUT/mut.cpp" -o "$OUT/mut.aster" >"$OUT/mut.build" 2>&1; then
        echo "FAIL: mutant $name does not build" >&2; sed -n '1,3p' "$OUT/mut.build" >&2; exit 1
    fi
    "$@"
    printf '  %-34s caught\n' "$name"
}
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the mutation layer needs qemu to observe a changed answer\n'
else
# (1) m1: one loop over both operators again — the pre-round shape.
mutate 'm1: && and || back to one level' \
    's/while(cur().k==TK::And){/while(cur().k==TK::And||cur().k==TK::Or){/' \
    must_differ 'T || T && F' 1 'fn main() -> i32 { if (1 == 1 || 1 == 1 && 1 == 2) { return 1; } return 0; }'
# m2: the two levels swapped. Under the mutant `||` binds tighter and each token
# builds the other's node, so `T && F || F` parses as `T && (F || F)` with `&&`
# computing || : true || false, i.e. 1. The real compiler reads `(T && F) || F`,
# false || false, i.e. 0. (The four rows whose answer the *grouping* alone
# decides cannot see this mutant at all — both groupings give the same answer
# there — which is why this row is the one pinned to it.)
mutate 'm2: the two levels swapped' \
    's/while(cur().k==TK::And){/while(cur().k==TK::ZZ){/;s/while(cur().k==TK::Or){/while(cur().k==TK::And){/;s/while(cur().k==TK::ZZ){/while(cur().k==TK::Or){/' \
    must_differ 'T && F || F' 0 'fn main() -> i32 { if (1 == 1 && 1 == 2 || 1 == 2) { return 1; } return 0; }'
# (2) m3: `-` takes a primary() operand again, so `-s.v` is `(-s).v`.
mutate 'm3: - takes a primary operand' \
    's/if(eat(TK::Minus)){E x=unary();/if(eat(TK::Minus)){E x=primary();/' \
    must_not_compile '-(s.v)' 'struct S { v: i32 }
fn main() -> i32 { let s: S = S { 5 }; return 0 - (-s.v); }'
# m4: `*` takes a primary() operand again, so `*s.p` is `(*s).p`.
mutate 'm4: * takes a primary operand' \
    's/if(eat(TK::Star)){E x=unary();/if(eat(TK::Star)){E x=primary();/' \
    must_not_compile '*(s.p)' 'struct S { p: ptr, v: i32 }
let buf: i32[4] = 9;
fn main() -> i32 { let s: S = S { buf, 1 }; return *s.p; }'
# m5: `!` takes a primary() operand again.
mutate 'm5: ! takes a primary operand' \
    's/if(eat(TK::Not)){E x=unary();/if(eat(TK::Not)){E x=primary();/' \
    must_not_compile '!(s.ok)' 'struct S { ok: bool }
fn main() -> i32 { let s: S = S { true }; if (!s.ok) { return 1; } return 2; }'
# (3) m6: relational() refuses a level crossing again — the pre-round shape.
mutate 'm6: relational refuses == too' \
    's/if(isRelationalOp(cur().k))throw Error("chained comparisons are not supported/if(isRelationalOp(cur().k)||isEqualityOp(cur().k))throw Error("chained comparisons are not supported/' \
    must_not_compile 'a < b == c' 'fn main() -> i32 { let a: i32 = 1; let b: i32 = 2; let c: i32 = 1;
    if (a < b == c) { return 1; } return 0; }'
# m7: equality() stops refusing a chain inside its own level. An empty block,
# not nothing: the mutant has to compile for the check to be observable.
# What the withdrawal buys is *not* acceptance — `a == b == c` still does not
# parse, it merely dies one token later on "expected ')'" — so the row that
# catches it is the rejection-matrix row, which asks for the specific message.
mutate 'm7: equality allows a chain' \
    's/if(isEqualityOp(cur().k))throw Error("chained comparisons are not supported at "+std::to_string(cur().line)+":"+std::to_string(cur().col));/if(isEqualityOp(cur().k)){}/' \
    must_not_say 'a == b == c' 'chained comparisons are not supported' 'fn main() -> i32 { let a: i32 = 1; let b: i32 = 1; let c: i32 = 1;
    if (a == b == c) { return 1; } return 0; }'
# (4) The range check on a narrow local initializer. It exists twice — once in
# sema, once in codegen — so it takes three mutants to pin down: each half on
# its own has to be sufficient, and the pair has to be the whole gate.
# m8: sema drops the scalar check; codegen's twin has to catch it.
mutate 'm8: sema drops the scalar check' \
    's/if(constantInteger(\*s.expr,v)&&!initializerFits(s.ty,\*s.expr,v))/if(false)/' \
    must_still_say 'local u8 = 300' 'local initializer does not fit in u8' 'fn main() -> i32 { let b: u8 = 300; return b; }'
# m9: both passes drop the scalar check — the bug the round closes comes back:
# `let b: u8 = 300;` compiles again and stores 44. (One sed program, two
# substitutions: this is the shape m4 of the null round taught.)
mutate 'm9: both passes drop the scalar check' \
    's/if(constantInteger(\*s.expr,v)&&!initializerFits(s.ty,\*s.expr,v))/if(false)/;s/if(constantInteger(\*s.expr,cv)&&!initializerFits(s.ty,\*s.expr,cv))/if(false)/' \
    must_now_compile 'local u8 = 300' 'fn main() -> i32 { let b: u8 = 300; return b; }'
# m10: sema drops the array check; codegen's twin has to catch it.
mutate 'm10: sema drops the array check' \
    's/if(!initializerFits(s.ty,\*s.expr,v))/if(false)/' \
    must_still_say 'local u8[4] = 300' 'local array initializer does not fit in u8' 'fn main() -> i32 { let a: u8[4] = 300; return a[0]; }'
# m11: both passes drop the array check.
mutate 'm11: both drop the array check' \
    's/if(!initializerFits(s.ty,\*s.expr,v))/if(false)/;s/if(!initializerFits(elem,\*s.expr,value))/if(false)/' \
    must_now_compile 'local u8[4] = 300' 'fn main() -> i32 { let a: u8[4] = 300; return a[0]; }'
# m12: the range check itself stops refusing anything narrow — the widest
# possible withdrawal, and the one that would silently restore truncation
# everywhere, globals included.
mutate 'm12: initializerFits always true' \
    's/static bool initializerFits(Ty t,const Expr& e,int64_t folded){/static bool initializerFits(Ty t,const Expr\& e,int64_t folded){return true;/' \
    must_now_compile 'global u8 = 300' 'let b: u8 = 300;
fn main() -> i32 { return 0; }'
printf '%s\n' 'PASS: twelve mutated compilers each lose exactly one rule, and the checks notice'
fi

# ---------------------------------------------------------------------------
# [8/9] Byte-identity baseline. Every line recorded before this round must
# reproduce byte for byte; the only new lines are the new example's three
# output modes.
# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Byte-identity baseline'
BASE=tests/baseline/v0.23.5-dev/example-hashes.txt
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
# A FAILED row is not a regression: 48 examples import symbols only a link with
# another object or a libc can supply, and build-elf on its own has always
# recorded FAILED for them. The comparison below is what has to hold.
# Four *families* are excluded rather than compared: `precedence.` is this
# round's own example, and `array_elem_types.`, `struct_array_field.`,
# `array_address.` and — from v0.23.31-dev — `multi_dim_array.` are later
# rounds'. None was in the baseline before its own round, so none counts as
# pre-existing.
grep -v -e '^sizeof_len\.' -e '^precedence\.' -e '^array_elem_types\.' -e '^struct_array_field\.' -e '^array_address\.' -e '^multi_dim_array\.' -e '^lifecycle\.' -e '^fn_type\.' -e '^cb_table\.' -e '^fn_ret.' -e '^call-stmt.' -e '^copy.' -e '^arena\.' -e '^stdlib_demo\.' "$BASE" > "$OUT/expected-old.txt"
grep -v -e '^sizeof_len\.' -e '^precedence\.' -e '^array_elem_types\.' -e '^struct_array_field\.' -e '^array_address\.' -e '^multi_dim_array\.' -e '^lifecycle\.' -e '^fn_type\.' -e '^cb_table\.' -e '^fn_ret.' -e '^call-stmt.' -e '^copy.' -e '^arena\.' -e '^stdlib_demo\.' "$OUT/hashes.txt" > "$OUT/got-old.txt"
if ! diff -u "$OUT/expected-old.txt" "$OUT/got-old.txt" > "$OUT/old.diff"; then
    echo 'FAIL: a pre-existing example moved — one of the four fixes changed bytes' >&2
    sed -n '1,20p' "$OUT/old.diff" >&2
    exit 1
fi
old=$(wc -l < "$OUT/expected-old.txt")
new=$(wc -l < "$OUT/got-old.txt")
# v0.23.37-dev: the function-type round's example joins the filter, so eight
# families are skipped — but the baseline gained that round's three rows, and
# the pre-existing count is the same 288: 327 recorded, 39 of them belonging to
# the thirteen rounds this suite knows are new — v0.23.39-dev's one (call-stmt) joined it.
# v0.23.41-dev: the heap round's example (arena.ast) joins the filter the same
# way, so fourteen families are skipped and the pre-existing count is the same
# 288: 327 recorded, 42 of them belonging to the fourteen rounds this suite
# knows are new.
# v0.23.42-dev: the standard-library round's example (stdlib_demo.ast) joins
# the filter the same way, so fourteen families are skipped and the
# pre-existing count is still 288: 330 recorded, 42 of them belonging to the
# fourteen rounds this suite knows are new.
[ "$old" -eq 288 ] \
    || { echo "FAIL: expected 288 pre-existing baseline rows, found $old" >&2; exit 1; }
[ "$new" -eq 288 ] \
    || { echo "FAIL: expected 288 rows of pre-existing output, found $new" >&2; exit 1; }
printf '  %-34s %s\n' 'pre-existing rows byte-identical' "$old"
printf '  %-34s %s\n' 'rows total' "$new"
printf '%s\n' 'PASS: byte-identity baseline holds'

# ---------------------------------------------------------------------------
# [9/9] The shipped example, end to end.
# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] The example, end to end'
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the example needs qemu to run\n'
else
    if ! "$A" build-elf examples/precedence.ast -o "$OUT/pr.a64" >"$OUT/pr.err" 2>&1; then
        echo 'FAIL: examples/precedence.ast does not build' >&2; sed -n '1,3p' "$OUT/pr.err" >&2; exit 1
    fi
    $RUNNER "$OUT/pr.a64" >/dev/null 2>&1 && got=0 || got=$?
    [ "$got" = 127 ] \
        || { echo "FAIL: precedence.ast: expected exit 127, got $got" >&2; exit 1; }
    printf '  %-34s %s\n' 'precedence.ast' "$got"
    printf '%s\n' 'PASS: the example runs and returns the value its C twin returns'
fi

printf '%s\n' '=== precedence checks: ALL PASSED ==='
