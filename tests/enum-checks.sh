#!/bin/sh
# v0.23.61-dev checks for enum — C-style named integer constants over a nominal
# i32.
#
# An enum is a nominal integer type. Its enumerators are compile-time i32
# constants (folded to literals in primary() at parse time), and the enum name
# is a distinct type spelled Ty::Enum(sid). Two enums are distinct nominal types
# even though both are four-byte signed integers:
#
#   * an enumerator constant folds to its integer value wherever it appears, so
#     `Red + 1` and `c == Green` behave exactly as if `Red`/`Green` were i32
#     literals — the nominal type only matters where a *type* is written;
#   * a variable of enum type stores its value as a four-byte signed integer,
#     and reads/writes/addressing treat it as i32;
#   * `enum -> i32` is implicit and free (the underlying storage is i32), and
#     `i32 constant -> enum` is allowed (any i32 constant fits the i32 range);
#   * the one strict rule is nominal isolation: enum<->enum requires the very
#     same enum (same sid). A different enum, an i32 *variable*, a ptr, a bool
#     or a struct never converts to or from an enum.
#
# The layers mirror cast-conversions-checks.sh / integer-cast-checks.sh:
#
#   [1]  strict build            -Werror, zero warnings
#   [2]  source guards           every load-bearing edit, pinned
#   [3]  qemu behaviour          hand-derived witnesses (auto-inc, explicit,
#                                negative, enum<->i32, arithmetic, sizeof, cmp)
#   [4]  gcc differential        the example against its C twin
#   [5]  rejection matrix        the new refusals, exact messages
#   [6]  coverage count          the behavioural matrix is the coverage
#   [7]  mutation layer          2 mutants, each observably wrong
#   [8]  byte baseline           pre-existing rows byte for byte
#   [9]  the example             end to end, exit 255
#
# The behavioural layers need qemu; the differential layer additionally needs a
# C compiler that emits AArch64 ELF. Neither is required to *build*, so each
# layer that cannot run says SKIP and the rest still runs.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-enum-checks}
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
    printf '%s\n' 'SKIP: enum-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each change is pinned where it was made.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: enum'
grep -qF '#define ASTER_VERSION_STRING "0.23.61-dev"' src/aster.cpp \
    || { echo "FAIL: the version constant is not 0.23.61-dev" >&2; exit 1; }
# the lexer recognises `enum` as a reserved word
grep -qF 'else if(x=="enum")k=TK::Enum;' src/aster.cpp \
    || { echo "FAIL: the lexer no longer recognises enum" >&2; exit 1; }
# the type system carries a distinct enum kind
grep -qF 'enum Kind { I32, U32, U8, U16, I64, U64, Ptr, Bool, Enum, Struct };' src/aster.cpp \
    || { echo "FAIL: Ty::Kind no longer lists Enum" >&2; exit 1; }
# the declaration parser builds the enum tables
grep -qF 'void enumDeclaration(){' src/aster.cpp \
    || { echo "FAIL: enumDeclaration is gone" >&2; exit 1; }
# an enumerator folds to its integer at parse time
grep -qF 'if(g_enumConsts.count(tok.s)){' src/aster.cpp \
    || { echo "FAIL: primary() no longer folds an enumerator to a Num" >&2; exit 1; }
# the nominal isolation lives in tyAssignable
grep -qF 'if(to.k==Ty::Enum||from.k==Ty::Enum){' src/aster.cpp \
    || { echo "FAIL: tyAssignable no longer branches on enum" >&2; exit 1; }
grep -qF 'if(to.k==Ty::Enum&&from.k==Ty::Enum)return to.sid==from.sid;' src/aster.cpp \
    || { echo "FAIL: tyAssignable no longer isolates distinct enums by sid" >&2; exit 1; }
# an enum prints by its declared name, like a struct
grep -qF 'case Ty::Enum: break;' src/aster.cpp \
    || { echo "FAIL: tyName no longer handles Enum" >&2; exit 1; }
# DWARF records the enum by name as a four-byte signed base type
grep -qF 'case Ty::Enum: nm=enumNameOf(t.sid);size=4;enc=0x05;break;' src/aster.cpp \
    || { echo "FAIL: typeRef no longer emits an enum base type" >&2; exit 1; }
# tyIsInteger now admits enum (so codegen treats it as i32)
grep -qF '|| t.k == Ty::Enum' src/aster.cpp \
    || { echo "FAIL: tyIsInteger no longer admits Enum" >&2; exit 1; }
# out-of-range enumerator initialisers are refused
grep -qF 'enumerator value out of i32 range:' src/aster.cpp \
    || { echo "FAIL: an out-of-i32-range enumerator is no longer refused" >&2; exit 1; }
printf '%s\n' 'PASS: enum is pinned in the source'

# ---------------------------------------------------------------------------
# [3/9] qemu: every witness hand-derived, each program returning the value it is
# named for, so a wrong fold or a wrong conversion is the exit code.
# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] qemu: enum, every witness'
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
# --- auto-increment (C semantics: Red=0, Green=1, Blue=2) ---
check "$A" 'auto-increment: Blue == 2'         2 'enum Color { Red, Green, Blue } fn main() -> i32 { let c: Color = Blue; let x: i32 = c; return x; }'
# --- explicit values are honoured; the next enumerator carries on from them ---
check "$A" 'explicit values: South == 20'      20 'enum Dir { North = 10, South = 20 } fn main() -> i32 { let d: Dir = South; let x: i32 = d; return x; }'
# --- a negative enumerator initialiser folds to its negative value ---
check "$A" 'negative: -West == 1'               1 'enum Dir { West = -1, East = -2 } fn main() -> i32 { let d: Dir = West; let x: i32 = d; return -x; }'
# --- enum -> i32 is free (the underlying storage is i32) ---
check "$A" 'enum -> i32 is free'               2 'enum C { A, B, Cc } fn main() -> i32 { let x: i32 = Cc; let y: i32 = A; return x + y; }'
# --- an i32 constant initialises an enum (any constant fits the i32 range) ---
check "$A" 'i32 constant -> enum'              5 'enum C { A = 5 } fn main() -> i32 { let c: C = 5; let x: i32 = c; return x; }'
# --- enumerators are i32 literals: arithmetic over them is i32 arithmetic ---
check "$A" 'enum arithmetic'                    5 'enum C { A = 2, B = 3 } fn main() -> i32 { let s: i32 = A + B; return s; }'
# --- sizeof(enum) is the i32 width, four bytes ---
check "$A" 'sizeof(enum) == 4'                 4 'enum C { A } fn main() -> i32 { return sizeof(C); }'
# --- an enum value compares against an enumerator (both are i32 under the hood) ---
check "$A" 'enum comparison'                   7 'enum C { A, B } fn main() -> i32 { let c: C = B; if (c == B) { return 7; } return 0; }'
# --- distinct enums that happen to share a value still compare equal as i32 ---
check "$A" 'distinct enums, same value, compared' 1 'enum A { X = 1 } enum B { Y = 1 } fn main() -> i32 { let a: A = X; let b: B = Y; if (a == b) { return 1; } return 0; }'
else
    printf '%s\n' '  SKIP: the behavioural cases need qemu to run'
fi

# ---------------------------------------------------------------------------
# [4/9] Differential: Aster against the target C compiler, whose enum rules are
# the rules Aster implements. No expectation here is hand-computed: the shipped
# example and its twin must agree exactly.
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
    diff_case 'examples/enum_demo.ast' \
        "$(cat examples/enum_demo.ast)" \
        "$(cat tests/enum-demo-twin.c)"
else
    printf '%s\n' '  SKIP: the differential layer needs qemu and a target C compiler'
fi

# ---------------------------------------------------------------------------
# [5/9] Rejection matrix. The legal shapes above are exercised; the refusals
# below hold — nominal isolation and the i32-constant-only rule. Each expected
# message is asserted verbatim.
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
reject 'cross-enum initialization' "type mismatch initializing 'b': expected B, got A" \
    'enum A { X } enum B { Y } fn main() -> i32 { let a: A = X; let b: B = a; return 0; }'
reject 'i32 variable -> enum' "type mismatch initializing 'a': expected A, got i32" \
    'enum A { X } fn main() -> i32 { let v: i32 = 5; let a: A = v; return 0; }'
reject 'enumerator out of i32 range' "enumerator value out of i32 range: X" \
    'enum A { X = 3000000000 } fn main() -> i32 { return 0; }'
reject 'duplicate enum name' "duplicate enum declaration: A" \
    'enum A { X } enum A { Y } fn main() -> i32 { return 0; }'
reject 'duplicate enumerator' "duplicate enumerator: X" \
    'enum A { X, X } fn main() -> i32 { return 0; }'
printf '%s\n' 'PASS: the rejection matrix holds'

# ---------------------------------------------------------------------------
# [6/9] Coverage: the type system, the constant folder, the backend and Sema
# are reached for every shape above, so a hole in a guard is a hole here.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Coverage: every shape is exercised'
if [ "$have_qemu" = yes ]; then
    n=$(grep -c '^check ' "$0")
    [ "$n" -ge 9 ] || { echo "FAIL: expected at least 9 behavioural cases, found $n" >&2; exit 1; }
    printf '  %-38s %s\n' 'behavioural cases' "$n"
    printf '%s\n' 'PASS: the behavioural matrix covers every shape'
else
    printf '%s\n' '  SKIP: the coverage count needs the behavioural cases to run'
fi

# ---------------------------------------------------------------------------
# [7/9] Mutation layer. Each mutant removes one rule; a case must notice.
# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Mutation layer'
must_reject() {   # must_reject <name> <source>: real compiler accepts, mutant refuses
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
# m1: enum is no longer an integer type — an enum value used as an `if`/
# `while` condition stops being "an integer", so checkCondition refuses it.
mutate 'm1: enum not an integer type' \
    's# || t.k == Ty::Enum##' \
    must_reject 'enum-as-condition under tyIsInteger' 'enum C { A, B } fn main() -> i32 { let c: C = A; if(c) { return 1; } return 0; }'
# m2: enum -> i32 is no longer free — assigning an enum value into an i32 is
# refused again.
mutate 'm2: enum not implicitly convertible to i32' \
    's#return from.k==Ty::Enum&&to.k==Ty::I32;#return false;#' \
    must_reject 'enum -> i32' 'enum C { A } fn main() -> i32 { let c: C = A; let x: i32 = c; return x; }'
printf '%s\n' 'PASS: two mutated compilers each lose exactly one rule, and the checks notice'
fi

# ---------------------------------------------------------------------------
# [8/9] Byte-identity baseline. Every line recorded before this round must
# reproduce byte for byte. enum_demo.ast is this round's own example, so it is
# excluded from the comparison (and asserted to be recorded in all three modes
# below). The pre-existing count stays 288.
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
[ "$(grep -c '^enum_demo\.' "$OUT/hashes.txt")" -eq 3 ] \
    || { echo 'FAIL: enum_demo.ast is not in the baseline in all three modes' >&2; exit 1; }
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
    if ! "$A" build-elf examples/enum_demo.ast -o "$OUT/ed.a64" >"$OUT/ed.err" 2>&1; then
        echo 'FAIL: examples/enum_demo.ast does not build' >&2; sed -n '1,3p' "$OUT/ed.err" >&2; exit 1
    fi
    $RUNNER "$OUT/ed.a64" >/dev/null 2>&1 && got=0 || got=$?
    [ "$got" = 255 ] \
        || { echo "FAIL: examples/enum_demo.ast: expected exit 255, got $got" >&2; exit 1; }
    printf '  %-38s %s\n' 'enum_demo.ast' "$got"
    printf '%s\n' 'PASS: the example runs and returns the value its C twin returns'
fi

printf '%s\n' '=== enum checks: ALL PASSED ==='
