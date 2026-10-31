#!/bin/sh
# v0.23.29-dev checks for struct array fields (`xs: T[N]` inside a struct).
# Until this release a struct field could only be a scalar, a bool, a pointer
# or a (nested) struct — `struct Buffers { nums: i32[4] }` was a syntax error
# ("array fields are not supported"). Four places had to change, and one of them
# is a parser loop that used to handle `.` and `[` in two separate passes:
#
#   1. `StructField` carries a length (`len`), and `layoutStruct()` sizes an
#      array field as `sizeof(elem) * len`. `structDeclaration()` parses the
#      optional `[N]` after a field type into that length.
#   2. `postfix()` interleaves `.` and `[` in a single loop, so `s.xs[i].f`
#      — a field of a struct array element — parses, not just `s.xs[i]`.
#   3. `Sema` and `Codegen` agree that `s.xs[i]` is an element of the field's
#      own type: `arrayFieldOf()` (a free function both passes call) tells an
#      Index apart from a named-array Index by the shape of its base; the
#      element reads, writes, is addressed and is scaled by `emitElemIndex`,
#      exactly like a named array element.
#   4. A struct that contains an array field cannot be set by a literal — the
#      field alone needs N values — so it is declared without an initializer
#      and zero-filled (`let b: Buffers;` on the frame, `let gb: Buffers;` in
#      .bss); its elements are written at run time. A literal `=` for one is
#      refused, in `structConstantImage()` and `emitStructStore()` (struct
#      globals) and by the parser's local `let` rule.
#
# None of it can move the bytes of a program that compiled before: every
# shipped example that declares a struct does so without an array field, and an
# array field is a strictly new declaration shape. Layer [8/9] asserts all 288
# pre-existing baseline rows reproduce.
#
# The behavioural layers need qemu (or an AArch64 host); the differential layer
# additionally needs $HOSTCC to emit AArch64 ELF. Neither is required to
# *build*, so each layer that cannot run says SKIP and the rest still runs.
set -eu
cd "$(dirname "$0")/.."
. tests/lib/baseline.sh
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-struct-array-field-checks}
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
    printf '%s\n' 'SKIP: struct-array-field-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each change is pinned where it was made, so a regression
# that quietly reopens one fails here rather than by a behavioural case.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: the four changes'
# v0.23.31-dev: StructField now carries the per-dimension lengths too, so a
# multi-dimensional field (`xs: i32[2][3]`) can be subscripted like any other
# array; `len` stays the outer length, which is what every earlier guard and
# every 1-D path still reads.
grep -qF 'struct StructField { std::string name; Ty ty; uint32_t offset = 0; uint32_t len = 0; std::vector<uint32_t> dims;' src/aster.cpp \
    || { echo 'FAIL: StructField no longer carries a length' >&2; exit 1; }
grep -qF 'static bool structHasArrayField(uint32_t sid){' src/aster.cpp \
    || { echo 'FAIL: structHasArrayField() is missing' >&2; exit 1; }
# A field may be a fixed-length array: the parser records flen from the [N].
# v0.23.31-dev: it records the whole dimension list now, flen still first.
grep -qF 'v0.23.29-dev: a field may be a fixed-length array' src/aster.cpp \
    || { echo 'FAIL: structDeclaration() no longer parses an array field' >&2; exit 1; }
grep -qF 's.fields.push_back({fn.s,fty,0,flen,std::move(dims),std::move(fieldFuncSig),fieldIsFunc});' src/aster.cpp \
    || { echo 'FAIL: structDeclaration() no longer records flen' >&2; exit 1; }
# postfix() interleaves `.` and `[` in one loop.
grep -qF 'v0.23.29-dev folds the once-separate `[]` pass into this' src/aster.cpp \
    || { echo 'FAIL: postfix() no longer interleaves . and [' >&2; exit 1; }
# arrayFieldOf is a free function both passes call.
grep -qF 'static const StructField* arrayFieldOf(Ty base,const Expr& field){' src/aster.cpp \
    || { echo 'FAIL: arrayFieldOf() is missing as a free function' >&2; exit 1; }
# A struct-with-array-field local is zero-filled: the parser and sema agree.
grep -qF 'v0.23.29-dev: a struct local may be declared without an initializer' src/aster.cpp \
    || { echo 'FAIL: letStatement() no longer allows a struct local with no initializer' >&2; exit 1; }
grep -qF 'v0.23.29-dev: a struct local declared without an' src/aster.cpp \
    || { echo 'FAIL: checkStmt() no longer skips type-checking a zero-filled struct local' >&2; exit 1; }
# A struct-with-array-field global is zero-filled in .bss; a literal is refused.
grep -qF 'v0.23.29-dev: a struct with an array field cannot be set by a' src/aster.cpp \
    || { echo 'FAIL: the global no-initializer branch is not marked' >&2; exit 1; }
grep -qF "contains an array field and cannot be initialized by a literal" src/aster.cpp \
    || { echo 'FAIL: structConstantImage()/emitStructStore() no longer refuse an array-field struct' >&2; exit 1; }
# The element address is shared with the named-array path.
grep -qF 'void emitElemAddrField(const Expr& fbase,const Expr& index){' src/aster.cpp \
    || { echo 'FAIL: emitElemAddrField() is missing' >&2; exit 1; }
printf '%s\n' '  all four changes pinned, in both passes'

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
printf '%s\n' '[3/9] qemu: every element type of a struct array field'
# --- i32 element: 4-byte stride (a shift).
check "$A" 'i32 field element'         11 'struct B { nums: i32[4] }
fn main() -> i32 { let b: B; b.nums[0] = 11; b.nums[3] = 33;
    if (b.nums[3] == 33 && b.nums[0] == 11) { return 11; } return 0; }'
check "$A" 'i32 field element, global' 7 'struct B { nums: i32[4] }
let gb: B;
fn main() -> i32 { gb.nums[2] = 7; if (gb.nums[2] == 7) { return 7; } return 0; }'
# --- bool element: 1-byte stride (a shift), read as a condition and stored.
check "$A" 'bool field element'        2 'struct B { flags: bool[3] }
fn main() -> i32 { let b: B; b.flags[0] = true; b.flags[2] = true;
    if (b.flags[0] && b.flags[2] && !b.flags[1]) { return 2; } return 0; }'
# --- ptr element: 8-byte stride, null fill then an address.
check "$A" 'ptr field element'         4 'struct B { ptrs: ptr[4] }
struct P { x: i32 }
fn main() -> i32 { let cell: P = P { 42 };
    let b: B; b.ptrs[1] = &cell; if (b.ptrs[1] == &cell && b.ptrs[0] == 0) { return 4; } return 0; }'
# --- struct element: 12 bytes (a multiply), addressed and walked field by field.
check "$A" 'struct field element'      8 'struct V { a: i32, b: i32, c: i32 }
struct B { pts: V[2] }
fn main() -> i32 { let b: B; b.pts[1].a = 100; b.pts[1].c = 200;
    if (b.pts[1].a == 100 && b.pts[1].c == 200 && b.pts[0].a == 0) { return 8; } return 0; }'
# --- the address of a struct element is a ptr<S>; deref and read a field.
check "$A" 'address of struct element' 16 'struct V { a: i32, b: i32, c: i32 }
struct B { pts: V[2] }
fn main() -> i32 { let b: B; b.pts[1].a = 100; let p: ptr<V> = &b.pts[1];
    if (p == &b.pts[1] && (*p).a == 100) { return 16; } return 0; }'
# --- a struct element can be written through a subscript's field, and a whole
# element copy is still refused (a struct has no register form).
check "$A" '12-byte element both scopes' 32 'struct V { a: i32, b: i32, c: i32 }
struct B { pts: V[2] }
let gb: B;
fn main() -> i32 { let b: B; b.pts[1].b = 5; gb.pts[0].b = 3;
    if (b.pts[1].b == 5 && gb.pts[0].b == 3) { return 32; } return 0; }'
# --- a struct element can be copied as a whole into a struct variable.
check "$A" 'struct element copy'     15 'struct V { a: i32, b: i32, c: i32 }
struct B { pts: V[2] }
fn main() -> i32 { let b: B; b.pts[1].a = 100; b.pts[1].b = 55; b.pts[1].c = 200;
    let c: V = b.pts[1];
    if (c.a == 100 && c.b == 55 && c.c == 200) { return 15; } return 0; }'
# --- an i32 element read into an i64 context is sign-extended, like an i32
# local, an i32 global and an i32 struct field: the one SXTW site the field
# path owns, and the reason it is not a bare 32-bit load.
check "$A" 'i32 field element into i64' 64 'struct B { nums: i32[4] }
fn main() -> i32 { let b: B; b.nums[0] = 0 - 5;
    let x: i64 = b.nums[0];
    if (x == 0 - 5) { return 64; } return 0; }'
fi

# ---------------------------------------------------------------------------
# [4/9] Differential layer: the same program under Aster and under the target
# C compiler must produce the same value. C has always had a struct array field;
# this round is Aster catching up to an answer that was never in doubt.
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
    diff_case 'i32/bool/ptr elements, both scopes' \
        'struct V3 { a: i32, b: i32, c: i32 }
struct B { nums: i32[4], flags: bool[3], ptrs: ptr[4], pts: V3[2] }
let gb: B;
fn main() -> i32 {
    let b: B;
    let anchor: V3 = V3 { 1, 2, 3 };
    let r: i32 = 0;
    b.nums[0] = 11; b.nums[3] = 33;
    if (b.nums[3] == 33 && b.nums[0] == 11) { r = r + 1; }
    b.flags[0] = true; b.flags[2] = true;
    if (b.flags[0] && b.flags[2] && !b.flags[1]) { r = r + 2; }
    b.ptrs[1] = &anchor;
    if (b.ptrs[1] == &anchor && b.ptrs[0] == 0) { r = r + 4; }
    b.pts[1].a = 100; b.pts[1].c = 200;
    if (b.pts[1].a == 100 && b.pts[1].c == 200 && b.pts[0].a == 0) { r = r + 8; }
    gb.nums[2] = 77;
    if (gb.nums[2] == 77) { r = r + 16; }
    return r; }' \
        '#include <stdint.h>
struct V3 { int32_t a, b, c; };
struct B { int32_t nums[4]; int8_t flags[3]; void *ptrs[4]; struct V3 pts[2]; };
static struct B gb;
int main(void) {
    struct B b;
    struct V3 anchor = { 1, 2, 3 };
    int32_t r = 0;
    b.nums[0] = 11; b.nums[3] = 33;
    if (b.nums[3] == 33 && b.nums[0] == 11) r += 1;
    b.flags[0] = 1; b.flags[2] = 1;
    if (b.flags[0] && b.flags[2] && !b.flags[1]) r += 2;
    b.ptrs[1] = &anchor;
    if (b.ptrs[1] == &anchor && b.ptrs[0] == 0) r += 4;
    b.pts[1].a = 100; b.pts[1].c = 200;
    if (b.pts[1].a == 100 && b.pts[1].c == 200 && b.pts[0].a == 0) r += 8;
    gb.nums[2] = 77;
    if (gb.nums[2] == 77) r += 16;
    return r; }'
    # The shipped example against its twin, end to end.
    diff_case 'examples/struct_array_field.ast' \
        "$(cat examples/struct_array_field.ast)" \
        "$(cat tests/struct-array-field-twin.c)"
fi

# ---------------------------------------------------------------------------
# [5/9] Rejection matrix. Opening the array field does not open the type rules
# that go with it, and a few of those rules are new.
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
# Indexing a non-array field — scalar, bool/ptr, or struct — is refused.
reject 'index a scalar field'        'cannot index non-array field: x' \
    'struct P { x: i32 }
fn main() -> i32 { let s: P = P { 1 }; return s.x[0]; }'
reject 'index a struct field'        'cannot index non-array field: nest' \
    'struct N { a: i32 }
struct P { nest: N }
fn main() -> i32 { let s: P = P { N { 1 } }; return s.nest[0].a; }'
reject 'index a bool field'          'cannot index non-array field: f' \
    'struct P { f: bool }
fn main() -> i32 { let s: P = P { true }; return s.f[0]; }'
# Indexing a non-array field and then a field-of-element: `s.x[0].y`.
reject 'index a scalar field then .y' 'cannot index non-array field: x' \
    'struct P { x: i32 }
fn main() -> i32 { let s: P = P { 1 }; return s.x[0].y; }'
# A compile-time out-of-bounds index on a struct array field.
reject 'struct array field OOB'      'array index out of bounds: index 9, length 4' \
    'struct B { nums: i32[4] }
fn main() -> i32 { let b: B; return b.nums[9]; }'
# A struct that contains an array field cannot be initialized by a literal.
reject 'local literal of array-field struct' "struct 'B' contains an array field and cannot be initialized by a literal" \
    'struct B { nums: i32[4] }
fn main() -> i32 { let b: B = B { 0 }; return 0; }'
reject 'global literal of array-field struct' "struct 'B' contains an array field and cannot be initialized by a literal" \
    'struct B { nums: i32[4] }
let gb: B = B { 0 };
fn main() -> i32 { return 0; }'
# An array field length is bounded like a local array.
reject 'array field length 0'        'array field length must be between 1 and 1000' \
    'struct B { nums: i32[0] }
fn main() -> i32 { return 0; }'
reject 'array field length 1001'     'array field length must be between 1 and 1000' \
    'struct B { nums: i32[1001] }
fn main() -> i32 { return 0; }'
# A struct array field element is still not a register value: it cannot be
# returned or read into an integer — only copied as a whole, or walked field by
# field.
reject 'struct element into an i32'  "type mismatch initializing 'n': expected i32, got V3" \
    'struct V3 { a: i32, b: i32, c: i32 }
struct B { pts: V3[2] }
fn main() -> i32 { let b: B; let n: i32 = b.pts[0]; return 0; }'

# ---------------------------------------------------------------------------
# [6/9] Coverage map. Every accepted row above has to name the rule it
# exercises, so deleting a case without noticing is a failure of the map.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Coverage map: which case exercises which rule'
cat > "$OUT/map.txt" <<'MAP'
i32 field element                  i32            a 4-byte struct array field element, read
i32 field element, global          i32            the same at file scope, zero-filled in .bss
bool field element                 bool           a 1-byte struct array field element
ptr field element                  ptr            an 8-byte struct array field element, null fill
struct field element               struct         a 12-byte element, scaled by a multiply
address of struct element          addr           &s.xs[i] is a ptr<S>, deref and read a field
struct element copy                struct         a struct element copied as a whole value
12-byte element both scopes        struct         a struct element written in both scopes
i32/bool/ptr elements, both scopes diff           the C oracle for every element type
struct array field OOB              bounds         a constant index checked against the field length
local literal of array-field struct rej            a literal initializer is refused
global literal of array-field struct rej            the same refusal at file scope
struct element into an i32         rej            a struct element is not an integer
i32 field element into i64         widen          an i32 element read into an i64 context (SXTW)
examples/struct_array_field.ast    diff           the shipped example against its twin
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
        echo "FAIL: mutant $name does not build" >&2; sed -n '1,3p' "$OUT/mut.build" >&2; exit 1
    fi
    "$@"
    printf '  %-34s caught\n' "$name"
}
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the mutation layer needs qemu to observe a changed answer\n'
else
# m1: arrayFieldOf always reports "not an array field", so every struct array
# field access is read as a non-array field index and refused in sema.
mutate 'm1: arrayFieldOf is gone' \
    's/if(field.k!=Expr::Field)return nullptr;/if(field.k!=Expr::Field)return nullptr; if(true)return nullptr;/' \
    must_not_compile 's.xs[i] read' 'struct B { nums: i32[4] }
fn main() -> i32 { let b: B; b.nums[0] = 1; return b.nums[0]; }'
# m2: postfix() splits `.` and `[` into two passes again, so `s.xs[i].f`
# fails to parse — the bracket after a field is no longer consumed.
mutate 'm2: postfix splits . and [' \
    's/while(cur().k==TK::Dot||cur().k==TK::LBracket||(cur().k==TK::LParen\&\&x->k==Expr::Field)){/while(cur().k==TK::Dot||(cur().k==TK::LParen\&\&x->k==Expr::Field)){/' \
    must_not_compile 's.xs[i].f' 'struct V3 { a: i32 }
struct B { pts: V3[2] }
fn main() -> i32 { let b: B; b.pts[1].a = 1; return b.pts[1].a; }'
# m3: structHasArrayField always answers false, so a literal initializer for an
# array-field struct is no longer refused — the new rejection is withdrawn.
mutate 'm3: array-field struct takes a literal' \
    's/if(f.len>0)return true;/if(false)return true;/' \
    must_now_compile 'local literal of array-field struct' 'struct B { nums: i32[4] }
fn main() -> i32 { let b: B = B { 0 }; return 0; }'
# m4: the field length is dropped from the declaration, so an array field is
# laid out as a single scalar and `b.nums[0]` indexes a non-array field — the
# whole declaration shape is withdrawn, and the witness no longer compiles.
# v0.23.31-dev: the push_back carries the dimension list too now; dropping the
# length is still dropping the length — `0` in flen's place.
mutate 'm4: array field length dropped' \
    's/s.fields.push_back({fn.s,fty,0,flen,std::move(dims),std::move(fieldFuncSig),fieldIsFunc});/s.fields.push_back({fn.s,fty,0,0,std::move(dims),std::move(fieldFuncSig),fieldIsFunc});/' \
    must_not_compile 'i32 field element' 'struct B { nums: i32[4] }
fn main() -> i32 { let b: B; b.nums[0] = 11; b.nums[3] = 33;
    if (b.nums[3] == 33 && b.nums[0] == 11) { return 11; } return 0; }'
# m5: a struct array field element is scaled by 4 instead of its real size, so
# a 12-byte element (`struct V`) is mis-addressed. The witness must observe it
# from a second element, not the one written: b.pts[1].a lands at offset 4 under
# the broken stride and at offset 12 under the real one, so b.pts[0].b — offset
# 4 either way — reads 100 (broken) instead of 0 (real).
mutate 'm5: struct element scaled as i32' \
    's/emit(movInt(sz,tySize(elem)));/emit(movInt(sz,4));/' \
    must_differ 'struct field element' 0 'struct V { a: i32, b: i32, c: i32 }
struct B { pts: V[2] }
fn main() -> i32 { let b: B; b.pts[1].a = 100; return b.pts[0].b; }'
# m6: the frame zero-fill stores x0 again instead of the zero register, so a
# struct local declared without an initializer takes whatever x0 happens to
# hold. The witness declares a struct with a literal *before* it (which leaves
# 42 in x0), so a never-written ptr element reads 42 instead of null. This is
# the bug the ptr case above was written for and caught.
mutate 'm6: zero-fill stores x0 not XZR' \
    's/emit(0xf90003e0u|31u|((uint32_t(slot+i))<<10));/emit(0xf90003e0u|0u|((uint32_t(slot+i))<<10));/' \
    must_differ 'ptr field element' 4 'struct P { x: i32 }
struct B { ptrs: ptr[4] }
fn main() -> i32 { let cell: P = P { 42 };
    let b: B;
    if (b.ptrs[0] == 0) { return 4; } return 0; }'
# m7: the field path's i32 element is not sign-extended when the consumer wants
# 64 bits, so `let x: i64 = b.nums[0];` reads 0x00000000FFFFFFFB instead of -5
# and the equality against -5 fails. The sed is anchored on the site's own
# indentation (24 spaces) because the named-array path carries the same rule one
# level out (16 spaces) and must keep it.
mutate 'm7: i32 field element not widened' \
    's/^                        if(tyIs64(want)&&elem==Ty::I32)emit(0x93407c00u|(uint32_t(d)<<5)|uint32_t(d));$/                        ;/' \
    must_differ 'i32 field element into i64' 64 'struct B { nums: i32[4] }
fn main() -> i32 { let b: B; b.nums[0] = 0 - 5;
    let x: i64 = b.nums[0];
    if (x == 0 - 5) { return 64; } return 0; }'
printf '%s\n' 'PASS: seven mutated compilers each lose exactly one rule, and the checks notice'
fi

# ---------------------------------------------------------------------------
# [8/9] Byte-identity baseline. Every line recorded before this round must
# reproduce byte for byte. Five families are excluded: this round's own example
# and the four most recent rounds', each of which is new rather than
# pre-existing.
# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Byte-identity baseline'
BASE=$(aster_baseline_file)
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
# v0.23.51-dev: the TLS round's example (tls_demo.ast) and the symbol-versioning
# round's example (so_verstrlen.ast) join the filter the same way, and v0.23.52-dev's
# example (so_tls_demo.ast) with them, so twenty
# families are skipped and the pre-existing count is still 288: 345 recorded,
# 57 of them belonging to the nineteen rounds this suite knows are new.
# v0.23.57-dev: c_ptr_difference.ast (the pointer-difference round) joins this filter the same way, so the pre-existing count stays 288.
grep -v -e '^cast-conversions\.' -e '^sizeof_len\.' -e '^struct_array_field\.' -e '^array_elem_types\.' -e '^precedence\.' -e '^array_address\.' -e '^multi_dim_array\.' -e '^lifecycle\.' -e '^fn_type\.' -e '^cb_table\.' -e '^fn_ret.' -e '^call-stmt.' -e '^copy.' -e '^arena\.' -e '^stdlib_demo\.' -e '^integer_cast\.' -e '^switch\.' -e '^literals\.' -e '^tls_demo\.' -e '^so_verstrlen\.' -e '^c_ptr_difference\.' -e '^address_of\.' -e '^address_of_abi\.' -e '^so_tls_demo\.' -e '^enum_demo\.' "$BASE" | LC_ALL=C sort > "$OUT/expected-old.txt"
grep -v -e '^cast-conversions\.' -e '^sizeof_len\.' -e '^struct_array_field\.' -e '^array_elem_types\.' -e '^precedence\.' -e '^array_address\.' -e '^multi_dim_array\.' -e '^lifecycle\.' -e '^fn_type\.' -e '^cb_table\.' -e '^fn_ret.' -e '^call-stmt.' -e '^copy.' -e '^arena\.' -e '^stdlib_demo\.' -e '^integer_cast\.' -e '^switch\.' -e '^literals\.' -e '^tls_demo\.' -e '^so_verstrlen\.' -e '^c_ptr_difference\.' -e '^address_of\.' -e '^address_of_abi\.' -e '^so_tls_demo\.' -e '^enum_demo\.' "$OUT/hashes.txt" | LC_ALL=C sort > "$OUT/got-old.txt"
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
# v0.23.48-dev: the u64 round's example (integer_cast.ast) joins the filter the
# same way, so fifteen families are skipped and the pre-existing count is still
# 288: 333 recorded, 45 of them belonging to the fifteen rounds this suite
# knows are new.
[ "$old" -eq 288 ] \
    || { echo "FAIL: expected 288 pre-existing baseline rows, found $old" >&2; exit 1; }
[ "$new" -eq 288 ] \
    || { echo "FAIL: expected 288 rows of pre-existing output, found $new" >&2; exit 1; }
[ "$(grep -c '^struct_array_field\.' "$OUT/hashes.txt")" -eq 3 ] \
    || { echo 'FAIL: struct_array_field.ast is not in the baseline in all three modes' >&2; exit 1; }
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
    if ! "$A" build-elf examples/struct_array_field.ast -o "$OUT/saf.a64" >"$OUT/saf.err" 2>&1; then
        echo 'FAIL: examples/struct_array_field.ast does not build' >&2; sed -n '1,3p' "$OUT/saf.err" >&2; exit 1
    fi
    $RUNNER "$OUT/saf.a64" >/dev/null 2>&1 && got=0 || got=$?
    [ "$got" = 63 ] \
        || { echo "FAIL: struct_array_field.ast: expected exit 63, got $got" >&2; exit 1; }
    printf '  %-34s %s\n' 'struct_array_field.ast' "$got"
    printf '%s\n' 'PASS: the example runs and returns the value its C twin returns'
fi

printf '%s\n' '=== struct array field checks: ALL PASSED ==='
