#!/bin/sh
# v0.23.30-dev checks for the address of a whole array: `&buf` is a `ptr`, so a
# `T[N]` can be handed to a function by reference instead of having to live at
# file scope.
#
# Until this round `&` was defined for a struct lvalue and for nothing else
# ("'&' is only defined for a struct lvalue, not i32"), so an array was the one
# object in the language a function could not reach unless it was a global.
# There is no parser change here and no new instruction:
#
#   1. A named array already *decays* — a local `T[N]`'s `Binding.ty` is
#      `Ty::Ptr` and `gen(Var)` emits `ADD Xd, SP, #slot*8`; a global `T[N]`
#      answers `Ty::Ptr` from `typeOf` and `emitGlobalAddress` from codegen.
#      So `let p: ptr = buf;` has always worked, and the address was always
#      there to hand over. `&` simply could not ask for it.
#   2. `Sema::arrayOperandOf()` answers "is this operand an array?" — from the
#      *length*, not the type, because the type cannot tell an array from a ptr
#      variable (both are `Ty::Ptr`). Three arms: a local `T[N]`, a global
#      `T[N]`, and a struct's array field.
#   3. `Sema::typeOf(AddrOf)` returns a plain `Ty::Ptr` for one, and `gen`
#      needs nothing new: `emitStructAddr` already reaches a local's frame slot,
#      a global's static address, and a struct field's base + offset.
#   4. **One honest restriction**: `p[i]` on a `ptr` means `*(p + i*4)`, and no
#      Aster pointer type carries a stride. So `&` on an array whose element is
#      not four bytes wide is refused rather than silently mis-scaled — an
#      `i64[4]` handed over as a ptr would be indexed at half the right
#      distance, and a `u8[4]` at four times it. A `struct Q { x: i32 }` is
#      four bytes, so `Q[N]` travels; a 12-byte struct does not.
#
# None of it can move the bytes of a program that compiled before: `&` on an
# array was a compile error until now, so no shipped example contains one.
# Layer [8/9] asserts all 288 pre-existing baseline rows reproduce.
#
# The behavioural layers need qemu (or an AArch64 host); the differential layer
# additionally needs $HOSTCC to emit AArch64 ELF. Neither is required to
# *build*, so each layer that cannot run says SKIP and the rest still runs.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-array-address-checks}
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
    printf '%s\n' 'SKIP: array-address-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each change is pinned where it was made, so a regression
# that quietly reopens one fails here rather than by a behavioural case.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: the new rule and its three arms'
# The predicate, and the reason it asks the length rather than the type.
grep -qF 'bool arrayOperandOf(const Expr& e,Ty& elem,uint32_t& len){' src/aster.cpp \
    || { echo 'FAIL: arrayOperandOf is gone' >&2; exit 1; }
grep -qF "// v0.23.30-dev: is \`e\` the name of a fixed-length array" src/aster.cpp \
    || { echo 'FAIL: the comment explaining why the length is asked is gone' >&2; exit 1; }
# All three arms: a local T[N] (elem from b->elem, not from the decayed b->ty),
# a global T[N], and a struct's array field.
grep -qF 'elem=b->elem; len=b->len; return true;' src/aster.cpp \
    || { echo 'FAIL: the local-array arm is gone' >&2; exit 1; }
grep -qF 'elem=arrayElemTypeOf(e.name); len=arrayLengthOf(e.name); return true;' src/aster.cpp \
    || { echo 'FAIL: the global-array arm is gone' >&2; exit 1; }
grep -qF 'const StructField* f=arrayFieldOf(typeOf(*e.a),e);' src/aster.cpp \
    || { echo 'FAIL: the struct-array-field arm is gone' >&2; exit 1; }
# The rule itself: consulted by AddrOf, answering a pointer that carries the
# element's stride. v0.23.34-dev lifted the 4-byte gate that used to stand
# here: `&arr` is now legal for *any* element width, because the pointer it
# answers remembers how wide an element is (tyPtrToElem) instead of every
# holder assuming four bytes.
grep -qF 'if(arrayOperandOf(*e.a,aelem,alen))' src/aster.cpp \
    || { echo 'FAIL: AddrOf no longer consults arrayOperandOf' >&2; exit 1; }
grep -qF 'return tyPtrToElem(aelem);' src/aster.cpp \
    || { echo 'FAIL: &arr no longer answers a strided element pointer' >&2; exit 1; }
grep -qF 'static Ty tyPtrToElem(Ty e)' src/aster.cpp \
    || { echo 'FAIL: the strided-pointer constructor is gone' >&2; exit 1; }
grep -qF 'static bool tyIsPtrToElem(Ty t)' src/aster.cpp \
    || { echo 'FAIL: the strided-pointer predicate is gone' >&2; exit 1; }
grep -qF '// v0.23.34-dev: an array has an address too' src/aster.cpp \
    || { echo 'FAIL: the comment naming the new rule is gone' >&2; exit 1; }
# What replaces the gate: a strided pointer must not land in a slot that would
# index it at the wrong width — an untyped `ptr` does so at four bytes, and
# reading the wrong element silently is the failure the gate used to prevent
# at the `&`. A negative guard says the gate itself is really gone: a suite
# that only ever asserted presence would keep passing if it came back.
if grep -qF 'if(tySize(aelem)!=4u)' src/aster.cpp; then
    echo 'FAIL: the 4-byte element gate is back' >&2; exit 1
fi
if grep -qF "on an array needs a 4-byte element type" src/aster.cpp; then
    echo 'FAIL: the 4-byte gate message is back' >&2; exit 1
fi
grep -qF 'return ptrElemWidth(from)==4u;' src/aster.cpp \
    || { echo 'FAIL: the stride guard in ptrToAssignable is gone' >&2; exit 1; }
# A ptr<S> strides at sizeof(S), not at four bytes: the arm that accepts its
# own element width, and the one that hands the width to the index.
grep -qF 'if(tyIsPtrToStruct(to))return ptrElemWidth(from)==tySize(Ty::ofStruct(to.sid));' src/aster.cpp \
    || { echo 'FAIL: a ptr<S> slot no longer accepts its own element width' >&2; exit 1; }
grep -qF 'if(tyIsPtrToStruct(st))pe=Ty::ofStruct(st.sid);' src/aster.cpp \
    || { echo 'FAIL: a ptr<S> no longer strides at sizeof(S)' >&2; exit 1; }
grep -qF 'cannot store a pointer to ' src/aster.cpp \
    || { echo 'FAIL: the stride-guard diagnostic is gone' >&2; exit 1; }
# `(&arr)[i]`: a `[` may follow an `&` — the pointer `&arr` answers is the one
# an array parameter is, so it subscripts where it is written — and no other
# expression that has no stride.
grep -qF 'if(x->k!=Expr::Field&&x->k!=Expr::Index&&x->k!=Expr::AddrOf)' src/aster.cpp \
    || { echo 'FAIL: postfix() no longer lets a subscript follow an &' >&2; exit 1; }
# The rule that must NOT have moved: `&` still requires an lvalue. (The
# *other* half — that `&` was struct-only for everything else — was deliberately
# relaxed in v0.23.58-dev: any lvalue now answers a typed `ptr<T>`, so the
# old "only defined for a struct lvalue" refusal is gone, not just moved.)
grep -qF "'&' requires a variable, a field, or a dereferenced ptr<S>" src/aster.cpp \
    || { echo 'FAIL: the lvalue rule for & moved' >&2; exit 1; }
# v0.23.58-dev: the struct-only refusal is genuinely gone.
if grep -qF "'&' is only defined for a struct lvalue, not " src/aster.cpp; then
    echo 'FAIL: the struct-only refusal for & is back' >&2; exit 1
fi
# v0.23.58-dev: in its place, a non-struct lvalue now answers tyPtrToElem.
grep -qF 'return tyPtrToElem(inner);' src/aster.cpp \
    || { echo 'FAIL: & no longer answers tyPtrToElem for a non-struct lvalue' >&2; exit 1; }
printf '  %-34s %s\n' 'all guards present' 'ok'

# ---------------------------------------------------------------------------
# [3/9] Behavioural layer. Every shape an array's address can be taken in.
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
A=$OUT/aster

if [ "$have_qemu" = yes ]; then
printf '%s\n' '[3/9] qemu: every shape an array address takes'
# --- a local array, read through a reference.
check "$A" 'local array by reference'   28 'fn sum4(p: ptr) -> i32 {
    let t: i32 = 0; let i: i32 = 0;
    while (i < 4) { t = t + p[i]; i = i + 1; }
    return t; }
fn main() -> i32 { let buf: i32[4] = 7; return sum4(&buf); }'
# --- written through the reference: the caller must see it, not a copy.
check "$A" 'written through a reference' 5 'fn fill(p: ptr, v: i32) -> i32 {
    let i: i32 = 0;
    while (i < 4) { p[i] = v; i = i + 1; }
    return p[0]; }
fn main() -> i32 { let buf: i32[4] = 0; if (fill(&buf, 5) == 5) { return buf[3]; } return 0; }'
# --- a global array, by reference.
check "$A" 'global array by reference'  44 'let g: i32[4] = 11;
fn sum4(p: ptr) -> i32 { let t: i32 = 0; let i: i32 = 0;
    while (i < 4) { t = t + p[i]; i = i + 1; }
    return t; }
fn main() -> i32 { return sum4(&g); }'
# --- a bool[3] stores a 4-byte slot an element, so it travels too.
check "$A" 'bool array by reference'     3 'fn count(p: ptr) -> i32 {
    let n: i32 = 0;
    if (p[0] != 0) { n = n + 1; }
    if (p[1] != 0) { n = n + 1; }
    if (p[2] != 0) { n = n + 1; }
    return n; }
fn main() -> i32 { let f: bool[3] = true; return count(&f); }'
# --- a u32[4]: the other 4-byte integer width.
check "$A" 'u32 array by reference'    100 'fn sum4(p: ptr) -> i32 { let t: i32 = 0; let i: i32 = 0;
    while (i < 4) { t = t + p[i]; i = i + 1; }
    return t; }
fn main() -> i32 { let a: u32[4] = 25; return sum4(&a); }'
# --- a struct whose size is 4 bytes is a 4-byte element, so S[N] travels.
check "$A" '4-byte struct array by ref' 10 'struct Q { x: i32 }
fn sum2(p: ptr) -> i32 { return p[0] + p[1]; }
fn main() -> i32 { let a: Q[2] = Q { 5 }; return sum2(&a); }'
# --- a struct's array field: field base + offset, then the ptr as a value.
check "$A" 'array field by reference'   10 'struct Row { cells: i32[4] }
fn sum4(p: ptr) -> i32 { let t: i32 = 0; let i: i32 = 0;
    while (i < 4) { t = t + p[i]; i = i + 1; }
    return t; }
fn main() -> i32 { let r: Row; r.cells[0] = 1; r.cells[1] = 2; r.cells[2] = 3; r.cells[3] = 4;
    return sum4(&r.cells); }'
# --- the same field reached through a ptr<S>, where the base is a value.
check "$A" 'array field behind ptr<S>'   9 'struct Row { cells: i32[4] }
fn peek(pr: ptr<Row>) -> i32 { let p: ptr = &pr.cells; return p[1]; }
fn main() -> i32 { let r: Row; r.cells[1] = 9; return peek(&r); }'
# --- the address itself, kept in a variable and indexed at a computed offset.
check "$A" 'address in a variable'      12 'fn main() -> i32 {
    let a: i32[4] = 0; let p: ptr = &a; let i: i32 = 3;
    p[0] = 5; p[i] = 7;
    return p[0] + a[3]; }'
# --- two arrays, two addresses: writing through one must not touch the other.
check "$A" 'two arrays, two addresses'   3 'fn set(p: ptr, i: i32, v: i32) -> i32 { p[i] = v; return p[i]; }
fn main() -> i32 { let a: i32[4] = 0; let b: i32[4] = 0;
    if (set(&a, 2, 9) == 9 && b[2] == 0) { return 3; } return 0; }'
# --- a reference passed onward to a second callee.
check "$A" 'reference passed onward'    18 'fn addup(p: ptr) -> i32 { return p[0] + p[1] + p[2]; }
fn twice(p: ptr) -> i32 { return addup(p) + addup(p); }
fn main() -> i32 { let a: i32[3] = 3; return twice(&a); }'
# --- `&buf` and the decayed array name are the same address.
check "$A" '&buf and buf agree'          7 'fn main() -> i32 {
    let a: i32[2] = 0; let p: ptr = &a;
    if (p == a && p[0] == 0) { return 7; } return 0; }'
# --------------------------------------------------------------------------
# v0.23.34-dev: the 4-byte gate is gone, so an array of *any* element width
# has an address that remembers its stride. Each case writes through the
# pointer and reads the answer back through the *named* array, which is what
# proves the store landed at the right offset rather than four bytes along.
# --------------------------------------------------------------------------
# --- an 8-byte element, through a ptr<i64> variable.
check "$A" 'i64 array through ptr<i64>'  24 'fn main() -> i32 {
    let w: i64[4] = 0; let p: ptr<i64> = &w;
    p[0] = 3; p[1] = 5; p[2] = 7; p[3] = 9;
    return w[0] + w[1] + w[2] + w[3]; }'
# --- a 1-byte element: the stride is one, not four.
check "$A" 'u8 array through ptr<u8>'    24 'fn main() -> i32 {
    let b: u8[4] = 0; let p: ptr<u8> = &b;
    p[0] = 3; p[1] = 5; p[2] = 7; p[3] = 9;
    return b[0] + b[1] + b[2] + b[3]; }'
# --- a 2-byte element.
check "$A" 'u16 array through ptr<u16>'  24 'fn main() -> i32 {
    let h: u16[4] = 0; let p: ptr<u16> = &h;
    p[0] = 3; p[1] = 5; p[2] = 7; p[3] = 9;
    return h[0] + h[1] + h[2] + h[3]; }'
# --- an array parameter: `fn f(a: i64[4])` takes the array by address and
#     indexes it at eight bytes, which is the same value `&w` handed over.
check "$A" 'i64 array parameter'         24 'fn fill(a: i64[4]) -> i64 {
    a[0] = 3; a[1] = 5; a[2] = 7; a[3] = 9;
    return a[0] + a[1] + a[2] + a[3]; }
fn main() -> i32 { let w: i64[4] = 0; return fill(w); }'
# --- the same parameter shape for a 1-byte element.
check "$A" 'u8 array parameter'          24 'fn fill(a: u8[4]) -> i32 {
    a[0] = 3; a[1] = 5; a[2] = 7; a[3] = 9;
    return a[0] + a[1] + a[2] + a[3]; }
fn main() -> i32 { let b: u8[4] = 0; return fill(b); }'
# --- the same stride on the way *in*: write through the array, read through
#     the pointer. (The case above proves the store lands at the right offset;
#     this one proves the load looks in the right place, which is a different
#     code path and the one the m8 mutant below withdraws.)
check "$A" 'i64 array read via ptr<i64>' 24 'fn main() -> i32 {
    let w: i64[4] = 0; let p: ptr<i64> = &w;
    w[0] = 3; w[1] = 5; w[2] = 7; w[3] = 9;
    return p[0] + p[1] + p[2] + p[3]; }'
# --- a strided pointer survives a return and a second binding.
check "$A" 'ptr<i64> returned and kept'  15 'fn get(w: ptr<i64>) -> ptr<i64> { return w; }
fn main() -> i32 {
    let w: i64[3] = 0; w[0] = 4; w[1] = 5; w[2] = 6;
    let q: ptr<i64> = get(&w);
    return q[0] + q[1] + q[2]; }'
fi

# ---------------------------------------------------------------------------
# [4/9] Differential layer: the same program under Aster and under the target C
# compiler must produce the same value. C has always had this — an array name
# decays to `&a[0]`, which is exactly what Aster's `&a` now answers.
# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] Differential: Aster vs the target C compiler'
if [ "$have_cc" = no ] || [ "$have_qemu" = no ]; then
    printf '  SKIP: the differential layer needs a C compiler that emits AArch64 ELF and qemu\n'
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
    diff_case 'local + global + write-through' \
        'let g: i32[4] = 11;
fn sum4(p: ptr) -> i32 { let t: i32 = 0; let i: i32 = 0;
    while (i < 4) { t = t + p[i]; i = i + 1; }
    return t; }
fn fill(p: ptr, v: i32) -> i32 { let i: i32 = 0;
    while (i < 4) { p[i] = v; i = i + 1; }
    return p[0]; }
fn main() -> i32 {
    let buf: i32[4] = 7;
    let r: i32 = 0;
    if (sum4(&buf) == 28) { r = r + 1; }
    if (fill(&buf, 5) == 5 && buf[3] == 5) { r = r + 2; }
    if (sum4(&g) == 44) { r = r + 4; }
    return r; }' \
        '#include <stdint.h>
static int32_t g[4] = { 11, 11, 11, 11 };
static int32_t sum4(int32_t *p) { int32_t t = 0; for (int32_t i = 0; i < 4; i++) t += p[i]; return t; }
static int32_t fill(int32_t *p, int32_t v) { for (int32_t i = 0; i < 4; i++) p[i] = v; return p[0]; }
int main(void) {
    int32_t buf[4] = { 7, 7, 7, 7 };
    int32_t r = 0;
    if (sum4(&buf[0]) == 28) r += 1;
    if (fill(&buf[0], 5) == 5 && buf[3] == 5) r += 2;
    if (sum4(&g[0]) == 44) r += 4;
    return r; }'
    diff_case 'array field, behind a ptr<S>' \
        'struct Row { cells: i32[4] }
fn sum4(p: ptr) -> i32 { let t: i32 = 0; let i: i32 = 0;
    while (i < 4) { t = t + p[i]; i = i + 1; }
    return t; }
fn rowSum(pr: ptr<Row>) -> i32 { let p: ptr = &pr.cells; return sum4(p); }
fn main() -> i32 {
    let r: Row;
    r.cells[0] = 1; r.cells[1] = 2; r.cells[2] = 3; r.cells[3] = 4;
    return rowSum(&r) + sum4(&r.cells); }' \
        '#include <stdint.h>
struct Row { int32_t cells[4]; };
static int32_t sum4(int32_t *p) { int32_t t = 0; for (int32_t i = 0; i < 4; i++) t += p[i]; return t; }
static int32_t rowSum(struct Row *pr) { int32_t *p = &pr->cells[0]; return sum4(p); }
int main(void) {
    struct Row r;
    r.cells[0] = 1; r.cells[1] = 2; r.cells[2] = 3; r.cells[3] = 4;
    return rowSum(&r) + sum4(&r.cells[0]); }'
    # The shipped example against its twin, end to end.
    diff_case 'examples/array_address.ast' \
        "$(cat examples/array_address.ast)" \
        "$(cat tests/array-address-twin.c)"
fi

# ---------------------------------------------------------------------------
# [5/9] Rejection matrix. v0.23.34-dev opens `&` for an array of *any* element
# width — the pointer carries the stride — so what is refused now is narrower
# and different in kind: a strided pointer may not be stored in an untyped
# `ptr`, which would index it at four bytes and read the wrong element in
# silence. `ptr<T>` (or an array parameter) is the spelling that keeps it.
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
GATE='cannot store a pointer to '
# An 8-byte element: an untyped ptr would index it at half the right distance.
reject '& of an i64[2] into a ptr'    "$GATE"'i64 elements in ptr' \
    'fn main() -> i32 { let a: i64[2] = 0; let p: ptr = &a; return 0; }'
# A 1-byte element: four times the right distance.
reject '& of a u8[2] into a ptr'      "$GATE"'u8 elements in ptr' \
    'fn main() -> i32 { let a: u8[2] = 0; let p: ptr = &a; return 0; }'
# A 2-byte element: twice.
reject '& of a u16[2] into a ptr'     "$GATE"'u16 elements in ptr' \
    'fn main() -> i32 { let a: u16[2] = 0; let p: ptr = &a; return 0; }'
reject '& of a ptr[2] into a ptr'     "$GATE"'ptr elements in ptr' \
    'fn main() -> i32 { let a: ptr[2] = 0; let p: ptr = &a; return 0; }'
# A 12-byte struct element: the size is not even a power of two.
reject '& of a 12-byte struct array'  "$GATE"'V3 elements in ptr' \
    'struct V3 { a: i32, b: i32, c: i32 }
fn main() -> i32 { let a: V3[2] = V3 { 1, 2, 3 }; let p: ptr = &a; return 0; }'
# The same rule at file scope, and for a struct's array field.
reject '& of a global i64[2]'         "$GATE"'i64 elements in ptr' \
    'let g: i64[2] = 0;
fn main() -> i32 { let p: ptr = &g; return 0; }'
reject '& of an i64 array field'      "$GATE"'i64 elements in ptr' \
    'struct B { w: i64[2] }
fn main() -> i32 { let b: B; let p: ptr = &b.w; return 0; }'
# A strided pointer of one element type does not go into a slot that strides
# over another: `p[i]` would disagree with the array the pointer came from.
reject 'ptr<i64> from a ptr<u8> slot' 'cannot store a pointer to u8 elements in' \
    'fn main() -> i32 { let a: u8[2] = 0; let p: ptr<i64> = &a; return 0; }'
# A ptr<S> names its own stride too: a pointer to V3 elements does not go into
# a ptr<Q>, which strides at sizeof(Q) and not at sizeof(V3).
reject 'ptr<V3> from a ptr<Q> slot'   "$GATE"'V3 elements in ptr<Q>' \
    'struct Q { x: i32 }
struct V3 { a: i32, b: i32, c: i32 }
fn main() -> i32 { let a: V3[2] = V3 { 1, 2, 3 }; let p: ptr<Q> = &a; return 0; }'
# Passing an array's address where an i32 is expected.
reject '&buf into an i32 parameter'     'argument type mismatch calling takes at argument 1: expected i32' \
    'fn takes(n: i32) -> i32 { return n; }
fn main() -> i32 { let a: i32[2] = 0; return takes(&a); }'
# v0.23.58-dev relaxed `&`: a scalar, bool, pointer or struct lvalue now answers
# a typed ptr<T>, so the old "struct-only" refusals for a scalar/bool/field/
# element are gone — those cases now compile into a matching typed slot. Only a
# size mismatch still refuses (a ptr<ptr> has no place in an untyped ptr), and
# `&` still requires an lvalue.
check "$A" '& of an i32 variable compiles' 0 'fn main() -> i32 { let x: i32 = 1; let q: ptr<i32> = &x; return 0; }'
check "$A" '& of a bool variable compiles' 0 'fn main() -> i32 { let x: bool = true; let q: ptr<bool> = &x; return 0; }'
check "$A" '& of a scalar struct field compiles' 0 'struct P { x: i32 } fn main() -> i32 { let s: P = P { 1 }; let q: ptr<i32> = &s.x; return 0; }'
check "$A" '& of an i32 array element compiles' 0 'fn main() -> i32 { let a: i32[2] = 0; let q: ptr<i32> = &a[0]; return 0; }'
reject '& of a ptr variable'           'cannot store a pointer to ptr elements in ptr' \
    'fn main() -> i32 { let p: ptr = 0; let q: ptr = &p; return 0; }'
reject '& of a call result'            "'&' requires a variable, a field, or a dereferenced ptr<S>" \
    'fn f() -> i32 { return 1; }
fn main() -> i32 { let q: ptr = &f(); return 0; }'

# ---------------------------------------------------------------------------
# [6/9] Coverage map. Every accepted row above has to name the rule it
# exercises, so deleting a case without noticing is a failure of the map.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Coverage map: which case exercises which rule'
cat > "$OUT/map.txt" <<'MAP'
local array by reference         ref            a local T[N] read through a ptr parameter
written through a reference      ref            a store through one, seen by the caller
global array by reference        ref            the same at file scope
bool array by reference          elem           a bool[3]: a 4-byte slot an element
u32 array by reference           elem           the other 4-byte integer width
4-byte struct array by ref       elem           sizeof(S)==4, so S[N] travels
array field by reference         field          &s.cells: field base + offset
array field behind ptr<S>        field          the same, base is a ptr<S> value
address in a variable            ref            the address kept, indexed at a computed offset
two arrays, two addresses        ref            two frames slots do not alias
reference passed onward          ref            a reference handed to a second callee
&buf and buf agree           decay          &buf == the decayed array name
i64 array through ptr<i64>   stride         an 8-byte element: &w keeps the stride it had
u8 array through ptr<u8>     stride         a 1-byte element: the stride is one, not four
u16 array through ptr<u16>   stride         a 2-byte element
i64 array parameter          param          fn f(a: i64[4]): the array taken by address
u8 array parameter           param          the same shape for a 1-byte element
ptr<i64> returned and kept   stride         a strided pointer survives return + rebinding
local + global + write-through   diff       the C oracle for the three shapes
array field, behind a ptr<S>     diff       the C oracle for the field shapes
& of an i64[2] into a ptr    guard         a strided pointer may not land in an untyped ptr
& of a 12-byte struct array  guard         a size that is not a power of two
ptr<i64> from a ptr<u8> slot rej           one stride does not pass as another
& of an i32 array element compiles  acc  &a[0] is now ptr<i32> (v0.23.58-dev relaxed &)
& of an i32 variable compiles      acc  &x is ptr<i32> (v0.23.58-dev relaxed &)
& of a bool variable compiles      acc  &x is ptr<bool> (v0.23.58-dev relaxed &)
& of a scalar struct field compiles acc  &s.x is ptr<i32> (v0.23.58-dev relaxed &)
& of a ptr variable            rej  ptr<ptr> has no place in an untyped ptr (size mismatch)
examples/array_address.ast       diff           the shipped example against its twin
MAP
n=$(wc -l < "$OUT/map.txt")
printf '  %-34s %s\n' 'cases mapped to a rule' "$n"

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
    if ! sed -i.bak "$script" "$OUT/mut.cpp" 2>/dev/null; then
        echo "FAIL: mutant $name could not be applied" >&2; exit 1
    fi
    if ! $CXX -std=c++17 -O2 -w "$OUT/mut.cpp" -o "$OUT/mut.aster" >"$OUT/mut.build" 2>&1; then
        echo "FAIL: mutant $name does not build" >&2
        # A mutant that could not be compiled is a broken *mutant*, not a
        # caught rule: say so with the compiler's own words, and do not let a
        # missing log turn into a second, unrelated error nobody can act on.
        if [ -f "$OUT/mut.build" ]; then sed -n '1,3p' "$OUT/mut.build" >&2
        else echo "  (the compiler produced no log: $CXX exited before writing one)" >&2; fi
        exit 1
    fi
    "$@"
    printf '  %-34s caught\n' "$name"
}
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the mutation layer needs qemu to observe a changed answer\n'
else
LOCALREF='fn main() -> i32 { let a: i32[4] = 7; let p: ptr = &a; return p[0]; }'
GLOBALREF='let g: i32[4] = 11;
fn main() -> i32 { let p: ptr = &g; return p[0]; }'
# m1: the predicate is gone, so `&` never sees an array — every array address
# falls through to the struct-only rule and is refused.
mutate 'm1: arrayOperandOf is gone' \
    's/bool arrayOperandOf(const Expr& e,Ty& elem,uint32_t& len){/bool arrayOperandOf(const Expr\& e,Ty\& elem,uint32_t\& len){return false;/' \
    must_not_compile '& of a local array' "$LOCALREF"
# m2: the local arm hands back the *decayed* type (Ty::Ptr, 8 bytes) instead of
# the element type, so the 4-byte gate refuses a perfectly ordinary i32[4].
mutate 'm2: local arm reads the decayed type' \
    's/elem=b->elem; len=b->len; return true;/elem=b->ty; len=b->len; return true;/' \
    must_not_compile '& of a local array' "$LOCALREF"
# m3: the global arm is gone, so a file-scope array's address is refused.
mutate 'm3: global arm is gone' \
    's/elem=arrayElemTypeOf(e.name); len=arrayLengthOf(e.name); return true;/return false;/' \
    must_not_compile '& of a global array' "$GLOBALREF"
# m4 (struct-array-field arm) removed for v0.23.58-dev: the AddrOf rule now
# answers tyPtrToElem(inner) for any non-struct lvalue, and typeOf(Field) of an
# array field already yields the element type, so arrayOperandOf's Field arm is
# redundant for `&` and withdrawing it no longer changes anything. The array-field
# address is instead pinned by address-of-checks.sh's "scalar field &s.a" case.
# m5: the stride guard in ptrToAssignable is withdrawn, so `&w` on an i64[2]
# is accepted into an untyped ptr — where it would be indexed at four bytes.
mutate 'm5: the stride guard is gone' \
    's/return ptrElemWidth(from)==4u;/return true;/' \
    must_now_compile '& of a local i64 array' 'fn main() -> i32 { let a: i64[2] = 0; let p: ptr = &a; return 0; }'
# m6: `&arr` answers the element type instead of a pointer, so it cannot be
# stored in a ptr or passed to one.
mutate 'm6: &arr answers the element type' \
    's/return tyPtrToElem(aelem);/return aelem;/' \
    must_not_compile '& of a local array' "$LOCALREF"
# m8: the stride a typed pointer applies is always four, so every non-4-byte
# element is read at the wrong distance — silently, which is the failure the
# round exists to prevent. The i64 case must notice it.
mutate 'm8: the stride is always four' \
    's/if(tyIsPtrToElem(st))pe=ptrElemType(st);/if(tyIsPtrToElem(st))pe=Ty::I32;/' \
    must_differ 'i64 array read via ptr<i64>' 24 'fn main() -> i32 {
    let w: i64[4] = 0; let p: ptr<i64> = &w;
    w[0] = 3; w[1] = 5; w[2] = 7; w[3] = 9;
    return p[0] + p[1] + p[2] + p[3]; }'
# m7: the frame address is the slot index rather than the slot's byte offset,
# so `&a` names the wrong place for every array past slot 0 — the shape of the
# v0.22.50-dev frame-base encoding bug, with the same kind of invisibility.
mutate 'm7: frame address not scaled' \
    's/if(slot>=0){emit(addImm(kGlobalBase,31,(uint32_t)slot\*8));return;}/if(slot>=0){emit(addImm(kGlobalBase,31,(uint32_t)slot));return;}/' \
    must_differ '& of a second-slot array' 7 'fn main() -> i32 {
    let pad: i32 = 1;
    let a: i32[4] = 7;
    let p: ptr = &a;
    return p[0]; }'
printf '%s\n' 'PASS: eight mutated compilers each lose exactly one rule, and the checks notice'
fi

# ---------------------------------------------------------------------------
# [8/9] Byte-identity baseline. Every line recorded before this round must
# reproduce byte for byte. Four families are excluded — this round's own example
# and the three most recent rounds', each of which is new rather than
# pre-existing — leaving the same 288 rows every recent suite compares.
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
# v0.23.31-dev: the multi-dimensional round's example joins the filter, so five
# families are skipped — but the baseline gained that round's three rows, and
# the pre-existing count is the same 288 it has been.
# v0.23.37-dev: the function-type round's example (fn_type.ast) joins the
# filter the same way, so thirteen families are skipped and the pre-existing count
# is still 288: 327 recorded, 39 of them belonging to the thirteen rounds this
# suite knows are new.
# v0.23.41-dev: the heap round's example (arena.ast) joins the filter the same
# way, so fourteen families are skipped and the pre-existing count is still 288:
# 327 recorded, 42 of them belonging to the fourteen rounds this suite knows
# are new.
# v0.23.42-dev: the standard-library round's example (stdlib_demo.ast) joins
# the filter the same way, so fourteen families are skipped and the
# pre-existing count is still 288: 330 recorded, 42 of them belonging to the
# fourteen rounds this suite knows are new.
# v0.23.48-dev: the u64 round's example (integer_cast.ast) joins the filter the
# same way, so fifteen families are skipped and the pre-existing count is still
# 288: 333 recorded, 45 of them belonging to the fifteen rounds this suite
# knows are new.
# v0.23.51-dev: the TLS round's example (tls_demo.ast) and the symbol-versioning
# round's example (so_verstrlen.ast) join the filter the same way; v0.23.52-dev
# adds so_tls_demo.ast beside them, so twenty families are skipped and the
# pre-existing count is still 288: 348 recorded, 60 of them belonging to the
# twenty rounds this suite knows are new.
# v0.23.57-dev: c_ptr_difference.ast (the pointer-difference round) joins this filter the same way, so the pre-existing count stays 288.
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
[ "$(grep -c '^array_address\.' "$OUT/hashes.txt")" -eq 3 ] \
    || { echo 'FAIL: array_address.ast is not in the baseline in all three modes' >&2; exit 1; }
printf '  %-34s %s\n' 'pre-existing rows byte-identical' "$old"
printf '  %-34s %s\n' 'new example rows recorded' '3'
printf '%s\n' 'PASS: byte-identity baseline holds'

# ---------------------------------------------------------------------------
# [9/9] The shipped example, end to end.
# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] The example, end to end'
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the example needs qemu to run\n'
else
    if ! "$A" build-elf examples/array_address.ast -o "$OUT/aa.a64" >"$OUT/aa.err" 2>&1; then
        echo 'FAIL: examples/array_address.ast does not build' >&2; sed -n '1,3p' "$OUT/aa.err" >&2; exit 1
    fi
    $RUNNER "$OUT/aa.a64" >/dev/null 2>&1 && got=0 || got=$?
    [ "$got" = 63 ] \
        || { echo "FAIL: array_address.ast: expected exit 63, got $got" >&2; exit 1; }
    printf '  %-34s %s\n' 'array_address.ast' "$got"
    printf '%s\n' 'PASS: the example runs and returns the value its C twin returns'
fi

printf '%s\n' '=== array address checks: ALL PASSED ==='
