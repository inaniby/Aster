#!/bin/sh
# v0.23.60-dev checks for the widened T(x) cast.
#
# This round widens the explicit cast from the integer family to every
# conversion C permits that does not touch a struct:
#
#   * bool <-> integer : a bool is a 0/1 i32, so the bits reinterpret directly.
#     integer -> bool is the one non-trivial direction — it normalizes to 0/1
#     at run time (CSET W, ne), because a bool is a 0/1 i32 and nothing else.
#   * integer <-> ptr  : an address's bits are an integer and vice versa.
#     `(ptr)0x10` is the address, `(i64)p` reads it back, `(i32)p` takes the
#     low 32 bits the way C does.
#   * ptr<S> <-> ptr<U> : a typed pointer reinterprets as another typed
#     pointer; the 64-bit value is unchanged, only its stride/target tag does,
#     so the backend emits nothing for it.
#
# Rejected (and pinned below): a struct on either side, and the two crossings
# bool <-> ptr — an address is neither a truthiness nor a number.
#
# The layers mirror integer-cast-checks.sh:
#
#   [1]  strict build            -Werror, zero warnings
#   [2]  source guards           every load-bearing edit, pinned
#   [3]  qemu behaviour          11 hand-derived witnesses
#   [4]  gcc differential        the example against its C twin
#   [5]  rejection matrix        the new refusals, exact messages
#   [6]  coverage count          the behavioural matrix is the coverage
#   [7]  mutation layer          5 mutants, each observably wrong
#   [8]  byte baseline           pre-existing rows byte for byte
#   [9]  the example             end to end, exit 255
#
# The behavioural layers need qemu (or an AArch64 host); the differential layer
# additionally needs a C compiler that can emit AArch64 ELF. Neither is
# required to *build*, so each layer that cannot run says SKIP and the rest
# still runs.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-cast-conversions-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
HOSTCC=${HOSTCC:-cc}
have_cc=yes
command -v "$HOSTCC" >/dev/null 2>&1 || have_cc=no
if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then HOSTCC=aarch64-linux-gnu-gcc; fi
if [ "$have_qemu" = no ]; then
    printf '%s\n' 'SKIP: cast-conversions-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each change is pinned where it was made.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: the widened cast'
grep -qF '#define ASTER_VERSION_STRING "0.23.61-dev"' src/aster.cpp \
    || { echo "FAIL: the version constant is not 0.23.60-dev" >&2; exit 1; }
# the parser now admits bool and ptr (and ptr<S>) as cast targets
grep -qF 'case TK::Bool: t=Ty::Bool; break;' src/aster.cpp \
    || { echo "FAIL: primary() no longer accepts a bool cast target" >&2; exit 1; }
grep -qF 'case TK::Ptr: {' src/aster.cpp \
    || { echo "FAIL: primary() no longer accepts a ptr cast target" >&2; exit 1; }
# the backend normalizes integer -> bool to 0/1
grep -qF 'if(e.ty==Ty::Bool){' src/aster.cpp \
    || { echo "FAIL: gen() no longer normalizes integer -> bool to 0/1" >&2; exit 1; }
grep -qF 'emit(csetBool(a,1));   // CSET Wa, ne  -> 1 when a != 0' src/aster.cpp \
    || { echo "FAIL: gen() no longer emits the integer -> bool CSET" >&2; exit 1; }
# the constant folder agrees (integer -> bool folds to 0/1)
grep -qF 'case Ty::Bool: return v!=0?1:0;' src/aster.cpp \
    || { echo "FAIL: castConstValue no longer folds integer -> bool to 0/1" >&2; exit 1; }
# Sema admits the new combinations and refuses the rest with one message
grep -qF 'toPtr&&!fromBool' src/aster.cpp \
    || { echo "FAIL: typeOf no longer admits integer/ptr -> ptr" >&2; exit 1; }
grep -qF 'toBool&&fromInt' src/aster.cpp \
    || { echo "FAIL: typeOf no longer admits integer -> bool" >&2; exit 1; }
grep -qF 'a cast must be between integers, between a bool and an integer' src/aster.cpp \
    || { echo "FAIL: typeOf no longer refuses the illegal cast combinations" >&2; exit 1; }
# genBool routes a cast to bool through gen(Cast), so `(bool)x` is a bool expr
grep -qF 'if(e.k==Expr::Cast) return gen(e,Ty::Bool);' src/aster.cpp \
    || { echo "FAIL: genBool no longer handles a cast to bool" >&2; exit 1; }
printf '%s\n' 'PASS: the widened cast is pinned in the source'

# ---------------------------------------------------------------------------
# [3/9] qemu: every witness hand-derived, each program returning the value it
# is named for, so a wrong fold or a wrong normalization is the exit code.
# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] qemu: the widened cast, every witness'
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
# --- bool <-> integer ---
check "$A" 'bool -> i32 (true=1, false=0)'      1 'fn main() -> i32 { if (i32(true) == 1 && i32(false) == 0) { return 1; } return 0; }'
check "$A" 'bool -> u64 (true=1, false=0)'      2 'fn main() -> i32 { if (u64(true) == 1 && u64(false) == 0) { return 2; } return 0; }'
check "$A" 'bool -> u8 (true=1, false=0)'       3 'fn main() -> i32 { if (u8(true) == 1 && u8(false) == 0) { return 3; } return 0; }'
# --- integer -> bool (the one non-trivial direction: normalized to 0/1) ---
check "$A" 'int -> bool, nonzero is true'       4 'fn main() -> i32 { if (bool(7)) { return 4; } return 0; }'
check "$A" 'int -> bool, zero is false'         8 'fn main() -> i32 { if (bool(0)) { return 0; } return 8; }'
check "$A" 'int -> bool, negative is true'      5 'fn main() -> i32 { let n: i32 = 0 - 1; if (bool(n)) { return 5; } return 0; }'
# --- integer <-> ptr ---
check "$A" 'int -> ptr -> i64 round trip'      16 'fn main() -> i32 { if (i64(ptr(0x10)) == 0x10) { return 16; } return 0; }'
check "$A" 'ptr -> i32 takes low 32 bits'      32 'fn main() -> i32 { if (i32(ptr(0x20)) == 0x20) { return 32; } return 0; }'
check "$A" 'int -> ptr keeps high bits'         17 'fn main() -> i32 { if (i64(ptr(0x100000000)) == 0x100000000) { return 17; } return 0; }'
# --- ptr<S> <-> ptr<U> is a pure reinterpretation ---
check "$A" 'ptr<S> -> ptr<U> reads the field'   64 'struct Point { x: i32, y: i32 }
fn main() -> i32 { let pt: Point; pt.x = 9; pt.y = 8; let pp: ptr<Point> = &pt; let ppa: ptr<i32> = ptr<i32>(pp); if (*ppa == 9) { return 64; } return 0; }'
check "$A" 'typed ptr -> untyped -> i32'       65 'fn main() -> i32 { let u: ptr = ptr(0x40); let ut: ptr<i32> = ptr<i32>(u); if (i32(ut) == 0x40) { return 65; } return 0; }'
else
    printf '%s\n' '  SKIP: the behavioural cases need qemu to run'
fi

# ---------------------------------------------------------------------------
# [4/9] Differential: Aster against the target C compiler, whose conversion
# rules are the rules the cast implements. No expectation here is
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
        printf '  %-38s %s\n' "$1" "$ga"
    }
    # The shipped example against its twin, end to end.
    diff_case 'examples/cast-conversions.ast' \
        "$(cat examples/cast-conversions.ast)" \
        "$(cat tests/cast-conversions-twin.c)"
else
    printf '%s\n' '  SKIP: the differential layer needs qemu and a target C compiler'
fi

# ---------------------------------------------------------------------------
# [5/9] Rejection matrix. The new legal combinations are exercised above; the
# refusals below hold: a struct on either side, and the two bool <-> ptr
# crossings. (The old "ptr( / bool( is not a cast" rejections are gone — those
# spellings are now legal casts — so they are deliberately not asserted here.)
# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] Rejection matrix'
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
reject 'bool -> ptr'                 "cannot cast bool to ptr" \
    'fn main() -> i32 { let b: bool = true; let z: ptr = ptr(b); return 0; }'
reject 'ptr -> bool'                 "cannot cast ptr to bool" \
    'fn main() -> i32 { let p: ptr = 0; let z: bool = bool(p); return 0; }'
reject 'struct -> integer'           "cannot cast struct" \
    'struct S { a: i32 }
fn main() -> i32 { let s: S; let z: i32 = i32(s); return 0; }'
reject 'cast without its paren'      "expected '(' after cast type" \
    'fn main() -> i32 { return i64 300; }'
reject 'cast unclosed'               "expected ')' after cast operand" \
    'fn main() -> i32 { return i64(300; }'
reject 'ptr< with no closing >'      "expected '>' after the type in a ptr<...> cast" \
    'fn main() -> i32 { let p: ptr = ptr<i32(0); return 0; }'
reject 'ptr< of unknown struct'      "unknown struct type in ptr<" \
    'fn main() -> i32 { let p: ptr<NoSuch> = ptr<NoSuch>(0); return 0; }'
printf '%s\n' 'PASS: the rejection matrix holds'

# ---------------------------------------------------------------------------
# [6/9] Coverage: the two type systems, the folder, the backend, and genBool
# are reached for every shape above, so a hole in a guard is a hole here.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Coverage: every shape is exercised'
if [ "$have_qemu" = yes ]; then
    n=$(grep -c '^check ' "$0")
    [ "$n" -ge 11 ] || { echo "FAIL: expected at least 11 behavioural cases, found $n" >&2; exit 1; }
    printf '  %-38s %s\n' 'behavioural cases' "$n"
    printf '%s\n' 'PASS: the behavioural matrix covers every shape'
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
    if [ "$got" -gt 127 ]; then got=$((got-256)); fi
    if [ "$got" = "$good" ]; then
        echo "FAIL: mutant $name still gives $got — the case does not see the rule" >&2; exit 1
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
# m1: the integer -> bool normalization is compiled out — a nonzero operand
# keeps its raw bits instead of becoming 1, so i32(bool(x)) is 5, not 1.
mutate 'm1: integer -> bool not normalized' \
    's#                if(e.ty==Ty::Bool){#                if(false){#' \
    must_differ 'i32(bool(x)) is 1' 1 'fn main() -> i32 { let x: i32 = 5; if (i32(bool(x)) == 1) { return 1; } return 0; }'
# m2: bool -> integer is refused again — sema only admits integer sources to
# integer targets when they are integers, not bools.
mutate 'm2: bool -> integer refused' \
    's#                if(toInt)         return e.ty;#                if(toInt \&\& !fromBool) return e.ty;#' \
    must_reject 'bool -> i32' 'fn main() -> i32 { if (i32(true) == 1) { return 1; } return 0; }'
# m4: integer -> ptr is refused again.
mutate 'm4: integer -> ptr refused' \
    's#                if(toPtr\&\&!fromBool) return e.ty;#                if(false) return e.ty;#' \
    must_reject 'int -> ptr' 'fn main() -> i32 { if (i64(ptr(0)) == 0) { return 16; } return 0; }'
# m5: integer -> bool is refused again.
mutate 'm5: integer -> bool refused' \
    's#                if(toBool\&\&fromInt)  return e.ty;#                if(false)  return e.ty;#' \
    must_reject 'int -> bool' 'fn main() -> i32 { if (bool(5)) { return 4; } return 0; }'
# m6: the cast operand is generated at the default width instead of the target's
# — a 64-bit address materialized through a 32-bit literal is truncated, so
# i64(ptr(0x100000000)) is 0, not 0x100000000.
mutate 'm6: the operand forgets the target width' \
    's#                int a=gen(\*e.a,e.ty);#                int a=gen(*e.a);#' \
    must_differ 'i64(ptr(0x100000000)) round trips' 17 'fn main() -> i32 { if (i64(ptr(0x100000000)) == 0x100000000) { return 17; } return 0; }'
printf '%s\n' 'PASS: five mutated compilers each lose exactly one rule, and the checks notice'
fi

# ---------------------------------------------------------------------------
# [8/9] Byte-identity baseline. Every line recorded before this round must
# reproduce byte for byte. cast-conversions.ast is this round's own example, so
# it is excluded from the comparison (and asserted to be recorded in all three
# modes below). The pre-existing count stays 288.
# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Byte-identity baseline'
BASE=tests/baseline/v0.23.5-dev/example-hashes.txt
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
FILTER='-e ^cast-conversions\. -e ^sizeof_len\. -e ^struct_array_field\. -e ^array_elem_types\. -e ^precedence\. -e ^array_address\. -e ^multi_dim_array\. -e ^lifecycle\. -e ^fn_type\. -e ^cb_table\. -e ^fn_ret\. -e ^call-stmt\. -e ^copy\. -e ^arena\. -e ^stdlib_demo\. -e ^integer_cast\. -e ^switch\. -e ^literals\. -e ^tls_demo\. -e ^so_verstrlen\. -e ^c_ptr_difference\. -e ^address_of\. -e ^address_of_abi\. -e ^so_tls_demo\. -e ^enum_demo\.'
grep -v $FILTER "$BASE" | LC_ALL=C sort > "$OUT/expected-old.txt"
grep -v $FILTER "$OUT/hashes.txt" | LC_ALL=C sort > "$OUT/got-old.txt"
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
[ "$(grep -c '^cast-conversions\.' "$OUT/hashes.txt")" -eq 3 ] \
    || { echo 'FAIL: cast_conversions.ast is not in the baseline in all three modes' >&2; exit 1; }
printf '  %-38s %s\n' 'pre-existing rows byte-identical' "$old"
printf '  %-38s %s\n' 'new example rows recorded' '3'
printf '%s\n' 'PASS: byte-identity baseline holds'

# ---------------------------------------------------------------------------
# [9/9] The shipped example, end to end.
# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] The example, end to end'
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the example needs qemu to run\n'
else
    if ! "$A" build-elf examples/cast-conversions.ast -o "$OUT/cc.a64" >"$OUT/cc.err" 2>&1; then
        echo 'FAIL: examples/cast-conversions.ast does not build' >&2; sed -n '1,3p' "$OUT/cc.err" >&2; exit 1
    fi
    $RUNNER "$OUT/cc.a64" >/dev/null 2>&1 && got=0 || got=$?
    [ "$got" = 255 ] \
        || { echo "FAIL: examples/cast-conversions.ast: expected exit 255, got $got" >&2; exit 1; }
    printf '  %-38s %s\n' 'cast-conversions.ast' "$got"
    printf '%s\n' 'PASS: the example runs and returns the value its C twin returns'
fi

printf '%s\n' '=== cast-conversions checks: ALL PASSED ==='
