#!/bin/sh
# v0.23.17-dev checks for the operator set Aster was missing: % , << , >> ,
# & , | , ^ , ~ , the compound assignments (OP=), ++ / --, and ?: .
#
# Before this round the language had + - * / and the comparisons, and nothing
# else: a remainder had to be written as `a - a / b * b`, and a bit mask was
# unreachable. The grammar now has a precedence chain (product -> sum -> shift
# -> relational -> equality -> & -> ^ -> | -> logical -> ?:) and the missing
# encodings were read off `aarch64-linux-gnu-gcc -O2` output, not guessed.
#
# Layers: strict compiler build; source guards that pin every new token, AST
# kind, grammar level and instruction encoding; a rejection matrix for the type
# and syntax misuses the new operators make possible; qemu self-checks of the
# real semantics; a differential comparison against cross-compiled C for the
# same expressions; constant-folding checks; and a mutation layer that proves
# the qemu checks actually test the encodings rather than the parser.

# The differential layer needs $HOSTCC to emit AArch64 ELF; the behavioural
# layers need qemu (or an AArch64 host). Neither is required to *build*, so the
# probe is softer than an e2e suite's: each layer that cannot run says SKIP and
# the rest still runs.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-operator-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/8] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

# qemu is required by layers 4-8; without it they cannot run at all.
have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
if [ "$have_qemu" = no ]; then
    printf '%s\n' 'SKIP: operator-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

printf '%s\n' '[2/8] Source guards: tokens, AST kinds, grammar levels, encodings'
# A regression that drops any piece of the new operator set must fail here,
# before a behavioural check has to explain it.
grep -qF 'Percent, Shl, Shr, BitXor, BitOr, Tilde, Question,' src/aster.cpp \
    || { echo 'FAIL: % << >> ^ | ~ ? tokens missing from the token kinds' >&2; exit 1; }
grep -qF 'PlusEq, MinusEq, StarEq, SlashEq, PercentEq, ShlEq, ShrEq, AndEq, OrEq, XorEq,' src/aster.cpp \
    || { echo 'FAIL: compound-assignment tokens missing' >&2; exit 1; }
grep -qF 'PlusPlus, MinusMinus,' src/aster.cpp \
    || { echo 'FAIL: ++ / -- tokens missing' >&2; exit 1; }
# The kinds are pinned without the enum's tail: v0.23.35-dev appended
# `SizeOf, Len` after Cond, and that pair is guarded by its own suite
# (tests/sizeof-len-checks.sh), so this guard stays a v0.23.17-round check.
grep -qF 'Mod, Shl, Shr, BitAnd, BitOr, BitXor, BitNot, Cond,' src/aster.cpp \
    || { echo 'FAIL: new expression kinds missing from Expr::Kind' >&2; exit 1; }
# The precedence chain: every level is named, so a level that disappears or is
# bypassed (e.g. shift() calling sum() instead of the other way round) fails.
for fn in 'E shift(){' 'E relational(){' 'E equality(){' 'E bitand_(){' 'E bitxor_(){' 'E bitor_(){'; do
    grep -qF "$fn" src/aster.cpp \
        || { echo "FAIL: grammar level $fn missing from the parser" >&2; exit 1; }
done
grep -qF 'E x=shift();' src/aster.cpp \
    || { echo 'FAIL: shift() is not wired into the expression chain' >&2; exit 1; }
# `<<=` must be one token, not `<<` followed by `=`: the lexer decides by
# lookahead, and a regression here turns `x <<= 1` into a syntax error at best.
grep -qF "if(peek()=='='){take();v.push_back({TK::ShlEq,\"<<=\",l,c});}" src/aster.cpp \
    || { echo 'FAIL: <<= must be lexed as a single token' >&2; exit 1; }
# The encodings, each read off gcc output for the equivalent C.
grep -qF '0x9b008000u:0x1b008000u' src/aster.cpp \
    || { echo 'FAIL: MSUB (the second half of %) missing or damaged' >&2; exit 1; }
grep -qF 'if(e.k==Expr::Shr)base|=(tyIsUnsigned(ta)?0x400u:0x800u);' src/aster.cpp \
    || { echo 'FAIL: >> must pick LSR for unsigned and ASR for signed' >&2; exit 1; }
grep -qF '0x8a000000u:0x0a000000u' src/aster.cpp \
    || { echo 'FAIL: AND encoding missing' >&2; exit 1; }
grep -qF '0xaa000000u:0x2a000000u' src/aster.cpp \
    || { echo 'FAIL: ORR encoding missing' >&2; exit 1; }
grep -qF '0xca000000u:0x4a000000u' src/aster.cpp \
    || { echo 'FAIL: EOR encoding missing' >&2; exit 1; }
grep -qF '0xaa200000u:0x2a200000u' src/aster.cpp \
    || { echo 'FAIL: ORN (the ~ encoding) missing' >&2; exit 1; }
grep -qF 'Stmt incDecStore(const Token& opTok,const Token& idTok)' src/aster.cpp \
    || { echo 'FAIL: the ++ / -- store is missing' >&2; exit 1; }
grep -qF 'bool isCompoundAssign(TK t)const' src/aster.cpp \
    || { echo 'FAIL: compound-assignment recognition missing' >&2; exit 1; }
# Constant folding has to cover the new operators too, or a global initializer
# that uses one silently becomes a runtime store.
grep -qF 'case Expr::BitNot: return ~foldConst(*e.a);' src/aster.cpp \
    || { echo 'FAIL: ~ is missing from the constant folder' >&2; exit 1; }

printf '%s\n' '[3/8] Rejection matrix: every misuse the new operators allow'
# reject <name> <expected-substring> <source>
reject() {
    printf '%s\n' "$3" > "$OUT/rej.ast"
    if out=$("$OUT/aster" build-elf "$OUT/rej.ast" -o "$OUT/rej.a64" 2>&1); then
        echo "FAIL: compiler accepted $1" >&2; exit 1
    fi
    printf '%s' "$out" | grep -qF "$2" \
        || { echo "FAIL: wrong diagnostic for $1 (wanted '$2'): $out" >&2; exit 1; }
    printf '  rejected: %s\n' "$1"
}
reject 'a pointer in &'   'cannot use a pointer in &' \
    'fn f(p: ptr) -> i32 { return p & 1; }'
reject 'a pointer in ~'   'cannot use a pointer in ~' \
    'fn f(p: ptr) -> i32 { return ~p; }'
reject 'a pointer in <<'  'cannot use a pointer in <' \
    'fn f(p: ptr) -> i32 { return p << 1; }'
reject 'a struct in &'    'cannot use a struct value (S) in &' \
    'struct S { a: i32 }
fn f(s: S) -> i32 { return s & 1; }'
reject 'postfix ++ in an expression' 'expected' \
    'fn main() -> i32 { let d: i32 = 10; return d++; }'
reject 'prefix ++ in an expression'  'expected' \
    'fn main() -> i32 { let d: i32 = 10; return ++d; }'
reject 'a non-bool ?: condition'     "the condition of '?:' must be a bool expression" \
    'fn main() -> i32 { return 1 ? 2 : 3; }'
reject '?: arms of different types'  "both arms of '?:' must have the same type (got i32 and bool)" \
    'fn main() -> i32 { return 1 == 1 ? 1 : 2 == 2; }'
reject 'a compound assign whose subscript is a call' \
       'compound assignment would evaluate the subscript twice' \
    'fn h() -> i32 { return 0; }
fn main() -> i32 { let a: i32[4] = 0; a[h()] += 1; return 0; }'
reject '% by zero in a global'  'division by zero in global variable initializer' \
    'let g: i32 = 7 % 0;
fn main() -> i32 { return g; }'
# A shift count outside [0,63] has no defined meaning. The old folder masked it
# with &63, so `1 << -1` silently became `1 << 63`.
reject 'a negative shift count'  'shift count -1 is out of range (0..63)' \
    'let g: i32 = 1 << -1;
fn main() -> i32 { return g; }'
reject 'a shift count past 63'   'shift count 99 is out of range (0..63)' \
    'let g: i32 = 1 << 99;
fn main() -> i32 { return g; }'
reject 'a left shift that leaves i64' 'left shift overflows i64' \
    'let g: i32 = 3 << 62;
fn main() -> i32 { return g; }'
# Chained comparisons were already rejected; the new precedence chain must not
# have quietly made them legal.
reject 'a chained comparison' 'chained comparisons are not supported' \
    'fn main() -> i32 { return 1 < 2 < 3; }'

# ---------------------------------------------------------------------------
# Behavioural layers. check <aster-binary> <name> <expected-exit> <source>:
# compile, run through RUNNER, compare the exit status. Exit statuses are 8
# bits wide, so an expected value is written in 0..127 or as a signed value in
# -128..-1 and compared the same way the kernel reports it.
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
printf '%s\n' '[4/8] qemu: the new operators, one at a time'
# The aggregate is the strongest single check: it is one program whose value is
# the sum of nine independent sub-results, so a wrong operator cannot be masked
# by another operator's accident.
check "$A" '% (signed, both signs)'   21 'fn main() -> i32 {
    let a: i32 = -17; let b: i32 = 5;
    let r1: i32 = a % b;          // -2
    let r2: i32 = 17 % -5;        //  2
    let r3: i32 = -8 >> 1;        // -4  (arithmetic: the sign survives)
    let r4: i32 = -8 << 1;        // -16
    let r5: i32 = 1 + 2 * 3 << 2 & 12;  // ((1+6)<<2)&12 = 12
    let r6: i32 = 1 == 1 ? 7 : 9; //  7
    let r7: i32 = 1 == 2 ? 7 : 9; //  9
    let c: i32 = 0;
    c += 5; c -= 2; c *= 3; c /= 2; c %= 4; c <<= 3; c >>= 1; c |= 1; c &= 12; c ^= 3;
    let d: i32 = 10;
    d++;
    --d;
    return r1 + r2 + r3 + r4 + r5 + r6 + r7 + c + d;
}'
# Individually, so a failure names its operator.
check "$A" '17 % 5'        2 'fn main() -> i32 { let a: i32 = 17; let b: i32 = 5; return a % b; }'
check "$A" '-17 % 5'      -2 'fn main() -> i32 { let a: i32 = -17; let b: i32 = 5; return a % b; }'
check "$A" '17 % -5'       2 'fn main() -> i32 { let a: i32 = 17; return a % -5; }'
check "$A" '-17 % -5'     -2 'fn main() -> i32 { let a: i32 = -17; return a % (-5); }'
check "$A" '17 << 2'      68 'fn main() -> i32 { let a: i32 = 17; return a << 2; }'
check "$A" '-8 >> 1 (ASR)' -4 'fn main() -> i32 { let a: i32 = -8; return a >> 1; }'
check "$A" '-8 << 1'     -16 'fn main() -> i32 { let a: i32 = -8; return a << 1; }'
check "$A" '17 & 5'        1 'fn main() -> i32 { let a: i32 = 17; let b: i32 = 5; return a & b; }'
check "$A" '17 | 5'       21 'fn main() -> i32 { let a: i32 = 17; let b: i32 = 5; return a | b; }'
check "$A" '17 ^ 5'       20 'fn main() -> i32 { let a: i32 = 17; let b: i32 = 5; return a ^ b; }'
check "$A" '~17'         -18 'fn main() -> i32 { let a: i32 = 17; return ~a; }'

printf '%s\n' '[5/8] qemu: precedence, compound assignment, ++/--, ?:'
# Precedence, checked against C's own order: * / % bind tighter than + -, which
# bind tighter than << >>, which bind tighter than & , ^ , | .
check "$A" '1 | 2 & 3 ^ 4'        7 'fn main() -> i32 { return 1 | 2 & 3 ^ 4; }'
check "$A" '1 + 2 << 3 | 1'      25 'fn main() -> i32 { return 1 + 2 << 3 | 1; }'
check "$A" '8 >> 1 + 1'           2 'fn main() -> i32 { return 8 >> 1 + 1; }'
check "$A" '2 * 3 % 4'            2 'fn main() -> i32 { return 2 * 3 % 4; }'
check "$A" '100 / 7 % 3'          2 'fn main() -> i32 { return 100 / 7 % 3; }'
# Compound assignment on every target form the parser accepts.
check "$A" 'x +=/-=/*=//=/%='     1 'fn main() -> i32 {
    let c: i32 = 10;
    c += 5; c -= 3; c *= 2; c /= 4; c %= 5;
    return c;
}'
check "$A" 'x <<=/>>=/&=/|=/^='  28 'fn main() -> i32 {
    let c: i32 = 3;
    c <<= 4; c >>= 1; c |= 1; c &= 30; c ^= 4;
    return c;
}'
check "$A" 'a[i] OP= e'          11 'fn main() -> i32 {
    let a: i32[4] = 0;
    a[2] = 5; a[2] *= 3; a[2] -= 4;
    return a[2];
}'
check "$A" 's.f OP= e'           21 'struct S { a: i32, b: i32 }
fn main() -> i32 {
    let s: S = S { 10, 20 };
    s.a += 5; s.b %= 7;
    return s.a + s.b;
}'
# ++ / -- in both spellings, and as a for step.
check "$A" 'd++'                 11 'fn main() -> i32 { let d: i32 = 10; d++; return d; }'
check "$A" '++d'                 11 'fn main() -> i32 { let d: i32 = 10; ++d; return d; }'
check "$A" 'd--'                  9 'fn main() -> i32 { let d: i32 = 10; d--; return d; }'
check "$A" '--d'                  9 'fn main() -> i32 { let d: i32 = 10; --d; return d; }'
check "$A" 'for step: i++'          10 'fn main() -> i32 {
    let s: i32 = 0;
    for (let i: i32 = 0; i < 5; i++) { s += i; }
    return s;
}'
check "$A" 'for step: i += 2'      20 'fn main() -> i32 {
    let s: i32 = 0;
    for (let i: i32 = 0; i < 10; i += 2) { s += i; }
    return s;
}'
check "$A" 'while with a ?: step'  3 'fn main() -> i32 {
    let n: i32 = 0;
    while ((n < 3 ? 1 : 0) == 1) { n += 1; }
    return n;
}'
# ?: , including nested and in an assignment target's value.
check "$A" '?: true arm'          7 'fn main() -> i32 { return 1 == 1 ? 7 : 9; }'
check "$A" '?: false arm'         9 'fn main() -> i32 { return 1 == 2 ? 7 : 9; }'
check "$A" '?: nested'            5 'fn main() -> i32 { return 1 == 1 ? (2 == 2 ? 5 : 6) : 7; }'
check "$A" '?: right-assoc'       7 'fn main() -> i32 { return 1 == 2 ? 1 : 2 == 2 ? 7 : 8; }'

printf '%s\n' '[6/8] qemu: constant folding of the new operators'
check "$A" 'let g = 1 << 4'      16 'let g: i32 = 1 << 4;
fn main() -> i32 { return g; }'
check "$A" 'let g = ~15'        -16 'let g: i32 = ~15;
fn main() -> i32 { return g; }'
check "$A" 'let g = 17 % 5'       2 'let g: i32 = 17 % 5;
fn main() -> i32 { return g; }'
check "$A" 'let g = (1 | 6) & 12' 4 'let g: i32 = (1 | 6) & 12;
fn main() -> i32 { return g; }'
check "$A" 'let g = 1 << 2 | 1'   5 'let g: i32 = 1 << 2 | 1;
fn main() -> i32 { return g; }'

# ---------------------------------------------------------------------------
# [7/8] Differential layer: the same expression, compiled by Aster and by the
# target C compiler, must produce the same value. This is the layer that would
# have caught a precedence mistake that happens to agree with the hand-written
# expected value above.
# ---------------------------------------------------------------------------
fi # the [4/8]-[6/8] behavioural block, which needs qemu

printf '%s\n' '[7/8] Differential: Aster vs the target C compiler'
HOSTCC=${HOSTCC:-cc}
probe_out=$( ( HOSTCC="$HOSTCC" . tests/host-toolchain-probe.sh ) 2>&1 ) || true
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the differential layer needs qemu-aarch64 to run either binary\n'
elif printf '%s' "$probe_out" | grep -q '^SKIP'; then
    printf '  SKIP: %s\n' "$(printf '%s' "$probe_out" | sed -n '1p')"
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
    # diff_expr <name> <expression> — the same text, in both languages.
    diff_expr() {
        diff_case "$1" "fn main() -> i32 { return $2; }" "int main(void) { return $2; }"
    }
    diff_expr '1 | 2 & 3 ^ 4'  '1 | 2 & 3 ^ 4'
    diff_expr '1 + 2 << 3 | 1' '1 + 2 << 3 | 1'
    diff_expr '8 >> 1 + 1'     '8 >> 1 + 1'
    diff_expr '2 * 3 % 4'      '2 * 3 % 4'
    diff_expr '100 / 7 % 3'    '100 / 7 % 3'
    diff_expr '~17 & 31'       '~17 & 31'
    diff_expr '-17 % 5'        '-17 % 5'
    diff_expr '-8 >> 1'        '-8 >> 1'
    diff_expr '(v >> 8) & 255' '(48879 >> 8) & 255'
    diff_expr '?: nesting'     '1 == 1 ? (2 == 2 ? 5 : 6) : 7'
    # A whole program rather than one expression, so the compound assignments
    # and the ++ / -- spellings are compared too.
    diff_case 'compound + ++ + ?:' 'fn main() -> i32 {
    let c: i32 = 0;
    c += 5; c -= 2; c *= 3; c /= 2; c %= 4; c <<= 3; c >>= 1; c |= 1; c &= 12; c ^= 3;
    let d: i32 = 10;
    d++; --d;
    return c + d + (1 == 1 ? 4 : 0);
}' 'int main(void) {
    int c = 0;
    c += 5; c -= 2; c *= 3; c /= 2; c %= 4; c <<= 3; c >>= 1; c |= 1; c &= 12; c ^= 3;
    int d = 10;
    d++; --d;
    return c + d + (1 == 1 ? 4 : 0);
}'
fi

# ---------------------------------------------------------------------------
# [8/8] Mutation layer. A behavioural check that passes on a damaged compiler
# is not checking anything: these rebuild aster with one encoding changed and
# assert that the same check now FAILS. Three encodings are mutated (the % 
# remainder step, the signed/unsigned choice in >>, and the ~ complement),
# which is what separates "the parser accepts %" from "the code is right".
# ---------------------------------------------------------------------------
if [ "$have_qemu" = yes ]; then
printf '%s\n' '[8/8] Mutation: the checks above must fail on a damaged compiler'
mutate() { # mutate <name> <sed-expr> <expected-value-source> <expected-value>
    sed "$2" src/aster.cpp > "$OUT/m.cpp"
    if cmp -s src/aster.cpp "$OUT/m.cpp"; then
        echo "FAIL: mutation $1 did not change the source (the guard is stale)" >&2; exit 1
    fi
    if ! $CXX -std=c++17 -O0 -w "$OUT/m.cpp" -o "$OUT/m.aster" 2>"$OUT/m.err"; then
        echo "FAIL: mutant $1 does not build" >&2; sed -n '1,3p' "$OUT/m.err" >&2; exit 1
    fi
    printf '%s\n' "$3" > "$OUT/m.ast"
    if ! "$OUT/m.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >/dev/null 2>&1; then
        echo "FAIL: mutant $1 rejected a valid program" >&2; exit 1
    fi
    $RUNNER "$OUT/m.a64" >/dev/null 2>&1 && got=0 || got=$?
    [ "$got" -gt 127 ] && got=$((got-256))
    if [ "$got" = "$4" ]; then
        echo "FAIL: $1: the mutant still produced $got — the checks do not test it" >&2; exit 1
    fi
    printf '  %-34s mutant gives %s (correct: %s)\n' "$1" "$got" "$4"
}
# MSUB -> MADD: `17 % 5` becomes 17 + 3*5 instead of 17 - 3*5.
mutate 'MSUB -> MADD (%)' 's/0x1b008000u/0x1b000000u/' \
    'fn main() -> i32 { let a: i32 = 17; let b: i32 = 5; return a % b; }' 2
# ASR -> LSR: a signed >> stops preserving the sign. (`if` always carries an
# else in Aster, so the two outcomes are two returns rather than one.)
mutate 'ASR -> LSR (>>)' 's/tyIsUnsigned(ta)?0x400u:0x800u/tyIsUnsigned(ta)?0x400u:0x400u/' \
    'fn main() -> i32 { let a: i32 = -8; if ((a >> 1) < 0) { return 1; } else { return 2; } }' 1
# ORN -> ORR: `~17` becomes 17.
mutate 'ORN -> ORR (~)' 's/0xaa200000u:0x2a200000u/0xaa000000u:0x2a000000u/' \
    'fn main() -> i32 { let a: i32 = 17; return ~a; }' -18
fi

printf '%s\n' 'PASS: operator-checks (% << >> & | ^ ~ OP= ++ -- ?:)'
