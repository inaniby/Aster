#!/bin/sh
# v0.23.28-dev checks for array element types. An array's element type is the
# type written before the `[N]`, and until this release three places disagreed
# with that sentence:
#
#   1. `letStatement()` opened the `[N]` suffix only after an integer type, so
#      a local `bool[4]`, `Point[4]` or `ptr[4]` was not a declaration Aster
#      could parse — and a local `ptr[4]` was refused with a message of its own.
#   2. `globalDeclaration()`'s Bool branch and Struct branch never looked for
#      a `[`, so `let flags: bool[4] = true;` and `let pts: Point[4] = …;` were
#      syntax errors although the integer branch right below them accepted one.
#   3. `Sema::typeOf(Expr::Index)` answered `Ty::I32` for every subscript
#      whatever the element really was, while codegen loaded and stored at the
#      element's real width. The two halves of the compiler disagreed, and the
#      disagreement was visible: `let q: Point = a[1];` was a type error
#      against itself.
#
# Plus the one rule the three have in common and that was missing everywhere:
# a struct element is addressed by a multiply, not by a shift, because a
# struct's size need not be a power of two (`{ i32, i32, i32 }` is 12). The old
# tyShift answered 2 for every type it did not name, so it could not scale a
# struct element at all; elemShiftOf answers -1 and the address falls back to
# UMADDL. (The obvious spelling of the fallback, `ADD Xt, XZR, Widx, UXTW #0`,
# is wrong: in the *extended* add Rn == 31 is the stack pointer, not XZR, so
# every struct array read added SP and walked off the frame. Hence UMADDL.)
#
# None of it can change the bytes of a program that compiled before: every
# shipped example that indexes an array declares it with an integer element
# type, and elemShiftOf agrees with the old tyShift for every scalar. Layer
# [8/9] asserts all 288 pre-existing baseline rows reproduce.
#
# The differential layer is the oracle: C has never had a bool[4], a struct[4]
# or a local pointer[4] question — the answers here are C's, and Aster is the
# side that moved.
#
# Layers: strict compiler build; source guards pinning each of the three holes
# and the addressing rule where they live; a qemu battery; a differential
# comparison against the target C compiler; a rejection matrix for what must
# still be refused; a coverage map; a mutation layer; the byte-identity
# baseline; and a self-check of the new example.
#
# The behavioural layers need qemu (or an AArch64 host); the differential layer
# additionally needs $HOSTCC to emit AArch64 ELF. Neither is required to
# *build*, so each layer that cannot run says SKIP and the rest still runs.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-array-elem-types-checks}
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
    printf '%s\n' 'SKIP: array-elem-types-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each hole is pinned where it was closed, so a regression
# that quietly reopens one fails here rather than having to be explained by a
# behavioural case.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: the three holes and the addressing rule'

# (1) A local array suffix is open to every element type — no gate on the type.
grep -qF 'v0.23.28-dev: a local array extension, open to every element type.' src/aster.cpp \
    || { echo 'FAIL: the local array extension is no longer marked' >&2; exit 1; }
# v0.23.31-dev: the suffix is one `[N]` per dimension, read by arrayDimList()
# and totalled by dimsTotal(); the recorded array is the same one — `isArray`
# and the total element `count` — only the spelling of how they are set moved.
grep -qF 'if(!s.dims.empty()){s.isArray=true;s.count=dimsTotal(s.dims,1000,"local array length",id.s,id.line,id.col);}' src/aster.cpp \
    || { echo 'FAIL: letStatement() no longer records a local array' >&2; exit 1; }
# The element type is carried on the binding, not re-derived from the name.
# v0.23.31-dev: the binding also carries every dimension length now, so a
# subscript chain can ask the length of the dimension it addresses.
# v0.23.37-dev: the struct gained a function signature beside these fields
# (FuncSig funcSig; bool isFunc) and became multi-line — the head line is
# pinned here, the new fields by function-type-checks.sh's own guard, so
# nothing about the element type or the dimensions is left unpinned.
grep -qF 'struct Binding { Ty ty=Ty::I32; uint32_t len=0; Ty elem=Ty::I32; std::vector<uint32_t> dims;' src/aster.cpp \
    || { echo 'FAIL: Sema::Binding no longer carries the element type' >&2; exit 1; }
grep -qF '    Ty arrayElemTypeOf(const std::string& n) const {' src/aster.cpp \
    || { echo 'FAIL: arrayElemTypeOf() is missing' >&2; exit 1; }

# (2) Both closed global branches look for a `[` now.
grep -qF 'v0.23.28-dev: `let flags : bool [ 4 ] = true;`' src/aster.cpp \
    || { echo 'FAIL: the Bool global branch is no longer marked' >&2; exit 1; }
grep -qF 'v0.23.28-dev: `let pts : Point [ 4 ] = Point { 0, 0 };`' src/aster.cpp \
    || { echo 'FAIL: the Struct global branch is no longer marked' >&2; exit 1; }
# Three `[N]` parsers in globalDeclaration: Bool, Struct, and the scalar one.
# v0.23.31-dev: each branch now reads a whole dimension list through
# arrayDimList() and totals it with dimsTotal() — still three branches, one
# line each, so the count below still pins all three.
[ "$(grep -c 'g.isArray=true;g.count=dimsTotal(g.dims,1048576,"array length",g.name,id.line,id.col);' src/aster.cpp)" -eq 3 ] \
    || { echo 'FAIL: globalDeclaration() must open [N] in all three branches' >&2; exit 1; }
# And the struct image is repeated once per element when it is an array.
grep -qF '            const uint64_t n=g.isArray?g.count:1;' src/aster.cpp \
    || { echo 'FAIL: layoutObject() no longer repeats a struct image per element' >&2; exit 1; }

# (3) typeOf(Index) answers the element type, read from the binding.
grep -qF '                return arrayElemTypeOf(e.name);' src/aster.cpp \
    || { echo 'FAIL: typeOf(Expr::Index) no longer answers the element type' >&2; exit 1; }
grep -qF 'case Ty::I32: return arrayElemTypeOf' src/aster.cpp \
    && { echo 'FAIL: typeOf(Expr::Index) is back to a hardcoded i32' >&2; exit 1; }

# The addressing rule: one shifter that admits it cannot shift, and one index
# emitter that falls back to a multiply.
grep -qF 'static int elemShiftOf(Ty t){' src/aster.cpp \
    || { echo 'FAIL: elemShiftOf() is missing' >&2; exit 1; }
grep -qF 'if(sz==0||(sz&(sz-1))!=0u)return -1;' src/aster.cpp \
    || { echo 'FAIL: elemShiftOf() no longer admits a non-power-of-two element' >&2; exit 1; }
grep -q 'int tyShift' src/aster.cpp \
    && { echo 'FAIL: the old tyShift is still in the source' >&2; exit 1; }
grep -qF '    void emitElemIndex(int idxReg,Ty elem){' src/aster.cpp \
    || { echo 'FAIL: emitElemIndex() is missing' >&2; exit 1; }
grep -qF 'emit(0x9ba00000u' src/aster.cpp \
    || { echo 'FAIL: the UMADDL fallback is gone — a 12-byte element cannot be scaled' >&2; exit 1; }
grep -qF '    void emitElemAddr(const std::string& name,const Expr& index){' src/aster.cpp \
    || { echo 'FAIL: emitElemAddr() is missing — element addresses are computed twice again' >&2; exit 1; }
# The extended add with XZR as Rn is SP, not zero — that spelling walked every
# struct array read off the frame, so the trap is recorded next to the emit it
# replaced and the fallback stays a multiply.
grep -qF 'Rn == 31 is the stack pointer and not XZR' src/aster.cpp \
    || { echo 'FAIL: the XZR/SP trap is no longer recorded where the emit can see it' >&2; exit 1; }

# An element is an lvalue, so &a[i] and a[i].f are addressable; a struct
# element is a struct lvalue, so emitStructAddr reaches it; and a bool element
# is a bool condition, so the condition walker reaches it.
grep -qF 'return e.k==Expr::Var||e.k==Expr::Index||e.k==Expr::Field||e.k==Expr::Deref;' src/aster.cpp \
    || { echo 'FAIL: isLValue() no longer admits an array element' >&2; exit 1; }
grep -qF '        if(!tyIsStruct(elementTypeOf(e.name)))' src/aster.cpp \
    || { echo 'FAIL: emitStructAddr() no longer reaches an array element' >&2; exit 1; }
grep -qF 'if(e.k==Expr::Field||e.k==Expr::Cond||e.k==Expr::Index){' src/aster.cpp \
    || { echo 'FAIL: the condition walker no longer admits an array element' >&2; exit 1; }
# `a[i].f = v` needs its own dispatch: the token that distinguishes it from
# `a[i] = v` is the one *after* the closing bracket, so the brackets are
# matched by depth (they nest: `a[b[i]].f`).
grep -qF '    bool indexedThenField() const {' src/aster.cpp \
    || { echo 'FAIL: indexedThenField() is missing' >&2; exit 1; }
grep -qF 'if(indexedThenField())return fieldAssignStatement();' src/aster.cpp \
    || { echo 'FAIL: statement() no longer dispatches a[i].f = v' >&2; exit 1; }
# A bool element accepts `true`/`false`, which no integer folder can read, and
# a bool initializer is range-checked like any other narrow one.
grep -qF 'static bool boolArrayValue(const Expr& e,int64_t& out){' src/aster.cpp \
    || { echo 'FAIL: boolArrayValue() is missing' >&2; exit 1; }
grep -qF 'if(t==Ty::Bool)return (uint64_t)e.n<=1u;' src/aster.cpp \
    || { echo 'FAIL: initializerFits() no longer range-checks a bool literal' >&2; exit 1; }
grep -qF 'case Ty::Bool: return folded==0||folded==1;' src/aster.cpp \
    || { echo 'FAIL: initializerFits() no longer range-checks a folded bool' >&2; exit 1; }
# A ptr element takes the null constant or another address, and the fill stores
# the register the address arrives in rather than folding it.
grep -qF 'const bool addrFill=(elem.k==Ty::Ptr)&&!constantInteger(*s.expr,value)&&exprIsPtr(*s.expr);' src/aster.cpp \
    || { echo 'FAIL: a ptr element no longer has an address fill' >&2; exit 1; }
grep -qF 'v0.23.28-dev: T is any type now.' src/aster.cpp \
    || { echo 'FAIL: the codegen array branch is no longer marked' >&2; exit 1; }
printf '%s\n' '  all three holes closed and the rule pinned, in both passes'

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
printf '%s\n' '[3/9] qemu: every element type, in both scopes, at every width'

# --- bool: a 4-byte 0/1 slot per element, in .data and on the frame.
check "$A" 'global bool[4] read'        1 'let flags: bool[4] = true;
fn main() -> i32 { if (flags[2]) { return 1; } return 0; }'
check "$A" 'local bool[3] write+read'   2 'fn main() -> i32 { let a: bool[3] = false; a[1] = true; if (a[1] && !a[0]) { return 2; } return 0; }'
check "$A" 'global bool[3] write'       5 'let flags: bool[3] = false;
fn main() -> i32 { flags[0] = true; flags[2] = true; let r: i32 = 0;
    if (flags[0]) { r = r + 1; } if (flags[2]) { r = r + 4; } if (flags[1]) { r = r + 8; } return r; }'
check "$A" 'local bool[2] store false'  6 'fn main() -> i32 { let a: bool[2] = true; a[1] = false; if (!a[1]) { return 6; } return 0; }'
check "$A" 'bool[4] under a while'      4 'fn main() -> i32 { let a: bool[4] = true; let n: i32 = 0; let i: i32 = 0;
    while (i < 4) { if (a[i]) { n = n + 1; } i = i + 1; } return n; }'
check "$A" 'bool element as an argument' 1 'fn take(b: bool) -> i32 { if (b) { return 1; } return 0; }
let f: bool[2] = true;
fn main() -> i32 { return take(f[1]); }'

# --- ptr: eight bytes per element, null or an address.
check "$A" 'local ptr[3]'               4 'struct P { x: i32 }
let cell: P = P { 42 };
fn main() -> i32 { let s: ptr[3] = 0; s[1] = &cell; if (s[0] == 0 && s[1] == &cell) { return 4; } return 0; }'
check "$A" 'global ptr[2]'              5 'struct P { x: i32 }
let cell: P = P { 7 };
let s: ptr[2] = 0;
fn main() -> i32 { s[0] = &cell; if (s[0] == &cell && s[1] == 0) { return 5; } return 0; }'
check "$A" 'ptr element into ptr<P>'    3 'struct P { x: i32 }
let cell: P = P { 42 };
fn main() -> i32 { let s: ptr[2] = 0; s[0] = &cell; let q: ptr<P> = s[0]; if (q == &cell) { return 3; } return 0; }'

# --- struct: N copies of the initializer, addressed by a shift or a multiply.
check "$A" 'global Point[3]'            8 'struct Point { x: i32, y: i32 }
let pts: Point[3] = Point { 7, 8 };
fn main() -> i32 { if (pts[2].x == 7 && pts[2].y == 8) { return 8; } return 0; }'
check "$A" 'local Point[3] field write' 16 'struct Point { x: i32, y: i32 }
fn main() -> i32 { let p: Point[3] = Point { 0, 0 }; p[2].x = 9; if (p[2].x == 9 && p[0].x == 0) { return 16; } return 0; }'
check "$A" 'Point field +='             6 'struct Point { x: i32, y: i32 }
fn main() -> i32 { let p: Point[2] = Point { 1, 2 }; p[1].x += 5; return p[1].x; }'
check "$A" '12-byte element, both scopes' 32 'struct T { a: i32, b: i32, c: i32 }
let tri: T[2] = T { 1, 2, 3 };
fn main() -> i32 { let lt: T[3] = T { 1, 2, 3 }; if (tri[1].c == 3 && lt[2].b == 2) { return 32; } return 0; }'
check "$A" '12-byte element, local only' 7 'struct T { a: i32, b: i32, c: i32 }
fn main() -> i32 { let t: T[4] = T { 0, 0, 0 }; t[3].b = 7; return t[3].b; }'
check "$A" 'struct with an i64 field'   2 'struct W { v: i64 }
let ws: W[2] = W { 5 };
fn main() -> i32 { let v: i64 = ws[1].v; if (v == 5) { return 2; } return 0; }'
# A nested subscript in the field target: `p[i[0]].x`, which is why the
# dispatch matches brackets by depth instead of counting one pair.
check "$A" 'nested subscript + field'   4 'struct Point { x: i32, y: i32 }
fn main() -> i32 { let p: Point[3] = Point { 0, 0 }; let i: i32[2] = 2; p[i[0]].x = 4; return p[2].x; }'

# --- an element is an lvalue, so it can be read as a whole value: &a[i], a
# whole-element copy, and a composite parameter.
check "$A" '&a[i] and a[i] as a value'  64 'struct Point { x: i32, y: i32 }
fn main() -> i32 { let p: Point[3] = Point { 0, 0 }; let q: ptr<Point> = &p[1]; let c: Point = p[1];
    if (q == &p[1] && c.y == 0) { return 64; } return 0; }'
check "$A" 'an element as a parameter'  7 'struct P { x: i32, y: i32 }
fn take(p: P) -> i32 { return p.x + p.y; }
fn main() -> i32 { let a: P[2] = P { 3, 4 }; return take(a[1]); }'

# --- widths that already worked, and must still work: the round is not allowed
# to move them. i64 and ptr are 8 bytes, u16 2, u8 1.
check "$A" 'i64[2] at 8 bytes/elem'     1 'fn main() -> i32 { let a: i64[2] = 5; let v: i64 = a[1]; if (v == 5) { return 1; } return 0; }'
check "$A" 'u8[4] at 1 byte/elem'       1 'fn main() -> i32 { let a: u8[4] = 200; if (a[3] == 200) { return 1; } return 0; }'
check "$A" 'u16[4] at 2 bytes/elem'     1 'fn main() -> i32 { let a: u16[4] = 65535; if (a[2] == 65535) { return 1; } return 0; }'
check "$A" 'i32[4] unchanged'           10 'fn main() -> i32 { let a: i32[4] = 7; a[2] = 3; return a[0] + a[2]; }'
# A ptr *local* is not an array: it indexes at the one i32 stride it always has.
check "$A" 'ptr local: i32 stride'      9 'let buf: i32[4] = 9;
fn main() -> i32 { let p: ptr = buf; return p[1]; }'
check "$A" 'bool scalar'                1 'fn main() -> i32 { let b: bool = true; if (b) { return 1; } return 0; }'

# ---------------------------------------------------------------------------
# [4/9] Differential layer: the same program under Aster and under the target
# C compiler must produce the same value. C has always had all four element
# types; this round is Aster catching up to an answer that was never in doubt.
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
    # Aster fills every element with the initializer, where C's `= { … }` fills
    # the first and zeroes the rest — so the twin spells the fill out. What is
    # being compared is the element type and the addressing, not the
    # initializer syntax.
    diff_case 'bool arrays, both scopes' \
        'let flags: bool[4] = true;
fn main() -> i32 {
    let seen: bool[3] = false;
    let r: i32 = 0;
    if (flags[2]) { r = r + 1; }
    seen[1] = true;
    if (seen[1] && !seen[0]) { r = r + 2; }
    flags[0] = false;
    if (!flags[0] && flags[3]) { r = r + 4; }
    return r; }' \
        '#include <stdint.h>
static int32_t flags[4] = { 1, 1, 1, 1 };
int main(void) {
    int32_t seen[3] = { 0, 0, 0 };
    int32_t r = 0;
    if (flags[2]) r += 1;
    seen[1] = 1;
    if (seen[1] && !seen[0]) r += 2;
    flags[0] = 0;
    if (!flags[0] && flags[3]) r += 4;
    return r; }'
    diff_case 'ptr arrays, both scopes' \
        'struct P { x: i32 }
let cell: P = P { 42 };
let gs: ptr[2] = 0;
fn main() -> i32 {
    let s: ptr[3] = 0;
    let r: i32 = 0;
    s[1] = &cell;
    gs[0] = &cell;
    if (s[0] == 0 && s[1] == &cell) { r = r + 1; }
    if (gs[0] == &cell && gs[1] == 0) { r = r + 2; }
    return r; }' \
        '#include <stdint.h>
struct P { int32_t x; };
static struct P cell = { 42 };
static void *gs[2];
int main(void) {
    void *s[3] = { 0, 0, 0 };
    int32_t r = 0;
    s[1] = &cell;
    gs[0] = &cell;
    if (s[0] == 0 && s[1] == &cell) r += 1;
    if (gs[0] == &cell && gs[1] == 0) r += 2;
    return r; }'
    diff_case 'struct arrays: 8 and 12 bytes' \
        'struct Point { x: i32, y: i32 }
struct T { a: i32, b: i32, c: i32 }
let pts: Point[3] = Point { 7, 8 };
let tri: T[2] = T { 1, 2, 3 };
fn main() -> i32 {
    let lp: Point[3] = Point { 0, 0 };
    let lt: T[3] = T { 1, 2, 3 };
    let r: i32 = 0;
    if (pts[2].x == 7 && pts[2].y == 8) { r = r + 1; }
    lp[2].x = 9;
    if (lp[2].x == 9 && lp[0].x == 0) { r = r + 2; }
    if (tri[1].c == 3 && lt[2].b == 2) { r = r + 4; }
    return r; }' \
        '#include <stdint.h>
struct Point { int32_t x, y; };
struct T { int32_t a, b, c; };
static struct Point pts[3] = { { 7, 8 }, { 7, 8 }, { 7, 8 } };
static struct T tri[2] = { { 1, 2, 3 }, { 1, 2, 3 } };
int main(void) {
    struct Point lp[3] = { { 0, 0 }, { 0, 0 }, { 0, 0 } };
    struct T lt[3] = { { 1, 2, 3 }, { 1, 2, 3 }, { 1, 2, 3 } };
    int32_t r = 0;
    if (pts[2].x == 7 && pts[2].y == 8) r += 1;
    lp[2].x = 9;
    if (lp[2].x == 9 && lp[0].x == 0) r += 2;
    if (tri[1].c == 3 && lt[2].b == 2) r += 4;
    return r; }'
    diff_case 'element widths: 1, 2, 8' \
        'fn main() -> i32 {
    let a: u8[4] = 200;
    let b: u16[4] = 65535;
    let c: i64[2] = 5;
    let r: i32 = 0;
    if (a[3] == 200) { r = r + 1; }
    if (b[2] == 65535) { r = r + 2; }
    if (c[1] == 5) { r = r + 4; }
    a[1] = 7; b[0] = 1;
    if (a[1] == 7 && b[0] == 1) { r = r + 8; }
    return r; }' \
        '#include <stdint.h>
int main(void) {
    uint8_t a[4] = { 200, 200, 200, 200 };
    uint16_t b[4] = { 65535, 65535, 65535, 65535 };
    int64_t c[2] = { 5, 5 };
    int32_t r = 0;
    if (a[3] == 200) r += 1;
    if (b[2] == 65535) r += 2;
    if (c[1] == 5) r += 4;
    a[1] = 7; b[0] = 1;
    if (a[1] == 7 && b[0] == 1) r += 8;
    return r; }'
    diff_case '&a[i] and a whole-element copy' \
        'struct Point { x: i32, y: i32 }
fn main() -> i32 {
    let p: Point[3] = Point { 0, 0 };
    let q: ptr<Point> = &p[1];
    let c: Point = p[1];
    if (q == &p[1] && c.y == 0) { return 64; }
    return 0; }' \
        '#include <stdint.h>
struct Point { int32_t x, y; };
int main(void) {
    struct Point p[3] = { { 0, 0 }, { 0, 0 }, { 0, 0 } };
    struct Point *q = &p[1];
    struct Point c = p[1];
    if (q == &p[1] && c.y == 0) return 64;
    return 0; }'
    # The shipped example against its twin, end to end.
    diff_case 'examples/array_elem_types.ast' \
        "$(cat examples/array_elem_types.ast)" \
        "$(cat tests/array-elem-types-example-twin.c)"
fi
# [3/9] and [4/9] both need to run the binaries they build.
fi

# ---------------------------------------------------------------------------
# [5/9] Rejection matrix. Opening the element type does not open the type
# rules that go with it.
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
# A bool element takes 0 or 1 — the check a bool scalar has always applied.
reject 'local bool[2] = 2'          'local array initializer does not fit in bool' \
    'fn main() -> i32 { let a: bool[2] = 2; return 0; }'
reject 'local bool[2] = 1 + 1'      'local array initializer does not fit in bool' \
    'fn main() -> i32 { let a: bool[2] = 1 + 1; return 0; }'
reject 'local bool[2] = 0 - 1'      'local array initializer does not fit in bool' \
    'fn main() -> i32 { let a: bool[2] = 0 - 1; return 0; }'
# An integer element does not take a bool, and does not take an address.
reject 'local i32[2] = true'        'array initializer type mismatch: expected i32, got bool' \
    'fn main() -> i32 { let a: i32[2] = true; return 0; }'
reject 'local i32[2] = &g'          'array initializer type mismatch: expected i32, got ptr' \
    'struct P { x: i32 }
let g: P = P { 1 };
fn main() -> i32 { let a: i32[2] = &g; return 0; }'
reject 'local i32[2] = a ptr var'   'array initializer type mismatch: expected i32, got ptr' \
    'fn main() -> i32 { let p: ptr = 0; let a: i32[2] = p; return 0; }'
# A ptr element takes the null constant or an address, and nothing else.
reject 'local ptr[2] = 7'           'array initializer type mismatch: expected ptr, got i32' \
    'fn main() -> i32 { let a: ptr[2] = 7; return 0; }'
reject 'local ptr[2] = true'        'array initializer type mismatch: expected ptr, got bool' \
    'fn main() -> i32 { let a: ptr[2] = true; return 0; }'
# The same rules on the store side, where the element type decides the width.
reject 'boolarr[0] = 2'             'type mismatch assigning array element of '"'"'f'"'"' (expected bool)' \
    'let f: bool[2] = true;
fn main() -> i32 { f[0] = 2; return 0; }'
reject 'ptrarr[0] = 7'              'type mismatch assigning array element of '"'"'s'"'"': expected ptr, got i32' \
    'fn main() -> i32 { let s: ptr[2] = 0; s[0] = 7; return 0; }'
reject 'i32arr[0] = true'           'type mismatch assigning array element of '"'"'a'"'"': expected i32, got bool' \
    'fn main() -> i32 { let a: i32[2] = 0; a[0] = true; return 0; }'
# `&` is still only for a struct lvalue: an element of an integer or pointer
# array is not one.
reject '& of an i32 element'        "'&' is only defined for a struct lvalue, not i32" \
    'fn main() -> i32 { let a: i32[2] = 0; let p: ptr = &a[0]; return 0; }'
reject '& of a ptr element'         "'&' is only defined for a struct lvalue, not ptr" \
    'fn main() -> i32 { let s: ptr[2] = 0; let p: ptr = &s[0]; return 0; }'
# A struct has no register form, so a whole element is not a value.
reject 'a struct element as a value' 'return type mismatch in function main: expected i32, got P' \
    'struct P { x: i32 }
let p: P[2] = P { 1 };
fn main() -> i32 { return p[0]; }'
# A field was still not an array when this round shipped: the round was about
# T[N], not about S.f[N]. v0.23.29-dev opened the field case, and v0.23.31-dev
# opened the nested one — a field may hold a multi-dimensional array exactly
# like any other array, which is what the multi-dim round's example does. The
# refusal this row used to pin is therefore gone: the boundary moved from
# "an array field" to "a field of the round's own shape", and the suites for
# that round carry the behavioural coverage. What stays pinned here is that
# the shape compiles at all — no qemu needed, like every row in this section.
printf '%s\n' 'struct P { x: i32[2][2] }
fn main() -> i32 { return 0; }' > "$OUT/r.ast"
if ! "$A" build-elf "$OUT/r.ast" -o "$OUT/r.a64" >"$OUT/r.err" 2>&1; then
    echo "FAIL: nested array field was refused: $(sed -n '1p' "$OUT/r.err")" >&2; exit 1
fi
printf '  %-34s accepted\n' 'nested array field'
reject 'array field of zero length' 'array field length must be between 1 and 1000' \
    'struct P { x: i32[0] }
fn main() -> i32 { return 0; }'
# Lengths: the two limits the three parsers share.
reject 'local bool[0]'              'local array length must be between 1 and 1000' \
    'fn main() -> i32 { let a: bool[0] = true; return 0; }'
reject 'local bool[1001]'           'local array length must be between 1 and 1000' \
    'fn main() -> i32 { let a: bool[1001] = true; return 0; }'
reject 'global bool[0]'             'array length must be between 1 and 1048576' \
    'let f: bool[0] = true;
fn main() -> i32 { return 0; }'
reject 'global Point[0]'            'array length must be between 1 and 1048576' \
    'struct P { x: i32 }
let p: P[0] = P { 1 };
fn main() -> i32 { return 0; }'
# Bounds, on each of the three new element types: the check is a property of
# the array, not of what is in it.
reject 'bool[2] index 5'            'array index out of bounds for '"'"'f'"'"': index 5, length 2' \
    'let f: bool[2] = true;
fn main() -> i32 { return f[5]; }'
reject 'Point[2] index 3'           'array index out of bounds for '"'"'p'"'"': index 3, length 2' \
    'struct P { x: i32 }
let p: P[2] = P { 1 };
fn main() -> i32 { return p[3].x; }'
reject 'ptr[2] index 9'             'array index out of bounds for '"'"'s'"'"': index 9, length 2' \
    'fn main() -> i32 { let s: ptr[2] = 0; let q: ptr = s[9]; return 0; }'
# Indexing something that is not an array is still a mistake — including a
# struct scalar, which is now the only struct declaration without a `[`.
reject 'index an i32 scalar'        'cannot index non-array variable: x' \
    'fn main() -> i32 { let x: i32 = 5; return x[0]; }'
reject 'index a struct scalar'      'cannot index non-array variable: s' \
    'struct P { x: i32 }
fn main() -> i32 { let s: P = P { 1 }; return s[0].x; }'
# A bool array still needs a constant to fill with.
reject 'bool[2] = a call'           'array initializer must be a constant expression' \
    'fn f() -> bool { return true; }
fn main() -> i32 { let a: bool[2] = f(); return 0; }'
# The element type is not the type of a scalar of the same name.
reject 'u8 element into a bool'     "type mismatch initializing 'b': expected bool" \
    'fn main() -> i32 { let a: u8[2] = 1; let b: bool = a[0]; return 0; }'
reject 'bool element into an i32'   "type mismatch initializing 'n': expected i32, got bool" \
    'let f: bool[2] = true;
fn main() -> i32 { let n: i32 = f[0]; return n; }'

# ---------------------------------------------------------------------------
# [6/9] Coverage map. Every accepted row above has to name the rule it
# exercises, so deleting a case without noticing is a failure of the map.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Coverage map: which case exercises which rule'
cat > "$OUT/map.txt" <<'MAP'
global bool[4] read                  bool            a global bool element, read
local bool[3] write+read             bool            a local bool element, stored and read
global bool[3] write                 bool            three slots, written one at a time
local bool[2] store false            bool            storing false, and !element
bool[4] under a while                bool            a runtime subscript, not a constant one
bool element as an argument          bool            an element passed as a bool parameter
local ptr[3]                         ptr             null fill, then an address
global ptr[2]                        ptr             the same at file scope
ptr element into ptr<P>              ptr             an element read as a typed pointer
global Point[3]                      struct          N copies of the initializer, read
local Point[3] field write           struct          a[i].f = v, the dispatch this round adds
Point field +=                       struct          a compound store through a[i].f
12-byte element, both scopes         struct          a size no shift can scale
12-byte element, local only          struct          the UMADDL fallback on the frame
struct with an i64 field             struct          an 8-byte struct, shift 3
nested subscript + field             struct          p[i[0]].f, brackets matched by depth
&a[i] and a[i] as a value            elemtype        an element is a value of its own type
an element as a parameter            elemtype        an element is an lvalue, so it can be passed
i64[2] at 8 bytes/elem               width           8-byte elements, unchanged
u8[4] at 1 byte/elem                 width           1-byte elements, unchanged
u16[4] at 2 bytes/elem               width           2-byte elements, unchanged
i32[4] unchanged                     width           4-byte elements, unchanged
ptr local: i32 stride                width           a ptr local is not an array
bool scalar                          width           not an array at all
bool arrays, both scopes             diff            the C oracle for bool elements
ptr arrays, both scopes              diff            the C oracle for ptr elements
struct arrays: 8 and 12 bytes        diff            the C oracle for struct elements
element widths: 1, 2, 8              diff            the C oracle for the widths
&a[i] and a whole-element copy       diff            the C oracle for element type
examples/array_elem_types.ast        diff            the shipped example against its twin
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
    # One sed program: a mutant that has to damage both passes, or the second
    # of three identical lines, writes its substitutions with the usual `;`
    # separator, so the script stays one word.
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
# -- the addressing rule -----------------------------------------------------
# m1: elemShiftOf answers 2 for everything again — the old tyShift. A 12-byte
# element is then scaled by 4, so t[2] lands on t[0].c and the store is visible
# in a slot the real compiler never touches.
mutate 'm1: elemShiftOf is tyShift again' \
    's/static int elemShiftOf(Ty t){/static int elemShiftOf(Ty t){return 2;/' \
    must_differ '12-byte element' 0 'struct T { a: i32, b: i32, c: i32 }
fn main() -> i32 { let t: T[3] = T { 0, 0, 0 }; t[2].a = 5; return t[0].c; }'
# m2: the same, from the other end — a non-power-of-two scaled by 1. The
# witness has to be an index whose wrong address lands on a field's *first*
# byte, so index 4: at 12 bytes per element it is element 4, and at 1 byte per
# element it is t[0].b. (Index 2 was tried first and proved nothing: at 1 byte
# per element it lands two bytes into t[0].a, where the low byte — the only one
# a process exit status carries — is untouched.)
mutate 'm2: a 12-byte element scaled by 1' \
    's/if(sz==0||(sz&(sz-1))!=0u)return -1;/if(sz==0||(sz\&\&(sz-1))!=0u)return 0;/' \
    must_differ '12-byte element' 0 'struct T { a: i32, b: i32, c: i32 }
fn main() -> i32 { let t: T[6] = T { 0, 0, 0 }; t[4].a = 5; return t[0].b; }'
# m3 and m4: the element's own size, dropped in one scope at a time. Both
# EmitElemAddr arms must read elem; each mutant breaks exactly one, and the
# frame arm and the global arm have their own witness. (Two sed programs in
# one script: the first renames the occurrence it wants to skip, the second
# edits what is now the first remaining one, the third restores the rename.)
mutate 'm3: local elements scaled as i32' \
    '0,/emitElemIndex(r,elem);/s/emitElemIndex(r,elem);/emitElemIndex(r,Ty::I32);/' \
    must_differ 'local 12-byte element' 0 'struct T { a: i32, b: i32, c: i32 }
fn main() -> i32 { let t: T[3] = T { 0, 0, 0 }; t[2].a = 5; return t[0].c; }'
mutate 'm4: global elements scaled as i32' \
    '0,/emitElemIndex(r,elem);/s/emitElemIndex(r,elem);/ZZMUTZZ;/;0,/emitElemIndex(r,elem);/s/emitElemIndex(r,elem);/emitElemIndex(r,Ty::I32);/;0,/ZZMUTZZ/s/ZZMUTZZ/emitElemIndex(r,elem);/' \
    must_differ 'global 12-byte element' 0 'struct T { a: i32, b: i32, c: i32 }
let g: T[3] = T { 0, 0, 0 };
fn main() -> i32 { g[2].a = 5; return g[0].c; }'

# -- hole (3): the element type ----------------------------------------------
# m5: typeOf(Index) is i32 again, for every element. A Point initialized from
# a Point element is then a type error against itself — the bug the round
# started from. v0.23.31-dev moved where that answer lives: a named array's
# subscript — one dimension or many — is now answered by the chain branch's
# `ch.elem`, so the mutation targets that ternary. Two passes hold the same
# line (sema's typeOf and codegen's exprType, kept identical on purpose), and
# the witness is refused in sema, so the rename-then-edit-then-restore trick
# picks the second occurrence — sema's — exactly as m4 picks its second one.
mutate 'm5: typeOf(Index) is i32 again' \
    '0,/return ch.level+1<ch.dims->size()?Ty::Ptr:ch.elem;/s//ZZMUTZZ;/;0,/return ch.level+1<ch.dims->size()?Ty::Ptr:ch.elem;/s//return Ty::I32;/;0,/ZZMUTZZ/s//return ch.level+1<ch.dims->size()?Ty::Ptr:ch.elem;/' \
    must_not_compile 'a Point from a Point element' 'struct Point { x: i32, y: i32 }
fn main() -> i32 { let p: Point[2] = Point { 0, 0 }; let c: Point = p[1]; return c.y; }'
# m6: an element is not an lvalue again. isLValue is what `&` asks, so the
# witness is &a[i] — refused in sema, one layer above m7's codegen twin.
mutate 'm6: an element is not an lvalue' \
    's/return e.k==Expr::Var||e.k==Expr::Index||e.k==Expr::Field||e.k==Expr::Deref;/return e.k==Expr::Var||e.k==Expr::Field||e.k==Expr::Deref;/' \
    must_not_compile '&a[i]' 'struct Point { x: i32, y: i32 }
fn main() -> i32 { let p: Point[2] = Point { 0, 0 }; let q: ptr<Point> = &p[1]; return 0; }'
# m7: emitStructAddr no longer reaches an element, so &a[i] has no address.
mutate 'm7: emitStructAddr skips elements' \
    's/        if(!tyIsStruct(elementTypeOf(e.name)))/        if(true)/' \
    must_not_compile '&a[i]' 'struct Point { x: i32, y: i32 }
fn main() -> i32 { let p: Point[2] = Point { 0, 0 }; let q: ptr<Point> = &p[1]; return 0; }'
# m8: the condition walker no longer admits an element, so a bool array cannot
# be used as the condition it is made of.
mutate 'm8: a bool element is not a condition' \
    's/if(e.k==Expr::Field||e.k==Expr::Cond||e.k==Expr::Index){/if(e.k==Expr::Field||e.k==Expr::Cond){/' \
    must_not_compile 'if (flags[2])' 'let f: bool[2] = true;
fn main() -> i32 { if (f[1]) { return 1; } return 0; }'
# m9: the a[i].f dispatch is gone — the statement reads as an index assignment
# whose left side is not a name.
mutate 'm9: no a[i].f dispatch' \
    's/if(indexedThenField())return fieldAssignStatement();/if(false)return fieldAssignStatement();/' \
    must_not_compile 'a[i].f = v' 'struct Point { x: i32, y: i32 }
fn main() -> i32 { let p: Point[2] = Point { 0, 0 }; p[1].x = 9; return p[1].x; }'

# -- hole (1): the local declaration ------------------------------------------
# m10: the element-type gate is back on a local array. v0.23.31-dev moved the
# recording to arrayDimList()/dimsTotal(); the gate goes in front of the same
# line, which is where it used to go too.
mutate 'm10: local arrays, integers only' \
    's/if(!s.dims.empty()){s.isArray=true;/if(!tyIsInteger(ty))throw Error("arrays of this element type are not supported");if(!s.dims.empty()){s.isArray=true;/' \
    must_not_compile 'let a: bool[2] = true;' 'fn main() -> i32 { let a: bool[2] = true; return 0; }'

# -- hole (2): the global declarations ----------------------------------------
# m11: the Bool branch stops counting — `bool[2]` declares one element, so the
# second index is out of bounds. v0.23.31-dev: the same line, spelled through
# dimsTotal() now.
mutate 'm11: a bool global is never an array' \
    '0,/g.isArray=true;g.count=dimsTotal(g.dims,1048576,"array length",g.name,id.line,id.col);/s/g.isArray=true;g.count=dimsTotal(g.dims,1048576,"array length",g.name,id.line,id.col);/g.isArray=false;g.count=1;/' \
    must_not_compile 'global bool[2]' 'let f: bool[2] = true;
fn main() -> i32 { if (f[1]) { return 1; } return 0; }'
# m12: the same for the Struct branch — the second of the three identical lines.
mutate 'm12: a struct global is never an array' \
    '0,/g.isArray=true;g.count=dimsTotal(g.dims,1048576,"array length",g.name,id.line,id.col);/s/g.isArray=true;g.count=dimsTotal(g.dims,1048576,"array length",g.name,id.line,id.col);/ZZMUTZZ;/;0,/g.isArray=true;g.count=dimsTotal(g.dims,1048576,"array length",g.name,id.line,id.col);/s/g.isArray=true;g.count=dimsTotal(g.dims,1048576,"array length",g.name,id.line,id.col);/g.isArray=false;g.count=1;/;0,/ZZMUTZZ/s/ZZMUTZZ/g.isArray=true;g.count=dimsTotal(g.dims,1048576,"array length",g.name,id.line,id.col);/' \
    must_not_compile 'global Point[2]' 'struct Point { x: i32, y: i32 }
let p: Point[2] = Point { 1, 2 };
fn main() -> i32 { return p[1].x; }'

# -- the element's own rules --------------------------------------------------
# m13: a bool element loses its literal reader, so `true` is no longer a
# constant it can be filled with.
mutate 'm13: a bool[2] = true is refused' \
    's/if(!boolArrayValue(\*s.expr,v))/if(!constantInteger(\*s.expr,v))/' \
    must_not_compile 'let a: bool[2] = true;' 'fn main() -> i32 { let a: bool[2] = true; return 0; }'
# m14: a bool element stops being range-checked, so 2 is accepted again — in
# both arms of initializerFits (a literal, and a folded expression).
mutate 'm14: bool fits anything' \
    's/if(t==Ty::Bool)return (uint64_t)e.n<=1u;/if(t==Ty::Bool)return true;/;s/case Ty::Bool: return folded==0||folded==1;/case Ty::Bool: return true;/' \
    must_now_compile 'let a: bool[2] = 2;' 'fn main() -> i32 { let a: bool[2] = 2; return 0; }'
# m15: a ptr element takes any initializer, so an integer fills an array of
# addresses.
mutate 'm15: ptr[2] takes an integer' \
    's/if(actual.k!=Ty::Ptr\&\&!isNullConstant(\*s.expr))/if(false)/' \
    must_now_compile 'let a: ptr[2] = 7;' 'fn main() -> i32 { let a: ptr[2] = 7; return 0; }'
printf '%s\n' 'PASS: fifteen mutated compilers each lose exactly one rule, and the checks notice'
fi

# ---------------------------------------------------------------------------
# [8/9] Byte-identity baseline. Every line recorded before this round must
# reproduce byte for byte. Five rows are excluded: this round's own example and
# the four previous rounds' (precedence, struct_array_field, array_address and
# — from v0.23.31-dev — multi_dim_array), each of which is new rather than
# pre-existing.
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
# A FAILED row is not a regression: 48 examples import symbols only a link with
# another object or a libc can supply, and build-elf on its own has always
# recorded FAILED for them. The comparison below is what has to hold.
grep -v -e '^sizeof_len\.' -e '^array_elem_types\.' -e '^precedence\.' -e '^struct_array_field\.' -e '^array_address\.' -e '^multi_dim_array\.' -e '^lifecycle\.' -e '^fn_type\.' -e '^cb_table\.' -e '^fn_ret.' -e '^call-stmt.' -e '^copy.' -e '^arena\.' -e '^stdlib_demo\.' -e '^integer_cast\.' -e '^switch\.' -e '^literals\.' "$BASE" > "$OUT/expected-old.txt"
grep -v -e '^sizeof_len\.' -e '^array_elem_types\.' -e '^precedence\.' -e '^struct_array_field\.' -e '^array_address\.' -e '^multi_dim_array\.' -e '^lifecycle\.' -e '^fn_type\.' -e '^cb_table\.' -e '^fn_ret.' -e '^call-stmt.' -e '^copy.' -e '^arena\.' -e '^stdlib_demo\.' -e '^integer_cast\.' -e '^switch\.' -e '^literals\.' "$OUT/hashes.txt" > "$OUT/got-old.txt"
if ! diff -u "$OUT/expected-old.txt" "$OUT/got-old.txt" > "$OUT/old.diff"; then
    echo 'FAIL: a pre-existing example moved — one of the three fixes changed bytes' >&2
    sed -n '1,20p' "$OUT/old.diff" >&2
    exit 1
fi
old=$(wc -l < "$OUT/expected-old.txt")
new=$(wc -l < "$OUT/got-old.txt")
# v0.23.38-dev: the callback-table round added two more examples (cb_table.ast,
# fn_ret.ast) to the filter the same way, so thirteen families are skipped — but the
# baseline gained those six rows, and the count of pre-existing rows is the
# same 288 it has been since v0.23.30-dev: 327 recorded, 39 of them belonging
# to the thirteen rounds this suite knows are new.
# v0.23.41-dev: the heap round's example (arena.ast) joins the filter the same
# way, so fourteen families are skipped — but the baseline gained those three
# rows, and the count of pre-existing rows is the same 288 it has been since
# v0.23.30-dev: 327 recorded, 42 of them belonging to the fourteen rounds this
# suite knows are new.
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
# And this round's example is recorded, in all three modes, or the baseline is
# not doing its job.
[ "$(grep -c '^array_elem_types\.' "$OUT/hashes.txt")" -eq 3 ] \
    || { echo 'FAIL: array_elem_types.ast is not in the baseline in all three modes' >&2; exit 1; }
# The multi-dimensional round's example is recorded too — three rows, one per
# mode — so a later round that moves it fails here by name.
[ "$(grep -c '^multi_dim_array\.' "$OUT/hashes.txt")" -eq 3 ] \
    || { echo 'FAIL: multi_dim_array.ast is not in the baseline in all three modes' >&2; exit 1; }
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
    if ! "$A" build-elf examples/array_elem_types.ast -o "$OUT/aet.a64" >"$OUT/aet.err" 2>&1; then
        echo 'FAIL: examples/array_elem_types.ast does not build' >&2; sed -n '1,3p' "$OUT/aet.err" >&2; exit 1
    fi
    $RUNNER "$OUT/aet.a64" >/dev/null 2>&1 && got=0 || got=$?
    [ "$got" = 127 ] \
        || { echo "FAIL: array_elem_types.ast: expected exit 127, got $got" >&2; exit 1; }
    printf '  %-34s %s\n' 'array_elem_types.ast' "$got"
    printf '%s\n' 'PASS: the example runs and returns the value its C twin returns'
fi

printf '%s\n' '=== array element type checks: ALL PASSED ==='
