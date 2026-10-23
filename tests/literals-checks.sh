#!/bin/sh
# v0.23.50-dev checks for the literal surface: character literals, numeric
# suffixes (u / l / ul), digit separators, binary literals, and the extended
# escape table.
#
# The language's literal grammar was frozen early and stayed small: integer and
# string tokens, the hex prefix, and a six-entry escape table that still refused
# `\'` (a string could not name itself) and had no control codes beyond
# `n r t 0 \ "`. This round fills the surface out — every shape in
# examples/literals.ast, each returning the value it is named for — and it
# keeps the bytes of every program that compiled before, because a literal is a
# token, not an instruction: the byte-identity baseline is untouched except for
# this round's own example (Layer [8/9]).
#
# The behavioural layers need qemu (or an AArch64 host); the differential layer
# additionally needs $HOSTCC to emit AArch64 ELF. Neither is required to *build*,
# so each layer that cannot run says SKIP and the rest still runs.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-literals-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/9] Strictly build Aster compiler'
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
    printf '%s\n' 'SKIP: literals-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each change is pinned where it was made, so a regression
# that quietly reopens one fails here rather than by a behavioural case. Pinned
# without the enum tails: the enum tails move every round.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: the literal surface'
# the version constant — pinned to the current dev line so a stale compiler
# (or a forgotten version bump) fails loudly rather than silently.
grep -qF '#define ASTER_VERSION_STRING "0.23.50-dev"' src/aster.cpp \
    || { echo "FAIL: the version constant is not 0.23.50-dev" >&2; exit 1; }
# the character-literal token, sitting beside the other value tokens
grep -qF '    Char,                // v0.23.50-dev: the character literal' src/aster.cpp \
    || { echo "FAIL: TK no longer declares Char" >&2; exit 1; }
# the literal-suffix state on Num, and the shared escape table
grep -qF '    enum LitSuffix { LSNone, LSU, LSL, LSUL } suffix=LSNone;' src/aster.cpp \
    || { echo "FAIL: Expr no longer carries a literal suffix" >&2; exit 1; }
grep -qF '    int unescape(char e, unsigned l, unsigned c) {' src/aster.cpp \
    || { echo "FAIL: the shared escape table (unescape) is missing" >&2; exit 1; }
# the extended escapes the string table used to refuse
grep -qF 'case '"'"'a'"'"': return '"'"'\a'"'"';    // v0.23.50-dev: the escapes the string table used to refuse' src/aster.cpp \
    || { echo "FAIL: unescape no longer handles the extended escapes" >&2; exit 1; }
# the character literal dispatches to a Char token
grep -qF 'v.push_back({TK::Char, std::string(1,(char)(unsigned char)value), l, c}); continue;' src/aster.cpp \
    || { echo "FAIL: the lexer no longer emits a Char token" >&2; exit 1; }
# binary and hex prefix detection, and the digit-separator rule
grep -qF 'bool isHex=false, isBin=false;' src/aster.cpp \
    || { echo "FAIL: the lexer no longer detects the binary prefix" >&2; exit 1; }
grep -qF 'digit separator '"'"'_'"'"' must be between two digits in ' src/aster.cpp \
    || { echo "FAIL: the digit-separator rule is missing" >&2; exit 1; }
# the suffix maps to the three pinned widths
grep -qF 'if(low=="u"){nn->suffix=Expr::LSU;' src/aster.cpp \
    || { echo "FAIL: primary() no longer pins a u32 suffix" >&2; exit 1; }
grep -qF 'else if(low=="l"){nn->suffix=Expr::LSL;' src/aster.cpp \
    || { echo "FAIL: primary() no longer pins an i64 suffix" >&2; exit 1; }
grep -qF 'else {nn->suffix=Expr::LSUL;}' src/aster.cpp \
    || { echo "FAIL: primary() no longer pins a u64 suffix" >&2; exit 1; }
# the suffix range ceilings
grep -qF 'throw Error("u32 literal out of range at "' src/aster.cpp \
    || { echo "FAIL: the u32 suffix range check is missing" >&2; exit 1; }
grep -qF 'throw Error("i64 literal out of range at "' src/aster.cpp \
    || { echo "FAIL: the i64 suffix range check is missing" >&2; exit 1; }
# the pinned type answers for every suffix
grep -qF 'case Expr::LSU:  return Ty::U32;' src/aster.cpp \
    || { echo "FAIL: a sufixed literal no longer answers u32" >&2; exit 1; }
grep -qF 'case Expr::LSL:  return Ty::I64;' src/aster.cpp \
    || { echo "FAIL: a sufixed literal no longer answers i64" >&2; exit 1; }
grep -qF 'case Expr::LSUL: return Ty::U64;' src/aster.cpp \
    || { echo "FAIL: a sufixed literal no longer answers u64" >&2; exit 1; }
printf '%s\n' 'PASS: the literal surface is pinned in the source'

# ---------------------------------------------------------------------------
# [3/9] qemu: every shape, hand-derived. Each program returns the value it is
# named for, so a wrong code point, a wrong width, or a wrong decode is the
# exit code. qemu-aarch64 returns the guest exit status (& 0xff) verbatim, so
# every value in 0..255 is observable directly.
# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] qemu: the literal surface, every shape'
if [ "$have_qemu" = yes ]; then
check() {
    aster=$1; name=$2; want=$3
    printf '%s\n' "$4" > "$OUT/c.ast"
    if ! $aster build-elf "$OUT/c.ast" -o "$OUT/c.a64" >"$OUT/c.err" 2>&1; then
        echo "FAIL: $name does not compile" >&2; sed -n '1,3p' "$OUT/c.err" >&2; exit 1
    fi
    $RUNNER "$OUT/c.a64" >/dev/null 2>&1 && got=0 || got=$?
    if [ "$got" != "$want" ]; then
        echo "FAIL: $name: expected exit $want, got $got" >&2; exit 1
    fi
    printf '  %-42s %s\n' "$name" "$got"
}
A=$OUT/aster
# --- character literals: plain, newline, escaped quote, BEL, hex escape ---
check "$A" "char 'A' is 65"                      65 "fn main() -> i32 { if ('A' == 65) { return 65; } return 0; }"
check "$A" "char '\\n' is 10"                     10 "fn main() -> i32 { if ('\n' == 10) { return 10; } return 0; }"
check "$A" "char apostrophe is 39"                 39 "fn main() -> i32 { if ('\'' == 39) { return 39; } return 0; }"
check "$A" "char '\\a' is 7"                       7 "fn main() -> i32 { if ('\a' == 7) { return 7; } return 0; }"
check "$A" "char '\\x41' is 65"                   65 "fn main() -> i32 { if ('\x41' == 65) { return 65; } return 0; }"
# --- character arithmetic ---
check "$A" "'B' - 'A' is 1"                        1 "fn main() -> i32 { if ('B' - 'A' == 1) { return 1; } return 0; }"
check "$A" "'a' + 1 is 'b'"                       98 "fn main() -> i32 { if ('a' + 1 == 'b') { return 98; } return 0; }"
check "$A" "'z' - 'a' is 25"                      25 "fn main() -> i32 { if ('z' - 'a' == 25) { return 25; } return 0; }"
# --- numeric suffixes pin the width ---
check "$A" "0xFFFFFFFFu is u32, zero-extends"      3 "fn main() -> i32 { let u: u32 = 0xFFFFFFFFu; if (u64(u) == 4294967295) { return 3; } return 0; }"
check "$A" "5l is i64, equal to 5"                 5 "fn main() -> i32 { let l: i64 = 5l; if (l == 5) { return 5; } return 0; }"
check "$A" "-1l is a negative i64"                 6 "fn main() -> i32 { let l: i64 = -1l; if (l < 0) { return 6; } return 0; }"
check "$A" "0xFFFFFFFFFFFFFFFFul is u64 max"       8 "fn main() -> i32 { let b: u64 = 0xFFFFFFFFFFFFFFFFul; if (b == 18446744073709551615) { return 8; } return 0; }"
# --- binary literals ---
check "$A" "0b101010 is 42"                        42 "fn main() -> i32 { if (0b101010 == 42) { return 42; } return 0; }"
check "$A" "0b1 is 1"                              1 "fn main() -> i32 { if (0b1 == 1) { return 1; } return 0; }"
check "$A" "0b1111_1111 is 255"                  255 "fn main() -> i32 { if (0b1111_1111 == 255) { return 255; } return 0; }"
# --- digit separators ---
check "$A" "1_000_000 is 1000000"                   9 "fn main() -> i32 { if (1_000_000 == 1000000) { return 9; } return 0; }"
check "$A" "0xFF_FF is 65535"                     11 "fn main() -> i32 { if (0xFF_FF == 65535) { return 11; } return 0; }"
check "$A" "0xDEAD_BEEF is 3735928559"            12 "fn main() -> i32 { if (0xDEAD_BEEF == 3735928559) { return 12; } return 0; }"
check "$A" "0b1111_1111_1111 is 4095"             13 "fn main() -> i32 { if (0b1111_1111_1111 == 4095) { return 13; } return 0; }"
# --- extended escapes in a string literal ---
check "$A" "string '\\a\\b\\f\\v' is 7,8,12,11"    14 "fn main() -> i32 { let s: ptr<u8> = \"\a\b\f\v\"; if (s[0] == 7 && s[1] == 8 && s[2] == 12 && s[3] == 11) { return 14; } return 0; }"
printf '%s\n' 'PASS: every literal shape decodes as specified'
else
    printf '%s\n' '  SKIP: the behavioural cases need qemu to run'
fi

# ---------------------------------------------------------------------------
# [4/9] Differential: Aster against the target C compiler, whose literals are
# the literals the Aster surface implements. No expectation here is
# hand-computed: the shipped example and its twin must agree exactly.
# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] Differential: Aster vs the target C compiler'
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
        printf '  %-42s %s\n' "$1" "$ga"
    }
    # The shipped example against its twin, end to end.
    diff_case 'examples/literals.ast' \
        "$(cat examples/literals.ast)" \
        "$(cat tests/literals-twin.c)"
    # A small program using every surface feature, against an independent C read.
    diff_case 'char, suffix, binary, separator' \
        'fn main() -> i32 {
    let u: u32 = 0xFFFFFFFFu;
    let b: u64 = 0xFFFFFFFFFFFFFFFFul;
    let r: i32 = 0;
    if ('"'"'A'"'"' == 65 && 0b101010 == 42 && 1_000_000 == 1000000 && u == 4294967295 && b == 18446744073709551615) { r = r + 1; }
    return r; }' \
        '#include <stdint.h>
int main(void) {
    uint32_t u = 0xFFFFFFFFu;
    uint64_t b = 0xFFFFFFFFFFFFFFFFull;
    int32_t r = 0;
    if (65 == 65 && 0x2A == 42 && 1000000 == 1000000 && u == 4294967295u && b == 18446744073709551615ull) r = r + 1;
    return r; }'
else
    printf '%s\n' '  SKIP: the differential layer needs qemu and a target C compiler'
fi

# ---------------------------------------------------------------------------
# [5/9] Rejection matrix: a character literal holds exactly one code unit, a
# suffix is one of u/l/ul/lu, a separator sits between two digits, binary and
# hex have digits, and a suffix stays inside its width.
# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] Rejection matrix'
reject() {
    printf '%s\n' "$3" > "$OUT/r.ast"
    if "$A" build-elf "$OUT/r.ast" -o "$OUT/r.a64" >"$OUT/r.err" 2>&1; then
        echo "FAIL: $1 was accepted" >&2; exit 1
    fi
    grep -qF "$2" "$OUT/r.err" \
        || { echo "FAIL: $1: expected '$2', got: $(sed -n '1p' "$OUT/r.err")" >&2; exit 1; }
    printf '  %-42s refused\n' "$1"
}
A=$OUT/aster
reject 'bad suffix ll'           "invalid numeric suffix 'll'" \
    "fn main() -> i32 { let x: i32 = 1ll; return 0; }"
reject 'bad suffix uu'           "invalid numeric suffix 'uu'" \
    "fn main() -> i32 { let x: i32 = 1uu; return 0; }"
reject 'char literal too long'   "char literal must hold exactly one character" \
    "fn main() -> i32 { let x: i32 = 'ab'; return 0; }"
reject 'empty char literal'      "empty or unterminated char literal" \
    "fn main() -> i32 { let x: i32 = ''; return 0; }"
reject 'separator with no digit' "digit separator '_' must be between two digits" \
    "fn main() -> i32 { let x: i32 = 1_0_; return 0; }"
reject 'binary with no digits'   "binary literal has no digits" \
    "fn main() -> i32 { let x: i32 = 0b; return 0; }"
reject 'hex with no digits'      "hexadecimal literal has no digits" \
    "fn main() -> i32 { let x: i32 = 0x; return 0; }"
reject 'u32 suffix out of range' "u32 literal out of range at " \
    "fn main() -> i32 { let x: u32 = 0x1_0000_0001u; return 0; }"
reject 'i64 suffix out of range' "i64 literal out of range at " \
    "fn main() -> i32 { let x: i64 = 0x8000_0000_0000_0000l; return 0; }"
printf '%s\n' 'PASS: the rejection matrix holds'

# ---------------------------------------------------------------------------
# [6/9] Coverage: the behavioural layer above is the coverage, so a hole in a
# guard is a hole here. This is a positive layer, not a guard.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Coverage: every literal shape is exercised'
if [ "$have_qemu" = yes ]; then
    n=$(grep -c '^check ' "$0")
    [ "$n" -ge 18 ] || { echo "FAIL: expected at least 18 behavioural cases, found $n" >&2; exit 1; }
    printf '  %-42s %s\n' 'behavioural cases' "$n"
    printf '%s\n' 'PASS: the behavioural matrix covers every literal shape'
else
    printf '%s\n' '  SKIP: the coverage count needs the behavioural cases to run'
fi

# ---------------------------------------------------------------------------
# [7/9] Mutation layer. Each mutant removes one rule; a case must notice.
# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Mutation layer'
must_differ() {   # must_differ <name> <good-exit> <source>: mutant must NOT give good-exit
    name=$1; good=$2
    printf '%s\n' "$3" > "$OUT/m.ast"
    if ! "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant does not compile $name" >&2; exit 1
    fi
    $RUNNER "$OUT/m.a64" >/dev/null 2>&1 && got=0 || got=$?
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
must_reject() {   # must_reject <name> <source>: real compiler accepts, mutant must refuse
    name=$1
    printf '%s\n' "$2" > "$OUT/m.ast"
    if ! "$A" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
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
    printf '  %-42s caught\n' "$name"
}
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the mutation layer needs qemu to observe a changed answer'
else
# m1: the BEL escape is mis-decoded — a '\a' now answers '?' (63) instead of 7,
# so the witness that reads it returns the wrong bit.
mutate 'm1: BEL escape mis-decoded' \
    "s|case 'a': return '\\\\a';.*|case 'a': return '?';|" \
    must_differ 'char '\''\\a'\'' is 7' 7 "fn main() -> i32 { if ('\a' == 7) { return 7; } return 0; }"
# m2: binary-literal decoding is removed — unsignedLiteral no longer treats
# 0b/0B as base 2, so '0b101010' falls through to the base-10 path and is
# rejected. The real compiler accepts it; the mutant must refuse it. '#' is the
# sed delimiter because the patched line itself contains '|'.
mutate 'm2: binary literal decode removed' \
    's#const bool bin=digits.size()>1&&digits\[0\]=='\''0'\''&&(digits\[1\]=='\''b'\''||digits\[1\]=='\''B'\'');#const bool bin=false;#' \
    must_reject '0b101010 compiles' "fn main() -> i32 { if (0b101010 == 42) { return 42; } return 0; }"
# m3: the u32 suffix range check is gone, so a value past 2^32 is silently
# truncated into the slot. The real compiler refuses it; the mutant accepts.
mutate 'm3: the u32 suffix ceiling is dropped' \
    's|if(low=="u"){nn->suffix=Expr::LSU; if(n>0xffffffffULL)throw Error("u32 literal out of range at .*|if(low=="u"){nn->suffix=Expr::LSU;}|' \
    must_now_compile 'u32 suffix past 2^32' "fn main() -> i32 { let x: u32 = 0x1_0000_0001u; return 0; }"
printf '%s\n' 'PASS: three mutated compilers each lose exactly one rule, and the checks notice'
fi

# ---------------------------------------------------------------------------
# [8/9] Byte-identity baseline. Every line recorded before this round must
# reproduce byte for byte. This round's own example (literals.ast) is excluded;
# everything the rounds before it produced is pinned.
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
# v0.23.50-dev: this round's example (literals.ast) joins the filter; the
# sixteen families the rounds before v0.23.5-dev know are new are excluded, and
# the pre-existing count is the same 288 it has been since v0.23.30-dev.
FILTER='-e ^literals\. -e ^switch\. -e ^sizeof_len\. -e ^struct_array_field\. -e ^array_elem_types\. -e ^precedence\. -e ^array_address\. -e ^multi_dim_array\. -e ^lifecycle\. -e ^fn_type\. -e ^cb_table\. -e ^fn_ret\. -e ^call-stmt\. -e ^copy\. -e ^arena\. -e ^stdlib_demo\. -e ^integer_cast\.'
grep -v $FILTER "$BASE" > "$OUT/expected-old.txt"
grep -v $FILTER "$OUT/hashes.txt" > "$OUT/got-old.txt"
if ! diff -u "$OUT/expected-old.txt" "$OUT/got-old.txt" > "$OUT/old.diff"; then
    echo 'FAIL: a pre-existing example moved — the round changed bytes' >&2
    sed -n '1,20p' "$OUT/old.diff" >&2
    exit 1
fi
old=$(wc -l < "$OUT/expected-old.txt")
new=$(wc -l < "$OUT/got-old.txt")
[ "$old" -eq 288 ] \
    || { echo "FAIL: expected 288 pre-existing baseline rows, found $old" >&2; exit 1; }
[ "$new" -eq 288 ] \
    || { echo "FAIL: expected 288 rows of pre-existing output, found $new" >&2; exit 1; }
[ "$(grep -c '^literals\.' "$OUT/hashes.txt")" -eq 3 ] \
    || { echo 'FAIL: literals.ast is not in the baseline in all three modes' >&2; exit 1; }
printf '  %-42s %s\n' 'pre-existing rows byte-identical' "$old"
printf '  %-42s %s\n' 'new example rows recorded' '3'
printf '%s\n' 'PASS: byte-identity baseline holds'

# ---------------------------------------------------------------------------
# [9/9] The shipped example, end to end.
# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] The example, end to end'
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the example needs qemu to run\n'
else
    if ! "$A" build-elf examples/literals.ast -o "$OUT/lit.a64" >"$OUT/lit.err" 2>&1; then
        echo 'FAIL: examples/literals.ast does not build' >&2; sed -n '1,3p' "$OUT/lit.err" >&2; exit 1
    fi
    $RUNNER "$OUT/lit.a64" >/dev/null 2>&1 && got=0 || got=$?
    [ "$got" = 255 ] \
        || { echo "FAIL: examples/literals.ast: expected exit 255, got $got" >&2; exit 1; }
    printf '  %-42s %s\n' 'literals.ast' "$got"
    printf '%s\n' 'PASS: the example runs and returns the value its C twin returns'
fi

printf '%s\n' '=== literals checks: ALL PASSED ==='
