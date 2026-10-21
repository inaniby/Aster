#!/bin/sh
# tests/function-type-checks.sh — typed function pointers, differentially.
#
# v0.23.37-dev gives a function pointer a *signature*. `fn(P1,..,Pn) -> R` is a
# new type spelling that rides beside a ptr variable, so an indirect call
# `fp(x)` is now checked and code-generated like the direct call it stands for:
#
#   - the argument count and each argument's type are checked against the
#     signature (the same checkArgument a direct call uses);
#   - each argument is staged at the width its signature declares — an i32
#     argument in a W register, an i64 one in a full X register (AAPCS64) —
#     retiring the "every scalar rides at 64 bits" rule for typed callees;
#   - the result is read at the signature's return type (i64/ptr/bool, not just
#     i32).
#
# A bare `ptr` is deliberately unchanged: funcSigOf answers null for it, so
# every untyped indirect call keeps the legacy 64-bit staging and i32 result,
# and every program written before this round compiles to the same bytes. The
# distinction is the whole design — the signature is carried *beside* the ptr
# (in Binding.funcSig / slotFuncSig / globalFuncSig), never in Ty itself.
#
# Discipline (carried over from every suite): every behavioural case has an
# Aster source AND a C source, and the oracle is aarch64-linux-gnu-gcc -O2
# -fwrapv under qemu — never a hand-computed expectation.
#
# Layers: strict build; source guards pinning each piece of the new machinery
# (the FuncSig record, the parser's fn branch and its capture at every
# declaration site, the two funcSigOf resolvers, the sema signature check, the
# gen call that hands the signature to the staging sequence, the staging
# sequence's signature-first width and return type, callType's typed answer,
# the global wiring, and the two refusals); the differential battery (locals,
# reassignment, the i64 width, i64/bool returns, a global, a fn-pointer
# parameter, zero/many/stack arguments, a struct by value, negatives, a loop,
# and nesting); the shipped example against its C twin; the rejection matrix;
# the coverage map; and a mutation layer that damages each piece and requires
# the battery to go red.

set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-function-type-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# [1/8] Strictly build the Aster compiler
printf '%s\n' '[1/8] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
# [2/8] Source guards. Each piece of the machinery is pinned by its exact text.
printf '%s\n' '[2/8] Source guards: the function-type machinery is pinned'
grep -qF 'struct FuncSig { std::vector<Ty> params; Ty ret=Ty::I32; };' src/aster.cpp \
    || { echo 'FAIL: the FuncSig record is missing' >&2; exit 1; }
# The parser's fn branch and the signature it parks.
grep -qF 'case TK::Fn: {' src/aster.cpp \
    || { echo "FAIL: parseType no longer has a 'fn' branch" >&2; exit 1; }
grep -qF 'out=Ty::Ptr; pendingFuncType=true; pendingFuncSig=std::move(sig);' src/aster.cpp \
    || { echo 'FAIL: a fn type no longer parks its signature for the declaration to capture' >&2; exit 1; }
# The capture at each declaration site (local let, parameter, global).
grep -qF 'if(pendingFuncType){s.funcSig=pendingFuncSig;s.isFunc=true;' src/aster.cpp \
    || { echo 'FAIL: a local fn-pointer no longer captures its signature' >&2; exit 1; }
grep -qF 'if(pendingFuncType){f.paramFuncSig.push_back(pendingFuncSig);f.paramIsFunc.push_back(true);' src/aster.cpp \
    || { echo 'FAIL: a fn-pointer parameter no longer captures its signature' >&2; exit 1; }
# The Binding carries it.
grep -qF 'FuncSig funcSig; bool isFunc=false; };' src/aster.cpp \
    || { echo 'FAIL: Binding no longer carries a function signature' >&2; exit 1; }
# The two resolvers.
grep -qF 'const FuncSig* funcSigOf(const std::string& n) const {' src/aster.cpp \
    || { echo "FAIL: sema's funcSigOf resolver is missing" >&2; exit 1; }
grep -qF 'const FuncSig* funcSigOf(const std::string& name) const {' src/aster.cpp \
    || { echo "FAIL: codegen's funcSigOf resolver is missing" >&2; exit 1; }
# The sema signature check.
grep -qF 'if(const FuncSig* fs=funcSigOf(e.name)){' src/aster.cpp \
    || { echo 'FAIL: sema no longer checks an indirect call against its signature' >&2; exit 1; }
# The gen call hands the signature to the staging sequence.
grep -qF 'int d=emitCallSeq(e,fs,0,0,true);' src/aster.cpp \
    || { echo 'FAIL: gen no longer hands the callee signature to the indirect call sequence' >&2; exit 1; }
# The staging sequence: signature-first width, signature return type.
grep -qF 'if(sig&&i<sig->params.size())return sig->params[i];' src/aster.cpp \
    || { echo 'FAIL: the staging sequence no longer stages an argument at its signature width' >&2; exit 1; }
grep -qF 'const Ty rt=indirect?(sig?sig->ret:Ty::I32):returnTypeOf(e.name);' src/aster.cpp \
    || { echo 'FAIL: the staging sequence no longer reads the result at the signature return type' >&2; exit 1; }
# callType answers the typed return.
grep -qF 'if(const FuncSig* fs=funcSigOf(e.name))return fs->ret;' src/aster.cpp \
    || { echo 'FAIL: callType no longer answers a typed fn-pointer its return type' >&2; exit 1; }
# The global wiring, both the codegen member and the driver's build step.
grep -qF 'std::map<std::string,FuncSig> globalFuncSig;' src/aster.cpp \
    || { echo 'FAIL: codegen no longer holds a global function-signature map' >&2; exit 1; }
grep -qF 'if(g.isFunc)globalFuncSigMap[g.name]=g.funcSig;' src/aster.cpp \
    || { echo 'FAIL: the driver no longer collects global function signatures' >&2; exit 1; }
# v0.23.38-dev retired both refusals this suite used to pin: a function may now
# return a fn-pointer (function-return-fn-checks.sh owns it) and a struct field
# may now hold one (callback-table-checks.sh owns it). What this suite pins is
# that the retired text stays retired — a refusal nobody is watching for is
# worse than no refusal at all — plus the captures the round added.
if grep -qF 'a function cannot return a function type' src/aster.cpp; then
    echo 'FAIL: v0.23.38-dev lets a function return a fn-pointer; the refusal came back' >&2; exit 1
fi
if grep -qF 'a struct field cannot have a function type' src/aster.cpp; then
    echo 'FAIL: v0.23.38-dev lets a struct field hold a fn-pointer; the refusal came back' >&2; exit 1
fi
grep -qF 'if(pendingFuncType){f.returnFuncSig=pendingFuncSig;f.returnIsFunc=true;' src/aster.cpp \
    || { echo 'FAIL: a function returning a fn-pointer no longer captures the signature' >&2; exit 1; }
grep -qF 'if(f.returnIsFunc)returnFuncSigMap[f.name]=f.returnFuncSig;' src/aster.cpp \
    || { echo 'FAIL: the driver no longer collects return signatures' >&2; exit 1; }
grep -qF 'else if(isFuncType&&cur().k!=TK::Eq){' src/aster.cpp \
    || { echo 'FAIL: a fn-pointer global may no longer be declared without an initializer' >&2; exit 1; }
if [ "$(grep -cF 'const FuncSig* funcSigOf(' src/aster.cpp)" -ne 2 ]; then
    echo 'FAIL: there must be exactly two funcSigOf resolvers (sema and codegen)' >&2; exit 1
fi

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
    echo "SKIP: function-type coverage needs an AArch64 C compiler (none found)"
    exit 0
fi
printf 'int main(){return 0;}\n' > "$W/hostprobe.c"
if ! "$HOSTCC" -O2 -fwrapv "$W/hostprobe.c" -o "$W/hostprobe" 2>/dev/null \
   || ! readelf -h "$W/hostprobe" 2>/dev/null | grep -q 'AArch64'; then
    echo "SKIP: $HOSTCC does not emit AArch64 ELF (cross-compile toolchain missing)"
    exit 0
fi
if ! command -v qemu-aarch64 >/dev/null 2>&1 && [ "$(uname -m)" != "aarch64" ]; then
    echo "SKIP: function-type coverage needs qemu-aarch64 (or an AArch64 host)"
    exit 0
fi
run(){ sh tests/run-aarch64.sh "$@"; }

# ---------------------------------------------------------------------------
# [4/8] Differential battery. Each case writes $W/<name>.ast and
# $W/<name>.c, compiles both, runs both, and compares exit statuses — the
# oracle is gcc, nobody writes a number down.
#
# The battery is shape-complete:
#   callee forms — a local, reassignment of one variable to two functions, a
#                 global filled at run time, and a fn-pointer *parameter*
#                 applied inside a helper;
#   widths       — the round's centrepiece: an i64 argument staged at full
#                 width so a shift reads its upper half back (a truncated
#                 stage answers 0), an i64 *return* read at full width, and a
#                 negative i64;
#   return types — i64, bool, u32, and the i32 default;
#   argument forms — none, one, three of mixed class (i32/ptr/bool), ten (the
#                 ninth and tenth travel on the stack), and a struct by value;
#   call forms — in a loop, and nested as an argument.
printf '%s\n' '[4/8] Differential battery: every typed-call shape, against the C oracle'
CASES="ft_local ft_reassign ft_wide_shift ft_i64_ret ft_neg64 ft_bool_ret \
ft_global ft_global_wide ft_param ft_zero_args ft_multi ft_stack_args \
ft_struct_arg ft_loop ft_nested"

emit_case(){
    n="$1"
    case "$n" in
    ft_local)
        ast='fn inc(x: i32) -> i32 { return x + 1; }
fn main() -> i32 {
    let fp: fn(i32) -> i32 = inc;
    let a: i32 = fp(41);
    let b: i32 = inc(a);
    return (a + b) % 251;
}'
        c='static int inc(int x){ return x+1; }
int main(void){
    int (*fp)(int) = inc;
    int a = fp(41);
    int b = inc(a);
    return (a+b)%251;
}' ;;
    ft_reassign)
        ast='fn inc(x: i32) -> i32 { return x + 1; }
fn dec(x: i32) -> i32 { return x - 1; }
fn main() -> i32 {
    let fp: fn(i32) -> i32 = inc;
    let a: i32 = fp(10);
    fp = dec;
    let b: i32 = fp(10);
    return (a * 100 + b) % 251;
}'
        c='static int inc(int x){ return x+1; }
static int dec(int x){ return x-1; }
int main(void){
    int (*fp)(int) = inc;
    int a = fp(10);
    fp = dec;
    int b = fp(10);
    return (a*100+b)%251;
}' ;;
    ft_wide_shift)
        # The centrepiece. A 64-bit argument must ride at full width, or the
        # callee's >> 32 reads a zero upper half. The twin's `long` is what the
        # platform ABI does; Aster's typed stage must match it.
        ast='fn high32(a: i64) -> i64 { return a >> 32; }
fn main() -> i32 {
    let big: i64 = 0;
    big = big + 4294967296;
    let fp: fn(i64) -> i64 = high32;
    let hi: i64 = fp(big);
    return hi - 1;
}'
        c='static long high32(long a){ return a >> 32; }
int main(void){
    long big = 0;
    big = big + 4294967296L;
    long (*fp)(long) = high32;
    long hi = fp(big);
    return (int)(hi - 1);
}' ;;
    ft_i64_ret)
        # An i64 return must be read at full width, not collapsed to i32. The
        # result is nested in an addition so a live temporary forces the result
        # move to run at the signature's width (with the result alone in
        # register 0 the width is moot) — the high half carries the only
        # nonzero bit, so a 32-bit read answers 0.
        ast='fn dbl(a: i64) -> i64 { return a + a; }
fn main() -> i32 {
    let fp: fn(i64) -> i64 = dbl;
    let big: i64 = 0;
    big = big + 2147483648;
    let seed: i64 = 0;
    let r: i64 = seed + fp(big);
    let hi: i64 = r >> 32;
    return hi - 1;
}'
        c='static long dbl(long a){ return a+a; }
int main(void){
    long (*fp)(long) = dbl;
    long big = 0;
    big = big + 2147483648L;
    long seed = 0;
    long r = seed + fp(big);
    long hi = r >> 32;
    return (int)(hi - 1);
}' ;;
    ft_neg64)
        # A negative i64 argument, staged at full width (sign-extended).
        ast='fn sq(a: i64) -> i64 { return a * a; }
fn main() -> i32 {
    let fp: fn(i64) -> i64 = sq;
    let r: i64 = fp(-3);
    return r - 9;
}'
        c='static long sq(long a){ return a*a; }
int main(void){
    long (*fp)(long) = sq;
    long r = fp(-3);
    return (int)(r - 9);
}' ;;
    ft_bool_ret)
        ast='fn isodd(x: i32) -> bool { return (x & 1) == 1; }
fn main() -> i32 {
    let fp: fn(i32) -> bool = isodd;
    let a: bool = fp(3);
    let b: bool = fp(4);
    if (a) { if (b) { return 2; } return 0; }
    return 1;
}'
        c='static int isodd(int x){ return (x&1)==1; }
int main(void){
    int (*fp)(int) = isodd;
    int a = fp(3);
    int b = fp(4);
    if (a) { if (b) return 2; return 0; }
    return 1;
}' ;;
    ft_global)
        ast='fn dbl(x: i32) -> i32 { return x + x; }
let gfp: fn(i32) -> i32;
fn main() -> i32 {
    gfp = dbl;
    let a: i32 = gfp(21);
    return a - 42;
}'
        c='static int dbl(int x){ return x+x; }
static int (*gfp)(int);
int main(void){
    gfp = dbl;
    int a = gfp(21);
    return a - 42;
}' ;;
    ft_global_wide)
        # The global wiring: a global typed fn-pointer's signature must reach
        # the call, so an i64 return is read at full width here too. Nested in
        # an addition for the same reason ft_i64_ret is — the high half carries
        # the only nonzero bit.
        ast='fn setbit() -> i64 {
    let r: i64 = 0;
    r = r + 4294967296;
    return r;
}
let gfp: fn() -> i64;
fn main() -> i32 {
    gfp = setbit;
    let seed: i64 = 0;
    let r: i64 = seed + gfp();
    let hi: i64 = r >> 32;
    return hi - 1;
}'
        c='static long setbit(void){
    long r = 0;
    r = r + 4294967296L;
    return r;
}
static long (*gfp)(void);
int main(void){
    gfp = setbit;
    long seed = 0;
    long r = seed + gfp();
    long hi = r >> 32;
    return (int)(hi - 1);
}' ;;
    ft_param)
        # A fn-pointer parameter: its signature travels with it and is used by
        # the indirect call inside apply.
        ast='fn dbl(x: i32) -> i32 { return x + x; }
fn apply(op: fn(i32) -> i32, x: i32) -> i32 { return op(x); }
fn main() -> i32 {
    let a: i32 = apply(dbl, 5);
    let fp: fn(i32) -> i32 = dbl;
    let b: i32 = apply(fp, 5);
    return a + b - 20;
}'
        c='static int dbl(int x){ return x+x; }
static int apply(int (*op)(int), int x){ return op(x); }
int main(void){
    int a = apply(dbl, 5);
    int (*fp)(int) = dbl;
    int b = apply(fp, 5);
    return a + b - 20;
}' ;;
    ft_zero_args)
        ast='fn answer() -> i32 { return 42; }
fn main() -> i32 {
    let fp: fn() -> i32 = answer;
    let a: i32 = fp();
    return a - 42;
}'
        c='static int answer(void){ return 42; }
int main(void){
    int (*fp)(void) = answer;
    int a = fp();
    return a - 42;
}' ;;
    ft_multi)
        ast='fn mix(a: i32, p: ptr, b: bool) -> u32 {
    if (b) { return a + 1; }
    return a;
}
fn main() -> i32 {
    let fp: fn(i32, ptr, bool) -> u32 = mix;
    let a: u32 = fp(41, 0, true);
    let b: u32 = fp(100, 0, false);
    return a + b - 142;
}'
        c='static unsigned mix(int a, void *p, int b){
    if (b) return a+1;
    return a;
}
int main(void){
    unsigned (*fp)(int, void*, int) = mix;
    unsigned a = fp(41, 0, 1);
    unsigned b = fp(100, 0, 0);
    return (int)(a + b - 142);
}' ;;
    ft_stack_args)
        ast='fn add10(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32, h: i32, i: i32, j: i32) -> i32 {
    return a + b + c + d + e + f + g + h + i + j;
}
fn main() -> i32 {
    let fp: fn(i32, i32, i32, i32, i32, i32, i32, i32, i32, i32) -> i32 = add10;
    let r: i32 = fp(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
    return r - 55;
}'
        c='static int add10(int a,int b,int c,int d,int e,int f,int g,int h,int i,int j){
    return a+b+c+d+e+f+g+h+i+j;
}
int main(void){
    int (*fp)(int,int,int,int,int,int,int,int,int,int) = add10;
    int r = fp(1,2,3,4,5,6,7,8,9,10);
    return r - 55;
}' ;;
    ft_struct_arg)
        # A struct passed by value: the signature names the struct, so the
        # staging pipeline marshals it across the registers AAPCS64 assigns a
        # 12-byte composite (two of them). It is >8 bytes on purpose — a bare
        # ptr still refuses a struct argument, and a signature-blind stage
        # would pass only the first register and lose the third field.
        ast='struct Tri { a: i32, b: i32, c: i32 }
fn sum(t: Tri) -> i32 { return t.a + t.b + t.c; }
fn main() -> i32 {
    let fp: fn(Tri) -> i32 = sum;
    let t: Tri = Tri { 10, 20, 30 };
    let r: i32 = fp(t);
    return r - 60;
}'
        c='struct Tri { int a; int b; int c; };
static int sum(struct Tri t){ return t.a+t.b+t.c; }
int main(void){
    int (*fp)(struct Tri) = sum;
    struct Tri t = {10, 20, 30};
    int r = fp(t);
    return r - 60;
}' ;;
    ft_loop)
        ast='fn dbl(x: i32) -> i32 { return x + x; }
fn main() -> i32 {
    let fp: fn(i32) -> i32 = dbl;
    let s: i32 = 0;
    for (let k: i32 = 0; k < 5; k = k + 1) {
        s = s + fp(k);
    }
    return s - 20;
}'
        c='static int dbl(int x){ return x+x; }
int main(void){
    int (*fp)(int) = dbl;
    int s = 0;
    for (int k = 0; k < 5; k++) s = s + fp(k);
    return s - 20;
}' ;;
    ft_nested)
        ast='fn inc(x: i32) -> i32 { return x + 1; }
fn dbl(x: i32) -> i32 { return x + x; }
fn main() -> i32 {
    let a: fn(i32) -> i32 = inc;
    let b: fn(i32) -> i32 = dbl;
    let r: i32 = a(b(20));
    return r - 41;
}'
        c='static int inc(int x){ return x+1; }
static int dbl(int x){ return x+x; }
int main(void){
    int (*a)(int) = inc;
    int (*b)(int) = dbl;
    int r = a(b(20));
    return r - 41;
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
# [5/8] The shipped example, against its twin. examples/fn_type.ast is the
# round's showcase — every callee form in one program — and its C twin is
# tests/function-type-twin.c; the two exit statuses must agree, exactly as
# every battery case's do.
printf '%s\n' '[5/8] The shipped example, against its C twin'
if ! "$OUT/aster" build-elf examples/fn_type.ast -o "$W/fn_type" >"$W/ex.log" 2>&1; then
    echo "FAIL: examples/fn_type.ast no longer builds:" >&2; cat "$W/ex.log" >&2; exit 1
fi
"$HOSTCC" -O2 -static -o "$W/fn_type.twin" tests/function-type-twin.c
run "$W/fn_type" >/dev/null 2>&1 && a=0 || a=$?
run "$W/fn_type.twin" >/dev/null 2>&1 && c=0 || c=$?
[ "$a" -gt 127 ] && a=$((a-256)); [ "$c" -gt 127 ] && c=$((c-256))
if [ "$a" != "$c" ]; then
    echo "FAIL: examples/fn_type.ast exits $a, its C twin $c" >&2; exit 1
fi
printf 'PASS: the example and its twin both exit %s\n' "$a"

# ---------------------------------------------------------------------------
# [6/8] Rejection matrix. What a typed call refuses: the wrong argument count,
# the wrong argument type (each class the signature can name), the two
# misspellings of the type, and the two positions a function type may not
# occupy (a function's return, a struct's field).
printf '%s\n' '[6/8] Rejections: the signature contracts are enforced'
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
reject "the wrong argument count (a local)" \
    'fn f(x: i32) -> i32 { return x; }
fn main() -> i32 { let fp: fn(i32) -> i32 = f; return fp(1, 2); }' \
    "wrong argument count calling fp: expected 1, got 2"
reject "the wrong argument count (a global)" \
    'fn f(x: i32) -> i32 { return x; }
let gfp: fn(i32) -> i32;
fn main() -> i32 { gfp = f; return gfp(); }' \
    "wrong argument count calling gfp: expected 1, got 0"
reject "a ptr argument to an i32 parameter" \
    'fn f(x: i32) -> i32 { return x; }
fn main() -> i32 { let fp: fn(i32) -> i32 = f; let p: ptr = 0; return fp(p); }' \
    "argument type mismatch calling fp at argument 1"
reject "a bool argument to an i32 parameter" \
    'fn f(x: i32) -> i32 { return x; }
fn main() -> i32 { let fp: fn(i32) -> i32 = f; return fp(true); }' \
    "argument type mismatch calling fp at argument 1"
reject "a non-bool argument to a bool parameter" \
    'fn f(b: bool) -> i32 { return 0; }
fn main() -> i32 { let fp: fn(bool) -> i32 = f; return fp(5); }' \
    "argument type mismatch calling fp at argument 1"
reject "a fn type without its arrow" \
    'fn main() -> i32 { let fp: fn(i32) i32 = 0; return 0; }' \
    "expected '->' in a function type"
reject "a fn type without its parentheses" \
    'fn main() -> i32 { let fp: fn i32 -> i32 = 0; return 0; }' \
    "expected '(' after fn"
reject "a returned fn-pointer whose signature is not the return type's" \
    'fn wide(x: i64) -> i64 { return x; }
fn f() -> fn(i32) -> i32 { return wide; }
fn main() -> i32 { return 0; }' \
    "return type mismatch in function f"
reject "an array of fn-pointers as a struct field" \
    'struct S { f: fn(i32) -> i32[2] }
fn main() -> i32 { return 0; }' \
    "an array of function pointers is not supported: S.f"

# ---------------------------------------------------------------------------
# [7/8] Coverage map. Each named case reproduces a contract the feature
# actually has: the width the round was built for, the typed return, every
# callee form, and the two stack-travelling arguments. If a case is deleted
# without the map being updated, the map fails — that is the point of naming
# them.
printf '%s\n' '[7/8] Coverage map: the contract regressions stay resident'
for c in ft_local ft_wide_shift ft_i64_ret ft_global ft_param ft_struct_arg ft_stack_args; do
    case " $CASES " in
        *" $c "*) printf 'PASS: coverage map holds — %s\n' "$c" ;;
        *) echo "FAIL: coverage map lost $c (it pins a contract, not a decoration)" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# [8/8] Mutation layer. Put each piece of damage back and require the battery
# to go red — a check that passes on a damaged compiler is not checking
# anything. The pieces: sema's resolver (signature checks vanish), the
# staging sequence's signature-first width (i64 truncated), the result width
# (i64 return collapsed), the gen call that hands the signature over (typed
# call reverts to the untyped rule), the parser's fn branch (typed
# declarations stop parsing), the global wiring (a global's signature is
# lost), and the two position refusals (a diagnostic must vanish).
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
must_lose_diagnostic(){ # must_lose_diagnostic <tag> <probe> <fragment>
    if "$OUT/$1.aster" build-elf "$W/$2.ast" -o "$OUT/$1.a64" 2>"$OUT/$1.msg"; then
        echo "FAIL: under mutation $1, $2 compiled — unexpected" >&2; exit 1
    fi
    if grep -qF "$3" "$OUT/$1.msg"; then
        echo "FAIL: under mutation $1, $2 still carries '$3' — the mutation did not damage the line that produces it" >&2; exit 1
    fi
    printf '  %-42s %s loses its diagnostic (a worse one may still refuse it)\n' "$1" "$2"
}

must_accept(){ # must_accept <tag> <probe> — the mutation took the check away,
               # so what was refused is now accepted: that is the damage.
    if ! "$OUT/$1.aster" build-elf "$W/$2.ast" -o "$OUT/$1.a64" >/dev/null 2>&1; then
        echo "FAIL: under mutation $1, $2 is still refused — the mutation did not remove the check" >&2; exit 1
    fi
    printf '  %-42s %s is accepted (the signature check is gone)\n' "$1" "$2"
}

# Probes the mutation layer reuses: the two rejection sources (for m7/m8).
# Written here, before the layer runs, so each check really tests its mutation
# and not a missing file. v0.23.38-dev turned both positions into *legal* ones,
# so what is refused at each is now the signature contract inside them: a
# returned fn-pointer of the wrong shape, and an array of fn-pointers.
printf '%s\n' 'fn wide(x: i64) -> i64 { return x; }
fn f() -> fn(i32) -> i32 { return wide; }
fn main() -> i32 { return 0; }' > "$W/rej_ret.ast"
printf '%s\n' 'struct S { f: fn(i32) -> i32[2] }
fn main() -> i32 { return 0; }' > "$W/rej_field.ast"

# m1: sema's resolver never returns a local/parameter signature → the call is
# treated as a bare ptr, whose path refuses a struct argument. The struct-by-
# value battery case is only legal *because* sema sees the signature that names
# the struct, so this mutation must turn it back into a compile error.
build_mutant m1 's/if(b->isFunc) return &b->funcSig;/if(false) return \&b->funcSig;/'
must_not_compile m1 ft_struct_arg
# m2: the staging sequence loses its signature-first width → a struct argument
# is no longer recognised as a composite, so codegen tries to stage it as a
# scalar and refuses it ("cannot use a whole struct as a value").
build_mutant m2 's/if(sig&&i<sig->params.size())return sig->params\[i\];//'
must_not_compile m2 ft_struct_arg
# m3: the result width is forced to i32 → an i64 return is collapsed.
build_mutant m3 's/const Ty rt=indirect?(sig?sig->ret:Ty::I32):returnTypeOf(e.name);/const Ty rt=indirect?Ty::I32:returnTypeOf(e.name);/'
must_diverge m3 ft_i64_ret
# m4: gen hands a null signature to the staging sequence → a typed call reverts
# to the untyped 64-bit rule and mis-reads the i64 result.
build_mutant m4 's/int d=emitCallSeq(e,fs,0,0,true);/int d=emitCallSeq(e,(const FuncSig*)0,0,0,true);/'
must_diverge m4 ft_i64_ret
# m5: the parser's fn branch stops producing a signature → typed declarations
# stop parsing at all.
build_mutant m5 's/out=Ty::Ptr; pendingFuncType=true; pendingFuncSig=std::move(sig);/return false;/'
must_not_compile m5 ft_local
# m6: the driver never collects a global signature → a global typed call loses
# its checks and its width.
build_mutant m6 's/if(g.isFunc)globalFuncSigMap\[g.name\]=g.funcSig;/if(false)globalFuncSigMap[g.name]=g.funcSig;/'
must_diverge m6 ft_global_wide
# m7: the return slot stops checking by signature — a function that promises
# `-> fn(i32) -> i32` may then return any pointer at all, and the mismatch is
# discovered at the first call instead of where it is written.
build_mutant m7 's/if(retIsFunc&&actual==Ty::Ptr)/if(false)/'
must_accept m7 rej_ret
# m8: the array-of-fn-pointers refusal loses its specific diagnostic.
build_mutant m8 's/throw Error(loc(fn.line,fn.col,"an array of function pointers is not supported: "+id.s+"."+fn.s));/throw Error("no");/'
must_lose_diagnostic m8 rej_field "an array of function pointers"

printf '%s\n' 'ALL FUNCTION-TYPE CHECKS PASSED'
