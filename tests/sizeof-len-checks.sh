#!/bin/sh
# v0.23.35-dev checks for the sizeof / len operators and array parameters that
# carry their length.
#
# Until this round a program could not ask Aster how big a type was or how many
# elements an array held — it had to hard-code the answer. This round adds two
# operators that fold to an i32 constant at compile time:
#
#   * sizeof — bytes. `sizeof(i32)` is 4, `sizeof(i32[4])` is 16, `sizeof(ptr)`
#     is 8, `sizeof(S)` is the struct's laid-out size. Two spellings: a type
#     (`sizeof(i32[4])`) or an expression (`sizeof(w)`, `sizeof(row.cells)`).
#   * len — the element count, the product of the dimensions for a
#     multi-dimensional array (`len(i64[2][3])` is 6, not the row count 2).
#
# And it lets an array *parameter* remember its extent: `fn f(a: i32[4])` used
# to decay `a` to a bare pointer and throw the length away, so `len(a)` inside
# `f` had nothing to answer from. Five changes make it work:
#
#   1. `Expr` gains two kinds (`SizeOf`, `Len`) and two fields (`ty`/`idims`
#      carry a type-form argument; `a` carries an expression-form one).
#   2. `primary()` intercepts the `sizeof`/`len` identifiers before the generic
#      name path, tries the type spelling first and folds it on the spot, and
#      falls back to an expression for the rest.
#   3. `arrayParamType()` hands back the dimension list it was already reading,
#      and the parser stores it in `Function::paramDims`.
#   4. `Sema::check` fills the parameter's `Binding` with those dimensions, so
#      the existing array queries (`arrayOperandOf`, and the new
#      `arrayElemCountOf`) answer for a parameter just as for a local.
#   5. Both type systems (`Sema::typeOf` and Codegen's `exprType`) fold the
#      expression-form and answer i32, and `gen` materialises the value exactly
#      like a `Num` — so no downstream site learns a new concept.
#
# None of it can move the bytes of a program that compiled before: it is new
# syntax only, and the existing codegen is untouched. Layer [8/9] asserts all
# 288 pre-existing baseline rows reproduce byte for byte.
#
# The behavioural layers need qemu (or an AArch64 host); the differential layer
# additionally needs $HOSTCC to emit AArch64 ELF. Neither is required to
# *build*, so each layer that cannot run says SKIP and the rest still runs.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-sizeof-len-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

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
    printf '%s\n' 'SKIP: sizeof-len-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each change is pinned where it was made, so a regression
# that quietly reopens one fails here rather than by a behavioural case.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: the five changes'

# (1) The two new kinds, and the two fields that carry their argument.
# Pinned *without* the enum's tail: v0.23.35-dev appended SizeOf and Len after
# Cond and v0.23.38-dev has since appended FieldCall after them, so the tail
# moves every time a round adds a kind — the pair itself is what this suite
# owns, and `callback-table-checks.sh` pins FieldCall.
grep -qF 'SizeOf, Len,' src/aster.cpp \
    || { echo "FAIL: Expr::Kind no longer declares SizeOf and Len" >&2; exit 1; }
grep -qF 'Ty ty=Ty::I32; std::vector<uint32_t> idims;' src/aster.cpp \
    || { echo "FAIL: Expr no longer carries the sizeof/len type-form fields" >&2; exit 1; }
# The fold helpers, shared by the two type systems.
grep -qF 'static uint64_t dimsProduct(const std::vector<uint32_t>& d) {' src/aster.cpp \
    || { echo "FAIL: dimsProduct() is missing" >&2; exit 1; }
grep -qF 'static uint64_t sizeofTypeValue(Ty t, const std::vector<uint32_t>& dims) {' src/aster.cpp \
    || { echo "FAIL: sizeofTypeValue() is missing" >&2; exit 1; }

# (2) The parser intercept, before the generic name path, and the fold on the spot.
grep -qF 'if(cur().k==TK::Ident&&(cur().s=="sizeof"||cur().s=="len")){' src/aster.cpp \
    || { echo "FAIL: primary() no longer intercepts sizeof/len" >&2; exit 1; }
grep -qF 'E x(new Expr(op=="sizeof"?Expr::SizeOf:Expr::Len));' src/aster.cpp \
    || { echo "FAIL: primary() no longer builds a SizeOf/Len node" >&2; exit 1; }
# The type-form folds while parsing (no context needed); len of a non-array type
# is refused rather than silently answered.
grep -qF 'if(dims.empty())throw Error(loc(ln,cl,"len() requires an array type, e.g. len(i32[4])"));' src/aster.cpp \
    || { echo "FAIL: len() of a scalar type is no longer refused at parse time" >&2; exit 1; }

# (3) arrayParamType() hands back the dimensions, and the parser keeps them.
grep -qF 'Ty arrayParamType(std::vector<uint32_t>* outDims=nullptr){' src/aster.cpp \
    || { echo "FAIL: arrayParamType() no longer reports the dimension list" >&2; exit 1; }
grep -qF 'if(outDims)*outDims=dims;' src/aster.cpp \
    || { echo "FAIL: arrayParamType() no longer fills its dimension out-parameter" >&2; exit 1; }
grep -qF 'std::vector<std::vector<uint32_t>> paramDims;' src/aster.cpp \
    || { echo "FAIL: Function no longer carries per-parameter dimensions" >&2; exit 1; }
grep -qF 'const Ty pty=arrayParamType(&pd);' src/aster.cpp \
    || { echo "FAIL: the parameter parse loop no longer collects dimensions" >&2; exit 1; }

# (4) Sema fills the binding with those dimensions; len is the product.
grep -qF 'const std::vector<uint32_t>& pd = i<f.paramDims.size()?f.paramDims[i]:kEmptyDims;' src/aster.cpp \
    || { echo "FAIL: Sema::check no longer reads the parameter dimensions" >&2; exit 1; }
grep -qF 'const uint32_t plen = pd.empty()?0:(uint32_t)dimsProduct(pd);' src/aster.cpp \
    || { echo "FAIL: Sema::check no longer totals the parameter length" >&2; exit 1; }
# v0.23.37-dev: the aggregate gained the signature pair on a second line; the
# head line — the dimensions fill this guard exists for — is pinned here, the
# signature pair by function-type-checks.sh's own guard.
grep -qF 'scopes.back()[f.params[i]]=Binding{pty, plen, tyIsPtrToElem(pty)?ptrElemType(pty):Ty::I32, pd,' src/aster.cpp \
    || { echo "FAIL: Sema::check no longer fills the binding with the dimensions" >&2; exit 1; }
# The grand-total count (not the outermost dimension) is what len reports.
grep -qF 'bool arrayElemCountOf(const Expr& operand,Ty& elem,uint64_t& count) {' src/aster.cpp \
    || { echo "FAIL: arrayElemCountOf() is missing" >&2; exit 1; }
grep -qF 'uint64_t foldSizeOfExpr(const Expr& e) {' src/aster.cpp \
    || { echo "FAIL: foldSizeOfExpr() is missing" >&2; exit 1; }

# (5) Both type systems answer i32 and fold the expression-form; gen materialises
# the value like a Num; the constant paths read the folded e.n.
grep -qF 'if(e.a) const_cast<Expr&>(e).n = foldSizeOfExpr(e);' src/aster.cpp \
    || { echo "FAIL: Sema::typeOf no longer folds the expression-form" >&2; exit 1; }
grep -qF 'case Expr::SizeOf: case Expr::Len: return Ty::I32;' src/aster.cpp \
    || { echo "FAIL: a type system no longer answers i32 for sizeof/len" >&2; exit 1; }
grep -qF 'case Expr::SizeOf: case Expr::Len: {' src/aster.cpp \
    || { echo "FAIL: gen() no longer materialises sizeof/len" >&2; exit 1; }
grep -qF 'case Expr::SizeOf: case Expr::Len: out=static_cast<int64_t>(e.n); return true;' src/aster.cpp \
    || { echo "FAIL: constantInteger() no longer folds sizeof/len" >&2; exit 1; }
printf '%s\n' 'PASS: all five changes are pinned in the source'

# ---------------------------------------------------------------------------
# [3/9] qemu: every spelling and scope, hand-derived. Each case returns the
# value it is named for, so a wrong fold is the exit code.
# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] qemu: sizeof and len, every spelling'
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
# --- the type spelling ---
check "$A" 'sizeof(i32) is 4'               4 'fn main() -> i32 { return sizeof(i32); }'
check "$A" 'sizeof(i64) is 8'               8 'fn main() -> i32 { return sizeof(i64); }'
check "$A" 'sizeof(i32[4]) is 16'          16 'fn main() -> i32 { return sizeof(i32[4]); }'
check "$A" 'len(i32[4]) is 4'               4 'fn main() -> i32 { return len(i32[4]); }'
check "$A" 'sizeof(i64[2][3]) is 48'       48 'fn main() -> i32 { return sizeof(i64[2][3]); }'
check "$A" 'len(i64[2][3]) is 6'            6 'fn main() -> i32 { return len(i64[2][3]); }'
check "$A" 'sizeof(ptr) is 8'               8 'fn main() -> i32 { return sizeof(ptr); }'
check "$A" 'sizeof(u8[10]) is 10'          10 'fn main() -> i32 { return sizeof(u8[10]); }'
# --- the expression spelling on a local ---
check "$A" 'sizeof(local i32[4])'          16 'fn main() -> i32 { let w: i32[4] = 0; return sizeof(w); }'
check "$A" 'len(local i32[4])'              4 'fn main() -> i32 { let w: i32[4] = 0; return len(w); }'
check "$A" 'sizeof(local i64[2][3])'       48 'fn main() -> i32 { let g: i64[2][3] = 0; return sizeof(g); }'
check "$A" 'len(local i64[2][3]) is 6'      6 'fn main() -> i32 { let g: i64[2][3] = 0; return len(g); }'
check "$A" 'sizeof(local ptr) is 8'         8 'fn main() -> i32 { let p: ptr = 0; return sizeof(p); }'
# --- an array parameter carries its length ---
check "$A" 'sizeof(param i32[4]) is 16'    16 'fn f(a: i32[4]) -> i32 { return sizeof(a); }
fn main() -> i32 { return f(0); }'
check "$A" 'len(param i32[4]) is 4'         4 'fn f(a: i32[4]) -> i32 { return len(a); }
fn main() -> i32 { return f(0); }'
check "$A" 'sizeof(param i64[2][3]) is 48' 48 'fn f(a: i64[2][3]) -> i32 { return sizeof(a); }
fn main() -> i32 { return f(0); }'
check "$A" 'len(param i64[2][3]) is 6'      6 'fn f(a: i64[2][3]) -> i32 { return len(a); }
fn main() -> i32 { return f(0); }'
# --- a global array ---
check "$A" 'sizeof(global i32[10]) is 40'  40 'let g: i32[10] = 0;
fn main() -> i32 { return sizeof(g); }'
check "$A" 'len(global i32[10]) is 10'     10 'let g: i32[10] = 0;
fn main() -> i32 { return len(g); }'
# --- structs and their array fields ---
check "$A" 'sizeof(struct P) is 8'          8 'struct P { x: i32, y: i32 }
fn main() -> i32 { return sizeof(P); }'
check "$A" 'sizeof(struct instance) is 8'   8 'struct P { x: i32, y: i32 }
fn main() -> i32 { let p: P; p.x = 1; p.y = 2; return sizeof(p); }'
check "$A" 'sizeof(array field) is 16'     16 'struct B { xs: i32[4] }
fn main() -> i32 { let b: B; return sizeof(b.xs); }'
check "$A" 'len(array field) is 4'          4 'struct B { xs: i32[4] }
fn main() -> i32 { let b: B; return len(b.xs); }'
# --- sizeof/len composed with ordinary arithmetic ---
check "$A" 'len + sizeof compose'          20 'fn main() -> i32 { let a: i32[4] = 0; return len(a) + sizeof(a); }'
check "$A" 'sizeof in a bound'              6 'fn main() -> i32 { let a: i32[3] = 0; return len(a) * 2; }'
else
    printf '%s\n' '  SKIP: the behavioural cases need qemu to run'
fi

# ---------------------------------------------------------------------------
# [4/9] Differential: Aster against the target C compiler, whose sizeof and
# array decay these operators describe. No expectation here is hand-computed.
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
        printf '  %-34s %s\n' "$1" "$ga"
    }
    # A parameter decays to a pointer in C, so the twin measures a real array
    # type (the storage Aster describes) rather than sizeof on the decayed
    # parameter, which C would answer as 8.
    diff_case 'sizeof/len of arrays, local and param' \
        'fn nbytes(a: i32[4]) -> i32 { return sizeof(a); }
fn nelem(a: i32[4]) -> i32 { return len(a); }
fn main() -> i32 {
    let w: i32[4] = 0;
    let g: i64[2][3] = 0;
    if (sizeof(w) == 16 && len(w) == 4) { if (sizeof(g) == 48 && len(g) == 6) { if (nbytes(w) == 16 && nelem(w) == 4) { return 27; } } }
    return 0; }' \
        '#include <stdint.h>
static int32_t nbytes(int32_t a[4]) { (void)a; return (int32_t)sizeof(int32_t[4]); }
static int32_t nelem(int32_t a[4]) { (void)a; return (int32_t)(sizeof(int32_t[4]) / sizeof(int32_t)); }
int main(void) {
    int32_t w[4] = {0};
    int64_t g[2][3] = {{0}};
    if (sizeof(w) == 16 && (int32_t)(sizeof(w) / sizeof(int32_t)) == 4)
        if (sizeof(g) == 48 && (int32_t)(sizeof(g) / sizeof(int64_t)) == 6)
            if (nbytes(w) == 16 && nelem(w) == 4) return 27;
    return 0; }'
    diff_case 'struct and array field, scalar widths' \
        'struct Row { cells: i32[4] }
fn main() -> i32 {
    let row: Row;
    if (sizeof(Row) == 16 && sizeof(row) == 16) { if (sizeof(row.cells) == 16 && len(row.cells) == 4) { if (sizeof(i64) == 8 && sizeof(u8[3]) == 3) { return 44; } } }
    return 0; }' \
        '#include <stdint.h>
struct Row { int32_t cells[4]; };
int main(void) {
    struct Row row = {{0}};
    if (sizeof(struct Row) == 16 && sizeof(row) == 16)
        if (sizeof(row.cells) == 16 && (int32_t)(sizeof(row.cells) / sizeof(int32_t)) == 4)
            if (sizeof(int64_t) == 8 && sizeof(uint8_t[3]) == 3) return 44;
    return 0; }'
    # The shipped example against its twin, end to end.
    diff_case 'examples/sizeof_len.ast' \
        "$(cat examples/sizeof_len.ast)" \
        "$(cat tests/sizeof-len-twin.c)"
else
    printf '%s\n' '  SKIP: the differential layer needs qemu and a target C compiler'
fi

# ---------------------------------------------------------------------------
# [5/9] Rejection matrix. len refuses what has no element count, and the
# sizeof/len spellings are checked like any other construct.
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
reject 'len of a scalar local'      "len() requires an array, not a scalar or pointer" \
    'fn main() -> i32 { let x: i32 = 1; return len(x); }'
reject 'len of a ptr local'         "len() requires an array, not a scalar or pointer" \
    'fn main() -> i32 { let p: ptr = 0; return len(p); }'
reject 'len of a ptr parameter'     "len() requires an array, not a scalar or pointer" \
    'fn f(p: ptr) -> i32 { return len(p); }
fn main() -> i32 { return f(0); }'
reject 'len of a scalar type'       "len() requires an array type, e.g. len(i32[4])" \
    'fn main() -> i32 { return len(i32); }'
reject 'len of a struct type'       "len() requires an array type, e.g. len(i32[4])" \
    'struct P { x: i32 }
fn main() -> i32 { return len(P); }'
reject 'sizeof missing open paren'  "expected '(' after sizeof" \
    'fn main() -> i32 { return sizeof i32; }'
reject 'sizeof missing close paren' "expected ')' after sizeof expression" \
    'fn main() -> i32 { let w: i32[4] = 0; return sizeof(w; }'
reject 'sizeof missing close paren (type)' "expected ')' after sizeof type" \
    'fn main() -> i32 { return sizeof(i32[4]; }'
reject 'zero-length array type'     "array length out of range" \
    'fn main() -> i32 { return sizeof(i32[0]); }'
reject 'len read as a variable'     "expected '(' after len" \
    'fn main() -> i32 { let len: i32 = 5; return len; }'
reject 'len named, read inside sizeof' "expected '(' after len" \
    'fn main() -> i32 { let len: i32 = 5; return sizeof(len); }'
printf '%s\n' 'PASS: the rejection matrix holds'

# ---------------------------------------------------------------------------
# [6/9] Coverage: the two fold helpers are reached for every operand shape, so
# a hole in the guard is a hole here. This is a positive layer, not a guard.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Coverage: every operand shape folds'
# (No test-only artifact; the [3/9] cases above are the coverage. Kept as its
# own layer to mirror the house structure and to make the count explicit.)
if [ "$have_qemu" = yes ]; then
    n=$(grep -c '^check ' "$0")
    [ "$n" -ge 20 ] || { echo "FAIL: expected at least 20 behavioural cases, found $n" >&2; exit 1; }
    printf '  %-34s %s\n' 'behavioural cases' "$n"
    printf '%s\n' 'PASS: the behavioural matrix covers every operand shape'
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
    printf '  SKIP: the mutation layer needs qemu to observe a changed answer'
else
# m1: the parameter's dimensions are dropped from the binding, so len of a
# parameter has nothing to answer from and is refused — the real compiler
# accepts it (returning 4 in [3/9]), so the fill is what makes it legal.
mutate 'm1: a parameter forgets its length' \
    's|scopes.back()\[f.params\[i\]\]=Binding{pty, plen, tyIsPtrToElem(pty)?ptrElemType(pty):Ty::I32, pd,|scopes.back()[f.params[i]]=Binding{pty, 0, tyIsPtrToElem(pty)?ptrElemType(pty):Ty::I32, {},|' \
    must_not_compile 'len of a param i32[4]' 'fn f(a: i32[4]) -> i32 { return len(a); }
fn main() -> i32 { return f(0); }'
# m2: the expression-form no longer folds in sema, so e.n stays 0 and gen
# materialises 0 instead of the array's size.
mutate 'm2: the expression-form does not fold' \
    's|                if(e.a) const_cast<Expr\&>(e).n = foldSizeOfExpr(e);||' \
    must_differ 'sizeof of a local i32[4]' 16 'fn main() -> i32 { let w: i32[4] = 0; return sizeof(w); }'
# m3: len no longer multiplies the dimensions, reporting only the outermost —
# so a 2-D array answers 2 instead of 6.
mutate 'm3: len reports the outermost dimension' \
    's|                elem=b->elem; count=dimsProduct(b->dims); return true;|                elem=b->elem; count=b->dims.empty()?1:b->dims[0]; return true;|' \
    must_differ 'len of a 2-D local' 6 'fn main() -> i32 { let g: i64[2][3] = 0; return len(g); }'
# m4: len of a scalar is no longer refused — the honest rejection this round
# added. The mutant therefore *accepts* what the real compiler refuses.
mutate 'm4: len of a scalar is not refused' \
    's|        if(isLen)throw Error(loc(e.line,e.col,"len() requires an array, not a scalar or pointer"));||' \
    must_now_compile 'len of a scalar local' 'fn main() -> i32 { let x: i32 = 1; return len(x); }'
# m5: the type-form's array literal is ignored, so sizeof(i32[4]) answers the
# scalar size (4) instead of the array size (16).
mutate 'm5: the type-form ignores its array literal' \
    's|                } else x->n=sizeofTypeValue(t,dims);|                } else x->n=(uint64_t)tySize(t);|' \
    must_differ 'sizeof(i32[4])' 16 'fn main() -> i32 { return sizeof(i32[4]); }'
printf '%s\n' 'PASS: five mutated compilers each lose exactly one rule, and the checks notice'
fi

# ---------------------------------------------------------------------------
# [8/9] Byte-identity baseline. Every line recorded before this round must
# reproduce byte for byte. Seven families are excluded: this round's own example
# and the six previous rounds', each of which is new rather than pre-existing.
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
FILTER='-e ^sizeof_len\. -e ^struct_array_field\. -e ^array_elem_types\. -e ^precedence\. -e ^array_address\. -e ^multi_dim_array\. -e ^lifecycle\. -e ^fn_type\. -e ^cb_table\. -e ^fn_ret\. -e ^call-stmt\. -e ^copy\. -e ^arena\. -e ^stdlib_demo\. -e ^integer_cast\. -e ^switch\. -e ^literals\.'
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
# families are skipped; v0.23.39-dev's one (call-stmt) make thirteen — and
# the pre-existing count is the same 288 it has been since v0.23.30-dev — 318
# recorded, 39 of them belonging to the thirteen rounds this suite knows are new (sizeof_len is in the baseline too but is filtered
# here all the same).
# v0.23.41-dev: the heap round's example (arena.ast) joins the filter the same
# way, so fourteen families are skipped; and the pre-existing count is the same
# 288 it has been since v0.23.30-dev — 327 recorded, 42 of them belonging to the
# fourteen rounds this suite knows are new (sizeof_len is in the baseline too
# but is filtered here all the same).
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
# And this round's example is recorded, in all three modes.
[ "$(grep -c '^sizeof_len\.' "$OUT/hashes.txt")" -eq 3 ] \
    || { echo 'FAIL: sizeof_len.ast is not in the baseline in all three modes' >&2; exit 1; }
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
    if ! "$A" build-elf examples/sizeof_len.ast -o "$OUT/sl.a64" >"$OUT/sl.err" 2>&1; then
        echo 'FAIL: examples/sizeof_len.ast does not build' >&2; sed -n '1,3p' "$OUT/sl.err" >&2; exit 1
    fi
    $RUNNER "$OUT/sl.a64" >/dev/null 2>&1 && got=0 || got=$?
    [ "$got" = 255 ] \
        || { echo "FAIL: examples/sizeof_len.ast: expected exit 255, got $got" >&2; exit 1; }
    printf '  %-34s %s\n' 'sizeof_len.ast' "$got"
    printf '%s\n' 'PASS: the example runs and returns the value its C twin returns'
fi

printf '%s\n' '=== sizeof-len checks: ALL PASSED ==='
