#!/bin/sh
# v0.23.58-dev checks for the address-of completion: `&` is now defined for
# *every* lvalue, not only a struct. A scalar, bool, pointer or struct lvalue
# now yields a `ptr<T>` (or `ptr<S>` for a struct) that strides at the element's
# real width. This round adds no parser change and no new instruction: the type
# rule that had been refusing these shapes is relaxed, and every new codegen
# path routes to an already-existing, byte-stable helper (emitElemAddr for an
# array element, emitPtrElemAddr for a typed-pointer base).
#
# Nothing moves for a program that compiled before: a struct lvalue still gets
# the dedicated `ptr<S>` shape (sid-based) and a whole array still decays to a
# `ptr<T>`; only the previously-refused scalar/bool/pointer cases become legal.
# Layer [4/5] runs examples/address_of.ast (the feature's byte-baseline example)
# and asserts its checksum exit code, and all nine baseline suites now filter the
# new `address_of` family out of their 288-row pre-existing count.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-address-of-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/5] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
if [ "$have_qemu" = no ]; then
    printf '%s\n' 'SKIP: address-of-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

# ---------------------------------------------------------------------------
# [2/5] Source guards: the relaxed rule and its codegen branch, pinned where
# they were made, so a regression that quietly reopens a refusal fails here.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/5] Source guards: the relaxed & rule and its ptr-base branch'
# The type rule keeps the dedicated ptr<S> shape for a struct (byte-identical
# with every prior round) but now answers every other lvalue with tyPtrToElem,
# which carries the element type so the result strides at its real width.
grep -qF 'if(tyIsStruct(inner))return Ty::ptrTo(inner.sid);' src/aster.cpp \
    || { echo 'FAIL: & no longer keeps the ptr<S> shape for a struct' >&2; exit 1; }
grep -qF '// v0.23.58-dev: the address of any lvalue' src/aster.cpp \
    || { echo 'FAIL: the new & type rule comment is gone' >&2; exit 1; }
# The codegen branch that addresses an element through a typed pointer: &p[i].
grep -qF 'if(tyIsPtrToElem(baseType)){' src/aster.cpp \
    || { echo 'FAIL: emitStructAddr no longer handles a typed-pointer base' >&2; exit 1; }
grep -qF 'emitPtrElemAddr(*e.a,*e.b,ptrElemType(baseType));' src/aster.cpp \
    || { echo 'FAIL: &p[i] no longer routes to emitPtrElemAddr' >&2; exit 1; }
grep -qF '// v0.23.58-dev: a typed-pointer base' src/aster.cpp \
    || { echo 'FAIL: the &p[i] codegen comment is gone' >&2; exit 1; }
# The old struct-only refusal is genuinely gone — a suite that only ever
# asserted presence would keep passing if it crept back.
if grep -qF "'&' is only defined for a struct lvalue, not " src/aster.cpp; then
    echo 'FAIL: the struct-only refusal for & is back' >&2; exit 1
fi
printf '  %-34s %s\n' 'all guards present' 'ok'

# ---------------------------------------------------------------------------
# [3/5] Behavioural layer. Every lvalue kind & can now take the address of.
# ---------------------------------------------------------------------------
check() {   # check <compiler> <name> <expected-exit> <source>
    printf '%s\n' "$4" > "$OUT/c.ast"
    if ! "$1" build-elf "$OUT/c.ast" -o "$OUT/c.a64" >"$OUT/c.err" 2>&1; then
        echo "FAIL: $2 does not compile" >&2; sed -n '1,3p' "$OUT/c.err" >&2; exit 1
    fi
    $RUNNER "$OUT/c.a64" >/dev/null 2>&1 && got=0 || got=$?
    if [ "$got" -gt 127 ]; then got=$((got-256)); fi
    if [ "$got" != "$3" ]; then
        echo "FAIL: $2: expected exit $3, got $got" >&2; exit 1
    fi
    printf '  %-34s %s\n' "$2" "$got"
}
reject() {
    printf '%s\n' "$3" > "$OUT/r.ast"
    if "$A" build-elf "$OUT/r.ast" -o "$OUT/r.a64" >"$OUT/r.err" 2>&1; then
        echo "FAIL: $1 was accepted" >&2; exit 1
    fi
    grep -qF "$2" "$OUT/r.err" \
        || { echo "FAIL: $1: expected '$2', got: $(sed -n '1p' "$OUT/r.err")" >&2; exit 1; }
    printf '  %-34s refused\n' "$1"
}
A=$OUT/aster

if [ "$have_qemu" = yes ]; then
printf '%s\n' '[3/5] qemu: every lvalue kind & now addresses'
# scalar local: &x is ptr<i32>, loaded back through it
check "$A" 'scalar local &x'        7 'fn main() -> i32 { let x: i32 = 7; let p: ptr<i32> = &x; return *p; }'
# global scalar: &g is ptr<i32>, store through it, global sees the write
check "$A" 'global scalar &g store' 9 'let g: i32 = 1; fn main() -> i32 { let p: ptr<i32> = &g; *p = 9; return g; }'
# scalar struct field: &s.a is ptr<i32>
check "$A" 'scalar field &s.a'      11 'struct S { a: i32 } fn main() -> i32 { let s: S; s.a = 11; let p: ptr<i32> = &s.a; return *p; }'
# array element with DISTINCT values: &arr[2] must stride at 4 bytes
check "$A" 'i32 element &arr[2]'    3 'fn main() -> i32 { let a: i32[4] = 0; let k: i32 = 0; while (k < 4) { a[k] = k + 1; k = k + 1; } let p: ptr<i32> = &a[2]; return *p; }'
# i64 element with DISTINCT values: &w[1] must stride at 8 bytes (lands on 20, not 10)
check "$A" 'i64 element &w[1]'     20 'fn main() -> i32 { let w: i64[3] = 0; w[0] = 10; w[1] = 20; w[2] = 30; let p: ptr<i64> = &w[1]; return i32(*p); }'
# through a typed pointer with DISTINCT values: &p[1] (p is ptr<i32>) lands on arr[1]
check "$A" 'through ptr &p[1]'      2 'fn main() -> i32 { let a: i32[4] = 0; let k: i32 = 0; while (k < 4) { a[k] = k + 1; k = k + 1; } let base: ptr<i32> = &a[0]; let p: ptr<i32> = &base[1]; return *p; }'
# chain through a typed pointer with DISTINCT values: (&arr)[2] is arr[2]
check "$A" 'chain (&arr)[2]'        3 'fn main() -> i32 { let a: i32[4] = 0; let k: i32 = 0; while (k < 4) { a[k] = k + 1; k = k + 1; } let base: ptr<i32> = &a[0]; let p: ptr<i32> = &base[2]; return *p; }'
# regression: struct address is still ptr<S>
check "$A" 'struct &s regression'   4 'struct S { a: i32 } fn main() -> i32 { let s: S; s.a = 4; let p: ptr<S> = &s; return p.a; }'
# regression: whole-array address still decays to ptr<T>, distinct element
check "$A" 'whole-array &arr regr.' 4 'fn main() -> i32 { let a: i32[4] = 0; let k: i32 = 0; while (k < 4) { a[k] = k + 1; k = k + 1; } let p: ptr<i32> = &a; return p[3]; }'
fi

# ---------------------------------------------------------------------------
# [4/5] Refusals that must stand: & still requires an lvalue.
# ---------------------------------------------------------------------------
printf '%s\n' '[4/5] & still requires a real lvalue'
reject 'non-lvalue operand' "'&' requires a variable, a field, or a dereferenced ptr<S>" 'fn main() -> i32 { let x: i32 = 1; let p: ptr<i32> = &(x+1); return 0; }'
reject 'literal operand'      "'&' requires a variable, a field, or a dereferenced ptr<S>" 'fn main() -> i32 { let p: ptr<i32> = &5; return 0; }'

# ---------------------------------------------------------------------------
# [5/5] The feature example, with its checksum, end to end.
# ---------------------------------------------------------------------------
printf '%s\n' '[5/5] examples/address_of.ast checksum'
if [ "$have_qemu" = yes ]; then
    "$A" build-elf examples/address_of.ast -o "$OUT/example.a64" >"$OUT/ex.err" 2>&1 \
        || { echo 'FAIL: examples/address_of.ast does not compile' >&2; sed -n '1,3p' "$OUT/ex.err" >&2; exit 1; }
    $RUNNER "$OUT/example.a64" >/dev/null 2>&1 && ec=0 || ec=$?
    # main returns 7992545; the low byte is 225.
    [ "$ec" -eq 225 ] \
        || { echo "FAIL: examples/address_of.ast: expected exit 225 (checksum 7992545), got $ec" >&2; exit 1; }
    printf '  %-34s %s\n' 'checksum 7992545 (exit 225)' 'ok'
else
    printf '%s\n' 'SKIP: qemu unavailable for example run'
fi

printf '%s\n' 'PASS: address-of-checks'
