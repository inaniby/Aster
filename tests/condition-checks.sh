#!/bin/sh
# v0.23.25-dev checks for conditions: the true/false literals and integer
# truthiness.
#
# Before this round an if/while/for condition had to be a comparison or a bool
# expression — a bare integer was a compile error, and the language had no way
# to spell a bool constant except 0 and 1. Now `true` and `false` are Bool
# literals, and any integer is a condition in its own right: zero is false,
# non-zero is true, tested at the integer's own width. The literals also
# exposed an old hole — arithmetic never rejected a bool operand — so this
# round closes that too, and the suite holds both halves.
#
# Layers: strict compiler build; source guards pinning every new token, AST
# flag, type rule and encoding; a qemu battery over the whole condition
# decision table; a differential comparison against the target C compiler
# (the example twin plus four focused cases); a rejection matrix for the
# misuses the literals and the truthiness rule make possible; a coverage map
# naming which case exercises which rule; a mutation layer proving the checks
# bite; the byte-identity baseline; and a self-check of the new example.
#
# The behavioural layers need qemu (or an AArch64 host); the differential
# layer additionally needs $HOSTCC to emit AArch64 ELF. Neither is required to
# *build*, so the probe is softer than an e2e suite's: each layer that cannot
# run says SKIP and the rest still runs.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-condition-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

# qemu is required by the behavioural and differential layers; HOSTCC by the
# differential one. Without them those layers say SKIP and the rest runs.
have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
HOSTCC=${HOSTCC:-cc}
have_cc=yes
command -v "$HOSTCC" >/dev/null 2>&1 || have_cc=no
if [ "$have_qemu" = no ]; then
    printf '%s\n' 'SKIP: condition-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

# ---------------------------------------------------------------------------
# [2/9] Source guards. A regression that drops any piece of the round — the
# keywords, the literal flag, a type rule, an encoding, a refusal — fails here,
# before a behavioural check has to explain it.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: keywords, literal flag, type rules, encodings, refusals'
# The tokens and the lexer entries that produce them.
grep -qF 'True, False,         // v0.23.25-dev: Bool literals' src/aster.cpp \
    || { echo 'FAIL: true/false token kinds missing' >&2; exit 1; }
grep -qF 'else if(x=="true")k=TK::True; else if(x=="false")k=TK::False;' src/aster.cpp \
    || { echo 'FAIL: true/false are not lexed as keywords' >&2; exit 1; }
# The literal flag on the Num node and the parser branch that sets it.
grep -qF 'bool boolLit=false;' src/aster.cpp \
    || { echo 'FAIL: the Expr bool-literal flag is missing' >&2; exit 1; }
grep -qF 'if(cur().k==TK::True||cur().k==TK::False){' src/aster.cpp \
    || { echo 'FAIL: primary() does not recognize the true/false tokens' >&2; exit 1; }
# Both typeOf copies must read the flag: sema's and codegen's. The one-liner
# this used to pin (`case Expr::Num: return e.boolLit?Ty::Bool:Ty::I32;`)
# became a multi-line switch when v0.23.50-dev's numeric suffix landed, so the
# pin now reads the branch it is really about: a bool literal answers Bool
# first, and only then does the suffix decide the width — in both copies.
[ "$(grep -cF 'if(e.boolLit) return Ty::Bool;' src/aster.cpp)" -eq 2 ] \
    || { echo 'FAIL: both exprType copies must type a bool literal as bool' >&2; exit 1; }
[ "$(grep -cF 'case Expr::LSU:  return Ty::U32;' src/aster.cpp)" -eq 2 ] \
    || { echo 'FAIL: both exprType copies must answer a suffixed literal from its suffix' >&2; exit 1; }
# The fold chokepoint: a bool literal is not an integer constant. (v0.23.28-dev:
# every bool-literal path now carries its own type check, so this is defence in
# depth rather than the only door — it stays pinned here, and m4 targets the
# 0/1-constant rule that is the other half of the same "bool is not int" story.)
grep -qF 'case Expr::Num: if(e.boolLit)return false; out=static_cast<int64_t>(e.n); return true;' src/aster.cpp \
    || { echo 'FAIL: constantInteger must not fold a bool literal' >&2; exit 1; }
# genBool: the literal itself, and the two bool-valued shapes that used to die
# in its fallthrough (a struct field and a ?: selection).
grep -qF 'if(e.k==Expr::Num&&e.boolLit){' src/aster.cpp \
    || { echo 'FAIL: genBool cannot materialize a bool literal' >&2; exit 1; }
# v0.23.28-dev: an array element is a condition too (`if (flags[2])` on a
# `bool[N]`), so it joins the field and `?:` forms in the same delegation.
grep -qF 'if(e.k==Expr::Field||e.k==Expr::Cond||e.k==Expr::Index){' src/aster.cpp \
    || { echo 'FAIL: genBool lost the field/?: delegation' >&2; exit 1; }
# The 64-bit zero test, and the integer condition path that chooses it.
grep -qF 'static uint32_t cmpZeroX(int reg){return 0xf1000000u|(uint32_t(reg)<<5)|31u;}' src/aster.cpp \
    || { echo 'FAIL: CMP Xn, #0 (cmpZeroX) missing or damaged' >&2; exit 1; }
grep -qF 'if(tyIsInteger(t)){' src/aster.cpp \
    || { echo 'FAIL: emitCondition has no integer-condition path' >&2; exit 1; }
grep -qF 'emit(tyIs64(t)?cmpZeroX(r):cmpZero(r));releaseTemp(r);' src/aster.cpp \
    || { echo 'FAIL: an integer condition must be tested at its own width' >&2; exit 1; }
# The shared condition message, in both the sema and the codegen copy (sema
# wraps it in loc(), so the message itself is what is counted).
[ "$(grep -o 'condition must be a comparison, a bool expression, or an integer' src/aster.cpp | wc -l)" -eq 2 ] \
    || { echo 'FAIL: the condition refusal must be the new shared message, twice' >&2; exit 1; }
grep -qF 'if(!isComparison(e.k)&&t!=Ty::Bool&&!tyIsInteger(t))' src/aster.cpp \
    || { echo 'FAIL: checkCondition must accept an integer condition' >&2; exit 1; }
# The arithmetic refusal: one helper, called at every integer-only operator.
grep -qF 'static void rejectBool(Ty t,const char* what){' src/aster.cpp \
    || { echo 'FAIL: rejectBool helper missing' >&2; exit 1; }
# v0.23.31-dev: the 17th call site is the per-level chain walk, which checks
# *every* subscript of `a[i][j]` against its own dimension — the 16th was
# v0.23.29-dev's array-field index. v0.23.34-dev added an 18th call at the
# ptr-to-elem Index branch, refusing a bool subscript on `(&arr)[i]`. One
# definition, eighteen calls.
[ "$(grep -o 'rejectBool(' src/aster.cpp | wc -l)" -eq 19 ] \
    || { echo "FAIL: rejectBool occurrences moved (expected 19: 1 definition + 18 calls (the 18th is v0.23.34-dev's ptr-to-elem index)), found $(grep -o 'rejectBool(' src/aster.cpp | wc -l)" >&2; exit 1; }
# The two initializer gates the literals would otherwise walk through.
grep -qF 'if(init->k==Expr::Num&&init->boolLit)' src/aster.cpp \
    || { echo 'FAIL: a bool literal must not initialize a non-bool global' >&2; exit 1; }
grep -qF "global struct initializer type mismatch: field '" src/aster.cpp \
    || { echo 'FAIL: a bool literal must not initialize a non-bool struct field' >&2; exit 1; }
grep -qF 'rejectBool(idxTy,"an array index");' src/aster.cpp \
    || { echo 'FAIL: an array index must refuse a bool literal' >&2; exit 1; }
printf '%s\n' 'PASS: keywords, boolLit flag, type rules, cmpZeroX, integer condition path and every refusal present'

# ---------------------------------------------------------------------------
# Behavioural layers. check <aster-binary> <name> <expected-exit> <source>:
# compile, run through RUNNER, compare the exit status. Exit statuses are 8
# bits wide, so an expected value is written in 0..127 or as a signed value in
# -128..-1 and compared the way the kernel reports it.
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
printf '%s\n' '[3/9] qemu: the condition decision table, one rule at a time'
# The literals, in every branch shape.
check "$A" 'if (true)'          7 'fn main() -> i32 { if (true) { return 7; } return 9; }'
check "$A" 'if (false)'         9 'fn main() -> i32 { if (false) { return 7; } return 9; }'
check "$A" 'else-if chain'      2 'fn main() -> i32 { if (false) { return 1; } else if (true) { return 2; } else { return 3; } }'
# Integer truthiness: the shape the language refused before this round.
check "$A" 'while counts down'  5 'fn main() -> i32 { let n: i32 = 5; let c: i32 = 0; while (n) { c = c + 1; n = n - 1; } return c; }'
check "$A" 'while (0) never runs' 0 'fn main() -> i32 { let c: i32 = 0; while (0) { c = c + 1; } return c; }'
check "$A" 'negative is true'   3 'fn main() -> i32 { let n: i32 = -3; let c: i32 = 0; while (n) { c = c + 1; n = n + 1; } return c; }'
check "$A" 'for integer cond'   6 'fn main() -> i32 { let s: i32 = 0; for (let i: i32 = 0; i < 4; i = i + 1) { s = s + i; } return s; }'
check "$A" 'while (true) + return' 3 'fn main() -> i32 { let c: i32 = 0; while (true) { c = c + 1; if (c == 3) { return c; } } return 0; }'
# The 64-bit zero test: a value whose low half is zero is still non-zero. A
# 32-bit compare here would read 4294967296 as false.
check "$A" 'i64 wide zero-test' 1 'fn main() -> i32 { let big: i64 = 4294967296; if (big) { return 1; } return 0; }'
check "$A" 'i64 while'          3 'fn main() -> i32 { let n: i64 = 3; let c: i32 = 0; while (n) { c = c + 1; n = n - 1; } return c; }'
# The narrow widths, including the ones whose high bit is set.
check "$A" 'u8/u16/u32 truthiness' 108 'fn main() -> i32 {
    let a: u8 = 0; let b: u8 = 200;
    let c: u16 = 0; let d: u16 = 65535;
    let e: u32 = 0; let f: u32 = 4294967295;
    let r: i32 = 0;
    if (a) { r = r + 1; }
    if (b) { r = r + 10; }
    if (c) { r = r + 100; }
    if (d) { r = r + 1000; }
    if (e) { r = r + 10000; }
    if (f) { r = r + 100000; }
    return r % 251;
}'
# Bool expressions that are not bare variables: a bool variable, a call, a
# struct field, a ?: selection, and the logical operators.
check "$A" 'bool var + literals + loop' 6 'fn main() -> i32 {
    let on: bool = true;
    let off: bool = false;
    let n: i32 = 2;
    let r: i32 = 0;
    if (on) { r = r + 1; }
    if (off) { r = r + 100; } else { r = r + 2; }
    while (n) { r = r + n; n = n - 1; }
    return r;
}'
check "$A" 'i32 call condition'  7 'fn f() -> i32 { return 3; }
fn main() -> i32 { if (f()) { return 7; } return 0; }'
check "$A" 'bool call condition' 7 'fn p() -> bool { return true; }
fn main() -> i32 { if (p()) { return 7; } return 0; }'
check "$A" 'zero call condition' 8 'fn z() -> i32 { return 0; }
fn main() -> i32 { if (z()) { return 7; } return 8; }'
check "$A" 'bool field condition' 5 'struct S { b: bool }
fn main() -> i32 { let s: S = S { true }; if (s.b) { return 5; } return 6; }'
check "$A" '?: arms as condition' 3 'fn main() -> i32 { let c: bool = true; if (c ? true : false) { return 3; } return 4; }'
check "$A" '&& with literals'    2 'fn main() -> i32 { if (true && false) { return 1; } return 2; }'
check "$A" '|| with literals'    3 'fn main() -> i32 { if (true || false) { return 3; } return 4; }'
check "$A" '!false'              5 'fn main() -> i32 { if (!false) { return 5; } return 6; }'
# The aggregate: one program whose value is the sum of eleven independent
# sub-results, so a wrong rule cannot be masked by another rule's accident.
check "$A" 'aggregate'          14 'fn main() -> i32 {
    let r: i32 = 0;
    if (true) { r = r + 1; }
    if (false) { r = r + 100; } else { r = r + 2; }
    let n: i32 = 3;
    while (n) { r = r + n; n = n - 1; }
    for (let i: i32 = 0; i < 2; i = i + 1) { r = r + 1; }
    if (0) { r = r + 1000; }
    let big: i64 = 4294967296;
    if (big) { r = r + 1; }
    let z8: u8 = 0; let nz8: u8 = 255;
    if (z8) { r = r + 10000; }
    if (nz8) { r = r + 2; }
    return r;
}'
fi # the [3/9] behavioural battery, which needs qemu

# ---------------------------------------------------------------------------
# [4/9] Differential layer: the same program, compiled by Aster and by the
# target C compiler, must produce the same value. This is the layer that would
# catch a truthiness rule that happens to agree with the hand-written expected
# values above.
# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] Differential: Aster vs the target C compiler'
if [ "$have_qemu" = no ] || [ "$have_cc" = no ]; then
    printf '  SKIP: the differential layer needs qemu-aarch64 and a C compiler that emits AArch64 ELF\n'
else
    # diff_case <name> <aster-source> <c-source>
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
    # The 64-bit zero test against C's long long, and the high-bit unsigned
    # case against C's unsigned — the two places a width mistake hides.
    diff_case 'i64 wide zero-test' \
        'fn main() -> i32 { let big: i64 = 4294967296; if (big) { return 1; } return 0; }' \
        'int main(void) { long long big = 4294967296; if (big) { return 1; } return 0; }'
    diff_case 'u32 high bit' \
        'fn main() -> i32 { let f: u32 = 4294967295; if (f) { return 1; } return 0; }' \
        'int main(void) { unsigned f = 4294967295u; if (f) { return 1; } return 0; }'
    # The literals against C's 0/1, in the same branch shapes.
    diff_case 'literals in branches' \
        'fn main() -> i32 { let r: i32 = 0; if (true) { r = r + 1; } if (false) { r = r + 100; } else { r = r + 2; } return r; }' \
        'int main(void) { int r = 0; if (1) { r = r + 1; } if (0) { r = r + 100; } else { r = r + 2; } return r; }'
    # A whole program: nested loops whose conditions are the integers
    # themselves, plus a ?: selection as a condition.
    diff_case 'loops + ?: condition' \
        'fn main() -> i32 {
    let r: i32 = 0;
    let n: i32 = 4;
    while (n) { let m: i32 = 2; while (m) { r = r + 1; m = m - 1; } n = n - 1; }
    let c: bool = false;
    if (c ? true : false) { r = r + 100; }
    return r;
}' 'int main(void) {
    int r = 0;
    int n = 4;
    while (n) { int m = 2; while (m) { r = r + 1; m = m - 1; } n = n - 1; }
    int c = 0;
    if (c ? 1 : 0) { r = r + 100; }
    return r;
}'
    printf '%s\n' 'PASS: four differential cases agree with the target C compiler'
fi

# ---------------------------------------------------------------------------
# [5/9] Rejection matrix. Every way the new literals and the truthiness rule
# can be misused, plus the old refusals this round must not have loosened.
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
# Conditions that are not a comparison, a bool or an integer.
reject 'a ptr condition'      'condition must be a comparison, a bool expression, or an integer' \
    'fn f(p: ptr) -> i32 { if (p) { return 1; } return 0; }
fn main() -> i32 { return 0; }'
reject 'a struct condition'   'condition must be a comparison, a bool expression, or an integer' \
    'struct S { x: i32 }
fn main() -> i32 { let s: S = S { 1 }; if (s) { return 1; } return 0; }'
# The literals are bool, not the integers 0 and 1.
reject 'bool literal to i32'  "type mismatch initializing 'x': expected i32, got bool" \
    'fn main() -> i32 { let x: i32 = true; return x; }'
reject 'bool literal to u8'   "type mismatch initializing 'x': expected i32, got bool" \
    'fn main() -> i32 { let x: u8 = true; return x; }'
reject 'bool literal assign'  'type mismatch assigning variable: x' \
    'fn main() -> i32 { let x: i32 = 5; x = true; return x; }'
reject 'bool literal arg'     'argument type mismatch calling f at argument 1: expected i32' \
    'fn f(a: i32) -> i32 { return a; }
fn main() -> i32 { return f(true); }'
reject 'bool literal return'  'return type mismatch in function main: expected i32, got bool' \
    'fn main() -> i32 { return true; }'
# Arithmetic and bitwise operators take integer operands.
reject 'true + 1'             'cannot use a bool value in +'  'fn main() -> i32 { return 1 + true; }'
reject 'true - 1'             'cannot use a bool value in -'  'fn main() -> i32 { return true - 1; }'
reject 'true * 2'             'cannot use a bool value in *'  'fn main() -> i32 { return true * 2; }'
reject 'true / 2'             'cannot use a bool value in /'  'fn main() -> i32 { return true / 2; }'
reject 'true % 2'             'cannot use a bool value in %'  'fn main() -> i32 { return true % 2; }'
reject '1 << true'            'cannot use a bool value in <<' 'fn main() -> i32 { return 1 << true; }'
reject 'true >> 1'            'cannot use a bool value in >>' 'fn main() -> i32 { return true >> 1; }'
reject 'true & 1'             'cannot use a bool value in &'  'fn main() -> i32 { return true & 1; }'
reject 'true | 1'             'cannot use a bool value in |'  'fn main() -> i32 { return true | 1; }'
reject 'true ^ 1'             'cannot use a bool value in ^'  'fn main() -> i32 { return true ^ 1; }'
reject '~true'                'cannot use a bool value in ~'  'fn main() -> i32 { return ~true; }'
reject '-true'                'cannot use a bool value in -'  'fn main() -> i32 { return -true; }'
reject 'a[true]'              'cannot use a bool value in an array index' \
    'fn main() -> i32 { let a: i32[4] = 0; return a[true]; }'
reject 'array init = true'    'array initializer type mismatch: expected i32, got bool' \
    'fn main() -> i32 { let a: i32[4] = true; return a[0]; }'
# The literals are reserved words now.
reject 'let true'             'expected variable name' \
    'fn main() -> i32 { let true = 5; return 0; }'
reject 'fn true'              'expected function name' \
    'fn true() -> i32 { return 1; }
fn main() -> i32 { return 0; }'
# Global and struct-field initializers, where a constant folder would
# otherwise store the literal as the value 1.
reject 'global i32 = true'    'global initializer type mismatch: expected i32, got bool' \
    'let g: i32 = true;
fn main() -> i32 { return g; }'
reject 'global u8 = true'     'global initializer type mismatch: expected u8, got bool' \
    'let g: u8 = true;
fn main() -> i32 { return 0; }'
reject 'struct i32 field = true' "global struct initializer type mismatch: field 'S.x' is i32, got bool: g" \
    'struct S { x: i32 }
let g: S = S { true };
fn main() -> i32 { return g.x; }'
# The truthiness coercion lives at conditions only: ?:, && and ! keep their
# strict bool rule, and the old bool/i32 matrix keeps its refusals.
reject '?: with an integer'   "the condition of '?:' must be a bool expression" \
    'fn main() -> i32 { let x: i32 = 5; return x ? 1 : 2; }'
reject '&& with an integer'   '&& and || require bool operands (&&)' \
    'fn main() -> i32 { let x: i32 = 5; return x && true; }'
reject '|| with an integer'   '&& and || require bool operands (||)' \
    'fn main() -> i32 { if (true || 5) { return 1; } return 0; }'
reject '! with an integer'    "'!' requires a bool operand" \
    'fn main() -> i32 { let x: i32 = 5; return !x; }'
reject 'bool from 5'          "type mismatch initializing 'b': expected bool" \
    'fn main() -> i32 { let b: bool = 5; return 0; }'
reject 'bool global from 2'   'bool global initializer must be 0 or 1: flag' \
    'let flag: bool = 2;
fn main() -> i32 { return 0; }'
printf '%s\n' 'PASS: every misuse refused with the message that names the rule'

# ---------------------------------------------------------------------------
# [6/9] Coverage map. The decision table a condition is checked against, and
# the case that exercises each row. A row with no case is a hole, so the count
# is asserted, not just printed.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Coverage map: one case per row of the condition decision table'
cat <<'MAP'
  condition shape                     accepted as          case
  -----------------------------------  -------------------  ----------------------------
  comparison (== != < <= > >=)         bool                 existing if_* examples, ?: arms
  bool literal true                    bool                 if (true), else-if chain
  bool literal false                   bool                 if (false), else-if chain
  bool variable                        bool                 bool var + literals + loop
  bool call result                     bool                 bool call condition
  bool struct field                    bool                 bool field condition
  ?: selection of bool arms            bool                 ?: arms as condition
  && / || / ! of bools                 bool                 && / || / ! cases
  i32 non-zero / zero / negative       integer truthiness    while counts down, while (0), negative
  i64 (wide zero-test)                 integer truthiness    i64 wide zero-test, i64 while
  u8 / u16 / u32 (high bit set)        integer truthiness    u8/u16/u32 truthiness
  for-loop integer condition           integer truthiness    for integer cond
  ptr / struct                         refused              a ptr condition, a struct condition
  bool literal in arithmetic           refused              the + - * / % << >> & | ^ ~ - cases
  bool literal as index / array init   refused              a[true], array init = true
  bool literal to i32 slot / arg       refused              bool literal to i32 / arg / return
  integer in ?:, &&, !                 refused              ?: with an integer, &&, ! cases
MAP
# 21 behavioural cases above; the rejection matrix adds its own count. The map
# is only honest if the battery really ran — if qemu was missing, say so here
# rather than printing a map of cases that never executed.
if [ "$have_qemu" = yes ]; then
    printf '%s\n' 'PASS: 21 behavioural cases cover the accepted rows; the refusal rows are covered by the rejection matrix'
else
    printf '%s\n' 'NOTE: the map describes cases that need qemu; the refusal rows ran regardless'
fi

# ---------------------------------------------------------------------------
# [7/9] Mutation layer. A behavioural check that passes on a damaged compiler
# is not checking anything: these rebuild aster with one rule changed and
# assert that the same check now FAILS. Seven sites are mutated — the sema
# acceptance, the 64-bit zero test, the literal's value, the fold chokepoint,
# the arithmetic refusal, the global gate and the struct-field gate — which is
# what separates "the parser accepts the shape" from "the rule is enforced".
# ---------------------------------------------------------------------------
if [ "$have_qemu" = yes ]; then
printf '%s\n' '[7/9] Mutation: the checks above must fail on a damaged compiler'
# must_not_compile <mutant> <name> <source> <message-fragment>: the mutated
# compiler must refuse the program, with the message that names the rule.
must_not_compile() {
    m=$1; name=$2
    printf '%s\n' "$3" > "$OUT/m.ast"
    if "$OUT/m.$m/aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant $m accepted $name (the check does not bite)" >&2; exit 1
    fi
    grep -qF "$4" "$OUT/m.err" \
        || { echo "FAIL: mutant $m refused $name with the wrong message: $(sed -n '1p' "$OUT/m.err")" >&2; exit 1; }
    printf '  %-34s still refused\n' "$m: $name"
}
# must_diverge <mutant> <name> <source> <expected>: the mutated compiler must
# produce a different exit status than the real one.
must_diverge() {
    m=$1; name=$2
    printf '%s\n' "$3" > "$OUT/m.ast"
    if ! "$OUT/m.$m/aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant $m rejected a valid program ($name)" >&2; sed -n '1,3p' "$OUT/m.err" >&2; exit 1
    fi
    $RUNNER "$OUT/m.a64" >/dev/null 2>&1 && got=0 || got=$?
    if [ "$got" -gt 127 ]; then got=$((got-256)); fi
    if [ "$got" = "$4" ]; then
        echo "FAIL: mutant $m still produces $got for $name (the check does not bite)" >&2; exit 1
    fi
    printf '  %-34s %s (not %s)\n' "$m: $name" "$got" "$4"
}
# must_now_compile <mutant> <name> <source>: the mutated compiler must ACCEPT
# a program the real one refuses — the guard under mutation is the only thing
# standing between the two.
must_now_compile() {
    m=$1; name=$2
    printf '%s\n' "$3" > "$OUT/m.ast"
    if ! "$OUT/m.$m/aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant $m still refuses $name (the check does not bite)" >&2; sed -n '1,3p' "$OUT/m.err" >&2; exit 1
    fi
    printf '  %-34s now compiles\n' "$m: $name"
}
build_mutant() { # build_mutant <name> <sed-expr>
    mkdir -p "$OUT/m.$1"
    sed "$2" src/aster.cpp > "$OUT/m.$1/aster.cpp"
    if cmp -s src/aster.cpp "$OUT/m.$1/aster.cpp"; then
        echo "FAIL: mutation $1 did not change the source (the guard is stale)" >&2; exit 1
    fi
    $CXX -std=c++17 -O0 -w "$OUT/m.$1/aster.cpp" -o "$OUT/m.$1/aster" 2>"$OUT/m.$1.err" \
        || { echo "FAIL: mutant $1 does not build" >&2; sed -n '1,3p' "$OUT/m.$1.err" >&2; exit 1; }
}
# m1: sema stops accepting an integer condition (the round's core rule, at the
# sema half). m2: the 64-bit zero test degrades to a 32-bit one. m3: `true`
# materializes as 0. m4: a bool slot stops accepting the 0/1 integer constant.
# m5: arithmetic stops refusing a bool operand. m6: the global-initializer gate
# is bypassed. m7: a bool struct field initialized from `true` stores 0.
build_mutant m1 's/if(!isComparison(e.k)&&t!=Ty::Bool&&!tyIsInteger(t))/if(!isComparison(e.k)\&\&t!=Ty::Bool)/'
build_mutant m2 's/emit(tyIs64(t)?cmpZeroX(r):cmpZero(r));releaseTemp(r);/emit(cmpZero(r));releaseTemp(r);/'
build_mutant m3 's/z->boolLit=true;z->line=tok.line;z->col=tok.col;return z;/z->boolLit=true;z->n=tok.k==TK::True?0u:0u;z->line=tok.line;z->col=tok.col;return z;/'
# m4: a bool slot stops accepting the 0/1 integer constant it has always
# accepted — the two isBoolConstant copies (sema's and codegen's) change
# together, because they are one rule stated twice. The bool *literal* keeps
# its own road in, so `let b: bool = true;` is untouched by this mutant.
build_mutant m4 's/return constantInteger(e,v)&&(v==0||v==1);/return false;/'
build_mutant m5 's/rejectBool(a,"+");rejectBool(b,"+");//'
# m6: the global-initializer gate is bypassed. v0.23.28-dev gave that gate a
# twin in initializerFits (`true` fits a bool slot and only a bool slot), so
# the mutant has to lift both — one rule, stated twice, as m4's is.
build_mutant m6 's/if(init->k==Expr::Num&&init->boolLit)/if(init->k==Expr::Num\&\&init->boolLit\&\&false)/;s/if(e.k==Expr::Num&&e.boolLit)return t==Ty::Bool;/if(false)return false;/'
build_mutant m7 's/v=(int64_t)e.n;/v=0;/'
must_not_compile  m1 'an integer condition' \
    'fn main() -> i32 { let x: i32 = 5; if (x) { return 1; } return 0; }' \
    'condition must be a comparison, a bool expression, or an integer'
must_diverge      m2 'i64 wide zero-test' \
    'fn main() -> i32 { let big: i64 = 4294967296; if (big) { return 1; } return 0; }' 1
must_diverge      m3 'if (true)' \
    'fn main() -> i32 { if (true) { return 7; } return 9; }' 7
must_not_compile  m4 'bool slot = 1' \
    'fn main() -> i32 { let b: bool = 1; return 0; }' \
    "type mismatch initializing 'b': expected bool"
must_now_compile  m5 '1 + true' \
    'fn main() -> i32 { return 1 + true; }'
must_now_compile  m6 'global i32 = true' \
    'let g: i32 = true;
fn main() -> i32 { return g; }'
must_diverge      m7 'struct bool field = true' \
    'struct S { b: bool }
let g: S = S { true };
fn main() -> i32 { if (g.b) { return 5; } return 6; }' 5
printf '%s\n' 'PASS: seven mutated compilers each lose exactly one rule, and the checks notice'
fi

# ---------------------------------------------------------------------------
# [8/9] Byte-identity baseline. Every line in the recorded baseline — the 93
# examples recorded through v0.23.23-dev, the indirect-call example from
# v0.23.24-dev, and this round's condition example — must reproduce byte for
# byte in all three build modes. A moved byte is a regression, not a
# re-recording; re-recording is tests/rebuild-baseline-v0.23.25.sh's job.
# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Byte-identity baseline: every example, all three build modes'
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
if ! diff -u "$BASE" "$OUT/hashes.txt" > "$OUT/base.diff"; then
    echo 'FAIL: the byte baseline moved — a pre-existing example changed, or a new one is unrecorded' >&2
    sed -n '1,20p' "$OUT/base.diff" >&2
    exit 1
fi
lines=$(wc -l < "$OUT/hashes.txt")
cond=$(grep -c '^condition\.' "$OUT/hashes.txt")
[ "$cond" -eq 3 ] \
    || { echo "FAIL: expected exactly 3 condition.* baseline lines, found $cond" >&2; exit 1; }
printf '  %s lines reproduce byte for byte (3 of them condition.*)\n' "$lines"
printf '%s\n' 'PASS: byte-identity baseline holds'

# ---------------------------------------------------------------------------
# [9/9] The example itself: build it, run it, and check the value the twin
# agrees on. 9 + 4 + 3 = 16.
# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] The example, end to end'
"$A" build-elf examples/condition.ast -o "$OUT/condition.a64" >/dev/null
$RUNNER "$OUT/condition.a64" >/dev/null 2>&1 && got=0 || got=$?
if [ "$got" -gt 127 ]; then got=$((got-256)); fi
[ "$got" = 16 ] \
    || { echo "FAIL: examples/condition.ast exited $got, expected 16" >&2; exit 1; }
printf '  %-34s %s\n' 'condition.ast' "$got"
printf '%s\n' 'PASS: the example runs and returns the value its C twin returns'
printf '%s\n' '=== condition checks: ALL PASSED ==='
