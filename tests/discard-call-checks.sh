#!/bin/sh
# tests/discard-call-checks.sh — a bare call whose result is thrown away:
# `foo();` and `h.onClick(41);` for fire-and-forget callbacks.
#
# v0.23.39-dev adds a discarded-call statement. Aster had no expression
# statement at all — every call result had to land in a `let`, a `return`, or
# an arithmetic position. That was deliberate (keep expressions side-effect
# free), but a *call* already has its side effects in the expression world — a
# function body runs when called, whether or not the caller keeps the answer —
# so the only thing the old rule actually blocked was writing the discard
# explicitly, not performing it indirectly (`let r = h.onClick(41) + 0;`).
#
# The new statement is deliberately narrow: only an expression whose outermost
# node is a Call or a FieldCall qualifies. `x;`, `a+b;` and the assignment
# forms keep their readings, so the language gains no meaningless expression
# statement (an `x;` you can never mean). The parser peeks far enough to tell
# `h.onClick(41)` (a discarded field call) from `h.field = v` (a field store)
# without consuming a token, so the new branch runs *before* the field-assign
# dispatch would catch the `h.` spelling.
#
# What "discard" means in codegen: the call is generated exactly as it would be
# for a value — the callee's side effects run — but the result register is
# released rather than bound. The type checker runs first (argument count,
# signature, width), so a discarded call is checked as hard as a kept one.
#
# Discipline: every behavioural case has an Aster source AND a C source, and
# the oracle is aarch64-linux-gnu-gcc -O2 -fwrapv under qemu — never a
# hand-computed expectation.
#
# Layers: strict build; source guards pinning each piece of the new machinery;
# the differential battery; the shipped example against its C twin; the
# rejection matrix (the narrowing is the feature, so it is tested here); the
# coverage map; and a mutation layer that damages each piece and requires the
# checks to go red.

set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-discard-call-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# [1/8] Strictly build the Aster compiler
printf '%s\n' '[1/8] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
# [2/8] Source guards. Each piece of the machinery is pinned by its exact text.
printf '%s\n' '[2/8] Source guards: the discarded-call machinery is pinned'
# The new statement kind. v0.23.49-dev inserted Switch between Continue and
# Expr (Round B); Expr still closes the enum as the discarded-call kind.
grep -qF 'Continue, Switch, Expr } k;' src/aster.cpp \
    || { echo 'FAIL: Stmt no longer carries the Expr (discarded call) kind' >&2; exit 1; }
# The peek that tells a discarded call from a field store.
grep -qF 'bool isCallStatement() const {' src/aster.cpp \
    || { echo 'FAIL: the parser no longer peeks for a call statement' >&2; exit 1; }
# The parser branch that builds the statement.
grep -qF 'if(isCallStatement()){' src/aster.cpp \
    || { echo 'FAIL: the parser no longer builds a discarded-call statement' >&2; exit 1; }
grep -qF 'Stmt s(Stmt::Expr);s.expr=std::move(e);' src/aster.cpp \
    || { echo 'FAIL: the parser no longer attaches the call to the statement' >&2; exit 1; }
# The Sema check — a discarded call is type-checked like a value.
grep -qF 'a discarded call — type-check it exactly as a' src/aster.cpp \
    || { echo 'FAIL: sema no longer checks a discarded call' >&2; exit 1; }
# v0.23.53-dev: the check enters through annotateExpr, which answers typeOf
# for the node (and recurses into its children) and throws exactly where the
# direct typeOf call did — the discarded call is still type-checked as a value.
grep -qF 'annotateExpr(*s.expr);' src/aster.cpp \
    || { echo 'FAIL: sema no longer type-checks the discarded call expression' >&2; exit 1; }
# The codegen — generate the call, then drop the result register.
grep -qF '} else if(s.k==Stmt::Expr){' src/aster.cpp \
    || { echo 'FAIL: codegen no longer handles a discarded-call statement' >&2; exit 1; }
grep -qF 'int d=gen(*s.expr);releaseTemp(d);' src/aster.cpp \
    || { echo 'FAIL: codegen no longer generates and releases the discarded call' >&2; exit 1; }
# The narrowing is explicit: only Call / FieldCall reach the branch.
grep -qF 'expression whose outermost node is a Call or a FieldCall qualifies' src/aster.cpp \
    || { echo 'FAIL: the discarded-call statement is no longer narrowed to calls' >&2; exit 1; }

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
    echo "SKIP: discarded-call coverage needs an AArch64 C compiler (none found)"
    exit 0
fi
printf 'int main(){return 0;}\n' > "$W/hostprobe.c"
if ! "$HOSTCC" -O2 -fwrapv "$W/hostprobe.c" -o "$W/hostprobe" 2>/dev/null \
   || ! readelf -h "$W/hostprobe" 2>/dev/null | grep -q 'AArch64'; then
    echo "SKIP: $HOSTCC does not emit AArch64 ELF (cross-compile toolchain missing)"
    exit 0
fi
if ! command -v qemu-aarch64 >/dev/null 2>&1 && [ "$(uname -m)" != "aarch64" ]; then
    echo "SKIP: discarded-call coverage needs qemu-aarch64 (or an AArch64 host)"
    exit 0
fi
run(){ sh tests/run-aarch64.sh "$@"; }

# ---------------------------------------------------------------------------
# [4/8] Differential battery. Each case writes $W/<name>.ast and $W/<name>.c,
# compiles both, runs both, and compares exit statuses — the oracle is gcc.
#
# Shape-complete over the discarded calls this round introduces:
#   forms      — a direct call `foo();`, a struct-field call `h.cb();`, and a
#                call whose discarded result is taken with ten arguments (the
#                last two on the stack);
#   widths     — an i64 result, a bool result, a ptr result, a zero-argument
#                call, and a call taken fresh each loop iteration;
#   the proof  — one case where the discard has no observable effect at all, so
#                the statement is shown to be a true drop and not a corruption
#                of the registers around it.
# Every case's exit depends on the discarded call's SIDE EFFECT (a global it
# writes), so "discard" is measured, never assumed.
printf '%s\n' '[4/8] Differential battery: every discarded-call shape, against the C oracle'
CASES="dc_direct dc_field dc_wide dc_zero dc_bool dc_ptr dc_stack dc_loop dc_harmless"

emit_case(){
    n="$1"
    case "$n" in
    dc_direct)
        # The simplest form: a direct call, result dropped, side effect counted.
        ast='let fired: i32 = 0;
fn bump(x: i32) -> i32 { fired = fired + 1; return x; }
fn main() -> i32 {
    bump(7);
    bump(3);
    bump(9);
    return fired % 251;
}'
        c='static int fired = 0;
static int bump(int x){ (void)x; fired = fired + 1; return x; }
int main(void){
    bump(7); bump(3); bump(9);
    return fired % 251;
}' ;;
    dc_field)
        # A discarded call through a struct field, side effect counted. The same
        # Handlers shape the callback-table round introduced, but called only
        # for the increment it performs.
        ast='struct H { cb: fn(i32) -> i32, tag: i32 }
let fired: i32 = 0;
fn handler(x: i32) -> i32 { fired = fired + 1; return x; }
fn main() -> i32 {
    let h: H = H { handler, 0 };
    h.cb(41);
    h.cb(2);
    h.tag = 0;
    return fired % 251;
}'
        c='struct H { int (*cb)(int); int tag; };
static int fired = 0;
static int handler(int x){ (void)x; fired = fired + 1; return x; }
int main(void){
    struct H h = { handler, 0 };
    h.cb(41); h.cb(2); h.tag = 0;
    return fired % 251;
}' ;;
    dc_wide)
        # An i64 result discarded: the call is still staged and its side effect
        # (writing a global i64) still runs; only the 64-bit answer is dropped.
        ast='let fired: i64 = 0;
fn setbig(x: i64) -> i64 { fired = x; return x; }
fn main() -> i32 {
    setbig(9000000000);
    let r: i64 = fired;
    return (r - 9000000000) % 251;
}'
        c='static long fired = 0;
static long setbig(long x){ fired = x; return x; }
int main(void){
    setbig(9000000000L);
    long r = fired;
    return (int)((r - 9000000000L) % 251);
}' ;;
    dc_zero)
        # The empty parameter list as a discarded call.
        ast='let fired: i32 = 0;
fn tick() -> i32 { fired = fired + 5; return 0; }
fn main() -> i32 {
    tick();
    return fired % 251;
}'
        c='static int fired = 0;
static int tick(void){ fired = fired + 5; return 0; }
int main(void){
    tick();
    return fired % 251;
}' ;;
    dc_bool)
        # A bool result discarded: the call runs, its side effect (a guarded
        # increment) is what the exit depends on.
        ast='let fired: i32 = 0;
fn setf(b: bool) -> bool { if (b) { fired = 1; } return b; }
fn main() -> i32 {
    setf(true);
    setf(false);
    return fired % 251;
}'
        c='static int fired = 0;
static int setf(int b){ if (b) fired = 1; return b; }
int main(void){
    setf(1); setf(0);
    return fired % 251;
}' ;;
    dc_ptr)
        # A ptr result discarded: eight bytes not read back, but the call ran.
        ast='let fired: i32 = 0;
fn setp(x: i32) -> ptr { fired = x; return 0; }
fn main() -> i32 {
    setp(13);
    return fired % 251;
}'
        c='static int fired = 0;
static void *setp(int x){ fired = x; return (void*)0; }
int main(void){
    setp(13);
    return fired % 251;
}' ;;
    dc_stack)
        # A discarded call carrying ten arguments: the ninth and tenth ride on
        # the stack, and the side effect (summing them into a global) still
        # lands.
        ast='let fired: i32 = 0;
fn rec(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32, h: i32, i: i32, j: i32) -> i32 {
    fired = a + b + c + d + e + f + g + h + i + j;
    return fired;
}
fn main() -> i32 {
    rec(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
    return fired % 251;
}'
        c='static int fired = 0;
static int rec(int a,int b,int c,int d,int e,int f,int g,int h,int i,int j){
    fired = a+b+c+d+e+f+g+h+i+j;
    return fired;
}
int main(void){
    rec(1,2,3,4,5,6,7,8,9,10);
    return fired % 251;
}' ;;
    dc_loop)
        # A discarded call taken fresh each iteration, its side effect the loop
        # body's only purpose.
        ast='let fired: i32 = 0;
fn tick(x: i32) -> i32 { fired = fired + x; return x; }
fn main() -> i32 {
    let i: i32 = 0;
    while (i < 5) {
        tick(i);
        i = i + 1;
    }
    return fired % 251;
}'
        c='static int fired = 0;
static int tick(int x){ fired = fired + x; return x; }
int main(void){
    int i = 0;
    while (i < 5) { tick(i); i = i + 1; }
    return fired % 251;
}' ;;
    dc_harmless)
        # The discard has no observable effect and must not corrupt the
        # registers around it: a nearby computation that does not touch the
        # discarded call's result must come out exactly as if the call had been
        # written as a value.
        ast='fn noop(x: i32) -> i32 { return x; }
fn main() -> i32 {
    let a: i32 = 10;
    let b: i32 = 20;
    noop(a + b);
    let c: i32 = a * b + 5;
    return c % 251;
}'
        c='static int noop(int x){ return x; }
int main(void){
    int a = 10;
    int b = 20;
    noop(a + b);
    int c = a * b + 5;
    return c % 251;
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
# [5/8] The shipped example, against its twin. examples/call-stmt.ast is the
# round's showcase: three fire-and-forget field calls plus two value calls,
# exit 56. Its C twin is tests/call-stmt-twin.c.
printf '%s\n' '[5/8] The shipped example, against its C twin'
if ! "$OUT/aster" build-elf examples/call-stmt.ast -o "$W/call_stmt" >"$W/ex.log" 2>&1; then
    echo "FAIL: examples/call-stmt.ast no longer builds:" >&2; cat "$W/ex.log" >&2; exit 1
fi
if ! "$HOSTCC" -O2 -fwrapv tests/call-stmt-twin.c -o "$W/call_stmt.c64" >"$W/ex2.log" 2>&1; then
    echo "FAIL: the C twin no longer builds:" >&2; cat "$W/ex2.log" >&2; exit 1
fi
run "$W/call_stmt" >/dev/null 2>&1 && ae=0 || ae=$?
run "$W/call_stmt.c64" >/dev/null 2>&1 && ce=0 || ce=$?
[ "$ae" -gt 127 ] && ae=$((ae-256))
[ "$ce" -gt 127 ] && ce=$((ce-256))
if [ "$ae" != "$ce" ]; then
    echo "FAIL: call-stmt.ast exits $ae, its C twin exits $ce" >&2; exit 1
fi
printf 'PASS: the example and its twin both exit %s\n' "$ae"

# ---------------------------------------------------------------------------
# [6/8] Rejections. The narrowing is the feature: a discarded call is checked
# exactly as a kept one, and a non-call expression is still refused.
printf '%s\n' '[6/8] Rejections: the discarded call stays checked, and non-calls stay refused'
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
reject "a bare variable is still not a statement" \
    'fn main() -> i32 { let x: i32 = 3; x; return 0; }' \
    "expected let, assignment, return, if, while, for, break, continue, or switch"
reject "an arithmetic expression is still not a statement" \
    'fn main() -> i32 { let x: i32 = 3; let y: i32 = 4; x + y; return 0; }' \
    "expected let, assignment, return, if, while, for, break, continue, or switch"
reject "a discarded direct call is still checked for argument count" \
    'fn f(a: i32) -> i32 { return a; }
fn main() -> i32 { f(1, 2); return 0; }' \
    "wrong argument count calling f: expected 1, got 2"
reject "a discarded field call is still checked for argument count" \
    'struct H { cb: fn(i32) -> i32 }
fn impl(a: i32) -> i32 { return a; }
fn main() -> i32 { let h: H = H { impl }; h.cb(1, 2); return 0; }' \
    "wrong argument count calling field 'cb': expected 1, got 2"

# ---------------------------------------------------------------------------
# [7/8] Coverage map. Each named case reproduces a contract the feature has:
# the direct form, the field form, the width the result is dropped at, the
# empty parameter list, the stack-passing form, and the proof that the drop is
# harmless. A coverage regression is a lost contract, not a lost decoration.
printf '%s\n' '[7/8] Coverage map: the contract regressions stay resident'
for c in dc_direct dc_field dc_wide dc_zero dc_stack dc_harmless; do
    case " $CASES " in
        *" $c "*) printf 'PASS: coverage map holds — %s\n' "$c" ;;
        *) echo "FAIL: coverage map lost $c (it pins a contract, not a decoration)" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# [8/8] Mutation layer. Put each piece of damage back and require the checks to
# go red — a check that passes on a damaged compiler is not checking anything.
# The pieces: the parser branch, the peek that feeds it, the Sema check, and
# the codegen that emits the call. Three damage modes are covered: a previously
# accepted program stops compiling (the path is gone), a previously refused
# program is accepted (the check is gone), and a previously matching program
# diverges from C (the call is no longer emitted).
printf '%s\n' '[8/8] Mutation: the checks above must fail on a damaged compiler'
build_mutant(){ # build_mutant <tag> <sed-expr>
    m="$1"
    sed "$2" src/aster.cpp > "$OUT/$m.cpp"
    if ! ${CXX:-c++} -std=c++17 -O0 -w "$OUT/$m.cpp" -o "$OUT/$m.aster" 2>"$OUT/$m.err"; then
        echo "FAIL: mutant $m does not build" >&2; sed -n '1,3p' "$OUT/$m.err" >&2; exit 1
    fi
}
must_not_compile(){ # must_not_compile <tag> <probe> — the mutation removed the
                    # path, so a program that compiled now fails.
    if "$OUT/$1.aster" build-elf "$W/$2.ast" -o "$OUT/$1.a64" >/dev/null 2>&1; then
        echo "FAIL: under mutation $1, $2 still compiles — the mutation did not remove the call-statement path" >&2; exit 1
    fi
    printf '  %-42s %s no longer compiles (path gone)\n' "$1" "$2"
}
must_accept(){ # must_accept <tag> <probe> — the mutation removed the check, so
               # a program that was refused is now accepted.
    if ! "$OUT/$1.aster" build-elf "$W/$2.ast" -o "$OUT/$1.a64" >/dev/null 2>&1; then
        echo "FAIL: under mutation $1, $2 is still refused — the type check was not removed" >&2; exit 1
    fi
    printf '  %-42s %s is now accepted (check gone)\n' "$1" "$2"
}
must_diverge(){ # must_diverge <tag> <probe> — the mutation stopped emitting the
                # call, so the program no longer matches its C twin.
    if ! "$OUT/$1.aster" build-elf "$W/$2.ast" -o "$OUT/$1.a64" >/dev/null 2>&1; then
        echo "FAIL: under mutation $1, $2 failed to build (should still build)" >&2; exit 1
    fi
    run "$OUT/$1.a64" >/dev/null 2>&1 && a=0 || a=$?
    run "$W/$2.c64" >/dev/null 2>&1 && c=0 || c=$?
    [ "$a" -gt 127 ] && a=$((a-256))
    [ "$c" -gt 127 ] && c=$((c-256))
    if [ "$a" = "$c" ]; then
        echo "FAIL: under mutation $1, $2 still matches C (exit $a) — the mutation did not change behaviour" >&2; exit 1
    fi
    printf '  %-42s %s diverges from C (call dropped)\n' "$1" "$2"
}

# Probes the mutation layer reuses, written here so each check really tests its
# mutation and not a missing file.
printf '%s\n' 'struct H { cb: fn(i32) -> i32 }
fn impl(x: i32) -> i32 { return x; }
fn main() -> i32 { let h: H = H { impl }; h.cb(1); return 0; }' > "$W/m_probe.ast"
printf '%s\n' 'struct S { tag: i32 }
fn main() -> i32 { let s: S = S { 7 }; s.tag(1); return 0; }' > "$W/rej_notfunc.ast"

# m1: the parser branch is gone, so a discarded field call falls through to the
# field-assign dispatch and fails to parse.
build_mutant m1 's/if(isCallStatement()){/if(false){/'
must_not_compile m1 m_probe
# m2: the Sema check is gone, so a discarded call of a field that is not a
# function type is now accepted — the "cannot call field 'tag'" refusal lived
# only in Sema (codegen does not re-check the field's kind), so dropping the
# check opens exactly that hole. (Argument-count is enforced independently in
# codegen too, so it is not the probe here.)
build_mutant m2 's|^                annotateExpr(\*s.expr);$|                ;|'
must_accept m2 rej_notfunc
# m3: codegen no longer emits the call, so the side effect it performed
# disappears and the program diverges from C.
build_mutant m3 's/int d=gen(\*s.expr);releaseTemp(d);/;/'
must_diverge m3 dc_direct
# m4: the peek itself always answers false, so the parser branch is never taken
# and a discarded field call fails exactly as under m1.
build_mutant m4 's/if(cur().k!=TK::Ident) return false;/if(true) return false;/'
must_not_compile m4 m_probe

printf '%s\n' 'ALL DISCARD-CALL CHECKS PASSED'
