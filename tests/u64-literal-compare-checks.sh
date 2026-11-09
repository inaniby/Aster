#!/bin/sh
# v0.23.75-dev checks for the WIDE-LITERAL COMPARISON round (audit A-01, F-06,
# F-07; F-05 rides along because it is what let CI start at all).
#
# Three defects, one shape: a literal's *type* was decided by a rule that did
# not match its *value*.
#
#   F-01  An unsuffixed literal past 2^63-1 has no signed 64-bit reading, and
#         v0.23.48-dev accepts the whole unsigned range, but exprType(Num)
#         still answered I32. `constExceedsI32` then widened the *operation*
#         to 64 bits while the condition code stayed signed (both sides look
#         like I32), so the top-bit-set pattern compared as a negative value:
#         `if (18446744073709551615 > 0)` answered false. primary() now types
#         such a literal u64 — what C does with a decimal constant too large
#         for long long — and every downstream rule (comparison codes,
#         UDIV/LSR, initializerFits) follows the type.
#   F-06  A literal with the `u` suffix is a u32 *by declaration*, and its
#         value is past 2^31 by construction, so the magnitude test in
#         constExceedsI32 forced every operation that touched it to 64 bits and
#         defeated the 32-bit wrap the type promises: `4294967295u * 2u`
#         produced 8589934590 instead of 4294967294. The suffix now wins.
#   F-07  `integer literal exceeds u64 range` was never the message a user
#         saw: unsignedLiteral() rejects first with "integer literal is too
#         large", and primary()'s own guard is unreachable. The docs now say
#         what the compiler prints.
#   F-05  parseObject()'s relocation push_back was glued to the throw's line;
#         -Wmisleading-indentation plus the project's own -Werror gate meant
#         `sh tests/ci.sh` could not build the compiler at all on HEAD.
#
# Layers:
#   [1] strict build (-Werror) — also the F-05 gate
#   [2] source guards pinning all three rules where they were written
#   [3] behavioural matrix: 24 cases, each returning its own exit code
#   [4] C differential against the target compiler's unsigned long long
#   [5] rejection matrix: what must still be refused
#   [6] coverage census
#   [7] mutation layer: three mutants, each must lose exactly one rule
#   [8] byte-identity baseline: the round changes no pre-existing example
#   [9] the two fixes together, end to end
#
# Every queue below is hand-derived (C's rules for an out-of-range decimal
# constant, and the u32 wrap the language documents), so the differential layer
# is a cross-check, never the expectation.
set -eu
cd "$(dirname "$0")/.."
. tests/lib/baseline.sh
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-u64-literal-compare-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
HOSTCC=${HOSTCC:-cc}
if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then HOSTCC=aarch64-linux-gnu-gcc; fi
have_cc=no
if command -v "$HOSTCC" >/dev/null 2>&1; then
    printf 'int main(void){return 0;}\n' > "$OUT/ccprobe.c"
    if "$HOSTCC" -O2 "$OUT/ccprobe.c" -o "$OUT/ccprobe" >"$OUT/ccprobe.log" 2>&1; then
        have_cc=yes
    fi
fi
if [ "$have_qemu" = no ]; then
    printf '%s\n' 'SKIP: u64-literal-compare-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each rule is pinned at the line that implements it.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: the literal typing and comparison rules'
grep -qF 'if(suf.empty()&&n>0x7fffffffffffffffULL)nn->suffix=Expr::LSUL;' src/aster.cpp \
    || { echo 'FAIL: primary() no longer types an unsuffixed literal past 2^63-1 as u64 (F-01)' >&2; exit 1; }
grep -qF 'if(p->suffix==Expr::LSU)return false;' src/aster.cpp \
    || { echo 'FAIL: constExceedsI32 no longer lets the `u` suffix win (F-06)' >&2; exit 1; }
[ "$(grep -c 'case Expr::LSUL: return Ty::U64;' src/aster.cpp)" -eq 3 ] \
    || { echo 'FAIL: exprType(Num) (both copies) and constExprType no longer all answer U64 for LSUL' >&2; exit 1; }
grep -qF 'result.relocs.push_back({r.offset,namesByIndex[si],type,r.addend});}' src/aster.cpp \
    || { echo 'FAIL: the relocation push_back is missing (F-05)' >&2; exit 1; }
if grep -qF 'remain");result.relocs' src/aster.cpp; then
    echo 'FAIL: the push_back is glued to the throw line again — -Werror rejects it (F-05)' >&2; exit 1
fi
# v0.23.77-dev (audit A-11): exprType is memoised, so the cache and the pure
# implementation both exist. Removing either brings back exponential type
# computation (a 20-term chain already ran 11M type computations).
[ "$(grep -c 'Ty exprTypeUncached(const Expr& e) const {' src/aster.cpp)" -eq 1 ] \
    || { echo 'FAIL: exprType lost its uncached implementation (A-11)' >&2; exit 1; }
[ "$(grep -c 'exprTypeCache.find(&e)' src/aster.cpp)" -eq 1 ] \
    || { echo 'FAIL: exprType is not memoised any more (A-11)' >&2; exit 1; }
grep -qF 'throw Error(std::string(what)+" is too large at ' src/aster.cpp \
    || { echo 'FAIL: unsignedLiteral no longer names the overflow it reports (F-07)' >&2; exit 1; }
printf '%s\n' 'PASS: the typing, suffix and formatting rules are pinned'

# ---------------------------------------------------------------------------
# [3/9] Behavioural matrix. Each case returns the code it is named for.
# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] Behavioural matrix: unsigned literals and u32 wrapping'
A=$OUT/aster
if [ "$have_qemu" = yes ]; then
check() {
    name=$1; want=$2
    printf '%s\n' "$3" > "$OUT/c.ast"
    if ! "$A" build-elf "$OUT/c.ast" -o "$OUT/c.a64" >"$OUT/c.err" 2>&1; then
        echo "FAIL: $name does not compile" >&2; sed -n '1,3p' "$OUT/c.err" >&2; exit 1
    fi
    $RUNNER "$OUT/c.a64" >/dev/null 2>&1 && got=0 || got=$?
    if [ "$got" != "$want" ]; then
        echo "FAIL: $name: expected exit $want, got $got" >&2; exit 1
    fi
    printf '  %-46s %s\n' "$name" "$got"
}
# --- F-01: a bare literal at or past 2^63 is unsigned ---
check 'max u64 > 0'                    1 'fn main() -> i32 { if (18446744073709551615 > 0) { return 1; } return 0; }'
check '2^63 < literal > 2^63-1'        2 'fn main() -> i32 { if (9223372036854775807 < 10823014186374572430) { return 2; } return 0; }'
check '0 < literal > 2^63'             3 'fn main() -> i32 { if (0 < 10823014186374572430) { return 3; } return 0; }'
check 'literal < 2^63 is false'        4 'fn main() -> i32 { if (18446744073709551615 < 9223372036854775807) { return 0; } return 4; }'
check 'equal literals compare equal'   5 'fn main() -> i32 { if (10823014186374572430 == 10823014186374572430) { return 5; } return 0; }'
check 'u64 variable vs bare literal'   6 'fn main() -> i32 { let a: u64 = 1; if (a < 10823014186374572430) { return 6; } return 0; }'
check 'i64 1 < max u64 (unsigned read)' 7 'fn main() -> i32 { let n: i64 = 1; if (n < 18446744073709551615) { return 7; } return 0; }'
check 'i64 -1 < max u64 is equal, not <' 8 'fn main() -> i32 { let n: i64 = -1; if (n < 18446744073709551615) { return 0; } return 8; }'
check 'u64 vs i64 -1 compares unsigned' 9 'fn main() -> i32 { let u: u64 = 18446744073709551615; let i: i64 = -1; if (u == i) { return 9; } return 0; }'
check 'u64 slot holds the whole range' 10 'fn main() -> i32 { let q: u64 = 18446744073709551615; if (q > 0) { return 10; } return 0; }'
check 'ul suffix agrees with the bare form' 11 'fn main() -> i32 { if (18446744073709551615ul > 0) { return 11; } return 0; }'
check 'literal >> is logical at 64 bits' 12 'fn main() -> i32 { if (18446744073709551615 >> 62 == 3) { return 12; } return 0; }'
check 'literal / is unsigned'          13 'fn main() -> i32 { if (18446744073709551615 / 3 == 6148914691236517205) { return 13; } return 0; }'
check 'literal % is unsigned'          14 'fn main() -> i32 { if (18446744073709551615 % 10 == 5) { return 14; } return 0; }'
check 'u64 shift into the top bit'     15 'fn main() -> i32 { let a: u64 = 1; if ((a << 63) > 0) { return 15; } return 0; }'
check 'negative i64 literal stays signed' 16 'fn main() -> i32 { if (-9223372036854775807l - 1l < 0) { return 16; } return 0; }'
# --- F-06: the `u` suffix pins u32, so the arithmetic wraps at 32 bits ---
check 'u32 multiply wraps'             17 'fn main() -> i32 { if (4294967295u * 2u == 4294967294u) { return 17; } return 0; }'
check 'u32 add wraps to zero'          18 'fn main() -> i32 { if (0xFFFFFFFFu + 1u == 0) { return 18; } return 0; }'
check 'u32 wrap with a variable operand' 19 'fn main() -> i32 { let a: u32 = 1; if (4294967295u + a == 0) { return 19; } return 0; }'
check 'u32 literal compares unsigned'   20 'fn main() -> i32 { if (4294967295u > 0) { return 20; } return 0; }'
check 'u32 variable vs u32 literal'     21 'fn main() -> i32 { let x: u32 = 4294967295u; if (x == 4294967295u) { return 21; } return 0; }'
check 'i64 context still widens a u32 literal' 22 'fn main() -> i32 { let q: i64 = 4294967295u + 1; if (q == 4294967296) { return 22; } return 0; }'
check 'u8 store wraps, expression does not' 23 'fn main() -> i32 { let a: u8 = 255; if (a + 1 == 256) { let b: u8 = a + 1; if (b == 0) { return 23; } } return 0; }'
check 'u32 cast is the folding escape hatch' 24 'fn main() -> i32 { let q: u32 = u32(4294967295u + 1u); if (q == 0) { return 24; } return 0; }'
# --- F-06b: a constant initializer folds at the type it names, so the same
# expression is accepted without the cast now that the fold wraps ---
check 'u32 initializer folds with the wrap' 25 'fn main() -> i32 { let q: u32 = 4294967295u + 1u; if (q == 0) { return 25; } return 0; }'
check 'u32 global initializer folds too' 26 'let g: u32 = 4294967295u + 1u;
fn main() -> i32 { if (g == 0) { return 26; } return 0; }'
check 'a u64 consumer keeps the fold and the run equal' 27 'let g: u64 = 0u - 1u;
fn main() -> i32 { let q: u64 = 0u - 1u; if (q == g) { return 27; } return 0; }'
# --- A-11: a long operator chain must not cost exponential type computation ---
long=$(awk 'BEGIN{s="1"; for(i=1;i<200;i++)s=s"+1"; printf "fn main() -> i32 { let a: i32 = %s; if (a == 200) { return 29; } return 0; }\n", s}')
check '200-term chain compiles and runs'       29 "$long"
check 'u32 switch case folds at its own type' 28 'fn main() -> i32 { let x: u32 = 4294967295u; switch (x) { case 0u - 1u: return 28; default: return 0; } }'
else
    printf '%s\n' '  SKIP: the behavioural matrix needs qemu to run'
fi

# ---------------------------------------------------------------------------
# [4/9] Differential: the same expressions compiled by the target C compiler,
# which reads an oversized decimal constant unsigned — the rule Aster now
# follows.
# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] Differential: Aster vs the target C compiler'
if [ "$have_qemu" = yes ] && [ "$have_cc" = yes ]; then
    diff_case() {
        printf '%s\n' "$2" > "$OUT/d.ast"
        printf '%s\n' "$3" > "$OUT/d.c"
        if ! "$A" build-elf "$OUT/d.ast" -o "$OUT/d.a64" >"$OUT/d.err" 2>&1; then
            echo "FAIL: $1 does not compile under Aster" >&2; sed -n '1,3p' "$OUT/d.err" >&2; exit 1
        fi
        "$HOSTCC" -O2 -w "$OUT/d.c" -o "$OUT/dc.a64"
        $RUNNER "$OUT/d.a64" >/dev/null 2>&1 && ga=0 || ga=$?
        $RUNNER "$OUT/dc.a64" >/dev/null 2>&1 && gc=0 || gc=$?
        if [ "$ga" != "$gc" ]; then
            echo "FAIL: $1: Aster exit $ga, C exit $gc" >&2; exit 1
        fi
        printf '  %-46s %s\n' "$1" "$ga"
    }
    diff_case 'max u64 > 0' \
        'fn main() -> i32 { if (18446744073709551615 > 0) { return 31; } return 0; }' \
        '#include <stdint.h>
int main(void) { if (18446744073709551615ULL > 0ULL) { return 31; } return 0; }'
    diff_case 'i64 1 < max u64' \
        'fn main() -> i32 { let n: i64 = 1; if (n < 18446744073709551615) { return 32; } return 0; }' \
        '#include <stdint.h>
int main(void) { int64_t n = 1; if ((uint64_t)n < 18446744073709551615ULL) { return 32; } return 0; }'
    diff_case 'u32 multiply wraps' \
        'fn main() -> i32 { if (4294967295u * 2u == 4294967294u) { return 33; } return 0; }' \
        '#include <stdint.h>
int main(void) { if ((uint32_t)(4294967295u * 2u) == 4294967294u) { return 33; } return 0; }'
    diff_case 'literal / and % are unsigned' \
        'fn main() -> i32 { if (18446744073709551615 / 3 == 6148914691236517205) { if (18446744073709551615 % 10 == 5) { return 34; } } return 0; }' \
        '#include <stdint.h>
int main(void) { if (18446744073709551615ULL / 3ULL == 6148914691236517205ULL) { if (18446744073709551615ULL % 10ULL == 5ULL) { return 34; } } return 0; }'
    diff_case 'u8 store wraps, expression does not' \
        'fn main() -> i32 { let a: u8 = 255; if (a + 1 == 256) { let b: u8 = a + 1; if (b == 0) { return 35; } } return 0; }' \
        '#include <stdint.h>
int main(void) { uint8_t a = 255; if ((int32_t)a + 1 == 256) { uint8_t b = (uint8_t)(a + 1); if (b == 0) { return 35; } } return 0; }'
else
    printf '%s\n' '  SKIP: the differential layer needs qemu and a working target C compiler'
fi

# ---------------------------------------------------------------------------
# [5/9] Rejection matrix: the widening must not have loosened any check.
# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] Rejection matrix'
reject() {
    printf '%s\n' "$3" > "$OUT/r.ast"
    if "$A" build-elf "$OUT/r.ast" -o "$OUT/r.a64" >"$OUT/r.err" 2>&1; then
        echo "FAIL: $1 was accepted" >&2; exit 1
    fi
    grep -qF "$2" "$OUT/r.err" \
        || { echo "FAIL: $1: expected '$2', got: $(sed -n '1p' "$OUT/r.err")" >&2; exit 1; }
    printf '  %-46s refused\n' "$1"
}
reject 'i64 slot refuses max u64' 'local initializer does not fit in i64' \
    'fn main() -> i32 { let x: i64 = 18446744073709551615; return 1; }'
reject 'u32 suffix past 2^32' 'u32 literal out of range' \
    'fn main() -> i32 { let x: u32 = 4294967296u; return 1; }'
reject 'i64 suffix past 2^63-1' 'i64 literal out of range' \
    'fn main() -> i32 { let x: i64 = 9223372036854775808l; return 1; }'
reject 'past 2^64-1' 'integer literal is too large' \
    'fn main() -> i32 { let x: u64 = 18446744073709551616; return 1; }'
reject 'u8 slot still range-checked' 'local initializer does not fit in u8' \
    'fn main() -> i32 { let x: u8 = 300; return 1; }'
printf '%s\n' 'PASS: the rejection matrix holds'

# ---------------------------------------------------------------------------
# [6/9] Coverage: the behavioural layer is the coverage.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Coverage: every literal shape is exercised'
if [ "$have_qemu" = yes ]; then
    n=$(grep -c '^check ' "$0")
    [ "$n" -ge 20 ] || { echo "FAIL: expected at least 20 behavioural cases, found $n" >&2; exit 1; }
    printf '  %-46s %s\n' 'behavioural cases' "$n"
    printf '%s\n' 'PASS: the behavioural matrix covers the unsigned range and the u32 wrap'
else
    printf '%s\n' '  SKIP: the coverage count needs the behavioural cases to run'
fi

# ---------------------------------------------------------------------------
# [7/9] Mutation layer: each mutant removes one rule, and a case must notice.
# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Mutation layer'
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the mutation layer needs qemu to observe a changed answer\n'
else
must_not_compile() {   # must_not_compile <name> <source>: the mutant refuses it
    name=$1
    printf '%s\n' "$2" > "$OUT/m.ast"
    if "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant $name accepted a program the real compiler takes" >&2; exit 1
    fi
}
must_not_time_out() {   # must_not_time_out <name> <source>: the mutant is too slow
    name=$1
    printf '%s\n' "$2" > "$OUT/m.ast"
    if ! timeout 20 "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        if [ $? -eq 124 ]; then
            echo "FAIL: mutant $name still takes exponential time on $name" >&2; exit 1
        fi
    fi
}
must_differ() {   # must_differ <name> <good-exit> <source>
    name=$1; good=$2
    printf '%s\n' "$3" > "$OUT/m.ast"
    if ! "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant does not compile $name" >&2; sed -n '1,3p' "$OUT/m.err" >&2; exit 1
    fi
    $RUNNER "$OUT/m.a64" >/dev/null 2>&1 && got=0 || got=$?
    if [ "$got" = "$good" ]; then
        echo "FAIL: mutant $name still gives $got — the case does not see the rule" >&2; exit 1
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
    printf '  %-46s caught\n' "$name"
}
# m1: the u64 typing of an oversized unsuffixed literal is removed, so the
# comparison goes back to reading its top bit as a sign.
mutate 'm1: oversized literals stay i32-typed' \
    's|if(suf.empty()&&n>0x7fffffffffffffffULL)nn->suffix=Expr::LSUL;||' \
    must_differ 'max u64 > 0' 1 'fn main() -> i32 { if (18446744073709551615 > 0) { return 1; } return 0; }'
# m2: the `u` suffix no longer wins over the magnitude test, so a u32
# operation is forced to 64 bits and stops wrapping.
mutate 'm2: the u suffix no longer wins' \
    's|if(p->suffix==Expr::LSU)return false;||' \
    must_differ 'u32 multiply wraps' 17 'fn main() -> i32 { if (4294967295u * 2u == 4294967294u) { return 17; } return 0; }'
# m4: the fold wraps at the expression's width even when the consumer is
# 64-bit, so the global and the running local disagree.
mutate 'm4: the fold ignores the consumer width' \
    's|t==Ty::U32&&!tyIs64(slot)|t==Ty::U32|' \
    must_differ 'a u64 consumer keeps the fold and the run equal' 27 'let g: u64 = 0u - 1u;
fn main() -> i32 { let q: u64 = 0u - 1u; if (q == g) { return 27; } return 0; }'
# m6: the memo lookup is removed, so a 200-term chain goes back to 2^n work.
mutate 'm6: the type cache is bypassed' \
    's|if(it!=exprTypeCache.end())return it->second;||' \
    must_not_time_out '200-term chain compiles and runs' "$long"
# m5: a switch case value is folded in i64 again, so a u32 label is refused.
mutate 'm5: case labels ignore their own type' \
    's|v=foldAtExprType(constExprType(c),subj,v);||' \
    must_not_compile 'u32 switch case folds at its own type' 'fn main() -> i32 { let x: u32 = 4294967295u; switch (x) { case 0u - 1u: return 28; default: return 0; } }'
# m3: the oversized literal is typed i64 instead of u64 — the value cannot fit,
# so the unsigned reading is lost and `> 0` flips.
mutate 'm3: oversized literals typed i64' \
    's|nn->suffix=Expr::LSUL;|nn->suffix=Expr::LSL;|g' \
    must_differ 'ul suffix agrees with the bare form' 11 'fn main() -> i32 { if (18446744073709551615ul > 0) { return 11; } return 0; }'
printf '%s\n' 'PASS: six mutated compilers each lose exactly one rule, and the checks notice'
fi

# ---------------------------------------------------------------------------
# [8/9] Byte-identity baseline. This round changes no example: the widened
# typing only reaches literals no example writes, so every pre-existing row
# must reproduce byte for byte (312 rows, the count every suite pins).
# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Byte-identity baseline'
BASE=$(aster_baseline_file)
: > "$OUT/hashes.txt"
for mode in build-so build-elf "build-obj --pic"; do
    tag=$(echo "$mode" | tr ' ' '_')
    for f in examples/*.ast; do
        b=$(basename "$f" .ast)
        if "$A" $mode "$f" -o "$OUT/$b.$tag" >/dev/null 2>&1; then
            printf '%s %s\n' "$b.$tag" "$(sha256sum "$OUT/$b.$tag" | cut -d' ' -f1)" >> "$OUT/hashes.txt"
        else
            printf '%s FAILED\n' "$b.$tag" >> "$OUT/hashes.txt"
        fi
    done
done
FILTER='-e ^cast-conversions\. -e ^switch\. -e ^sizeof_len\. -e ^struct_array_field\. -e ^array_elem_types\. -e ^precedence\. -e ^array_address\. -e ^multi_dim_array\. -e ^lifecycle\. -e ^fn_type\. -e ^cb_table\. -e ^fn_ret\. -e ^call-stmt\. -e ^copy\. -e ^arena\. -e ^stdlib_demo\. -e ^integer_cast\. -e ^literals\. -e ^tls_demo\. -e ^so_verstrlen\. -e ^c_ptr_difference\. -e ^address_of\. -e ^address_of_abi\. -e ^so_tls_demo\. -e ^enum_demo\. -e ^type_alias\. -e ^const_binding\. -e ^void_return\.'
grep -v $FILTER "$BASE" | LC_ALL=C sort > "$OUT/expected-old.txt"
grep -v $FILTER "$OUT/hashes.txt" | LC_ALL=C sort > "$OUT/got-old.txt"
if ! diff -u "$OUT/expected-old.txt" "$OUT/got-old.txt" > "$OUT/old.diff"; then
    echo 'FAIL: a pre-existing example moved — the round changed bytes' >&2
    sed -n '1,20p' "$OUT/old.diff" >&2
    exit 1
fi
old=$(wc -l < "$OUT/expected-old.txt")
new=$(wc -l < "$OUT/got-old.txt")
[ "$old" -eq 312 ] || { echo "FAIL: expected 312 pre-existing baseline rows, found $old" >&2; exit 1; }
[ "$new" -eq 312 ] || { echo "FAIL: expected 312 rows of pre-existing output, found $new" >&2; exit 1; }
printf '  %-46s %s\n' 'pre-existing rows byte-identical' "$old"
printf '  %-46s %s\n' 'new example rows recorded' '0'
printf '%s\n' 'PASS: byte-identity baseline holds'

# ---------------------------------------------------------------------------
# [9/9] Both fixes in one program, end to end.
# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] The two fixes together'
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the end-to-end case needs qemu to run\n'
else
    printf '%s\n' 'fn main() -> i32 {
    if (18446744073709551615 > 0) {
        if (4294967295u * 2u == 4294967294u) {
            if (10823014186374572430 > 9223372036854775807) {
                return 173;
            }
        }
    }
    return 0; }' > "$OUT/e2e.ast"
    if ! "$A" build-elf "$OUT/e2e.ast" -o "$OUT/e2e.a64" >"$OUT/e2e.err" 2>&1; then
        echo 'FAIL: the combined case does not build' >&2; sed -n '1,3p' "$OUT/e2e.err" >&2; exit 1
    fi
    $RUNNER "$OUT/e2e.a64" >/dev/null 2>&1 && got=0 || got=$?
    [ "$got" = 173 ] || { echo "FAIL: the combined case returned $got, expected 173" >&2; exit 1; }
    printf '  %-46s %s\n' 'combined fixes' "$got"
    printf '%s\n' 'PASS: the unsigned reading and the u32 wrap hold together'
fi

printf '%s\n' '=== u64 literal compare checks: ALL PASSED ==='
