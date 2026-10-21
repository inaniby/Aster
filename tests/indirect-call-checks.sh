#!/bin/sh
# tests/indirect-call-checks.sh — calls through a function pointer, differentially.
#
# v0.23.24-dev adds the call Aster could not make. Taking a function's address
# has yielded a ptr since the callback-table work (a function name in a value
# position is its address), but every call site branched through a relocated
# BL — the compiler never emitted a BLR — so the address could be stored,
# passed and handed to C, yet never called. `fp(x)` where `fp` is a ptr
# variable now stages the arguments exactly as a direct call does and branches
# through a register.
#
# The language surface, and why it is this small:
#   - the callee is a ptr variable (local, global, or parameter). A function
#     name in call position is still a direct call — the function always wins,
#     exactly as a user function shadows an intrinsic;
#   - there is no function type, so there is no signature: every scalar
#     argument rides at 64-bit width (an i32-declaring callee reads the low
#     half, an i64-declaring one reads a properly extended full register —
#     AAPCS64 leaves a sub-64-bit argument's upper half unspecified, and one
#     staging width answers for both), and the call answers i32;
#   - a struct argument is refused (no signature exists to lay one out), a
#     struct or array callee is refused, and an extern function's address
#     cannot be taken (its location is another object's business).
#
# The round's second half is a linker change that the language surface made
# necessary: a static ELF (build-elf, build-pie, link-obj) rejected the
# ADRP/ADD pair that materializes a function's address — the restriction
# existed because a *shared object's* text cannot carry a load-time
# relocation, and there every function address is rerouted through a GOT slot
# before linking. A static image knows every function's address at link time
# and ADRP/ADD are PC-relative, so the restriction is lifted there only. This
# is not decoration: without it `let fp: ptr = f;` does not link outside a
# shared object, and the feature would have been unreachable in the one mode
# the differential suites exercise.
#
# Discipline (carried over from every suite since write-output-checks.sh):
# every behavioural case has an Aster source AND a C source, and the oracle is
# aarch64-linux-gnu-gcc -O2 -fwrapv under qemu — never a hand-computed
# expectation. Where the twin's function-pointer type says i64 and Aster's
# untyped ptr cannot, the twin casts the result to int exactly as the Aster
# program's i32 consumer sees it: the contract is that an indirect call
# answers i32, and the twin models that contract rather than the callee's.
#
# Layers: strict build; source guards pinning each piece of the new machinery
# (the sema resolution, the gen dispatch, the callee materialization, the BLR,
# the 64-bit staging, the global-callee value load, and the linker flag); the
# differential battery (locals, reassignment, parameters, globals, stack
# arguments, wide and narrow values at both widths, pointers, bools, loops,
# memory-resident pointers, nesting, zero arguments, and the precedence
# rule); the shared-object structural check; the shipped example run against
# its C twin; the rejection matrix; the coverage map; and a mutation layer
# that damages each piece and requires the battery to go red.

set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-indirect-call-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# [1/7] Strictly build the Aster compiler
printf '%s\n' '[1/7] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
# [2/7] Source guards. Each piece of the machinery is pinned by its exact
# text: the sema resolution of a ptr-variable callee (and its two naming
# diagnostics), the gen dispatch behind indirectCallee, the callee
# materialization into X9, the BLR itself, the 64-bit staging width, the
# global callee's *value* load (a local loads its slot's contents; a global
# must answer the same contents, not the global's own address — the first cut
# of this round branched to the data and segfaulted), and the linker flag with
# its two guarded sites.
printf '%s\n' '[2/7] Source guards: the indirect-call machinery is pinned'
grep -qF 'bool indirectCallee(const std::string& name) const {' src/aster.cpp \
    || { echo 'FAIL: the ptr-variable callee resolver is missing' >&2; exit 1; }
grep -qF 'if(!indirectCallee(e.name))' src/aster.cpp \
    || { echo 'FAIL: gen no longer dispatches an indirect call (or lost its resolution)' >&2; exit 1; }
grep -qF 'int d=emitCallSeq(e,fs,0,0,true);' src/aster.cpp \
    || { echo 'FAIL: gen no longer passes the callee signature to the indirect call sequence' >&2; exit 1; }
grep -qF 'if(indirect&&e.k!=Expr::FieldCall)emitCalleeAddr(9,e.name);' src/aster.cpp \
    || { echo 'FAIL: the callee address is no longer materialized into X9' >&2; exit 1; }
grep -qF 'emit(0xd63f0000u|(9u<<5));' src/aster.cpp \
    || { echo 'FAIL: the BLR X9 emission is missing (or changed register)' >&2; exit 1; }
# v0.23.37-dev: a typed fn-pointer stages each argument at the width its
# signature declares; a bare ptr keeps the legacy 64-bit rule. Both paths are
# pinned — the first is the new behaviour, the second must not move.
grep -qF 'if(sig&&i<sig->params.size())return sig->params[i];' src/aster.cpp \
    || { echo 'FAIL: a typed indirect call no longer stages arguments at their signature width' >&2; exit 1; }
grep -qF 'return indirect?Ty::I64:(i<argT.size()?argT[i]:Ty::I32);' src/aster.cpp \
    || { echo 'FAIL: a bare-ptr indirect call no longer stages every scalar argument at 64-bit width' >&2; exit 1; }
grep -qF 'emit(loadGlobalT(reg,Ty::Ptr));' src/aster.cpp \
    || { echo 'FAIL: a global callee no longer loads the pointer it holds' >&2; exit 1; }
grep -qF 'void emitCalleeAddr(int reg,const std::string& name){' src/aster.cpp \
    || { echo 'FAIL: the callee-address materializer is missing' >&2; exit 1; }
grep -qF 'if(const Binding* b=find(e.name)){' src/aster.cpp \
    || { echo 'FAIL: sema no longer resolves a ptr-variable callee' >&2; exit 1; }
grep -qF "cannot call through '" src/aster.cpp \
    || { echo "FAIL: sema no longer names the offending callee in its diagnostic" >&2; exit 1; }
grep -qF 'an indirect call cannot take a struct argument' src/aster.cpp \
    || { echo 'FAIL: sema no longer refuses a struct argument to an indirect call' >&2; exit 1; }
grep -qF "cannot take the address of extern function '" src/aster.cpp \
    || { echo "FAIL: sema no longer explains why an extern function has no address to take" >&2; exit 1; }
grep -qF 'uint64_t textVaddr,bool funcAddrDirect=false' src/aster.cpp \
    || { echo 'FAIL: resolveRelocations lost its funcAddrDirect parameter' >&2; exit 1; }
if [ "$(grep -cF 'if(kind==0&&!funcAddrDirect)' src/aster.cpp)" -ne 2 ]; then
    echo 'FAIL: the two ADRP/ADD sites no longer guard on funcAddrDirect' >&2; exit 1
fi
grep -qF 'resolveRelocations(mergedText,pending,symbolVaddr,symbolKind,textVaddr,/*funcAddrDirect=*/true);' src/aster.cpp \
    || { echo 'FAIL: the static linker no longer permits a direct function address' >&2; exit 1; }
# A direct call must keep its relocated BL — the indirect path is an addition,
# not a replacement.
grep -qF 'relocations.push_back({uint64_t(at2)*4,e.name,kRelCall26});' src/aster.cpp \
    || { echo 'FAIL: the direct-call BL relocation is missing' >&2; exit 1; }
echo 'OK: guards hold — sema, gen, staging, BLR, global load and linker flag all pinned'

# ---------------------------------------------------------------------------
# [3/7] Locate the tools: an AArch64 C compiler (the independent oracle) and
# something to run AArch64 ELFs with. The battery compares against gcc, so
# without both it SKIPs cleanly; the guards above already ran.
printf '%s\n' '[3/7] Locate an AArch64 C compiler and a runner'
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
if [ -z "$HOSTCC" ]; then
    echo "SKIP: indirect-call coverage needs an AArch64 C compiler (none found)"
    exit 0
fi
printf 'int main(){return 0;}\n' > "$W/hostprobe.c"
if ! "$HOSTCC" -O2 -fwrapv "$W/hostprobe.c" -o "$W/hostprobe" 2>/dev/null \
   || ! readelf -h "$W/hostprobe" 2>/dev/null | grep -q 'AArch64'; then
    echo "SKIP: $HOSTCC does not emit AArch64 ELF (cross-compile toolchain missing)"
    exit 0
fi
if ! command -v qemu-aarch64 >/dev/null 2>&1 && [ "$(uname -m)" != "aarch64" ]; then
    echo "SKIP: indirect-call coverage needs qemu-aarch64 (or an AArch64 host)"
    exit 0
fi
run(){ sh tests/run-aarch64.sh "$@"; }

# ---------------------------------------------------------------------------
# [4/7] Differential battery. Each case writes $W/<name>.ast and
# $W/<name>.c, compiles both, runs both, and compares exit statuses — the
# oracle is gcc, nobody writes a number down.
#
# The battery is shape-complete:
#   callee forms — a ptr local, reassignment of one variable to two functions,
#                 a ptr parameter (the trampoline), a ptr global filled by the
#                 synthetic initializer, and a pointer read out of memory with
#                 load_ptr (the dlsym shape);
#   argument forms — none, one, ten (the ninth and tenth travel on the stack),
#                 a wide literal and an i32 variable both landing in an i64
#                 parameter (the shift case reads the wide argument's upper
#                 half back, which a truncated stage cannot answer), a small
#                 negative literal likewise, a ptr, a bool, mixed widths, and
#                 negative i32 values;
#   call forms — in a loop, nested as an argument, from a helper that calls
#                through the pointer twice;
#   precedence — a function wins over a same-named ptr variable in call
#                position (the twin spells the direct call explicitly, because
#                C's own scoping would answer the other way: this case pins
#                Aster's documented rule, not the platform ABI).
printf '%s\n' '[4/7] Differential battery: every call shape, against the C oracle'
CASES="call_local call_reassign call_param call_global call_stack_args \
call_wide_literal call_wide_shift call_var64 call_neg64 call_ptr_arg call_bool_arg \
call_loop call_memory call_nested call_zero_args call_mixed_widths call_neg \
call_helper precedence_function_wins"

emit_case(){
    n="$1"
    case "$n" in
    call_local)
        ast='fn add_one(x: i32) -> i32 { return x + 1; }
fn main() -> i32 {
    let fp: ptr = add_one;
    let a: i32 = fp(41);
    let b: i32 = add_one(a);
    return (a + b) % 251;
}'
        c='static int add_one(int x){ return x+1; }
int main(void){
    int (*fp)(int) = add_one;
    int a = fp(41);
    int b = add_one(a);
    return (a+b)%251;
}' ;;
    call_reassign)
        # One variable, two functions: the call must follow what the variable
        # holds *now*, not what it held at the declaration.
        ast='fn inc(x: i32) -> i32 { return x + 1; }
fn dec(x: i32) -> i32 { return x - 1; }
fn main() -> i32 {
    let fp: ptr = inc;
    let a: i32 = fp(10);
    fp = dec;
    let b: i32 = fp(10);
    return (a * 7 + b * 3) % 251;
}'
        c='static int inc(int x){ return x+1; }
static int dec(int x){ return x-1; }
int main(void){
    int (*fp)(int) = inc;
    int a = fp(10);
    fp = dec;
    int b = fp(10);
    return (a*7+b*3)%251;
}' ;;
    call_param)
        # The trampoline: the callee arrives as a parameter. This is the
        # callback shape — the reason the round exists.
        ast='fn double_it(x: i32) -> i32 { return x * 2; }
fn apply(g: ptr, x: i32) -> i32 { return g(x); }
fn main() -> i32 { return apply(double_it, 21) % 251; }'
        c='static int double_it(int x){ return x*2; }
static int apply(int (*g)(int), int x){ return g(x); }
int main(void){ return apply(double_it, 21)%251; }' ;;
    call_global)
        # A ptr global, filled by the synthetic initializer before main runs.
        # The call must load the pointer the global *holds* — branching to the
        # global's own address is the bug the first cut of this round shipped
        # (caught by this very case segfaulting under mutation m6).
        ast='fn triple(x: i32) -> i32 { return x * 3; }
let gp: ptr = triple;
fn main() -> i32 { return gp(14) % 251; }'
        c='static int triple(int x){ return x*3; }
static int (*gp)(int) = triple;
int main(void){ return gp(14)%251; }' ;;
    call_stack_args)
        # Ten arguments: the first eight ride in X0-X7, the ninth and tenth
        # are copied into the outgoing stack area — the same marshalling a
        # direct call uses, now reached through a BLR.
        ast='fn sum10(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32, h: i32, i: i32, j: i32) -> i32 {
    return a + b + c + d + e + f + g + h + i + j;
}
fn main() -> i32 {
    let fp: ptr = sum10;
    return fp(1, 2, 3, 4, 5, 6, 7, 8, 9, 10) % 251;
}'
        c='static int sum10(int a,int b,int c,int d,int e,int f,int g,int h,int i,int j){
    return a+b+c+d+e+f+g+h+i+j;
}
int main(void){
    int (*fp)(int,int,int,int,int,int,int,int,int,int) = sum10;
    return fp(1,2,3,4,5,6,7,8,9,10)%251;
}' ;;
    call_wide_literal)
        # A literal wider than i32 rides at full width into an i64 parameter,
        # and the callee's i64 result is read at i32 width — the documented
        # "an indirect call answers i32" contract, which the twin models by
        # casting exactly as the Aster consumer sees it.
        ast='fn wadd(a: i64, b: i64) -> i64 { return a + b; }
fn main() -> i32 {
    let fp: ptr = wadd;
    let r: i32 = fp(1000000000000, 7);
    return r % 251;
}'
        c='static long long wadd(long long a, long long b){ return a+b; }
int main(void){
    long long (*fp)(long long, long long) = wadd;
    int r = (int)fp(1000000000000LL, 7);
    return r%251;
}' ;;
    call_wide_shift)
        # The upper half of a wide argument made *observable*. The sum above
        # cannot tell a full-width stage from a truncated one — addition is
        # congruence-preserving mod 2^32 and the consumer reads i32 width — so
        # the callee here shifts the argument down instead: its answer is the
        # argument's upper half itself, and a stage that truncated it answers
        # a different number (this is the case mutation m5 must fail).
        ast='fn whigh(a: i64) -> i64 { return a >> 32; }
fn main() -> i32 {
    let fp: ptr = whigh;
    let r: i32 = fp(1000000000000);
    return r % 251;
}'
        c='static long long whigh(long long a){ return a>>32; }
int main(void){
    long long (*fp)(long long) = whigh;
    int r = (int)fp(1000000000000LL);
    return r%251;
}' ;;
    call_var64)
        # An i32 *variable* landing in an i64 parameter: the upper half of the
        # register must be the sign-extension of the value, not whatever the
        # register happened to hold — AAPCS64 leaves a sub-64-bit argument's
        # upper half unspecified, which is why every scalar argument of an
        # indirect call stages at 64-bit width.
        ast='fn wadd(a: i64, b: i64) -> i64 { return a + b; }
fn main() -> i32 {
    let x: i32 = 1000000000;
    let fp: ptr = wadd;
    let r: i32 = fp(x, 7);
    return r % 251;
}'
        c='static long long wadd(long long a, long long b){ return a+b; }
int main(void){
    int x = 1000000000;
    long long (*fp)(long long, long long) = wadd;
    int r = (int)fp(x, 7);
    return r%251;
}' ;;
    call_neg64)
        # A small *negative* literal into an i64 parameter: -7 fits i32, so a
        # per-argument-width staging would pass 0xFFFFFFF9 in a W register and
        # leave the upper half of X1 unspecified. Sign-extension at the
        # 64-bit stage is what makes this agree with the oracle.
        ast='fn wsub(a: i64, b: i64) -> i64 { return a - b; }
fn main() -> i32 {
    let fp: ptr = wsub;
    let r: i32 = fp(-1000000000000, -7);
    return r % 251;
}'
        c='static long long wsub(long long a, long long b){ return a-b; }
int main(void){
    long long (*fp)(long long, long long) = wsub;
    int r = (int)fp(-1000000000000LL, -7LL);
    return r%251;
}' ;;
    call_ptr_arg)
        # A pointer argument through the indirect call, and the callee reading
        # through it — the buffer arrives as the address it is.
        ast='fn pick_first(p: ptr) -> i32 { return load_u8(p); }
let buf: u8[4] = 0;
fn main() -> i32 {
    let a: i32 = store_u8(buf, 200);
    let fp: ptr = pick_first;
    return (fp(buf) + (a % 251)) % 251;
}'
        c='static unsigned char buf[4] __attribute__((aligned(8)));
static int pick_first(const void *p){ return *(const unsigned char*)p; }
int main(void){
    int a = 200; *(unsigned char*)buf = 200;
    int (*fp)(const void*) = pick_first;
    return (fp(buf) + (a%251))%251;
}' ;;
    call_bool_arg)
        # A bool argument: 0/1 in a W register, read by the callee as an int.
        # (bool constants come from comparisons — there are no true/false
        # literals in the language.)
        ast='fn flag(b: bool) -> i32 { if (b) { return 60; } return 6; }
fn main() -> i32 {
    let fp: ptr = flag;
    let t: bool = 1 < 2;
    let f: bool = 2 < 1;
    return (fp(t) + fp(f)) % 251;
}'
        c='static int flag(int b){ return b ? 60 : 6; }
int main(void){
    int (*fp)(int) = flag;
    int t = 1<2, f = 2<1;
    return (fp(t)+fp(f))%251;
}' ;;
    call_loop)
        ast='fn step(x: i32) -> i32 { return x + 3; }
fn main() -> i32 {
    let fp: ptr = step;
    let i: i32 = 0;
    let s: i32 = 0;
    while (i < 10) {
        s = s + fp(i);
        i = i + 1;
    }
    return s % 251;
}'
        c='static int step(int x){ return x+3; }
int main(void){
    int (*fp)(int) = step;
    int i=0, s=0;
    while(i<10){ s = s + fp(i); i = i+1; }
    return s%251;
}' ;;
    call_memory)
        # The dlsym shape: a function address that lives in memory (a struct
        # field, as a framework's callback table would hold one), read out
        # with load_ptr into a variable, and called through that. The pointer
        # is swapped between the two calls, so both loads are observed.
        ast='struct Box { f: ptr }
fn inc(x: i32) -> i32 { return x + 1; }
fn dec(x: i32) -> i32 { return x - 1; }
fn main() -> i32 {
    let b: Box = Box { "x" };
    b.f = inc;
    let q: ptr = load_ptr(&b);
    let a: i32 = q(20);
    b.f = dec;
    let r: ptr = load_ptr(&b);
    let c: i32 = r(20);
    return (a + c) % 251;
}'
        c='struct Box { int (*f)(int); };
static int inc(int x){ return x+1; }
static int dec(int x){ return x-1; }
int main(void){
    struct Box b; b.f = 0;               /* never called: overwritten first */
    b.f = inc;
    int (*q)(int) = b.f;
    int a = q(20);
    b.f = dec;
    int (*r)(int) = b.f;
    int c = r(20);
    return (a+c)%251;
}' ;;
    call_nested)
        # An indirect call whose argument is another indirect call's result:
        # the second call's staging must not disturb the first's registers.
        ast='fn twice(x: i32) -> i32 { return x * 2; }
fn wrap(x: i32) -> i32 { return x + 5; }
fn main() -> i32 {
    let a: ptr = twice;
    let b: ptr = wrap;
    return b(a(18)) % 251;
}'
        c='static int twice(int x){ return x*2; }
static int wrap(int x){ return x+5; }
int main(void){
    int (*a)(int) = twice;
    int (*b)(int) = wrap;
    return b(a(18))%251;
}' ;;
    call_zero_args)
        ast='fn answer() -> i32 { return 42; }
fn main() -> i32 {
    let fp: ptr = answer;
    return fp() % 251;
}'
        c='static int answer(void){ return 42; }
int main(void){
    int (*fp)(void) = answer;
    return fp()%251;
}' ;;
    call_mixed_widths)
        # One call, four widths: i32, ptr, a wide i64 literal, i32. The wide
        # literal is what a per-argument-width staging would truncate.
        ast='fn mix(a: i32, p: ptr, b: i64, c: i32) -> i32 { return a + load_u8(p) + (b % 100) + c; }
let buf: u8[4] = 0;
fn main() -> i32 {
    let a: i32 = store_u8(buf, 30);
    let fp: ptr = mix;
    let r: i32 = fp(1, buf, 1000000000007, 2);
    return (r + (a % 251)) % 251;
}'
        c='static unsigned char buf[4] __attribute__((aligned(8)));
static int mix(int a, const void *p, long long b, int c){
    return a + *(const unsigned char*)p + (int)(b%100) + c;
}
int main(void){
    int a = 30; *(unsigned char*)buf = 30;
    int (*fp)(int, const void*, long long, int) = mix;
    int r = fp(1, buf, 1000000000007LL, 2);
    return (r + (a%251))%251;
}' ;;
    call_neg)
        # Negative i32 values through the 32-bit half of the staging: the sign
        # bit must survive the round trip in both directions.
        ast='fn neg(x: i32) -> i32 { return -x; }
fn main() -> i32 {
    let fp: ptr = neg;
    let a: i32 = fp(-5);
    let b: i32 = fp(a);
    return (a + b) % 251;
}'
        c='static int neg(int x){ return -x; }
int main(void){
    int (*fp)(int) = neg;
    int a = fp(-5);
    int b = fp(a);
    return (a+b)%251;
}' ;;
    call_helper)
        # A helper that calls through the pointer twice: the second call's
        # staging runs while the first call's result is still live.
        ast='fn sq(x: i32) -> i32 { return x * x; }
fn twice_call(g: ptr, x: i32) -> i32 { return g(x) + g(x + 1); }
fn main() -> i32 { return twice_call(sq, 5) % 251; }'
        c='static int sq(int x){ return x*x; }
static int twice_call(int (*g)(int), int x){ return g(x)+g(x+1); }
int main(void){ return twice_call(sq, 5)%251; }' ;;
    precedence_function_wins)
        # A ptr variable sharing a function's name: in call position the
        # function wins, exactly as a user function shadows an intrinsic.
        # C's own scoping would answer the other way (the local hides the
        # function), so the twin spells the direct call explicitly — this case
        # pins Aster's documented precedence rule, not the platform ABI.
        ast='fn f(x: i32) -> i32 { return 100; }
fn other(x: i32) -> i32 { return 7; }
fn main() -> i32 {
    let f: ptr = other;
    return f(1) % 251;
}'
        c='static int f(int x){ (void)x; return 100; }
static int other(int x){ (void)x; return 7; }
int main(void){ return f(1)%251; }   /* Aster: the function wins in call position */' ;;
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
# [4b/7] The shared-object path. build-so already routed a function address
# through a GOT slot (that is how the callback table shipped), so an indirect
# call there is a BLR over a GOT-loaded pointer. The check is structural —
# the library builds, it contains the BLR, and no relocation targets raw text
# — because the .so path's bytes are the .so writer's business, not this
# suite's oracle.
printf '%s\n' '[4b/7] Shared object: the indirect call builds and branches'
printf '%s\n' 'fn add_one(x: i32) -> i32 { return x + 1; }
fn trampoline(g: ptr, x: i32) -> i32 { return g(x); }' > "$W/so.ast"
if ! "$OUT/aster" build-so "$W/so.ast" -o "$W/libindirect.so" --soname libindirect.so >"$W/so.log" 2>&1; then
    echo "FAIL: build-so rejected an indirect call:" >&2; cat "$W/so.log" >&2; exit 1
fi
if ! aarch64-linux-gnu-objdump -d "$W/libindirect.so" 2>/dev/null | grep -q 'blr'; then
    echo 'FAIL: the shared object contains no BLR — the indirect call did not branch' >&2; exit 1
fi
if aarch64-linux-gnu-readelf -r "$W/libindirect.so" 2>/dev/null | grep -q 'R_AARCH64_RELATIVE.*\.text'; then
    echo 'FAIL: the shared object carries a text relocation for a function address' >&2; exit 1
fi
echo 'OK: the shared object builds, branches through a register, and keeps its text clean'

# [4c/7] The shipped example, against its twin. examples/indirect_call.ast is
# the round's showcase — every callee form in one program — and the byte
# baseline records its three build modes but not that it still *runs* to the
# number its header claims. The twin (tests/indirect-call-example-twin.c) is
# compiled by the same oracle the battery uses; the two exit statuses must
# agree, exactly as every battery case's do.
printf '%s\n' '[4c/7] The shipped example, against its C twin'
if ! "$OUT/aster" build-elf examples/indirect_call.ast -o "$W/indirect_call" >"$W/ex.log" 2>&1; then
    echo "FAIL: examples/indirect_call.ast no longer builds:" >&2; cat "$W/ex.log" >&2; exit 1
fi
"$HOSTCC" -O2 -static -o "$W/indirect_call.twin" tests/indirect-call-example-twin.c
run "$W/indirect_call" >/dev/null 2>&1 && a=0 || a=$?
run "$W/indirect_call.twin" >/dev/null 2>&1 && c=0 || c=$?
[ "$a" -gt 127 ] && a=$((a-256)); [ "$c" -gt 127 ] && c=$((c-256))
if [ "$a" != "$c" ]; then
    echo "FAIL: examples/indirect_call.ast exits $a, its C twin $c" >&2; exit 1
fi
printf 'PASS: the example and its twin both exit %s\n' "$a"

# ---------------------------------------------------------------------------
# [5/7] Rejection matrix. What a ptr-variable callee is not, what cannot be
# passed to one, and the two boundaries the language cannot express (an extern
# function's address; a bool result from an untyped call).
printf '%s\n' '[5/7] Rejections: the callee and argument contracts are enforced'
reject(){ # reject <name> <source> <expected message fragment>
    printf '%s\n' "$2" > "$W/rej.ast"
    if "$OUT/aster" build-elf "$W/rej.ast" -o "$W/rej.a64" >"$W/rej.log" 2>&1; then
        echo "FAIL: $1 — was accepted" >&2; return 1
    fi
    if ! grep -q "$3" "$W/rej.log"; then
        echo "FAIL: $1 — wrong diagnostic:" >&2; cat "$W/rej.log" >&2; return 1
    fi
    printf 'PASS: rejected — %s\n' "$1"
}
reject "an i32 local as callee" \
    'fn main() -> i32 { let n: i32 = 5; return n(1); }' \
    "cannot call through 'n': expected a function pointer (ptr), got i32"
reject "a bool local as callee" \
    'fn main() -> i32 { let b: bool = 1 < 2; return b(1); }' \
    "cannot call through 'b': expected a function pointer (ptr), got bool"
reject "a struct local as callee" \
    'struct Box { v: i32 }
fn main() -> i32 { let s: Box = Box { 1 }; return s(1); }' \
    "cannot call through 's': expected a function pointer (ptr), got Box"
reject "a local array as callee" \
    'fn main() -> i32 { let a: i32[4] = 0; return a(1); }' \
    "cannot call through 'a': it is an array"
reject "an i32 global as callee" \
    'let g: i32 = 3;
fn main() -> i32 { return g(1); }' \
    "cannot call through 'g': expected a function pointer (ptr), got i32"
reject "a global array as callee" \
    'let ga: ptr[2] = 0;
fn main() -> i32 { return ga(1); }' \
    "cannot call through 'ga': it is an array"
reject "an undeclared callee" \
    'fn main() -> i32 { return nope(1); }' \
    "call to undeclared function: nope"
reject "a struct argument" \
    'fn f(x: i32) -> i32 { return x; }
struct Box { v: i32 }
fn main() -> i32 {
    let b: Box = Box { 1 };
    let fp: ptr = f;
    return fp(b);
}' \
    "an indirect call cannot take a struct argument"
reject "an extern function as the pointer's value" \
    'extern fn ext(x: i32) -> i32;
fn main() -> i32 { let fp: ptr = ext; return fp(1); }' \
    "cannot take the address of extern function 'ext'"
reject "a bool consumed from an indirect call" \
    'fn f(x: i32) -> i32 { return x; }
fn main() -> i32 { let fp: ptr = f; let b: bool = fp(1); return 0; }' \
    "type mismatch initializing 'b': expected bool"

# ---------------------------------------------------------------------------
# [6/7] Coverage map. Each named case reproduces a contract the feature
# actually has: the four callee forms, the two stack-travelling arguments, the
# wide/narrow staging that one width must serve, the memory-resident pointer,
# and the precedence rule. If a case is deleted without the map being updated,
# the map fails — that is the point of naming them.
printf '%s\n' '[6/7] Coverage map: the contract regressions stay resident'
for c in call_local call_reassign call_param call_global call_stack_args \
         call_wide_literal call_wide_shift call_var64 call_memory precedence_function_wins; do
    case " $CASES " in
        *" $c "*) printf 'PASS: coverage map holds — %s\n' "$c" ;;
        *) echo "FAIL: coverage map lost $c (it pins a contract, not a decoration)" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# [7/7] Mutation layer. Put each piece of damage back and require the battery
# to go red — a check that passes on a damaged compiler is not checking
# anything. Seven behavioural mutants (dispatch dropped, BLR demoted to BR,
# callee not materialized, sema resolution dropped, 64-bit staging reverted to
# 32-bit, the global callee loading its own address, the static linker's
# function-address permission withdrawn) plus one that removes a sema
# diagnostic and requires it to vanish — codegen's own guard still refuses the
# program, but with a worse message, which is why the diagnostic lives in sema.
printf '%s\n' '[7/7] Mutation: the checks above must fail on a damaged compiler'
build_mutant(){ # build_mutant <tag> <sed-expr>
    m="$1"
    if ! sed "$2" src/aster.cpp > "$OUT/$m.cpp"; then
        echo "FAIL: mutation $m sed failed" >&2; exit 1
    fi
    if cmp -s src/aster.cpp "$OUT/$m.cpp"; then
        echo "FAIL: mutation $m did not change the source (the guard is stale)" >&2; exit 1
    fi
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
must_lose_diagnostic(){ # must_lose_diagnostic <tag> <probe> <fragment> — the diagnostic is sema's, alone
    if "$OUT/$1.aster" build-elf "$W/$2.ast" -o "$OUT/$1.a64" 2>"$OUT/$1.msg"; then
        echo "FAIL: under mutation $1, $2 compiled — unexpected" >&2; exit 1
    fi
    if grep -qF "$3" "$OUT/$1.msg"; then
        echo "FAIL: under mutation $1, $2 still carries '$3' — the mutation did not damage the line that produces it" >&2; exit 1
    fi
    printf '  %-42s %s loses its sema diagnostic (a worse one still refuses it)\n' "$1" "$2"
}

build_mutant m1 's/if(!indirectCallee(e.name))/if(true)/'
must_not_compile m1 call_local
build_mutant m2 's/emit(0xd63f0000u|(9u<<5));/emit(0xd61f0000u|(9u<<5));/'
must_diverge m2 call_local
build_mutant m3 's/if(indirect&&e.k!=Expr::FieldCall)emitCalleeAddr(9,e.name);/if(false)emitCalleeAddr(9,e.name);/'
must_diverge m3 call_local
build_mutant m4 's/if(const Binding\* b=find(e.name)){/if(const Binding* b=find(e.name);false){/'
must_not_compile m4 call_local
build_mutant m5 's/return indirect?Ty::I64:/return indirect?Ty::I32:/'
must_diverge m5 call_wide_shift
build_mutant m6 's/emit(loadGlobalT(reg,Ty::Ptr));/emit(movX(reg,kGlobalBase));/'
must_diverge m6 call_global
build_mutant m7 's/resolveRelocations(mergedText,pending,symbolVaddr,symbolKind,textVaddr,\/\*funcAddrDirect=\*\/true);/resolveRelocations(mergedText,pending,symbolVaddr,symbolKind,textVaddr);/'
must_not_compile m7 call_local
# The struct-argument refusal is a diagnostic layer, not the only guard:
# codegen's struct-as-value rule refuses the same program with a worse
# message ("read its fields, or pass &b"). The mutation removes sema's line
# and requires the specific diagnostic to vanish — the message the rejection
# battery asserts on is produced by exactly that line.
printf '%s\n' 'fn f(x: i32) -> i32 { return x; }
struct Box { v: i32 }
fn main() -> i32 {
    let b: Box = Box { 1 };
    let fp: ptr = f;
    return fp(b);
}' > "$W/struct_arg.ast"
build_mutant m8 's/if(tyIsStruct(typeOf(\*e.args\[i\])))/if(false)/'
must_lose_diagnostic m8 struct_arg "an indirect call cannot take a struct argument"

printf '%s\n' 'ALL INDIRECT-CALL CHECKS PASSED'
