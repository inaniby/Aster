#!/bin/sh
# v0.23.31-dev checks for multi-dimensional arrays (`T[N][M]`, and `T[N][M][K]`).
# Until this round a subscript was the last thing you could do to an array:
# `a[i]` was the element, full stop. C has never worked that way — `a[i]` on
# an `int[2][3]` is a *row*, the address of three ints, and `a[i][j]` is the
# element. This round makes Aster agree, and it does it without a new type:
# an array name already decays to a ptr, so a row address is the same decay
# one level in. Five places had to change:
#
#   1. `arrayDimList()` reads one `[N]` per dimension at every declaration
#      site (local, global in all three branches, struct field), and
#      `dimsTotal()` bounds the *total* element count the way the
#      one-dimensional spelling always did. `count` stays the total, so the
#      frame reservation, the broadcast initializer, `.data`/`.bss` sizing and
#      `layoutStruct` are untouched.
#   2. `indexSubscripts()` (the assignment target) and `postfix()` (every
#      expression) agree on one chain shape: the array's name rides on the
#      innermost `Index` node, and each subscript above it is another `Index`.
#      One subscript still comes back as itself, so the one-dimensional path
#      is unchanged in every respect.
#   3. `Sema` answers "which dimension does this subscript address?" by
#      walking the chain (`indexChainOf`): level k's bounds come from
#      `dims[k]`, the answer is a row (a ptr) unless this is the innermost
#      subscript, and every subscript in the chain is checked — an inner
#      `a[true][0]` is as illegal as an outer one.
#   4. `Codegen`'s `emitIndexAddr()` computes every subscript *first*, then
#      materializes the base address (evaluating a subscript can clobber X16,
#      where the base is about to go), then scales each subscript by the
#      product of the dimensions below it — `emitElemStride` for the power-of-
#      two strides, a 32-bit materialize plus `UMADLL` for the rest.
#   5. A chain that stops short of the elements addresses a row, and a store
#      to a row is refused in both assignment forms — including the
#      single-subscript spelling, which arrives from the parser as itself and
#      is therefore told apart by the subscript count the parser records.
#
# None of it can move the bytes of a program that compiled before: a
# one-dimensional program's every subscript still walks `emitElemAddr` with
# the same stride, because the chain path is only entered when a second
# subscript exists. Layer [8/9] asserts all 288 pre-existing baseline rows
# reproduce byte for byte.
#
# The behavioural layers need qemu (or an AArch64 host); the differential layer
# additionally needs $HOSTCC to emit AArch64 ELF. Neither is required to
# *build*, so each layer that cannot run says SKIP and the rest still runs.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-multi-dim-array-checks}
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
    printf '%s\n' 'SKIP: multi-dim-array-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each change is pinned where it was made, so a regression
# that quietly reopens one fails here rather than by a behavioural case.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: the five changes'

# (1) One `[N]` per dimension, and the leading `[` is consumed — the bug that
# made every array declaration (one-dimensional included) unparseable until it
# was fixed.
grep -qF "++p;                                                    // the '['" src/aster.cpp \
    || { echo "FAIL: arrayDimList() no longer consumes the leading '['" >&2; exit 1; }
grep -qF 'std::vector<uint32_t> arrayDimList(const std::string& what,uint32_t limit,const std::string& subject){' src/aster.cpp \
    || { echo 'FAIL: arrayDimList() is missing' >&2; exit 1; }
grep -qF 'uint32_t dimsTotal(std::vector<uint32_t>& dims,uint32_t limit,const std::string& what,' src/aster.cpp \
    || { echo 'FAIL: dimsTotal() is missing' >&2; exit 1; }
# `count` is still the total element count — that is what kept the frame
# reservation and the initializer broadcast unchanged.
grep -qF 's.count=dimsTotal(s.dims,1000,"local array length",id.s,id.line,id.col);' src/aster.cpp \
    || { echo 'FAIL: a local multi-dimensional declaration no longer totals its count' >&2; exit 1; }
[ "$(grep -c 'g.isArray=true;g.count=dimsTotal(g.dims,1048576,"array length",g.name,id.line,id.col);' src/aster.cpp)" -eq 3 ] \
    || { echo 'FAIL: globalDeclaration() must open a dimension list in all three branches' >&2; exit 1; }
grep -qF 's.fields.push_back({fn.s,fty,0,flen,std::move(dims),std::move(fieldFuncSig),fieldIsFunc});' src/aster.cpp \
    || { echo 'FAIL: structDeclaration() no longer records a field dimension list' >&2; exit 1; }
# The main-program registration feeds Sema's global dimension map.
grep -qF 'arrayDims[g.name]=g.dims;' src/aster.cpp \
    || { echo 'FAIL: a multi-dimensional global is not registered with its dimensions' >&2; exit 1; }

# (2) One chain shape, and the name rides on the innermost node.
grep -qF 'E indexSubscripts(const std::string& name,unsigned line,unsigned col,unsigned& subs){' src/aster.cpp \
    || { echo 'FAIL: indexSubscripts() no longer reports its subscript count' >&2; exit 1; }
grep -qF 'if(cur().k!=TK::LBracket)return first;' src/aster.cpp \
    || { echo 'FAIL: indexSubscripts() no longer keeps the one-subscript shape' >&2; exit 1; }
grep -qF 'if(x->k!=Expr::Field&&x->k!=Expr::Index&&x->k!=Expr::AddrOf)' src/aster.cpp \
    || { echo 'FAIL: postfix() no longer allows a [ after a Field, an Index or an AddrOf' >&2; exit 1; }

# (3) Sema: the chain walk, and the per-level checks it now performs.
grep -qF 'struct IndexChain {' src/aster.cpp \
    || { echo 'FAIL: IndexChain is missing' >&2; exit 1; }
grep -qF 'bool indexChainOf(const Expr& e,IndexChain& out){' src/aster.cpp \
    || { echo 'FAIL: Sema indexChainOf() is missing' >&2; exit 1; }
grep -qF 'bool indexChainIsRow(const Expr& e,std::string* what=nullptr){' src/aster.cpp \
    || { echo 'FAIL: indexChainIsRow() is missing' >&2; exit 1; }
grep -qF 'const std::vector<uint32_t>* arrayDimsOfName(const std::string& name){' src/aster.cpp \
    || { echo 'FAIL: arrayDimsOfName() is missing' >&2; exit 1; }
# Every subscript in the chain is checked, not just the outermost one.
grep -qF 'for(uint32_t l=ch.level+1;l-->0;){' src/aster.cpp \
    || { echo 'FAIL: typeOf(Index) no longer checks every subscript in the chain' >&2; exit 1; }
grep -qF 'checkArrayBounds((*ch.dims)[l],index);' src/aster.cpp \
    || { echo 'FAIL: a chain subscript is no longer bounds-checked against its own dimension' >&2; exit 1; }
# The one-dimensional answer is unchanged: the named overload, with the name.
grep -qF 'if(l==0&&!n->name.empty())checkArrayBounds(n->name,index);' src/aster.cpp \
    || { echo 'FAIL: a one-dimensional subscript lost its named bounds diagnostic' >&2; exit 1; }
# The binding carries the dimensions; `len` is still the outer length.
# v0.23.37-dev: the struct gained a function signature beside these fields
# (FuncSig funcSig; bool isFunc) and became multi-line — the head line is
# pinned here, the new fields by function-type-checks.sh's own guard.
grep -qF 'struct Binding { Ty ty=Ty::I32; uint32_t len=0; Ty elem=Ty::I32; std::vector<uint32_t> dims;' src/aster.cpp \
    || { echo 'FAIL: Sema::Binding no longer carries the dimension list' >&2; exit 1; }

# (4) Codegen: the address computation, in the order that keeps X16 safe.
grep -qF 'void emitIndexAddr(const Expr& e){' src/aster.cpp \
    || { echo 'FAIL: emitIndexAddr() is missing' >&2; exit 1; }
grep -qF 'void emitElemStride(int idxReg,uint64_t stride){' src/aster.cpp \
    || { echo 'FAIL: emitElemStride() is missing' >&2; exit 1; }
grep -qF 'std::map<int,std::vector<uint32_t>> slotDims;' src/aster.cpp \
    || { echo 'FAIL: Codegen no longer remembers a local array dimension list' >&2; exit 1; }
grep -qF 'const std::map<std::string,std::vector<uint32_t>>& globalArrayDims;' src/aster.cpp \
    || { echo 'FAIL: Codegen no longer receives the global dimension map' >&2; exit 1; }
grep -qF 'localArrayLength[slot]=s.dims[0];slotDims[slot]=s.dims;' src/aster.cpp \
    || { echo 'FAIL: a local array registration no longer records its dimensions' >&2; exit 1; }
# Subscripts first, base address after — the order the X16 rule requires.
grep -qF 'const unsigned levels=depth+1;' src/aster.cpp \
    || { echo 'FAIL: emitIndexAddr() no longer counts the subscripts it was given' >&2; exit 1; }
grep -qF 'for(size_t k=levels;k<dims->size();++k)stride*=(*dims)[k];' src/aster.cpp \
    || { echo 'FAIL: a short chain no longer strides by the dimensions below it' >&2; exit 1; }

# (5) A row is not a store target, in both assignment forms, and a single
# subscript is told apart from a chain by the count the parser recorded.
grep -qF 'if(rowWhat.empty()&&s.subs<2){' src/aster.cpp \
    || { echo 'FAIL: the single-subscript row store is no longer refused' >&2; exit 1; }
grep -qF 'unsigned subs=1;' src/aster.cpp \
    || { echo 'FAIL: Stmt no longer records its subscript count' >&2; exit 1; }
grep -qF "if(e.name.empty())" src/aster.cpp \
    || { echo 'FAIL: a two-level subscript on a ptr lost its diagnostic' >&2; exit 1; }
printf '%s\n' '  all five changes pinned, in both passes'

# ---------------------------------------------------------------------------
# [3/9] qemu: every shape of chain, with a hand-derived expected exit status.
# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] qemu: every chain shape, hand-derived'
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
    printf '  %-34s %s\n' "$name" "$got"
}
A=$OUT/aster
check "$A" '2-D element write and read'   42 'fn main() -> i32 { let a: i32[2][3] = 0; a[1][2] = 42; return a[1][2]; }'
check "$A" 'row address to a function'    15 'fn rowSum(p: ptr, n: i32) -> i32 { let t: i32 = 0; let i: i32 = 0; while (i < n) { t = t + p[i]; i = i + 1; } return t; }
fn main() -> i32 { let a: i32[2][3] = 0; a[0][0] = 1; a[0][1] = 2; a[0][2] = 3; a[1][0] = 4; a[1][1] = 5; a[1][2] = 6; return rowSum(a[1], 3); }'
check "$A" 'global 2-D grid'              22 'let g: i32[2][3] = 0;
fn main() -> i32 { g[1][2] = 22; if (g[0][0] == 0 && g[1][2] == 22) { return 22; } return 0; }'
check "$A" '3-D walk'                      8 'fn main() -> i32 { let c: i32[2][2][2] = 0; c[1][1][1] = 8; c[0][1][0] = 3; if (c[1][1][1] == 8 && c[0][1][0] == 3) { return 8; } return 0; }'
check "$A" '3-D row to a function'        11 'fn rowSum(p: ptr, n: i32) -> i32 { let t: i32 = 0; let i: i32 = 0; while (i < n) { t = t + p[i]; i = i + 1; } return t; }
fn main() -> i32 { let c: i32[2][2][2] = 0; c[1][0][0] = 5; c[1][0][1] = 6; return rowSum(c[1][0], 2); }'
check "$A" 'struct field 2-D'              6 'struct Grid { cells: i32[2][3] }
fn main() -> i32 { let g: Grid; g.cells[1][2] = 6; g.cells[0][1] = 2; if (g.cells[1][2] == 6 && g.cells[0][1] == 2) { return 6; } return 0; }'
check "$A" 'i64 grid, stride 24'          88 'fn main() -> i32 { let w: i64[2][3] = 0; w[1][2] = 600; w[0][0] = 100; if (w[1][2] == 600 && w[0][0] == 100) { return 88; } return 0; }'
check "$A" 'u8 grid, stride 1'             5 'fn main() -> i32 { let n: u8[2][3] = 0; n[1][1] = 5; if (n[1][1] == 5 && n[0][2] == 0) { return 5; } return 0; }'
check "$A" 'computed subscripts'          61 'fn main() -> i32 { let a: i32[2][3] = 0; let i: i32 = 0; while (i < 2) { let j: i32 = 0; while (j < 3) { a[i][j] = i * 3 + j + 1; j = j + 1; } i = i + 1; } return a[1][2] * 10 + a[0][0]; }'
check "$A" 'a row is a ptr value'          4 'fn main() -> i32 { let a: i32[2][3] = 0; a[1][0] = 4; let p: ptr = a[1]; return p[0]; }'
check "$A" 'compound assign on 2-D'       42 'fn main() -> i32 { let a: i32[2][3] = 0; a[1][2] = 40; a[1][2] += 2; return a[1][2]; }'
check "$A" '2-D inside for loops'          9 'fn main() -> i32 { let a: i32[2][3] = 0; let s: i32 = 0; for (let i: i32 = 0; i < 2; i = i + 1) { for (let j: i32 = 0; j < 3; j = j + 1) { a[i][j] = i + j; s = s + a[i][j]; } } return s; }'
else
    printf '%s\n' '  SKIP: the behavioural cases need qemu to run'
fi

# ---------------------------------------------------------------------------
# [4/9] Differential: Aster against the target C compiler, which has always
# had this exact decay. No expectation here is hand-computed.
# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] Differential: Aster vs the target C compiler'
if [ "$have_qemu" = yes ] && [ "$have_cc" = yes ]; then
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
    diff_case '2-D and 3-D, rows to a function' \
        'fn rowSum(p: ptr, n: i32) -> i32 { let t: i32 = 0; let i: i32 = 0; while (i < n) { t = t + p[i]; i = i + 1; } return t; }
fn main() -> i32 {
    let a: i32[3][4] = 0;
    let i: i32 = 0;
    while (i < 3) { let j: i32 = 0; while (j < 4) { a[i][j] = i * 4 + j; j = j + 1; } i = i + 1; }
    let c: i32[2][3][2] = 0;
    c[1][2][1] = 77; c[0][1][0] = 5;
    if (rowSum(a[2], 4) == 38 && rowSum(a[0], 4) == 6) { if (c[1][2][1] == 77 && c[0][1][0] == 5) { return 33; } }
    return 0; }' \
        '#include <stdint.h>
static int32_t rowSum(int32_t *p, int32_t n) { int32_t t = 0; for (int32_t i = 0; i < n; i++) t += p[i]; return t; }
int main(void) {
    int32_t a[3][4];
    for (int32_t i = 0; i < 3; i++) for (int32_t j = 0; j < 4; j++) a[i][j] = i * 4 + j;
    int32_t c[2][3][2] = {0};
    c[1][2][1] = 77; c[0][1][0] = 5;
    if (rowSum(a[2], 4) == 38 && rowSum(a[0], 4) == 6) { if (c[1][2][1] == 77 && c[0][1][0] == 5) return 33; }
    return 0; }'
    diff_case 'i64 and u8 grids, struct field grid' \
        'struct Grid { cells: i32[2][3] }
fn main() -> i32 {
    let w: i64[2][3] = 0;
    w[0][2] = 300; w[1][0] = 400; w[1][2] = 600;
    let n: u8[3][2] = 0;
    n[2][1] = 250; n[0][0] = 1;
    let g: Grid;
    g.cells[1][1] = 55; g.cells[0][2] = 3;
    if (w[0][2] + w[1][0] == 700 && w[1][2] == 600) { if (n[2][1] == 250 && n[0][0] == 1) { if (g.cells[1][1] == 55 && g.cells[0][2] == 3) { return 71; } } }
    return 0; }' \
        '#include <stdint.h>
struct Grid { int32_t cells[2][3]; };
int main(void) {
    int64_t w[2][3] = {0};
    w[0][2] = 300; w[1][0] = 400; w[1][2] = 600;
    uint8_t n[3][2] = {0};
    n[2][1] = 250; n[0][0] = 1;
    struct Grid g;
    g.cells[1][1] = 55; g.cells[0][2] = 3;
    if (w[0][2] + w[1][0] == 700 && w[1][2] == 600) { if (n[2][1] == 250 && n[0][0] == 1) { if (g.cells[1][1] == 55 && g.cells[0][2] == 3) return 71; } }
    return 0; }'
    diff_case 'global grid, both scopes, shared rows' \
        'let g: i32[2][3] = 0;
fn bump(p: ptr, n: i32) -> i32 { let i: i32 = 0; while (i < n) { p[i] = p[i] + 1; i = i + 1; } return p[0]; }
fn main() -> i32 {
    let i: i32 = 0;
    while (i < 2) { let j: i32 = 0; while (j < 3) { g[i][j] = i * 3 + j; j = j + 1; } i = i + 1; }
    let z: i32 = bump(g[1], 3);
    if (z == 4 && g[1][0] == 4 && g[1][2] == 6 && g[0][2] == 2) { return 19; }
    return 0; }' \
        '#include <stdint.h>
static int32_t g[2][3];
static int32_t bump(int32_t *p, int32_t n) { for (int32_t i = 0; i < n; i++) p[i] = p[i] + 1; return p[0]; }
int main(void) {
    for (int32_t i = 0; i < 2; i++) for (int32_t j = 0; j < 3; j++) g[i][j] = i * 3 + j;
    int32_t z = bump(g[1], 3);
    if (z == 4 && g[1][0] == 4 && g[1][2] == 6 && g[0][2] == 2) return 19;
    return 0; }'
    # The shipped example against its twin, end to end.
    diff_case 'examples/multi_dim_array.ast' \
        "$(cat examples/multi_dim_array.ast)" \
        "$(cat tests/multi-dim-array-twin.c)"
else
    printf '%s\n' '  SKIP: the differential layer needs qemu and a target C compiler'
fi

# ---------------------------------------------------------------------------
# [5/9] Rejection matrix. Opening the second subscript does not open the rules
# that go with it, and several of those rules are new.
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
A=$OUT/aster
reject '1-D then two subscripts'    "too many subscripts for 'a': it has 1 dimension" \
    'fn main() -> i32 { let a: i32[3] = 0; return a[0][1]; }'
reject '2-D then three subscripts'  "too many subscripts for 'a': it has 2 dimensions" \
    'fn main() -> i32 { let a: i32[2][3] = 0; return a[0][1][0]; }'
reject 'row store, single subscript' "cannot assign to 'a'[i]: it addresses a row, not an element" \
    'fn main() -> i32 { let a: i32[2][3] = 0; a[1] = 5; return 0; }'
reject 'row compound store'         "cannot assign to 'a'[i]: it addresses a row, not an element" \
    'fn main() -> i32 { let a: i32[2][3] = 0; a[1] += 5; return 0; }'
reject 'row store on 3-D'           "cannot assign to 'a'[i]: it addresses a row, not an element" \
    'fn main() -> i32 { let a: i32[2][2][2] = 0; a[0][1] = 5; return 0; }'
reject 'row store, field'           "cannot assign to field 'xs'[i]: it addresses a row, not an element" \
    'struct S { xs: i32[2][3] }
fn main() -> i32 { let s: S; s.xs[0] = 5; return 0; }'
reject 'row store in a for step'    "cannot assign to 'a'[i]: it addresses a row, not an element" \
    'fn main() -> i32 { let a: i32[2][3] = 0; for (let i: i32 = 0; i < 2; a[1] = 5) { } return 0; }'
reject 'row into an i32'            'type mismatch initializing '"'"'x'"'"': expected i32, got ptr' \
    'fn main() -> i32 { let a: i32[2][3] = 0; let x: i32 = a[1]; return x; }'
reject 'row into an i32 parameter'  'argument type mismatch calling f at argument 1: expected i32' \
    'fn f(n: i32) -> i32 { return n; }
fn main() -> i32 { let a: i32[2][3] = 0; return f(a[1]); }'
reject 'two levels on a ptr'        'pointer indexing is not supported yet' \
    'fn main() -> i32 { let p: ptr = 0; return p[0][1]; }'
reject 'bool subscript, outer'      'cannot use a bool value in an array index' \
    'fn main() -> i32 { let a: i32[2][3] = 0; return a[true][0]; }'
reject 'bool subscript, inner'      'cannot use a bool value in an array index' \
    'fn main() -> i32 { let a: i32[2][3] = 0; return a[0][true]; }'
reject 'outer subscript out of bounds' "array index out of bounds for 'a': index 2, length 2" \
    'fn main() -> i32 { let a: i32[2][3] = 0; return a[2][0]; }'
reject 'inner subscript out of bounds' 'array index out of bounds: index 3, length 3' \
    'fn main() -> i32 { let a: i32[2][3] = 0; return a[0][3]; }'
reject 'negative subscript'         "array index out of bounds for 'a': index -1, length 2" \
    'fn main() -> i32 { let a: i32[2][3] = 0; return a[0 - 1][0]; }'
reject 'zero dimension'             'local array length must be between 1 and 1000: a' \
    'fn main() -> i32 { let a: i32[0][3] = 0; return a[0][0]; }'
reject 'total too large'            'local array length must be between 1 and 1000: a' \
    'fn main() -> i32 { let a: i32[1000][1000] = 0; return a[0][0]; }'
reject 'scalar, two subscripts'     'cannot index non-array variable: x' \
    'fn main() -> i32 { let x: i32 = 1; return x[0][1]; }'
reject 'unknown, two subscripts'    'unknown array: q' \
    'fn main() -> i32 { return q[0][1]; }'
reject '1-D global, two subscripts' "too many subscripts for 'g': it has 1 dimension" \
    'let g: i32[3] = 0;
fn main() -> i32 { return g[0][1]; }'
reject '1-D field, two subscripts'  "too many subscripts for field 'xs': it has 1 dimension" \
    'struct S { xs: i32[3] }
fn main() -> i32 { let s: S; return s.xs[0][1]; }'
reject 'row in a condition'         'condition must be a comparison, a bool expression, or an integer' \
    'fn main() -> i32 { let a: i32[2][3] = 0; if (a[1]) { return 1; } return 0; }'

# ---------------------------------------------------------------------------
# [6/9] Coverage map: which case exercises which rule.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Coverage map: which case exercises which rule'
cat > "$OUT/map.txt" <<'MAP'
2-D element write and read         inner       the innermost subscript strides by the element size
computed subscripts                inner       the same with variable indexes, both levels
row address to a function          row         a[i] is a ptr, and it travels like &buf
a row is a ptr value               row         a short chain assigned to a ptr, then indexed
3-D walk                           middle      the middle subscript strides by the product below it
3-D row to a function              row         a row of a 3-D grid is two dimensions short
global 2-D grid                    global      the same chain at file scope, .bss zero-fill
struct field 2-D                   field       the field's offset plus both strides
i64 grid, stride 24                stride      a non-power-of-two row stride, by multiply
u8 grid, stride 1                  stride      a one-byte element, both strides at width
compound assign on 2-D             compound    a[i][j] OP= reads back through the same chain
2-D inside for loops               loops       a chain in a loop body, indexes varying
2-D and 3-D, rows to a function    diff        the C oracle for the row decay
i64 and u8 grids, struct field     diff        the C oracle for every element width
global grid, both scopes           diff        the C oracle for a global grid written through a row
examples/multi_dim_array.ast       diff        the shipped example against its twin
row store, single subscript        rej         one subscript on a 2-D array is a row, not an element
row compound store                 rej         the same refusal for OP=
row store on 3-D                   rej         two subscripts on a 3-D array is still a row
row store, field                   rej         the same rule for a struct field chain
row store in a for step            rej         the parser's for-clause path records the count too
row into an i32                    rej         a row is a ptr, and a ptr is not an i32
row into an i32 parameter          rej         the same at a call boundary
two levels on a ptr                rej         p[0][1] has no stride Aster could apply
bool subscript, outer              rej         an index is an integer, at every level
bool subscript, inner              rej         an inner subscript answers for its own dimension
outer subscript out of bounds      bounds      level 0 checked against dims[0]
inner subscript out of bounds      bounds      level 1 checked against dims[1]
negative subscript                 bounds      a folded negative index, at level 0
zero dimension                     bounds      a dimension of 0 is refused where it is read
total too large                    bounds      the total element limit, one dimension at a time
scalar, two subscripts             rej         the chain's base is not an array
unknown, two subscripts            rej         the chain's base is not a name
1-D global, two subscripts         rej         too many subscripts, at file scope
1-D field, two subscripts          rej         too many subscripts, on a field
row in a condition                 rej         a row is not a truth value either
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
# m1: the short-chain stride is dropped, so `a[1]` on a 2-D array addresses
# element 1 instead of element 3 — the row is one element wide. The witness
# sums the second row through a function: 15 real, 9 broken.
mutate 'm1: a row strides by the element' \
    's|        for(size_t k=levels;k<dims->size();++k)stride\*=(\*dims)\[k\];||' \
    must_differ 'rowSum over the second row' 15 'fn rowSum(p: ptr, n: i32) -> i32 { let t: i32 = 0; let i: i32 = 0; while (i < n) { t = t + p[i]; i = i + 1; } return t; }
fn main() -> i32 { let a: i32[2][3] = 0; let i: i32 = 0; while (i < 2) { let j: i32 = 0; while (j < 3) { a[i][j] = i * 3 + j + 1; j = j + 1; } i = i + 1; } return rowSum(a[1], 3); }'
# m2: the outer stride multiply is dropped, so every level strides by the
# element size. The witness cannot read back through the same broken chain —
# that cancels — so it reads a[0][2], which under the broken stride lands on
# element 2, where the broken fill last wrote a[1][1]'s value: 3 real, 5 broken.
mutate 'm2: every level strides by the element' \
    's|            if(k>0)stride\*=(\*dims)\[k\];||' \
    must_differ 'a[0][2] after a full fill' 3 'fn main() -> i32 { let a: i32[2][3] = 0; let i: i32 = 0; while (i < 2) { let j: i32 = 0; while (j < 3) { a[i][j] = i * 3 + j + 1; j = j + 1; } i = i + 1; } return a[0][2]; }'
# m3: sema checks only the outermost subscript again, so an inner bool
# literal compiles — the hole this round's per-level walk closed. The mutant
# therefore *accepts* what the real compiler refuses, and the rejection matrix
# above is what pins the refusal.
mutate 'm3: only the outer subscript is checked' \
    's|for(uint32_t l=ch.level+1;l-->0;){|for(uint32_t l=ch.level+1;l-->ch.level;){|' \
    must_now_compile 'a[true][0]' 'fn main() -> i32 { let a: i32[2][3] = 0; return a[true][0]; }'
# m4: the single-subscript row store is no longer refused — the check that
# reads the dimension count for a target the parser handed over as itself.
# Withdrawn, the store is accepted (and lands on an element), so the mutant
# compiles what the real compiler refuses.
mutate 'm4: a single subscript may store a row' \
    's|if(rowWhat.empty()&&s.subs<2){|if(false){|' \
    must_now_compile 'a[1] = 5 on a 2-D array' 'fn main() -> i32 { let a: i32[2][3] = 0; a[1] = 5; return 0; }'
# m5: indexSubscripts() stops building a chain, so `a[i][j] = v` leaves the
# second subscript unconsumed and the statement no longer parses.
mutate 'm5: no chain for a second subscript' \
    's|        if(cur().k!=TK::LBracket)return first;|        return first;|' \
    must_not_compile 'a[0][1] = 5' 'fn main() -> i32 { let a: i32[2][3] = 0; a[0][1] = 5; return a[0][1]; }'
# m6: arrayDimList() no longer consumes the leading `[`, so no array
# declaration parses at all — the one-dimensional spelling included.
mutate 'm6: the leading [ is not consumed' \
    "s|            ++p;                                                    // the '\\['|            ;|" \
    must_not_compile 'let a: i32[2][3]' 'fn main() -> i32 { let a: i32[2][3] = 0; return a[0][0]; }'
# m7: a local array's dimensions are no longer registered for codegen, so a
# two-dimensional local is refused at address computation (a one-dimensional
# one still walks emitElemAddr and still compiles).
mutate 'm7: local dimensions not registered' \
    's|localArrayLength\[slot\]=s.dims\[0\];slotDims\[slot\]=s.dims;|localArrayLength[slot]=s.dims[0];|' \
    must_not_compile 'a local 2-D element' 'fn main() -> i32 { let a: i32[2][3] = 0; a[0][0] = 1; return a[0][0]; }'
# m8: a global array's dimensions are no longer registered, so a
# two-dimensional global is refused in sema (a one-dimensional one still
# answers through the fallback path and still compiles).
mutate 'm8: global dimensions not registered' \
    's|arrayLengths\[g.name\]=g.dims\[0\];arrayDims\[g.name\]=g.dims;|arrayLengths[g.name]=g.dims[0];|' \
    must_not_compile 'a global 2-D element' 'let g: i32[2][3] = 0;
fn main() -> i32 { g[0][1] = 5; return g[0][1]; }'
printf '%s\n' 'PASS: eight mutated compilers each lose exactly one rule, and the checks notice'
fi

# ---------------------------------------------------------------------------
# [8/9] Byte-identity baseline. Every line recorded before this round must
# reproduce byte for byte. Five families are excluded: this round's own example
# and the four previous rounds', each of which is new rather than pre-existing.
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
FILTER='-e ^sizeof_len\. -e ^multi_dim_array\. -e ^lifecycle\. -e ^array_address\. -e ^struct_array_field\. -e ^array_elem_types\. -e ^precedence\. -e ^fn_type\. -e ^cb_table\. -e ^fn_ret\. -e ^call-stmt\. -e ^copy\. -e ^arena\. -e ^stdlib_demo\.'
grep -v $FILTER "$BASE" > "$OUT/expected-old.txt"
grep -v $FILTER "$OUT/hashes.txt" > "$OUT/got-old.txt"
if ! diff -u "$OUT/expected-old.txt" "$OUT/got-old.txt" > "$OUT/old.diff"; then
    echo 'FAIL: a pre-existing example moved — the round changed bytes' >&2
    sed -n '1,20p' "$OUT/old.diff" >&2
    exit 1
fi
old=$(wc -l < "$OUT/expected-old.txt")
new=$(wc -l < "$OUT/got-old.txt")
# v0.23.37-dev: the function-type round's example joins the filter, so eight
# families are skipped; v0.23.39-dev's one (call-stmt) make thirteen — but
# the baseline gained those rows, and the pre-existing count is the same 288 it
# has been since v0.23.30-dev: 327 recorded, 39 of them belonging to the thirteen
# rounds this suite knows are new.
# v0.23.41-dev: the heap round's example (arena.ast) joins the filter the same
# way, so fourteen families are skipped; the baseline gained those three rows,
# and the pre-existing count is the same 288 it has been since v0.23.30-dev:
# 327 recorded, 42 of them belonging to the fourteen rounds this suite knows
# are new.
# v0.23.42-dev: the standard-library round's example (stdlib_demo.ast) joins
# the filter the same way, so fourteen families are skipped and the
# pre-existing count is still 288: 330 recorded, 42 of them belonging to the
# fourteen rounds this suite knows are new.
[ "$old" -eq 288 ] \
    || { echo "FAIL: expected 288 pre-existing baseline rows, found $old" >&2; exit 1; }
[ "$new" -eq 288 ] \
    || { echo "FAIL: expected 288 rows of pre-existing output, found $new" >&2; exit 1; }
# And this round's example is recorded, in all three modes, or the baseline is
# not doing its job.
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
    if ! "$A" build-elf examples/multi_dim_array.ast -o "$OUT/md.a64" >"$OUT/md.err" 2>&1; then
        echo 'FAIL: examples/multi_dim_array.ast does not build' >&2; sed -n '1,3p' "$OUT/md.err" >&2; exit 1
    fi
    $RUNNER "$OUT/md.a64" >/dev/null 2>&1 && got=0 || got=$?
    [ "$got" = 255 ] \
        || { echo "FAIL: multi_dim_array.ast: expected exit 255, got $got" >&2; exit 1; }
    printf '  %-34s %s\n' 'multi_dim_array.ast' "$got"
    printf '%s\n' 'PASS: the example runs and returns the value its C twin returns'
fi

printf '%s\n' '=== multi dimensional array checks: ALL PASSED ==='
