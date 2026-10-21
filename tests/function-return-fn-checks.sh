#!/bin/sh
# tests/function-return-fn-checks.sh — a function that returns a function
# pointer, differentially.
#
# v0.23.38-dev lets the *return type* be a function type:
#
#     fn pick(which: i32) -> fn(i32) -> i32 { ... }
#
# What comes back is still an address — there is no first-class function value
# — but the signature travels with it, in the return slot, the same way it
# travels beside a ptr variable. Two things follow, and the round is worth
# exactly as much as they are:
#
#   - `return inc;` inside pick is checked. inc has to *be* `fn(i32) -> i32`,
#     so a `fn(i64) -> i64` there is a compile error at the return statement
#     rather than a silent mismatch discovered at the first call;
#   - the value a call hands back carries that signature into whatever it
#     lands in, so `apply(pick(1), 20)` is checked against apply's parameter —
#     the return slot and the parameter slot agreeing, or not, is one check
#     spanning two functions.
#
# What the return slot does *not* do is change codegen: `let f: fn(i32) -> i32
# = pick(0);` gets its staging and result widths from f's own declared type,
# which is the same signature. The return slot's signature is a contract, and
# a contract's worth is measured in the mistakes it refuses — so this suite's
# battery confirms the legal programs still agree with gcc, and its rejection
# matrix is where the feature is actually tested.
#
# The address a call hands back cannot itself be called on the spot: `pick(0)
# (20)` is refused, because a call is not a value you can take an address of.
# Assign it first — which is also what makes the signature worth carrying.
#
# Discipline: every behavioural case has an Aster source AND a C source, and
# the oracle is aarch64-linux-gnu-gcc -O2 -fwrapv under qemu — never a
# hand-computed expectation.
#
# Layers: strict build; source guards pinning each piece of the new machinery;
# the differential battery; the shipped example against its C twin; the
# rejection matrix; the coverage map; and a mutation layer that damages each
# piece and requires the checks to go red.

set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-function-return-fn-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# [1/8] Strictly build the Aster compiler
printf '%s\n' '[1/8] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
# [2/8] Source guards. Each piece of the machinery is pinned by its exact text.
printf '%s\n' '[2/8] Source guards: the function-returning-fn machinery is pinned'
# The return slot carries a signature beside the ptr it already was.
grep -qF 'FuncSig returnFuncSig; bool returnIsFunc=false;' src/aster.cpp \
    || { echo 'FAIL: a function no longer carries a return-slot signature' >&2; exit 1; }
# The capture, where v0.23.37-dev refused the type outright.
grep -qF 'if(pendingFuncType){f.returnFuncSig=pendingFuncSig;f.returnIsFunc=true;' src/aster.cpp \
    || { echo 'FAIL: a return type no longer captures its function type' >&2; exit 1; }
# Sema reads it: the member, the per-function seed, and the return check.
grep -qF 'const std::map<std::string,FuncSig>& returnFuncSig;' src/aster.cpp \
    || { echo "FAIL: sema no longer holds the return-signature map" >&2; exit 1; }
grep -qF 'bool retIsFunc=false; FuncSig retFuncSig;' src/aster.cpp \
    || { echo 'FAIL: sema no longer seeds the return signature per function' >&2; exit 1; }
grep -qF 'retIsFunc=f.returnIsFunc;retFuncSig=f.returnFuncSig;' src/aster.cpp \
    || { echo 'FAIL: sema no longer picks up the function it is checking' >&2; exit 1; }
grep -qF 'if(retIsFunc&&actual==Ty::Ptr)' src/aster.cpp \
    || { echo 'FAIL: a returned pointer is no longer checked by signature' >&2; exit 1; }
# A call's *result* answers that signature, which is how the return slot's
# contract reaches a parameter slot two functions away.
grep -qF 'auto it=returnFuncSig.find(e.name);' src/aster.cpp \
    || { echo "FAIL: the value resolver no longer consults the return slot" >&2; exit 1; }
grep -qF 'if(it!=returnFuncSig.end()){out=it->second;return true;}' src/aster.cpp \
    || { echo 'FAIL: a call returning a fn-pointer no longer answers its signature' >&2; exit 1; }
# The parameter side it flows into, keyed by function name so a callee's
# declaration is visible at every call site.
grep -qF 'struct ParamSig { bool isFunc=false; FuncSig sig; };' src/aster.cpp \
    || { echo 'FAIL: the per-parameter signature record is missing' >&2; exit 1; }
grep -qF 'const std::map<std::string,std::vector<ParamSig>>& paramFuncSig;' src/aster.cpp \
    || { echo "FAIL: sema no longer holds the parameter-signature map" >&2; exit 1; }
grep -qF 'const FuncSig* wantSig=(i<ps.size()&&ps[i].isFunc)?&ps[i].sig:nullptr;' src/aster.cpp \
    || { echo 'FAIL: an argument is no longer checked against a parameter signature' >&2; exit 1; }
# The driver's two collections and the wiring into sema.
grep -qF 'std::map<std::string,FuncSig> returnFuncSigMap;' src/aster.cpp \
    || { echo 'FAIL: the driver no longer collects return signatures' >&2; exit 1; }
grep -qF 'if(f.returnIsFunc)returnFuncSigMap[f.name]=f.returnFuncSig;' src/aster.cpp \
    || { echo 'FAIL: a return signature no longer reaches sema' >&2; exit 1; }
grep -qF 'returnFuncSigMap,paramFuncSigMap};' src/aster.cpp \
    || { echo 'FAIL: sema is no longer handed the two signature maps' >&2; exit 1; }
# The refusal that keeps a returned address from being called on the spot.
grep -qF 'cannot call the result of this expression' src/aster.cpp \
    || { echo 'FAIL: calling a call result is no longer diagnosed' >&2; exit 1; }

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
    echo "SKIP: function-returning-fn coverage needs an AArch64 C compiler (none found)"
    exit 0
fi
printf 'int main(){return 0;}\n' > "$W/hostprobe.c"
if ! "$HOSTCC" -O2 -fwrapv "$W/hostprobe.c" -o "$W/hostprobe" 2>/dev/null \
   || ! readelf -h "$W/hostprobe" 2>/dev/null | grep -q 'AArch64'; then
    echo "SKIP: $HOSTCC does not emit AArch64 ELF (cross-compile toolchain missing)"
    exit 0
fi
if ! command -v qemu-aarch64 >/dev/null 2>&1 && [ "$(uname -m)" != "aarch64" ]; then
    echo "SKIP: function-returning-fn coverage needs qemu-aarch64 (or an AArch64 host)"
    exit 0
fi
run(){ sh tests/run-aarch64.sh "$@"; }

# ---------------------------------------------------------------------------
# [4/8] Differential battery. Each case writes $W/<name>.ast and $W/<name>.c,
# compiles both, runs both, and compares exit statuses — the oracle is gcc.
#
# Shape-complete over what a returned function pointer is handed to:
#   destinations — a local, a global fn slot, a struct field (the other
#                  half of this round), and a fn-pointer parameter;
#   signatures   — zero arguments, ten (the last two on the stack), an i64
#                  argument and an i64 return, a bool return, a ptr return;
#   the value    — two getters of different signature, reassignment between
#                  them, a call taken in a loop, and a call nested in an
#                  argument.
printf '%s\n' '[4/8] Differential battery: every returned-fn shape, against the C oracle'
CASES="fr_basic fr_handoff fr_wide fr_zero_args fr_bool_ret fr_ptr_ret \
fr_two_sigs fr_reassign fr_loop fr_stack_args fr_global_slot fr_struct_field"

emit_case(){
    n="$1"
    case "$n" in
    fr_basic)
        # The feature itself: a getter whose return type is a function type,
        # and a call through what it handed back.
        ast='fn inc(x: i32) -> i32 { return x + 1; }
fn dbl(x: i32) -> i32 { return x + x; }
fn pick(which: i32) -> fn(i32) -> i32 {
    if (which == 0) { return inc; }
    return dbl;
}
fn main() -> i32 {
    let f: fn(i32) -> i32 = pick(0);
    let g: fn(i32) -> i32 = pick(1);
    return (f(20) + g(20)) % 251;
}'
        c='static int inc(int x){ return x+1; }
static int dbl(int x){ return x+x; }
typedef int (*Unary)(int);
static Unary pick(int which){
    if (which == 0) return inc;
    return dbl;
}
int main(void){
    Unary f = pick(0);
    Unary g = pick(1);
    return (f(20) + g(20)) % 251;
}' ;;
    fr_handoff)
        # Why the return slot carries a signature at all: the value never
        # touches a named variable, so the only signature in play is the one
        # the getter declared and the one the callee asked for.
        ast='fn inc(x: i32) -> i32 { return x + 1; }
fn dbl(x: i32) -> i32 { return x + x; }
fn pick(which: i32) -> fn(i32) -> i32 {
    if (which == 0) { return inc; }
    return dbl;
}
fn apply(op: fn(i32) -> i32, v: i32) -> i32 { return op(v); }
fn main() -> i32 {
    return apply(pick(1), 12) % 251;
}'
        c='static int inc(int x){ return x+1; }
static int dbl(int x){ return x+x; }
typedef int (*Unary)(int);
static Unary pick(int which){
    if (which == 0) return inc;
    return dbl;
}
static int apply(Unary op, int v){ return op(v); }
int main(void){
    return apply(pick(1), 12) % 251;
}' ;;
    fr_wide)
        # The width the returned signature is for. `a << 32` leaves the whole
        # answer in the upper half and zeroes the lower half, so a read at the
        # declared return width answers 7 and a read at i32 answers 0.
        ast='fn shift32(a: i64) -> i64 { return a << 32; }
fn getter() -> fn(i64) -> i64 { return shift32; }
fn main() -> i32 {
    let h: fn(i64) -> i64 = getter();
    let big: i64 = 7;
    let r: i64 = 0 + h(big);
    return (r >> 32) % 251;
}'
        c='static long shift32(long a){ return a << 32; }
typedef long (*Wide)(long);
static Wide getter(void){ return shift32; }
int main(void){
    Wide h = getter();
    long big = 7;
    long r = 0 + h(big);
    return (int)((r >> 32) % 251);
}' ;;
    fr_zero_args)
        # The empty parameter list is a signature too — and the reason a
        # per-parameter record exists: `fn() -> i32` has to be distinguishable
        # from "no signature was declared".
        ast='fn answer() -> i32 { return 7; }
fn getz() -> fn() -> i32 { return answer; }
fn main() -> i32 {
    let z: fn() -> i32 = getz();
    return z() % 251;
}'
        c='static int answer(void){ return 7; }
typedef int (*Nullary)(void);
static Nullary getz(void){ return answer; }
int main(void){
    Nullary z = getz();
    return z() % 251;
}' ;;
    fr_bool_ret)
        # A bool return, read and branched on at the declared width.
        ast='fn isBig(x: i32) -> bool { return x > 10; }
fn getb() -> fn(i32) -> bool { return isBig; }
fn main() -> i32 {
    let b: fn(i32) -> bool = getb();
    if (b(20)) { return 3; }
    return 8;
}'
        c='static int isBig(int x){ return x > 10; }
typedef int (*Pred)(int);
static Pred getb(void){ return isBig; }
int main(void){
    Pred b = getb();
    if (b(20)) return 3;
    return 8;
}' ;;
    fr_ptr_ret)
        # A ptr return: eight bytes that are not an i32, read as eight bytes.
        ast='fn nothing(x: i32) -> ptr { return 0; }
fn getp() -> fn(i32) -> ptr { return nothing; }
fn main() -> i32 {
    let h: fn(i32) -> ptr = getp();
    let p: ptr = h(3);
    if (p == 0) { return 5; }
    return 9;
}'
        c='static void *nothing(int x){ (void)x; return (void*)0; }
typedef void *(*Maker)(int);
static Maker getp(void){ return nothing; }
int main(void){
    Maker h = getp();
    void *p = h(3);
    if (p == 0) return 5;
    return 9;
}' ;;
    fr_two_sigs)
        # Two getters whose return slots declare different signatures: each
        # value is staged and read by its own, not by whichever was parsed
        # last.
        ast='fn inc(x: i32) -> i32 { return x + 1; }
fn shift32(a: i64) -> i64 { return a << 32; }
fn geti() -> fn(i32) -> i32 { return inc; }
fn getl() -> fn(i64) -> i64 { return shift32; }
fn main() -> i32 {
    let f: fn(i32) -> i32 = geti();
    let g: fn(i64) -> i64 = getl();
    let big: i64 = 7;
    let r: i64 = 0 + g(big);
    return (f(1) + (r >> 32)) % 251;
}'
        c='static int inc(int x){ return x+1; }
static long shift32(long a){ return a << 32; }
typedef int (*Unary)(int);
typedef long (*Wide)(long);
static Unary geti(void){ return inc; }
static Wide getl(void){ return shift32; }
int main(void){
    Unary f = geti();
    Wide g = getl();
    long big = 7;
    long r = 0 + g(big);
    return (int)((f(1) + (int)(r >> 32)) % 251);
}' ;;
    fr_reassign)
        # A returned fn-pointer is an ordinary value: the variable holding it
        # can be filled again from another getter.
        ast='fn inc(x: i32) -> i32 { return x + 1; }
fn dbl(x: i32) -> i32 { return x + x; }
fn geti() -> fn(i32) -> i32 { return inc; }
fn getd() -> fn(i32) -> i32 { return dbl; }
fn main() -> i32 {
    let f: fn(i32) -> i32 = geti();
    let a: i32 = f(10);
    f = getd();
    let b: i32 = f(10);
    return (a * 100 + b) % 251;
}'
        c='static int inc(int x){ return x+1; }
static int dbl(int x){ return x+x; }
typedef int (*Unary)(int);
static Unary geti(void){ return inc; }
static Unary getd(void){ return dbl; }
int main(void){
    Unary f = geti();
    int a = f(10);
    f = getd();
    int b = f(10);
    return (a * 100 + b) % 251;
}' ;;
    fr_loop)
        # Taken fresh each iteration, which is what a table lookup is.
        ast='fn inc(x: i32) -> i32 { return x + 1; }
fn geti() -> fn(i32) -> i32 { return inc; }
fn main() -> i32 {
    let s: i32 = 0;
    let i: i32 = 0;
    while (i < 5) {
        let f: fn(i32) -> i32 = geti();
        s = s + f(i);
        i = i + 1;
    }
    return s % 251;
}'
        c='static int inc(int x){ return x+1; }
typedef int (*Unary)(int);
static Unary geti(void){ return inc; }
int main(void){
    int s = 0;
    int i = 0;
    while (i < 5) {
        Unary f = geti();
        s = s + f(i);
        i = i + 1;
    }
    return s % 251;
}' ;;
    fr_stack_args)
        # Ten parameters: the ninth and tenth travel on the stack, staged by
        # a signature that came from a return slot.
        ast='fn sum10(a: i32, b: i32, c: i32, d: i32, e: i32, ff: i32, gg: i32, hh: i32, ii: i32, jj: i32) -> i32 {
    return a + b + c + d + e + ff + gg + hh + ii + jj;
}
fn get10() -> fn(i32, i32, i32, i32, i32, i32, i32, i32, i32, i32) -> i32 { return sum10; }
fn main() -> i32 {
    let s: fn(i32, i32, i32, i32, i32, i32, i32, i32, i32, i32) -> i32 = get10();
    return s(1, 2, 3, 4, 5, 6, 7, 8, 9, 10) % 251;
}'
        c='static int sum10(int a, int b, int c, int d, int e, int ff, int gg, int hh, int ii, int jj){
    return a+b+c+d+e+ff+gg+hh+ii+jj;
}
typedef int (*Ten)(int,int,int,int,int,int,int,int,int,int);
static Ten get10(void){ return sum10; }
int main(void){
    Ten s = get10();
    return s(1,2,3,4,5,6,7,8,9,10) % 251;
}' ;;
    fr_global_slot)
        # A global fn slot filled from a getter, then called through.
        ast='fn dbl(x: i32) -> i32 { return x + x; }
let gslot: fn(i32) -> i32;
fn getd() -> fn(i32) -> i32 { return dbl; }
fn main() -> i32 {
    gslot = getd();
    return gslot(41) % 251;
}'
        c='static int dbl(int x){ return x+x; }
typedef int (*Unary)(int);
static Unary gslot;
static Unary getd(void){ return dbl; }
int main(void){
    gslot = getd();
    return gslot(41) % 251;
}' ;;
    fr_struct_field)
        # Both halves of the round in one line: the return slot's signature
        # has to satisfy the field's, and the field's then stages the call.
        ast='struct H { cb: fn(i32) -> i32 }
fn dbl(x: i32) -> i32 { return x + x; }
fn getd() -> fn(i32) -> i32 { return dbl; }
fn main() -> i32 {
    let h: H = H { getd() };
    return h.cb(20) % 251;
}'
        c='struct H { int (*cb)(int); };
static int dbl(int x){ return x+x; }
typedef int (*Unary)(int);
static Unary getd(void){ return dbl; }
int main(void){
    struct H h = { getd() };
    return h.cb(20) % 251;
}' ;;
    *)
        echo "FAIL: no case named $n" >&2; exit 1 ;;
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
# [5/8] The shipped example, against its twin. examples/fn_ret.ast is the
# round's showcase for the return side; its C twin is
# tests/function-return-fn-twin.c, and the two exit statuses must agree.
printf '%s\n' '[5/8] The shipped example, against its C twin'
if ! "$OUT/aster" build-elf examples/fn_ret.ast -o "$W/fn_ret" >"$W/ex.log" 2>&1; then
    echo "FAIL: examples/fn_ret.ast no longer builds:" >&2; cat "$W/ex.log" >&2; exit 1
fi
if ! "$HOSTCC" -O2 -fwrapv tests/function-return-fn-twin.c -o "$W/fn_ret.c64" >"$W/ex2.log" 2>&1; then
    echo "FAIL: the C twin no longer builds:" >&2; cat "$W/ex2.log" >&2; exit 1
fi
run "$W/fn_ret" >/dev/null 2>&1 && ae=0 || ae=$?
run "$W/fn_ret.c64" >/dev/null 2>&1 && ce=0 || ce=$?
[ "$ae" -gt 127 ] && ae=$((ae-256))
[ "$ce" -gt 127 ] && ce=$((ce-256))
if [ "$ae" != "$ce" ]; then
    echo "FAIL: fn_ret.ast exits $ae, its C twin exits $ce" >&2; exit 1
fi
printf 'PASS: the example and its twin both exit %s\n' "$ae"

# ---------------------------------------------------------------------------
# [6/8] Rejections. This is where the return slot earns its keep: each of
# these is a mistake the signature catches at the point it is written.
printf '%s\n' '[6/8] Rejections: a returned fn-pointer keeps its signature contract'
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
reject "a returned fn-pointer whose signature is not the return type's" \
    'fn wide(x: i64) -> i64 { return x; }
fn get() -> fn(i32) -> i32 { return wide; }
fn main() -> i32 { return 0; }' \
    "return type mismatch in function get: expected fn(i32) -> i32, got fn(i64) -> i64"
reject "a returned fn-pointer with the wrong argument count" \
    'fn pair(a: i32, b: i32) -> i32 { return a + b; }
fn get() -> fn(i32) -> i32 { return pair; }
fn main() -> i32 { return 0; }' \
    "return type mismatch in function get: expected fn(i32) -> i32, got fn(i32, i32) -> i32"
reject "a returned fn-pointer with the wrong return type only" \
    'fn shift32(a: i32) -> i64 { return 0; }
fn get() -> fn(i32) -> i32 { return shift32; }
fn main() -> i32 { return 0; }' \
    "return type mismatch in function get: expected fn(i32) -> i32, got fn(i32) -> i64"
# The contract spanning two functions: what the getter promised is what the
# callee is asked for, and they disagree.
reject "a returned fn-pointer handed to a parameter wanting another signature" \
    'fn wide(x: i64) -> i64 { return x; }
fn getw() -> fn(i64) -> i64 { return wide; }
fn apply(op: fn(i32) -> i32, v: i32) -> i32 { return op(v); }
fn main() -> i32 { return apply(getw(), 1); }' \
    "argument type mismatch calling apply at argument 1: expected fn(i32) -> i32, got fn(i64) -> i64"
reject "a returned fn-pointer stored into a field wanting another signature" \
    'struct H { cb: fn(i32) -> i32 }
fn wide(x: i64) -> i64 { return x; }
fn getw() -> fn(i64) -> i64 { return wide; }
fn main() -> i32 {
    let h: H = H { getw() };
    return 0;
}' \
    "expected fn(i32) -> i32, got fn(i64) -> i64"
reject "calling the address a call handed back, on the spot" \
    'fn inc(x: i32) -> i32 { return x + 1; }
fn pick(which: i32) -> fn(i32) -> i32 { return inc; }
fn main() -> i32 {
    return pick(0)(20);
}' \
    "cannot call the result of this expression"

# ---------------------------------------------------------------------------
# [7/8] Coverage map. Each named case reproduces a contract the feature has:
# the getter itself, the hand-off that is the reason the return slot carries a
# signature at all, the width, the empty parameter list, and the two
# destinations a returned pointer is put into.
printf '%s\n' '[7/8] Coverage map: the contract regressions stay resident'
for c in fr_basic fr_handoff fr_wide fr_zero_args fr_global_slot fr_struct_field fr_two_sigs; do
    case " $CASES " in
        *" $c "*) printf 'PASS: coverage map holds — %s\n' "$c" ;;
        *) echo "FAIL: coverage map lost $c (it pins a contract, not a decoration)" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# [8/8] Mutation layer. Put each piece of damage back and require the checks to
# go red — a check that passes on a damaged compiler is not checking anything.
# The pieces: the return statement's check, sema's per-function seed, the
# parser's capture of the return type, the driver's collection, the parameter
# side the signature flows into, and the refusal that stops a call result from
# being called.
printf '%s\n' '[8/8] Mutation: the checks above must fail on a damaged compiler'
build_mutant(){ # build_mutant <tag> <sed-expr>
    m="$1"
    sed "$2" src/aster.cpp > "$OUT/$m.cpp"
    if ! ${CXX:-c++} -std=c++17 -O0 -w "$OUT/$m.cpp" -o "$OUT/$m.aster" 2>"$OUT/$m.err"; then
        echo "FAIL: mutant $m does not build" >&2; sed -n '1,3p' "$OUT/$m.err" >&2; exit 1
    fi
}
must_accept(){ # must_accept <tag> <probe> — the mutation took the check away,
               # so what was refused is now accepted: that is the damage.
    if ! "$OUT/$1.aster" build-elf "$W/$2.ast" -o "$OUT/$1.a64" >/dev/null 2>&1; then
        echo "FAIL: under mutation $1, $2 is still refused — the mutation did not remove the check" >&2; exit 1
    fi
    printf '  %-42s %s is accepted (the signature check is gone)\n' "$1" "$2"
}
must_lose_diagnostic(){ # must_lose_diagnostic <tag> <probe> <fragment>
    if "$OUT/$1.aster" build-elf "$W/$2.ast" -o "$OUT/$1.a64" 2>"$OUT/$1.msg"; then
        echo "FAIL: under mutation $1, $2 compiled — unexpected" >&2; exit 1
    fi
    if grep -qF "$3" "$OUT/$1.msg"; then
        echo "FAIL: under mutation $1, $2 still carries '$3' — the mutation did not damage the line that produces it" >&2; exit 1
    fi
    printf '  %-42s %s loses its diagnostic\n' "$1" "$2"
}

# Probes the mutation layer reuses, written here so each check really tests
# its mutation and not a missing file.
printf '%s\n' 'fn wide(x: i64) -> i64 { return x; }
fn get() -> fn(i32) -> i32 { return wide; }
fn main() -> i32 { return 0; }' > "$W/rej_retslot.ast"
printf '%s\n' 'fn wide(x: i64) -> i64 { return x; }
fn getw() -> fn(i64) -> i64 { return wide; }
fn apply(op: fn(i32) -> i32, v: i32) -> i32 { return op(v); }
fn main() -> i32 { return apply(getw(), 1); }' > "$W/rej_handoff.ast"
printf '%s\n' 'fn inc(x: i32) -> i32 { return x + 1; }
fn pick(which: i32) -> fn(i32) -> i32 { return inc; }
fn main() -> i32 {
    return pick(0)(20);
}' > "$W/rej_onthespot.ast"

# m1: the return statement stops checking by signature — any pointer may be
# returned from a function that promised a particular one.
build_mutant m1 's/if(retIsFunc&&actual==Ty::Ptr)/if(false)/'
must_accept m1 rej_retslot
# m2: sema never seeds the return signature for the function it is checking —
# same hole, entered one step earlier.
build_mutant m2 's/retIsFunc=f.returnIsFunc;retFuncSig=f.returnFuncSig;/retIsFunc=false;retFuncSig=f.returnFuncSig;/'
must_accept m2 rej_retslot
# m3: the parser stops capturing the return type's signature — the type is
# still accepted, but nothing remembers what it was.
build_mutant m3 's/if(pendingFuncType){f.returnFuncSig=pendingFuncSig;f.returnIsFunc=true;/if(false){f.returnFuncSig=pendingFuncSig;f.returnIsFunc=true;/'
must_accept m3 rej_retslot
# m4: the driver stops collecting return signatures — sema's map stays empty,
# so a call's result no longer answers one and the hand-off is unchecked.
build_mutant m4 's/if(f.returnIsFunc)returnFuncSigMap\[f.name\]=f.returnFuncSig;/if(false)returnFuncSigMap[f.name]=f.returnFuncSig;/'
must_accept m4 rej_handoff
# m5: the parameter side stops consulting the signature it was handed — the
# contract spanning the two functions is gone at the far end.
build_mutant m5 's/const FuncSig\* wantSig=(i<ps.size()\&\&ps\[i\].isFunc)?\&ps\[i\].sig:nullptr;/const FuncSig* wantSig=nullptr;/'
must_accept m5 rej_handoff
# m6: the refusal that keeps a returned address from being called on the spot
# loses its diagnostic.
build_mutant m6 's/if(cur().k==TK::LParen\&\&(x->k==Expr::Call||x->k==Expr::Index))/if(false)/'
must_lose_diagnostic m6 rej_onthespot "cannot call the result of this expression"

printf '%s\n' 'ALL FUNCTION-RETURN-FN CHECKS PASSED'
