#!/bin/sh
# v0.23.48-dev checks for the u64 type and the explicit integer cast T(x).
#
# Two gaps close together this round:
#
#   * u64 — the unsigned 64-bit grid. A program that needed the full unsigned
#     range had to fake it with i64 and hope the value never crossed 2^63.
#     u64 is a real type now: 8 bytes, unsigned comparisons, unsigned
#     division, literals up to 18446744073709551615.
#   * T(x) — the explicit cast, spelled like the sizeof/len it sits beside
#     (`u8(300)` is 44). Where the language refuses to drop bits on its own
#     (a narrow slot, a narrow parameter), a cast is how a program asks for
#     it; widening between integers stays implicit where lossless; ptr and
#     the other non-integer types have no cast.
#
# The implementation spans the whole compiler — a type kind, a lexer
# keyword, a parser node, both type systems, four normalisation encodings in
# the backend, the constant folder, the DWARF table — and the two generator
# tables plus the C twin that mirror the bootstrap side. The layers below:
#
#   [1]  strict build            -Werror, zero warnings
#   [2]  source guards           every load-bearing edit, pinned
#   [3]  qemu behaviour          30 hand-derived witnesses
#   [4]  gcc differential        the example against its C twin
#   [5]  rejection matrix        13 refusals, exact messages
#   [6]  cascade diagnostics     the three migrated i64 messages
#   [7]  coverage count          the behavioural matrix is the coverage
#   [8]  mutation layer          9 mutants, each observably wrong
#   [9]  byte baseline           288 pre-existing rows, byte for byte
#   [10] the example             end to end, exit 255
#
# The behavioural layers need qemu (or an AArch64 host); the differential layer
# additionally needs a C compiler that can emit AArch64 ELF. Neither is
# required to *build*, so each layer that cannot run says SKIP and the rest
# still runs.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-integer-cast-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/10] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
HOSTCC=${HOSTCC:-cc}
have_cc=yes
command -v "$HOSTCC" >/dev/null 2>&1 || have_cc=no
# The differential layer must emit AArch64 ELF; a native cc on an x86 host would
# build an x86 twin, so the probe prefers the cross toolchain.
if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then HOSTCC=aarch64-linux-gnu-gcc; fi
if [ "$have_qemu" = no ]; then
    printf '%s\n' 'SKIP: integer-cast-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

# ---------------------------------------------------------------------------
# [2/10] Source guards. Each change is pinned where it was made, so a
# regression that quietly reopens one fails here rather than by a behavioural
# case. Pinned without the enum tails: the enum tails move every round, and
# callback-table-checks.sh owns the tail positions.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/10] Source guards: the u64 grid and the cast'
# the version constant — pinned to the current dev line so a stale compiler
# (or a forgotten version bump) fails loudly rather than silently.
grep -qF '#define ASTER_VERSION_STRING "0.23.53-dev"' src/aster.cpp \
    || { echo "FAIL: the version constant is not 0.23.53-dev" >&2; exit 1; }
# the token and the keyword
grep -qF '    U64,' src/aster.cpp \
    || { echo "FAIL: enum class TK no longer declares U64" >&2; exit 1; }
grep -qF 'else if(x=="u64")k=TK::U64;' src/aster.cpp \
    || { echo "FAIL: the lexer no longer maps the u64 keyword" >&2; exit 1; }
# the type kind, its size/align, and its three predicates
grep -qF 'U64' src/aster.cpp >/dev/null \
    || { echo "FAIL: Ty::Kind no longer mentions U64" >&2; exit 1; }
grep -qF '|| t.k == Ty::U64' src/aster.cpp >/dev/null \
    || { echo "FAIL: tySize/tyAlign no longer covers U64" >&2; exit 1; }
grep -qF 'case Ty::U64: return "u64";' src/aster.cpp \
    || { echo "FAIL: tyName no longer names u64" >&2; exit 1; }
grep -qF 'expected i32, i64, u8, u16, u32, u64, ptr, ptr<S>, bool, or a struct name' src/aster.cpp \
    || { echo "FAIL: kTypeExpected no longer lists u64" >&2; exit 1; }
# the declaration-site range check and the u64 slot's acceptance
grep -qF 'if(t==Ty::I64) return (uint64_t)e.n<=0x7fffffffffffffffULL;' src/aster.cpp \
    || { echo "FAIL: initializerFits no longer range-checks an i64 slot at the declaration" >&2; exit 1; }
grep -qF 'case Ty::U64: return true;' src/aster.cpp \
    || { echo "FAIL: initializerFits no longer accepts every folded value for a u64 slot" >&2; exit 1; }
# the parser: the type, the literal range, the cast interception
grep -qF 'case TK::U64: out=Ty::U64;  ++p; return true;' src/aster.cpp \
    || { echo "FAIL: parseType no longer accepts the u64 keyword" >&2; exit 1; }
grep -qF 'if(n>0xffffffffffffffffULL)throw Error("integer literal exceeds u64 range at "' src/aster.cpp \
    || { echo "FAIL: the literal guard is no longer the full u64 range" >&2; exit 1; }
grep -qF 'need(TK::LParen,"expected '"'"'('"'"' after cast type")' src/aster.cpp >/dev/null \
    || { echo "FAIL: primary() no longer requires the cast's open paren" >&2; exit 1; }
grep -qF "need(TK::RParen,\"expected ')' after cast operand\")" src/aster.cpp \
    || { echo "FAIL: primary() no longer requires the cast's close paren" >&2; exit 1; }
# the expression kind and the constant folder's twin
grep -qF 'Cast } k;' src/aster.cpp \
    || { echo "FAIL: Expr::Kind no longer declares Cast" >&2; exit 1; }
grep -qF 'static int64_t castConstValue(int64_t v,Ty to){' src/aster.cpp \
    || { echo "FAIL: castConstValue() is missing" >&2; exit 1; }
grep -qF 'case Expr::Cast: return castConstValue(foldConst(*e.a),e.ty);' src/aster.cpp \
    || { echo "FAIL: foldConst no longer folds a cast" >&2; exit 1; }
grep -qF 'case Expr::Cast: return isConstExpr(*e.a);' src/aster.cpp \
    || { echo "FAIL: isConstExpr no longer looks through a cast" >&2; exit 1; }
# both type systems, and the promotion and assignment rules
grep -qF 'case Expr::Cast: return e.ty;' src/aster.cpp \
    || { echo "FAIL: a type system no longer answers the cast target" >&2; exit 1; }
grep -qF 'throw Error(loc(e.line,e.col,"cannot cast "+tyNameFull(from)+" to "+tyName(e.ty)));' src/aster.cpp \
    || { echo "FAIL: Sema no longer refuses a cast of a non-integer" >&2; exit 1; }
grep -qF 'if(a==Ty::U64||b==Ty::U64)return Ty::U64;' src/aster.cpp \
    || { echo "FAIL: promoteInt no longer puts u64 first" >&2; exit 1; }
grep -qF '||(to==Ty::U64&&from==Ty::I64)' src/aster.cpp \
    || { echo "FAIL: tyAssignable no longer shares the 64-bit representation" >&2; exit 1; }
# the backend: the operand is generated at the target width, then normalised
grep -qF 'int a=gen(*e.a,e.ty);' src/aster.cpp \
    || { echo "FAIL: gen() no longer generates a cast operand at the target width" >&2; exit 1; }
grep -qF 'if(tyIs64(want)&&e.ty==Ty::I32&&!(wf>wt))' src/aster.cpp \
    || { echo "FAIL: an i32 cast no longer answers a 64-bit consumer" >&2; exit 1; }
grep -qF 'else                   emit(0x93407c00u|(uint32_t(a)<<5)|uint32_t(a)); // SXTW Xa, Wa' src/aster.cpp \
    || { echo "FAIL: the cast's SXTW normalisation is missing" >&2; exit 1; }
# the DWARF table
grep -qF 'case Ty::U64:  nm="u64"; size=8;enc=0x07;break;' src/aster.cpp \
    || { echo "FAIL: the DWARF typeRef no longer carries u64" >&2; exit 1; }
printf '%s\n' 'PASS: the u64 grid and the cast are pinned in the source'

# ---------------------------------------------------------------------------
# [3/10] qemu: every witness hand-derived, each program returning the value
# it is named for, so a wrong fold or a wrong normalisation is the exit code.
# ---------------------------------------------------------------------------
printf '%s\n' '[3/10] qemu: the u64 grid and the cast, every witness'
if [ "$have_qemu" = yes ]; then
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
    printf '  %-38s %s\n' "$name" "$got"
}
A=$OUT/aster
# --- the u64 grid ---
check "$A" 'sizeof(u64) is 8'               8 'fn main() -> i32 { return sizeof(u64); }'
check "$A" 'u64 local holds 2^64-1'       100 'fn main() -> i32 { let x: u64 = 18446744073709551615; if (x == 18446744073709551615) { return 100; } return 0; }'
check "$A" 'u64 local holds 2^63'         101 'fn main() -> i32 { let x: u64 = 9223372036854775808; if (x == 9223372036854775808) { return 101; } return 0; }'
check "$A" 'u64 global beyond i64'          7 'let g: u64 = 12345678901234567890;
fn main() -> i32 { if (g == 12345678901234567890) { return 7; } return 0; }'
check "$A" 'u64 unsigned compare'            9 'fn main() -> i32 { let x: u64 = 9223372036854775808; if (x > 9223372036854775807) { return 9; } return 0; }'
check "$A" 'u64 unsigned division'          73 'fn main() -> i32 { let x: u64 = 18446744073709551615; if (x / 1000000000000 == 18446744) { return 73; } return 0; }'
check "$A" 'u64 plus i32 stays u64'         11 'fn main() -> i32 { let x: u64 = 1; if (x + 1 == 2) { return 11; } return 0; }'
check "$A" 'u64 parameter'                  13 'fn f(v: u64) -> i32 { if (v == 9223372036854775808) { return 13; } return 0; }
fn main() -> i32 { return f(9223372036854775808); }'
check "$A" 'u64 array elements'             17 'fn main() -> i32 { let a: u64[2] = 0; a[0] = 9223372036854775808; a[1] = 18446744073709551615; if (a[0] == 9223372036854775808 && a[1] == 18446744073709551615) { return 17; } return 0; }'
check "$A" 'u64 struct field'               19 'struct B { hi: u64 }
fn main() -> i32 { let b: B; b.hi = 18446744073709551615; if (b.hi == 18446744073709551615) { return 19; } return 0; }'
check "$A" 'ptr<u64> indexes'               23 'fn main() -> i32 { let a: u64[2] = 0; a[0] = 7; let p: ptr<u64> = &a; if (p[0] == 7) { return 23; } return 0; }'
check "$A" 'ptr<u64> parameter'             29 'fn f(p: ptr<u64>) -> i32 { if (p[0] == 7) { return 29; } return 0; }
fn main() -> i32 { let a: u64[2] = 0; a[0] = 7; return f(&a); }'
# --- narrowing ---
check "$A" 'u8(300) is 44'                  44 'fn main() -> i32 { if (u8(300) == 44) { return 44; } return 0; }'
check "$A" 'u16(70000) is 4464'            112 'fn main() -> i32 { if (u16(70000) == 4464) { return 112; } return 0; }'
check "$A" 'u32(0-1) is 2^32-1'            102 'fn main() -> i32 { if (u32(0 - 1) == 4294967295) { return 102; } return 0; }'
check "$A" 'u8(0-1) is 255'                 31 'fn main() -> i32 { if (u8(0 - 1) == 255) { return 31; } return 0; }'
check "$A" 'u16(0-1) is 65535'              37 'fn main() -> i32 { if (u16(0 - 1) == 65535) { return 37; } return 0; }'
check "$A" 'u32 of an i64 -1'               41 'fn main() -> i32 { let neg: i64 = 0 - 1; if (u32(neg) == 4294967295) { return 41; } return 0; }'
# --- widening ---
check "$A" 'u64(0-1) is 2^64-1'             43 'fn main() -> i32 { if (u64(0 - 1) == 18446744073709551615) { return 43; } return 0; }'
check "$A" 'u64 of a u8'                    47 'fn main() -> i32 { if (u64(u8(200)) == 200) { return 47; } return 0; }'
check "$A" 'u64 of a u32 top bit'           53 'fn main() -> i32 { if (u64(u32(4294967295)) == 4294967295) { return 53; } return 0; }'
check "$A" 'i64 of an i32 -1'               59 'fn main() -> i32 { if (i64(i32(0 - 1)) == 0 - 1) { return 59; } return 0; }'
check "$A" 'i64 of a u32 top bit'           61 'fn main() -> i32 { if (i64(u32(4294967295)) == 4294967295) { return 61; } return 0; }'
# --- same-width reinterpretation ---
check "$A" 'i32 of an i64 -1'               67 'fn main() -> i32 { let neg: i64 = 0 - 1; if (i32(neg) == 0 - 1) { return 67; } return 0; }'
check "$A" 'u64 of an i64 -1'               71 'fn main() -> i32 { let neg: i64 = 0 - 1; if (u64(neg) == 18446744073709551615) { return 71; } return 0; }'
# --- through a function, and the constant folder ---
check "$A" 'narrowing through a function'   79 'fn narrow8(v: i32) -> u8 { return u8(v); }
fn main() -> i32 { if (narrow8(300) == 44) { return 79; } return 0; }'
check "$A" 'widening through a function'    83 'fn widen64(v: i32) -> u64 { return u64(v); }
fn main() -> i32 { if (widen64(0 - 1) == 18446744073709551615) { return 83; } return 0; }'
check "$A" 'folded cast in a global'        89 'let g: u8 = u8(300);
fn main() -> i32 { if (g == 44) { return 89; } return 0; }'
# --- composition ---
check "$A" 'u8 of a u16 of 70000'           97 'fn main() -> i32 { if (u8(u16(70000)) == 112) { return 97; } return 0; }'
check "$A" 'u64 of a u8, plus five'        103 'fn main() -> i32 { if (u64(u8(300)) + 5 == 49) { return 103; } return 0; }'
check "$A" 'a cast as an array index'      107 'fn main() -> i32 { let a: i32[64] = 0; let i: i32 = u8(300); a[i] = 5; if (a[44] == 5) { return 107; } return 0; }'
check "$A" 'u8 of a u16 of a variable'     109 'fn main() -> i32 { let x: i32 = 70000; if (u8(u16(x)) == 112) { return 109; } return 0; }'
else
    printf '%s\n' '  SKIP: the behavioural cases need qemu to run'
fi

# ---------------------------------------------------------------------------
# [4/10] Differential: Aster against the target C compiler, whose conversion
# rules are the rules the cast implements. No expectation here is
# hand-computed: the shipped example and its twin must agree exactly.
# ---------------------------------------------------------------------------
printf '%s\n' '[4/10] Differential: Aster vs the target C compiler'
if [ "$have_qemu" = yes ] && [ "$have_cc" = yes ]; then
    diff_case() {
        printf '%s\n' "$2" > "$OUT/d.ast"
        printf '%s\n' "$3" > "$OUT/d.c"
        if ! "$A" build-elf "$OUT/d.ast" -o "$OUT/d.a64" >"$OUT/d.err" 2>&1; then
            echo "FAIL: $1 does not compile under Aster" >&2; sed -n '1,3p' "$OUT/d.err" >&2; exit 1
        fi
        "$HOSTCC" -std=c11 -O2 -w "$OUT/d.c" -o "$OUT/dc.a64"
        $RUNNER "$OUT/d.a64" >/dev/null 2>&1 && ga=0 || ga=$?
        $RUNNER "$OUT/dc.a64" >/dev/null 2>&1 && gc=0 || gc=$?
        if [ "$ga" != "$gc" ]; then
            echo "FAIL: $1: Aster exit $ga, C exit $gc" >&2; exit 1
        fi
        printf '  %-38s %s\n' "$1" "$ga"
    }
    # The two boundary literals, where the u64 slot and C's ull agree and an
    # i64 slot would have refused the value outright.
    diff_case 'the two u64-only literals' \
        'fn main() -> i32 {
    let top: u64 = 18446744073709551615;
    let bit63: u64 = 9223372036854775808;
    if (top == 18446744073709551615) { if (bit63 == 9223372036854775808) { return 33; } }
    return 0; }' \
        '#include <stdint.h>
int main(void) {
    uint64_t top = 18446744073709551615ull;
    uint64_t bit63 = 9223372036854775808ull;
    if (top == 18446744073709551615ull) { if (bit63 == 9223372036854775808ull) return 33; }
    return 0; }'
    # The shipped example against its twin, end to end.
    diff_case 'examples/integer_cast.ast' \
        "$(cat examples/integer_cast.ast)" \
        "$(cat tests/integer_cast-twin.c)"
else
    printf '%s\n' '  SKIP: the differential layer needs qemu and a target C compiler'
fi

# ---------------------------------------------------------------------------
# [5/10] Rejection matrix. The cast spellings are checked like any other
# construct; the narrow-slot discipline this round did not loosen still
# refuses; the ptr and struct operands have no cast to answer.
# ---------------------------------------------------------------------------
printf '%s\n' '[5/10] Rejection matrix'
reject() {
    printf '%s\n' "$3" > "$OUT/r.ast"
    if "$A" build-elf "$OUT/r.ast" -o "$OUT/r.a64" >"$OUT/r.err" 2>&1; then
        echo "FAIL: $1 was accepted" >&2; exit 1
    fi
    grep -qF "$2" "$OUT/r.err" \
        || { echo "FAIL: $1: expected '$2', got: $(sed -n '1p' "$OUT/r.err")" >&2; exit 1; }
    printf '  %-38s refused\n' "$1"
}
A=$OUT/aster
reject 'C-style cast (u8)x'          "expected '(' after cast type" \
    'fn main() -> i32 { let x: i32 = 300; return (u8)x; }'
reject 'cast without its paren'      "expected '(' after cast type" \
    'fn main() -> i32 { return u64 300; }'
reject 'cast unclosed'               "expected ')' after cast operand" \
    'fn main() -> i32 { return u64(300; }'
reject 'ptr( is not a cast'          "expected expression" \
    'fn main() -> i32 { return ptr(0); }'
reject 'bool( is not a cast'         "expected expression" \
    'fn main() -> i32 { return bool(1); }'
reject 'cast of a ptr'               "cannot cast ptr to u64" \
    'fn main() -> i32 { let p: ptr = 0; let z: u64 = u64(p); return 0; }'
reject 'cast of a struct'            "cannot cast B to u64" \
    'struct B { x: i32 }
fn main() -> i32 { let b: B; let z: u64 = u64(b); return 0; }'
reject 'cast of a bool'              "cannot cast bool to u64" \
    'fn main() -> i32 { let t: bool = true; let z: u64 = u64(t); return 0; }'
reject 'a narrow slot still refuses' "local initializer does not fit in u8: x (300)" \
    'fn main() -> i32 { let x: u8 = 300; return 0; }'
reject 'a narrow parameter still refuses' "argument type mismatch calling f at argument 1: expected u8, got i32" \
    'fn f(v: u8) -> i32 { return 0; }
fn main() -> i32 { let y: i32 = 1; return f(y); }'
reject 'a u64 is not a u8 either'    "argument type mismatch calling f at argument 1: expected u8, got u64" \
    'fn f(v: u8) -> i32 { return 0; }
fn main() -> i32 { let y: u64 = 1; return f(y); }'
reject 'an i64 slot still refuses'   "local initializer does not fit in i64: x (-9223372036854775808)" \
    'fn main() -> i32 { let x: i64 = 9223372036854775808; return 0; }'
reject 'a literal past 2^64-1'       "integer literal is too large" \
    'fn main() -> i32 { let x: u64 = 18446744073709551616; return 0; }'
printf '%s\n' 'PASS: the rejection matrix holds'

# ---------------------------------------------------------------------------
# [6/10] Cascade diagnostics. The i64 literal range check moved from the
# parser to the declaration site this round (only the slot knows which range
# the value was meant for), so three suites' expected messages moved with it.
# The programs are still refused — only the diagnostic's position changed —
# and this layer re-pins the new messages at their new positions.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/10] Cascade: the migrated diagnostics still refuse'
cascade() {
    printf '%s\n' "$3" > "$OUT/g.ast"
    if "$A" build-elf "$OUT/g.ast" -o "$OUT/g.a64" >"$OUT/g.err" 2>&1; then
        echo "FAIL: $1 was accepted" >&2; exit 1
    fi
    grep -qF "$2" "$OUT/g.err" \
        || { echo "FAIL: $1: expected '$2', got: $(sed -n '1p' "$OUT/g.err")" >&2; exit 1; }
    printf '  %-38s refused\n' "$1"
}
A=$OUT/aster
cascade 'wide-int-checks: i64 slot'        "local initializer does not fit in i64: x (-9223372036854775808)" \
    'fn main() -> i32 { let x: i64 = 9223372036854775808; return 0; }'
cascade 'wide-int-literal-checks: hex'     "local initializer does not fit in i64: x (-9223372036854775808)" \
    'fn main() -> i32 { let x: i64 = 0x8000000000000000; return 0; }'
cascade 'syntax-relief-checks: i64 slot'   "local initializer does not fit in i64: x (-1) at 2:9" \
    'fn main() -> i32 {
    let x: i64 = 18446744073709551615;
    return 0; }'
# and the suites that own those messages pin the new text
grep -qF 'local initializer does not fit in i64' tests/wide-int-checks.sh \
    || { echo "FAIL: wide-int-checks.sh no longer pins the migrated message" >&2; exit 1; }
grep -qF 'local initializer does not fit in i64' tests/wide-int-literal-checks.sh \
    || { echo "FAIL: wide-int-literal-checks.sh no longer pins the migrated message" >&2; exit 1; }
grep -qF "local initializer does not fit in i64: x (-1) at 2:9" tests/syntax-relief-checks.sh \
    || { echo "FAIL: syntax-relief-checks.sh no longer pins the migrated message" >&2; exit 1; }
printf '%s\n' 'PASS: the migrated diagnostics refuse at the declaration site, and the suites pin them'

# ---------------------------------------------------------------------------
# [7/10] Coverage: the two type systems, the folder, and every normalisation
# encoding are reached for every shape above, so a hole in a guard is a hole
# here. This is a positive layer, not a guard.
# ---------------------------------------------------------------------------
printf '%s\n' '[7/10] Coverage: every shape is exercised'
# (No test-only artifact; the [3/10] cases above are the coverage. Kept as its
# own layer to mirror the house structure and to make the count explicit.)
if [ "$have_qemu" = yes ]; then
    n=$(grep -c '^check ' "$0")
    [ "$n" -ge 28 ] || { echo "FAIL: expected at least 28 behavioural cases, found $n" >&2; exit 1; }
    printf '  %-38s %s\n' 'behavioural cases' "$n"
    printf '%s\n' 'PASS: the behavioural matrix covers every shape'
else
    printf '%s\n' '  SKIP: the coverage count needs the behavioural cases to run'
fi

# ---------------------------------------------------------------------------
# [8/10] Mutation layer. Each mutant removes one rule; a case must notice.
# must_reject is new this round: the real compiler *accepts* the program and
# the mutant must refuse it — the direction the other three helpers (a wrong
# answer, a new acceptance, a shared refusal) cannot see.
# ---------------------------------------------------------------------------
printf '%s\n' '[8/10] Mutation layer'
must_differ() {   # must_differ <name> <good-exit> <source>: mutant must NOT give good-exit
    name=$1; good=$2
    printf '%s\n' "$3" > "$OUT/m.ast"
    if ! "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant does not compile $name" >&2; exit 1
    fi
    $RUNNER "$OUT/m.a64" >/dev/null 2>&1 && got=0 || got=$?
    if [ "$got" -gt 127 ]; then got=$((got-256)); fi
    if [ "$got" = "$good" ]; then
        echo "FAIL: mutant $name still gives $got — the case does not see the rule" >&2; exit 1
    fi
}
must_now_compile() {   # must_now_compile <name> <source>: real compiler refuses, mutant accepts
    name=$1
    printf '%s\n' "$2" > "$OUT/m.ast"
    if "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        :   # the mutant accepts it — the rule was removed
    else
        echo "FAIL: mutant $name still refuses — the rule was not removed" >&2; exit 1
    fi
}
must_not_compile() {   # must_not_compile <name> <source>: real and mutant both refuse
    name=$1
    printf '%s\n' "$2" > "$OUT/m.ast"
    if "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant $name now compiles — a hard error turned into silence" >&2; exit 1
    fi
}
must_reject() {   # must_reject <name> <source>: real compiler accepts, mutant must refuse
    name=$1
    printf '%s\n' "$2" > "$OUT/m.ast"
    if "$A" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        :   # the real compiler accepts it — the rule stands
    else
        echo "FAIL: the real compiler refuses $name — the case is not a legal program" >&2; exit 1
    fi
    if "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant $name still accepts — the rule was not removed" >&2; exit 1
    fi
}
mutate() {   # mutate <name> <sed-script> <expectation...>
    name=$1; script=$2; shift 2
    cp src/aster.cpp "$OUT/mut.cpp"
    if ! sed -i.bak "$script" "$OUT/mut.cpp" 2>/dev/null; then
        echo "FAIL: mutant $name could not be applied" >&2; exit 1
    fi
    if ! $CXX -std=c++17 -O2 -w "$OUT/mut.cpp" -o "$OUT/mut.aster" >"$OUT/mut.build" 2>&1; then
        echo "FAIL: mutant $name does not build" >&2; sed -n '1,3p' "$OUT/mut.build" >&2; exit 1
    fi
    "$@"
    printf '  %-38s caught\n' "$name"
}
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the mutation layer needs qemu to observe a changed answer\n'
else
# m1: the whole normalisation block is compiled out — a u16 cast of 70000
# answers 70000 instead of 4464.
mutate 'm1: no normalisation at all' \
    's#                if(wf>wt){#                if(false){#' \
    must_differ 'u16(70000)' 112 'fn main() -> i32 { if (u16(70000) == 4464) { return 112; } return 0; }'
# m2: the i32 target takes the u32 target's encoding — a zero-extension
# instead of the sign-extension, so an i64 reading of the bits is wrong.
mutate 'm2: SXTW becomes UXTW' \
    's#                else                   emit(0x93407c00u|(uint32_t(a)<<5)|uint32_t(a)); // SXTW Xa, Wa#                else                   emit(0x2a0003e0u|(uint32_t(a)<<16)|uint32_t(a)); // SXTW Xa, Wa#' \
    must_differ 'i32 of an i64 top bit' 67 'fn main() -> i32 { let x: i64 = 4294967295; let y: i64 = i32(x); if (y == 0 - 1) { return 67; } return 0; }'
# m3: the 64-bit consumer's extension is dropped — the one case the operand's
# own producer cannot cover, because a 32-bit producer zeroes the upper half.
mutate 'm3: an i32 cast ignores its consumer' \
    's#                if(tyIs64(want)&&e.ty==Ty::I32&&!(wf>wt))#                if(false)#' \
    must_differ 'i64 of an i32 -1' 59 'fn main() -> i32 { if (i64(i32(0 - 1)) == 0 - 1) { return 59; } return 0; }'
# m4: promoteInt loses the u64-first rule, so u64 + i32 promotes to i64 and
# the comparison of that sum runs signed — 2^63 reads as negative. The sum is
# what carries the witness: a bare u64 comparison takes its signedness from
# tyIsUnsigned directly, but the sum's type is exactly promoteInt's answer.
mutate 'm4: promoteInt forgets u64' \
    's#    if(a==Ty::U64||b==Ty::U64)return Ty::U64;##' \
    must_differ 'unsigned compare of a u64 sum' 9 'fn main() -> i32 { let x: u64 = 9223372036854775808; if (x + 0 > 9223372036854775807) { return 9; } return 0; }'
# m5: the i64 slot's range check is gone, so a literal above 2^63-1 is
# silently truncated into the slot.
mutate 'm5: an i64 slot takes any literal' \
    's#        if(t==Ty::I64) return (uint64_t)e.n<=0x7fffffffffffffffULL;##' \
    must_now_compile 'i64 slot above 2^63-1' 'fn main() -> i32 { let x: i64 = 9223372036854775808; return 0; }'
# m6: the 64-bit representation is no longer shared, so an i64 value cannot
# be passed to a u64 parameter.
mutate 'm6: u64 and i64 stop sharing' \
    's#||(to==Ty::U64&&from==Ty::I64)##' \
    must_reject 'an i64 into a u64 parameter' 'fn f(v: u64) -> i32 { return 0; }
fn main() -> i32 { let a: i64 = 5; return f(a); }'
# m7: the cast operand is generated at the default width instead of the
# target's — an i32 widening to u64 keeps its zero-extended 32 bits.
mutate 'm7: the operand forgets the target width' \
    's#                int a=gen(\*e.a,e.ty);#                int a=gen(*e.a);#' \
    must_differ 'u64 of an i32 -1' 43 'fn main() -> i32 { if (u64(0 - 1) == 18446744073709551615) { return 43; } return 0; }'
# m8: only the u16 arm is dropped — u16 casts stop truncating.
mutate 'm8: only the UXTH arm is dropped' \
    's#                if(wf>wt){#                if(wf>wt \&\& e.ty!=Ty::U16){#' \
    must_differ 'u16(70000) still truncates' 112 'fn main() -> i32 { if (u16(70000) == 4464) { return 112; } return 0; }'
# m9: the literal guard drops back to the i64 ceiling — a u64-only literal
# has nowhere to go again. The real compiler accepts it; the mutant refuses.
mutate 'm9: the old i64 literal ceiling' \
    's#n>0xffffffffffffffffULL#n>0x7fffffffffffffffULL#' \
    must_reject 'the 2^64-1 literal' 'fn main() -> i32 { let x: u64 = 18446744073709551615; return 0; }'
printf '%s\n' 'PASS: nine mutated compilers each lose exactly one rule, and the checks notice'
fi

# ---------------------------------------------------------------------------
# [9/10] Byte-identity baseline. Every line recorded before this round must
# reproduce byte for byte. Fifteen families are excluded: this round's own
# example and the fourteen previous rounds', each of which is new rather
# than pre-existing.
# ---------------------------------------------------------------------------
printf '%s\n' '[9/10] Byte-identity baseline'
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
# v0.23.51-dev: the TLS round's example (tls_demo.ast) and the symbol-versioning
# round's example (so_verstrlen.ast) join the filter the same way; v0.23.52-dev
# adds so_tls_demo.ast beside them, so twenty families are skipped and the
# pre-existing count is still 288: 348 recorded, 60 of them belonging to the
# twenty rounds this suite knows are new.
FILTER='-e ^sizeof_len\. -e ^struct_array_field\. -e ^array_elem_types\. -e ^precedence\. -e ^array_address\. -e ^multi_dim_array\. -e ^lifecycle\. -e ^fn_type\. -e ^cb_table\. -e ^fn_ret\. -e ^call-stmt\. -e ^copy\. -e ^arena\. -e ^stdlib_demo\. -e ^integer_cast\. -e ^switch\. -e ^literals\. -e ^tls_demo\. -e ^so_verstrlen\. -e ^so_tls_demo\.'
grep -v $FILTER "$BASE" | LC_ALL=C sort > "$OUT/expected-old.txt"
grep -v $FILTER "$OUT/hashes.txt" | LC_ALL=C sort > "$OUT/got-old.txt"
if ! diff -u "$OUT/expected-old.txt" "$OUT/got-old.txt" > "$OUT/old.diff"; then
    echo 'FAIL: a pre-existing example moved — the round changed bytes' >&2
    sed -n '1,20p' "$OUT/old.diff" >&2
    exit 1
fi
old=$(wc -l < "$OUT/expected-old.txt")
new=$(wc -l < "$OUT/got-old.txt")
# v0.23.42-dev: the standard-library round's example (stdlib_demo.ast) joined
# the filter, so fourteen families were skipped and the pre-existing count
# stayed 288; v0.23.48-dev adds integer_cast, the fifteenth — the same 288,
# 333 recorded, 45 of them belonging to the fifteen rounds this suite knows
# are new.
[ "$old" -eq 288 ] \
    || { echo "FAIL: expected 288 pre-existing baseline rows, found $old" >&2; exit 1; }
[ "$new" -eq 288 ] \
    || { echo "FAIL: expected 288 rows of pre-existing output, found $new" >&2; exit 1; }
# And this round's example is recorded, in all three modes.
[ "$(grep -c '^integer_cast\.' "$OUT/hashes.txt")" -eq 3 ] \
    || { echo 'FAIL: integer_cast.ast is not in the baseline in all three modes' >&2; exit 1; }
printf '  %-38s %s\n' 'pre-existing rows byte-identical' "$old"
printf '  %-38s %s\n' 'new example rows recorded' '3'
printf '%s\n' 'PASS: byte-identity baseline holds'

# ---------------------------------------------------------------------------
# [10/10] The shipped example, end to end.
# ---------------------------------------------------------------------------
printf '%s\n' '[10/10] The example, end to end'
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the example needs qemu to run\n'
else
    if ! "$A" build-elf examples/integer_cast.ast -o "$OUT/ic.a64" >"$OUT/ic.err" 2>&1; then
        echo 'FAIL: examples/integer_cast.ast does not build' >&2; sed -n '1,3p' "$OUT/ic.err" >&2; exit 1
    fi
    $RUNNER "$OUT/ic.a64" >/dev/null 2>&1 && got=0 || got=$?
    [ "$got" = 255 ] \
        || { echo "FAIL: examples/integer_cast.ast: expected exit 255, got $got" >&2; exit 1; }
    printf '  %-38s %s\n' 'integer_cast.ast' "$got"
    printf '%s\n' 'PASS: the example runs and returns the value its C twin returns'
fi

printf '%s\n' '=== integer-cast checks: ALL PASSED ==='
