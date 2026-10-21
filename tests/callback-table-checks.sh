#!/bin/sh
# tests/callback-table-checks.sh — fn-pointer struct fields, differentially.
#
# v0.23.38-dev lets a struct *field* carry a function type:
#
#     struct Handlers { onClick: fn(i32) -> i32, tag: i32 }
#
# The field is eight bytes of pointer in the layout, exactly as a `ptr` field
# has always been, and the signature rides beside it — the same shape a local,
# a parameter and a global have used since v0.23.37-dev. What the signature buys
# is the call written where the field is:
#
#     let r: i32 = h.onClick(41);
#
# checked (argument count and types) and staged (each argument at its declared
# width, the result read at the declared return type) by the field's own
# signature, and branched to through the value the field holds.
#
# Two decisions are load-bearing and each is pinned by a case:
#
#   - `h.onClick(x)` is its own expression kind (Expr::FieldCall), not a Call
#     with a flag. Every call site keys on a name, and a field whose name
#     matches a function in scope (`fn onClick` beside `Handlers.onClick`) would
#     otherwise be rerouted to the function. ct_clash is that case.
#   - storing into a fn-pointer field is checked by signature, not merely by
#     "both sides are eight bytes", which is the difference between a callback
#     table and a pointer that happens to fit.
#
# Discipline: every behavioural case has an Aster source AND a C source, and the
# oracle is aarch64-linux-gnu-gcc -O2 -fwrapv under qemu — never a hand-computed
# expectation.
#
# Layers: strict build; source guards pinning each piece of the new machinery;
# the differential battery; the shipped example against its C twin; the
# rejection matrix; the coverage map; and a mutation layer that damages each
# piece and requires the battery to go red.

set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-callback-table-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# [1/8] Strictly build the Aster compiler
printf '%s\n' '[1/8] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
# [2/8] Source guards. Each piece of the machinery is pinned by its exact text.
printf '%s\n' '[2/8] Source guards: the callback-table machinery is pinned'
# The field carries the signature.
grep -qF 'FuncSig funcSig; bool isFunc = false; };' src/aster.cpp \
    || { echo 'FAIL: a struct field no longer carries a function signature' >&2; exit 1; }
# The field's capture, where v0.23.37-dev refused.
grep -qF 'if(pendingFuncType){fieldIsFunc=true;fieldFuncSig=pendingFuncSig;' src/aster.cpp \
    || { echo 'FAIL: a struct field no longer captures its function type' >&2; exit 1; }
grep -qF 's.fields.push_back({fn.s,fty,0,flen,std::move(dims),std::move(fieldFuncSig),fieldIsFunc});' src/aster.cpp \
    || { echo 'FAIL: the captured signature no longer reaches the layout table' >&2; exit 1; }
grep -qF '"an array of function pointers is not supported: "+id.s+"."+fn.s' src/aster.cpp \
    || { echo 'FAIL: an array of fn-pointers is no longer refused' >&2; exit 1; }
# The call through a field is its own expression kind.
grep -qF 'FieldCall } k;' src/aster.cpp \
    || { echo 'FAIL: Expr::FieldCall is missing from the expression kinds' >&2; exit 1; }
grep -qF '(cur().k==TK::LParen&&x->k==Expr::Field)' src/aster.cpp \
    || { echo 'FAIL: postfix() no longer lets a `(` follow a field' >&2; exit 1; }
grep -qF 'E z(new Expr(Expr::FieldCall));' src/aster.cpp \
    || { echo 'FAIL: postfix() no longer builds a FieldCall' >&2; exit 1; }
grep -qF 'cannot call the result of this expression' src/aster.cpp \
    || { echo 'FAIL: calling a call result is no longer diagnosed' >&2; exit 1; }
# Sema: the resolver, the comparison, and the field-call check.
grep -qF 'bool funcSigOfExpr(const Expr& e,FuncSig& out){' src/aster.cpp \
    || { echo "FAIL: sema's value-signature resolver is missing" >&2; exit 1; }
grep -qF 'static bool sigEqual(const FuncSig& a,const FuncSig& b){' src/aster.cpp \
    || { echo 'FAIL: the signature comparison is missing' >&2; exit 1; }
grep -qF 'void checkPtrSig(const FuncSig* toSig,const Expr& e,const std::string& what){' src/aster.cpp \
    || { echo 'FAIL: the ptr-signature check is missing' >&2; exit 1; }
grep -qF 'case Expr::FieldCall: return checkFieldCall(e);' src/aster.cpp \
    || { echo 'FAIL: sema no longer types a call through a field' >&2; exit 1; }
grep -qF 'cannot call field '"'"'"+field.name+"'"'"': its type is ' src/aster.cpp \
    || { echo 'FAIL: calling a non-function field is no longer diagnosed' >&2; exit 1; }
grep -qF 'if(f.isFunc)checkPtrSig(&f.funcSig,*e.args[i],' src/aster.cpp \
    || { echo 'FAIL: a struct literal no longer checks a fn field by signature' >&2; exit 1; }
# The parameter side: a fn-pointer argument is checked against the signature
# the callee asked for.
grep -qF 'paramFuncSigMap[f.name]=std::move(ps);' src/aster.cpp \
    || { echo 'FAIL: the driver no longer collects parameter signatures' >&2; exit 1; }
grep -qF 'const FuncSig* wantSig=(i<ps.size()&&ps[i].isFunc)?&ps[i].sig:nullptr;' src/aster.cpp \
    || { echo 'FAIL: an argument is no longer checked against a parameter signature' >&2; exit 1; }
# Codegen: the type, the signature lookup, and the emission.
grep -qF 'case Expr::FieldCall: return fieldCallType(e);' src/aster.cpp \
    || { echo 'FAIL: codegen no longer types a call through a field' >&2; exit 1; }
grep -qF 'const FuncSig* fieldSigOf(const Expr& e) const {' src/aster.cpp \
    || { echo "FAIL: codegen's field-signature resolver is missing" >&2; exit 1; }
grep -qF 'int d=emitCallSeq(e,fs,0,0,true);' src/aster.cpp \
    || { echo 'FAIL: gen no longer hands the field signature to the call sequence' >&2; exit 1; }
# The callee is read before the arguments take X0-X7: reading a field needs a
# temporary, and a temporary comes out of that very pool.
grep -qF 'if(indirect&&e.k==Expr::FieldCall){' src/aster.cpp \
    || { echo 'FAIL: the field callee is no longer read before the argument loads' >&2; exit 1; }
grep -qF 'emit(loadGlobalT(9,Ty::Ptr));           // LDR X9, [X16]' src/aster.cpp \
    || { echo 'FAIL: the field callee is no longer loaded into X9' >&2; exit 1; }
grep -qF 'if(indirect&&e.k!=Expr::FieldCall)emitCalleeAddr(9,e.name);' src/aster.cpp \
    || { echo 'FAIL: an ordinary indirect call no longer takes its old path' >&2; exit 1; }

# ---------------------------------------------------------------------------
# [3/8] Locate the tools: an AArch64 C compiler (the independent oracle) and
# something to run AArch64 ELFs with. Without both the battery SKIPs cleanly;
# the guards above already ran.
printf '%s\n' '[3/8] Locate an AArch64 C compiler and a runner'
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
if [ -z "$HOSTCC" ]; then
    echo "SKIP: callback-table coverage needs an AArch64 C compiler (none found)"
    exit 0
fi
printf 'int main(){return 0;}\n' > "$W/hostprobe.c"
if ! "$HOSTCC" -O2 -fwrapv "$W/hostprobe.c" -o "$W/hostprobe" 2>/dev/null \
   || ! readelf -h "$W/hostprobe" 2>/dev/null | grep -q 'AArch64'; then
    echo "SKIP: $HOSTCC does not emit AArch64 ELF (cross-compile toolchain missing)"
    exit 0
fi
if ! command -v qemu-aarch64 >/dev/null 2>&1 && [ "$(uname -m)" != "aarch64" ]; then
    echo "SKIP: callback-table coverage needs qemu-aarch64 (or an AArch64 host)"
    exit 0
fi
run(){ sh tests/run-aarch64.sh "$@"; }

# ---------------------------------------------------------------------------
# [4/8] Differential battery. Each case writes $W/<name>.ast and $W/<name>.c,
# compiles both, runs both, and compares exit statuses — the oracle is gcc.
#
# Shape-complete over what a callback table actually is:
#   hosts      — a local struct, a ptr<S> parameter (the shape a table is
#                handed around as), and a struct nested inside another;
#   the name   — a field whose name matches a function in scope (ct_clash);
#   widths     — an i64 argument and an i64 return, staged and read at full
#                width (a 32-bit read answers 0);
#   signatures — zero arguments, ten (the last two on the stack), a bool
#                return and a ptr return;
#   the value  — read out into a fn variable, passed to a fn parameter,
#                reassigned, and called in a loop.
printf '%s\n' '[4/8] Differential battery: every callback-table shape, against the C oracle'
CASES="ct_basic ct_ptr_host ct_clash ct_wide ct_zero_args ct_stack_args \
ct_nested ct_readout ct_reassign ct_loop ct_bool_ret ct_ptr_ret"

emit_case(){
    n="$1"
    case "$n" in
    ct_basic)
        ast='struct H { cb: fn(i32) -> i32, tag: i32 }
fn inc(x: i32) -> i32 { return x + 1; }
fn main() -> i32 {
    let h: H = H { inc, 7 };
    let r: i32 = h.cb(41);
    return (r + h.tag) % 251;
}'
        c='struct H { int (*cb)(int); int tag; };
static int inc(int x){ return x+1; }
int main(void){
    struct H h = { inc, 7 };
    int r = h.cb(41);
    return (r + h.tag) % 251;
}' ;;
    ct_ptr_host)
        # The shape a callback table is handed around as: a ptr<H> parameter,
        # called through and reassigned inside a helper.
        ast='struct H { cb: fn(i32) -> i32, tag: i32 }
fn inc(x: i32) -> i32 { return x + 1; }
fn dbl(x: i32) -> i32 { return x + x; }
fn run(h: ptr<H>) -> i32 {
    let a: i32 = h.cb(41);
    h.cb = dbl;
    let b: i32 = h.cb(10);
    return (a + b) % 251;
}
fn main() -> i32 {
    let h: H = H { inc, 3 };
    return (run(&h) + h.tag) % 251;
}'
        c='struct H { int (*cb)(int); int tag; };
static int inc(int x){ return x+1; }
static int dbl(int x){ return x+x; }
static int run(struct H *h){
    int a = h->cb(41);
    h->cb = dbl;
    int b = h->cb(10);
    return (a + b) % 251;
}
int main(void){
    struct H h = { inc, 3 };
    return (run(&h) + h.tag) % 251;
}' ;;
    ct_clash)
        # The reason a field call is its own expression kind: a field named
        # like a function in scope must still be the field. Calling the
        # function instead answers 100; calling the field answers 42.
        ast='fn cb(x: i32) -> i32 { return 100; }
struct H { cb: fn(i32) -> i32 }
fn inc(x: i32) -> i32 { return x + 1; }
fn main() -> i32 {
    let h: H = H { inc };
    return h.cb(41) % 251;
}'
        c='static int cb(int x){ return 100; }
struct H { int (*cb)(int); };
static int inc(int x){ return x+1; }
int main(void){
    struct H h = { inc };
    return h.cb(41) % 251;
}' ;;
    ct_wide)
        # The width the field's signature is for. The result is the only part
        # a 32-bit read can lose: `a << 32` puts the entire answer in the upper
        # half and leaves the lower half zero, so a read at the signature's
        # declared width answers 7 and a read at i32 answers 0. The call is
        # nested in an addition so the result move runs at that width, and the
        # argument is an i64 variable (full width in, whatever the staging).
        ast='struct H { cb: fn(i64) -> i64 }
fn shift32(a: i64) -> i64 { return a << 32; }
fn main() -> i32 {
    let big: i64 = 7;
    let h: H = H { shift32 };
    let r: i64 = 0 + h.cb(big);
    return (r >> 32) % 251;
}'
        c='struct H { long (*cb)(long); };
static long shift32(long a){ return a << 32; }
int main(void){
    long big = 7;
    struct H h = { shift32 };
    long r = 0 + h.cb(big);
    return (int)((r >> 32) % 251);
}' ;;
    ct_zero_args)
        ast='struct H { cb: fn() -> i32 }
fn answer() -> i32 { return 77; }
fn main() -> i32 {
    let h: H = H { answer };
    return h.cb() % 251;
}'
        c='struct H { int (*cb)(void); };
static int answer(void){ return 77; }
int main(void){
    struct H h = { answer };
    return h.cb() % 251;
}' ;;
    ct_stack_args)
        # Ten arguments: the ninth and tenth travel on the stack, so the
        # outgoing area opens and the callee's address has to survive it.
        ast='struct H { cb: fn(i32, i32, i32, i32, i32, i32, i32, i32, i32, i32) -> i32 }
fn add10(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32, h: i32, i: i32, j: i32) -> i32 {
    return a + b + c + d + e + f + g + h + i + j;
}
fn main() -> i32 {
    let t: H = H { add10 };
    return t.cb(1, 2, 3, 4, 5, 6, 7, 8, 9, 10) % 251;
}'
        c='struct H { int (*cb)(int,int,int,int,int,int,int,int,int,int); };
static int add10(int a,int b,int c,int d,int e,int f,int g,int h,int i,int j){
    return a+b+c+d+e+f+g+h+i+j;
}
int main(void){
    struct H t = { add10 };
    return t.cb(1,2,3,4,5,6,7,8,9,10) % 251;
}' ;;
    ct_nested)
        # A field of a field: the call reads the inner struct's signature.
        ast='struct Inner { cb: fn(i32) -> i32 }
struct Outer { inner: Inner, tag: i32 }
fn inc(x: i32) -> i32 { return x + 1; }
fn main() -> i32 {
    let o: Outer = Outer { Inner { inc }, 5 };
    return (o.inner.cb(40) + o.tag) % 251;
}'
        c='struct Inner { int (*cb)(int); };
struct Outer { struct Inner inner; int tag; };
static int inc(int x){ return x+1; }
int main(void){
    struct Outer o = { { inc }, 5 };
    return (o.inner.cb(40) + o.tag) % 251;
}' ;;
    ct_readout)
        # A field's value is a fn-pointer like any other: read it out, or hand
        # it straight to a parameter that asks for one.
        ast='struct H { cb: fn(i32) -> i32 }
fn inc(x: i32) -> i32 { return x + 1; }
fn apply(op: fn(i32) -> i32, v: i32) -> i32 { return op(v); }
fn main() -> i32 {
    let h: H = H { inc };
    let g: fn(i32) -> i32 = h.cb;
    return (apply(h.cb, 10) + g(1)) % 251;
}'
        c='struct H { int (*cb)(int); };
static int inc(int x){ return x+1; }
static int apply(int (*op)(int), int v){ return op(v); }
int main(void){
    struct H h = { inc };
    int (*g)(int) = h.cb;
    return (apply(h.cb, 10) + g(1)) % 251;
}' ;;
    ct_reassign)
        # A field is reassigned like any other — and by signature, so this is
        # the same callback table with a different handler in it.
        ast='struct H { cb: fn(i32) -> i32 }
fn inc(x: i32) -> i32 { return x + 1; }
fn dbl(x: i32) -> i32 { return x + x; }
fn main() -> i32 {
    let h: H = H { inc };
    let a: i32 = h.cb(10);
    h.cb = dbl;
    let b: i32 = h.cb(10);
    return (a * 100 + b) % 251;
}'
        c='struct H { int (*cb)(int); };
static int inc(int x){ return x+1; }
static int dbl(int x){ return x+x; }
int main(void){
    struct H h = { inc };
    int a = h.cb(10);
    h.cb = dbl;
    int b = h.cb(10);
    return (a*100 + b) % 251;
}' ;;
    ct_loop)
        ast='struct H { cb: fn(i32) -> i32 }
fn dbl(x: i32) -> i32 { return x + x; }
fn main() -> i32 {
    let h: H = H { dbl };
    let s: i32 = 0;
    for (let k: i32 = 0; k < 5; k = k + 1) {
        s = s + h.cb(k);
    }
    return s % 251;
}'
        c='struct H { int (*cb)(int); };
static int dbl(int x){ return x+x; }
int main(void){
    struct H h = { dbl };
    int s = 0;
    for (int k = 0; k < 5; k++) s = s + h.cb(k);
    return s % 251;
}' ;;
    ct_bool_ret)
        ast='struct H { cb: fn(i32) -> bool }
fn isodd(x: i32) -> bool { return (x & 1) == 1; }
fn main() -> i32 {
    let h: H = H { isodd };
    let a: bool = h.cb(3);
    let b: bool = h.cb(4);
    if (a) { if (b) { return 2; } return 0; }
    return 1;
}'
        c='struct H { int (*cb)(int); };
static int isodd(int x){ return (x&1)==1; }
int main(void){
    struct H h = { isodd };
    int a = h.cb(3);
    int b = h.cb(4);
    if (a) { if (b) return 2; return 0; }
    return 1;
}' ;;
    ct_ptr_ret)
        ast='struct H { cb: fn() -> ptr }
fn none() -> ptr { return 0; }
fn main() -> i32 {
    let h: H = H { none };
    let p: ptr = h.cb();
    if (p == 0) { return 3; }
    return 4;
}'
        c='struct H { void *(*cb)(void); };
static void *none(void){ return 0; }
int main(void){
    struct H h = { none };
    void *p = h.cb();
    if (p == 0) return 3;
    return 4;
}' ;;
        *)
        echo "internal error: no such case '$n'" >&2
        return 1
        ;;
    esac
    printf '%s\n' "$ast" > "$W/$n.ast"
    printf '%s\n' "$c" > "$W/$n.c"
}

check_case(){
    n="$1"
    if ! "$OUT/aster" build-elf "$W/$n.ast" -o "$W/$n.a64" >"$W/$n.ab.log" 2>&1; then
        echo "FAIL: $n — Aster build failed:" >&2; cat "$W/$n.ab.log" >&2; return 1
    fi
    if ! "$HOSTCC" -O2 -fwrapv "$W/$n.c" -o "$W/$n.c64" >"$W/$n.c64.log" 2>&1; then
        echo "FAIL: $n — C oracle build failed:" >&2; cat "$W/$n.c64.log" >&2; return 1
    fi
    run "$W/$n.a64" >/dev/null 2>&1 && a=0 || a=$?
    run "$W/$n.c64" >/dev/null 2>&1 && c=0 || c=$?
    [ "$a" -gt 127 ] && a=$((a-256))
    [ "$c" -gt 127 ] && c=$((c-256))
    if [ "$a" != "$c" ]; then
        echo "FAIL: $n — Aster exit $a, C oracle exit $c" >&2; return 1
    fi
    printf 'PASS: %-24s exit %s (matches C)\n' "$n" "$a"
}

for n in $CASES; do emit_case "$n"; done
failed=0
for n in $CASES; do check_case "$n" || failed=1; done
[ "$failed" = 0 ] || exit 1

# ---------------------------------------------------------------------------
# [5/8] The shipped example, against its twin. examples/cb_table.ast is the
# round's showcase for the field side; its C twin is
# tests/callback-table-twin.c, and the two exit statuses must agree.
printf '%s\n' '[5/8] The shipped example, against its C twin'
if ! "$OUT/aster" build-elf examples/cb_table.ast -o "$W/cb_table" >"$W/ex.log" 2>&1; then
    echo "FAIL: examples/cb_table.ast no longer builds:" >&2; cat "$W/ex.log" >&2; exit 1
fi
"$HOSTCC" -O2 -static -o "$W/cb_table.twin" tests/callback-table-twin.c
run "$W/cb_table" >/dev/null 2>&1 && a=0 || a=$?
run "$W/cb_table.twin" >/dev/null 2>&1 && c=0 || c=$?
[ "$a" -gt 127 ] && a=$((a-256)); [ "$c" -gt 127 ] && c=$((c-256))
if [ "$a" != "$c" ]; then
    echo "FAIL: examples/cb_table.ast exits $a, its C twin $c" >&2; exit 1
fi
printf 'PASS: the example and its twin both exit %s\n' "$a"

# ---------------------------------------------------------------------------
# [6/8] Rejection matrix. What a fn-pointer field refuses: a value whose
# signature is not the field's (in a literal and in an assignment), the wrong
# argument count, a call through a field that has no function type, the two
# shapes this round deliberately does not do (an array of fn-pointers, a call
# on a call's result), and a global struct constant holding one.
printf '%s\n' '[6/8] Rejections: a fn-pointer field keeps its signature contract'
reject(){ # reject <name> <source> <expected message fragment>
    printf '%s\n' "$2" > "$W/rej.ast"
    if "$OUT/aster" build-elf "$W/rej.ast" -o "$W/rej.a64" >"$W/rej.log" 2>&1; then
        echo "FAIL: $1 — was accepted" >&2; return 1
    fi
    if ! grep -qF "$3" "$W/rej.log"; then
        echo "FAIL: $1 — wrong diagnostic:" >&2; cat "$W/rej.log" >&2; return 1
    fi
    printf 'PASS: rejected — %s\n' "$1"
}
reject "a literal whose signature is not the field's" \
    'struct H { cb: fn(i32) -> i32 }
fn wide(x: i64) -> i64 { return x + 1; }
fn main() -> i32 {
    let h: H = H { wide };
    return 0;
}' \
    "expected fn(i32) -> i32, got fn(i64) -> i64"
reject "an assignment whose signature is not the field's" \
    'struct H { cb: fn(i32) -> i32 }
fn inc(x: i32) -> i32 { return x + 1; }
fn wide(x: i64) -> i64 { return x + 1; }
fn main() -> i32 {
    let h: H = H { inc };
    h.cb = wide;
    return 0;
}' \
    "expected fn(i32) -> i32, got fn(i64) -> i64"
reject "the wrong argument count calling a field" \
    'struct H { cb: fn(i32, i32) -> i32 }
fn add(a: i32, b: i32) -> i32 { return a + b; }
fn main() -> i32 {
    let h: H = H { add };
    return h.cb(1);
}' \
    "wrong argument count calling field 'cb': expected 2, got 1"
reject "a call through a field that is not a function" \
    'struct H { cb: fn(i32) -> i32, tag: i32 }
fn inc(x: i32) -> i32 { return x + 1; }
fn main() -> i32 {
    let h: H = H { inc, 0 };
    return h.tag(1);
}' \
    "cannot call field 'tag': its type is i32, not a function type"
reject "an array of fn-pointers" \
    'struct H { cbs: fn(i32) -> i32[4] }
fn main() -> i32 { return 0; }' \
    "an array of function pointers is not supported: H.cbs"
reject "a call on a call's result" \
    'fn inc(x: i32) -> i32 { return x + 1; }
fn get() -> fn(i32) -> i32 { return inc; }
fn main() -> i32 { return get()(1); }' \
    "cannot call the result of this expression"
reject "a call through a subscripted field" \
    'struct H { ps: ptr[4] }
fn main() -> i32 {
    let h: H = H { 0 };
    return h.ps[0](1);
}' \
    "cannot call the result of this expression"
reject "a global struct constant holding a fn-pointer" \
    'struct H { cb: fn(i32) -> i32 }
fn inc(x: i32) -> i32 { return x + 1; }
let gh: H = H { inc };
fn main() -> i32 { return 0; }' \
    "global struct field 'H.cb' cannot be initialized by a constant"

# ---------------------------------------------------------------------------
# [7/8] Coverage map. Each named case reproduces a contract the feature has:
# the field call itself, the name clash it is shaped to survive, the width the
# signature is for, and the shapes a callback table is handed around as.
printf '%s\n' '[7/8] Coverage map: the contract regressions stay resident'
for c in ct_basic ct_ptr_host ct_clash ct_wide ct_readout ct_reassign ct_stack_args; do
    case " $CASES " in
        *" $c "*) printf 'PASS: coverage map holds — %s\n' "$c" ;;
        *) echo "FAIL: coverage map lost $c (it pins a contract, not a decoration)" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# [8/8] Mutation layer. Put each piece of damage back and require the battery
# to go red — a check that passes on a damaged compiler is not checking
# anything. The pieces: the value resolver (signature checks vanish), the
# comparison (every signature matches), the field capture (no field has a
# function type at all), gen's signature hand-off (the field call reverts to
# the untyped rule), the callee read's position (an argument register is
# clobbered), and the parser's FieldCall (field calls stop parsing).
printf '%s\n' '[8/8] Mutation: the checks above must fail on a damaged compiler'
build_mutant(){ # build_mutant <tag> <sed-expr>
    m="$1"
    sed "$2" src/aster.cpp > "$OUT/$m.cpp"
    if ! ${CXX:-c++} -std=c++17 -O0 -w "$OUT/$m.cpp" -o "$OUT/$m.aster" 2>"$OUT/$m.err"; then
        echo "FAIL: mutant $m does not build" >&2; sed -n '1,3p' "$OUT/$m.err" >&2; exit 1
    fi
}
must_not_compile(){ # must_not_compile <tag> <probe>
    if "$OUT/$1.aster" build-elf "$W/$2.ast" -o "$OUT/$1.a64" >/dev/null 2>&1; then
        echo "FAIL: under mutation $1, $2 still compiled — the battery does not test it" >&2; exit 1
    fi
    printf '  %-42s %s is a compile error again\n' "$1" "$2"
}
must_diverge(){ # must_diverge <tag> <probe> — compiles, but disagrees with gcc
    if ! "$OUT/$1.aster" build-elf "$W/$2.ast" -o "$OUT/$1.a64" >/dev/null 2>&1; then
        echo "FAIL: under mutation $1, $2 no longer compiles — unexpected" >&2; exit 1
    fi
    run "$W/$2.c64" >/dev/null 2>&1 && c=0 || c=$?
    run "$OUT/$1.a64" >/dev/null 2>&1 && a=0 || a=$?
    [ "$a" -gt 127 ] && a=$((a-256))
    [ "$c" -gt 127 ] && c=$((c-256))
    if [ "$a" = "$c" ]; then
        echo "FAIL: under mutation $1, $2 still matches the C oracle — the case does not test it" >&2; exit 1
    fi
    printf '  %-42s %s now disagrees with the C oracle\n' "$1" "$2"
}
must_accept(){ # must_accept <tag> <probe> — the mutation took the check away,
               # so what was refused is now accepted: that is the damage.
    if ! "$OUT/$1.aster" build-elf "$W/$2.ast" -o "$OUT/$1.a64" >/dev/null 2>&1; then
        echo "FAIL: under mutation $1, $2 is still refused — the mutation did not remove the check" >&2; exit 1
    fi
    printf '  %-42s %s is accepted (the signature check is gone)\n' "$1" "$2"
}

# Probes the mutation layer reuses, written here so each check really tests
# its mutation and not a missing file.
printf '%s\n' 'struct H { cb: fn(i32) -> i32 }
fn wide(x: i64) -> i64 { return x + 1; }
fn main() -> i32 {
    let h: H = H { wide };
    return 0;
}' > "$W/rej_sig.ast"
printf '%s\n' 'struct H { cb: fn(i32) -> i32, tag: i32 }
fn inc(x: i32) -> i32 { return x + 1; }
fn main() -> i32 {
    let h: H = H { inc, 0 };
    return h.tag(1);
}' > "$W/rej_notfn.ast"
printf '%s\n' 'struct H { cb: fn(i32) -> i32 }
fn inc(x: i32) -> i32 { return x + 1; }
fn main() -> i32 {
    let h: H = H { inc };
    return h.cb(41) % 251;
}' > "$W/ct_probe.ast"

# m1: the value resolver never answers — no store is checked by signature.
build_mutant m1 's|bool funcSigOfExpr(const Expr& e,FuncSig& out){|bool funcSigOfExpr(const Expr\& e,FuncSig\& out){ if(true) return false;|'
must_accept m1 rej_sig
# m2: every signature matches every other — same hole, different line.
build_mutant m2 's|static bool sigEqual(const FuncSig& a,const FuncSig& b){|static bool sigEqual(const FuncSig\& a,const FuncSig\& b){ return true;|'
must_accept m2 rej_sig
# m3: the field capture is dead — no field has a function type, so a call
# through one is a call through a plain field and is refused.
build_mutant m3 's|if(pendingFuncType){fieldIsFunc=true;fieldFuncSig=pendingFuncSig;|if(false){fieldIsFunc=true;fieldFuncSig=pendingFuncSig;|'
must_not_compile m3 ct_probe
# m4: gen hands a null signature to the call sequence — the i64 width and the
# i64 result both revert to the untyped rule.
build_mutant m4 's|const FuncSig\* fs=fieldSigOf(e);|const FuncSig* fs=(const FuncSig*)0;|'
must_diverge m4 ct_wide
# m5: the callee is read after the arguments took X0-X7 — the struct address
# lands in an argument register.
build_mutant m5 's|if(indirect\&\&e.k==Expr::FieldCall){|if(false)\{|'
must_diverge m5 ct_ptr_host
# m6: postfix() never builds a FieldCall — `h.cb(x)` stops parsing.
build_mutant m6 's|E z(new Expr(Expr::FieldCall));|E z(new Expr(Expr::Field));|'
must_not_compile m6 ct_probe

printf '%s\n' 'ALL CALLBACK-TABLE CHECKS PASSED'
