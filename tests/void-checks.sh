#!/bin/sh
# tests/void-checks.sh — `void` as a function return type.
#
# AUDIT-v0.23.61-dev.md's third part listed the language's gaps: `typedef`/
# type alias (1), `const` (2), `void` (3), `char` (4), `union` (5). Rounds
# v0.23.67-dev and v0.23.68-dev close the first three. `void` is the one that
# unlocks C-ABI interop: an Aster void function must link against, and be
# linked into, C that returns nothing, under the same AAPCS rule (no value in
# X0) the C compiler already obeys.
#
# What `void` is and is not:
#
#   * A return-slot property only. `void` names a return type and nothing else;
#     a parameter, a local, a global, a struct field and a type alias may not
#     be void. The guard lives in one place — needType's allowVoid flag — so
#     every spelling site that is not a return type refuses it with one
#     message, and the two return-type sites (a function declaration and a
#     fn-type) pass allowVoid=true.
#
#   * A void function still has a prologue and an epilogue, still links, and
#     still runs under the same ABI as any other Aster function. It may say
#     `return;` with no value, and — because it returns nothing — it may fall
#     off the end of its body, exactly as C permits. A value-returning
#     function still must return a value.
#
#   * The result of a void call is not a value. `let x = f();`, `x = f();`,
#     `return f();`, `g(f())` and `f() + 1` are all type errors, and a void
#     value used as an operand is refused at the operator. One predicate,
#     isVoidUsingOp, guards the operator case; the rest ride on the ordinary
#     type-mismatch machinery because a void call resolves to Ty::Void.
#
# The oracle is gcc: `void` is a C spelling, so every behavioural case has a C
# twin and the two must agree on the exit status under qemu, and every refusal
# has a C twin gcc must refuse too.
#
# Layers (the project 9-layer shape): strict build; source guards pinning
# every piece of the machinery plus the reserved-word list; an independent
# reader (a C program that links Aster's void function, proving the ABI); a
# gcc differential over several cases; a refusal matrix, most of whose entries
# gcc must refuse as well; the shipped example against its C twin; coverage
# counting; six mutations; and the byte baseline for the void example.

set -eu
cd "$(dirname "$0")/.."
. tests/lib/baseline.sh
. tests/lib/verdict.sh
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-void-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
run(){ sh "$RUNNER" "$@"; }

# The differential, the independent reader and the behavioural witnesses need a
# cross gcc and a way to run AArch64; without them those layers say SKIP with a
# reason and the rest of the suite still runs.
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
if [ -z "$HOSTCC" ] && command -v cc >/dev/null 2>&1; then HOSTCC=cc; fi
have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
if [ "$have_qemu" = yes ] && [ -n "$HOSTCC" ]; then
    printf 'int main(void){return 0;}\n' > "$W/probe.c"
    if ! "$HOSTCC" -O2 -fwrapv "$W/probe.c" -o "$W/probe" >/dev/null 2>&1; then
        have_qemu=no
    elif ! run "$W/probe" >/dev/null 2>&1; then
        have_qemu=no
    fi
fi

# ---------------------------------------------------------------------------
# [1/9] Strictly build the Aster compiler
printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
A=$OUT/aster

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each piece of the feature is pinned by its text.
printf '%s\n' '[2/9] Source guards: the void machinery'
guard_count=0
guard(){ # $1 = literal source text, $2 = what it is
    grep -qF "$1" src/aster.cpp \
        || { printf 'FAIL: %s is gone\n' "$2" >&2; exit 1; }
    guard_count=$((guard_count + 1))
}
grep -qF '#define ASTER_VERSION_STRING "0.23.68-dev"' src/aster.cpp \
    || { echo "FAIL: the version constant is not 0.23.68-dev" >&2; exit 1; }
guard ' Fn, Extern, Main, Let, Return, If, Else, While, For, Break, Continue, I32, Ptr, Bool, Void,' 'the Void token'
guard 'else if(x=="void")k=TK::Void;' 'the void reserved word'
guard 'enum Kind { I32, U32, U8, U16, I64, U64, Ptr, Bool, Enum, Struct, Void };' 'the Void type'
guard 'if (t.k == Ty::Void) return 0u;' 'void has no storage (tySize)'
guard 'if (t.k == Ty::Void) return 1u;' 'void never used as storage (tyAlign)'
guard 'case Ty::Void: return "void";' 'void names itself'
guard 'case TK::Void:out=Ty::Void; ++p; return true;' 'void parsed as a type'
guard 'Ty needType(const char* what, bool allowVoid=false){' 'the allowVoid gate on type parsing'
guard 'void is only a function return type at ' 'the one refusal message for void-as-value'
guard 'const Ty rty=needType(kTypeExpected,/*allowVoid=*/true);' 'the return-type position allows void'
guard 'sig.ret=needType("<function return type>",/*allowVoid=*/true);' 'the fn-type return position allows void'
guard 'a type alias cannot be void: ' 'the refusal to alias void'
guard 'static bool isVoidUsingOp(Expr::Kind k){' 'the operator-side void check'
guard 'a void value cannot be used in an expression' 'the operator refusal message'
guard 'void retVoid(){' 'the shared void epilogue'
guard 'if(s.expr)ret(*s.expr);else retVoid();' 'the return statement honours void'
guard 'if(f.retType!=Ty::Void&&!definitelyReturns(f.body))' 'a void function may fall off the end'
guard 'if(f.retType==Ty::Void&&!definitelyReturns(f.body))retVoid();' 'a void function epilogues on fall-through'
guard 'if(retType==Ty::Void){' 'the Sema void return branch'
guard 'cannot return a value from a void function ' 'the refusal to return a value from void'
# The void refusals appear at distinct sites; the count is part of the guard so
# a later round cannot quietly drop one.
[ "$(grep -c 'void is only a function return type at ' src/aster.cpp)" = 1 ] \
    || { echo 'FAIL: expected one "void is only a function return type" site' >&2; exit 1; }
guard_count=$((guard_count + 1))
[ "$(grep -c 'cannot return a value from a void function ' src/aster.cpp)" = 1 ] \
    || { echo 'FAIL: expected one "cannot return a value from a void function" site' >&2; exit 1; }
guard_count=$((guard_count + 1))
[ "$(grep -c 'a void value cannot be used in an expression' src/aster.cpp)" = 2 ] \
    || { echo 'FAIL: expected two "a void value cannot be used in an expression" sites' >&2; exit 1; }
guard_count=$((guard_count + 1))
# The reserved-word list is generated, not hand-written: 30 words now that
# `void` joined `type` and `const`, and `tls` is still a context keyword.
python3 - <<'PY' || exit 1
import re
src = open('bootstrap/gen_lexer_names.py').read()
m = re.search(r'KEYWORDS = \[(.*?)\]', src, re.S)
entries = re.findall(r'\("([^"]+)",', m.group(1))
assert len(entries) == 30, ('reserved-word count moved', len(entries), entries)
assert 'void' in entries, 'void is not a reserved word'
assert 'tls' not in entries, 'tls became a reserved word — it must stay a context keyword'
print('PASS: 30 reserved words, void among them, tls still a context keyword')
PY
guard_count=$((guard_count + 1))
printf '  %-30s %s\n' "guards passed" "$guard_count"

# ---------------------------------------------------------------------------
# [3/9] An independent reader: a C program links Aster's void function and must
# agree with a C program linking a C void function. This is the feature's whole
# point — void is the missing piece that lets Aster code call, and be called by,
# C that returns nothing — and a C linker is the reader that does not trust the
# Aster compiler's claim about its own ABI.
printf '%s\n' '[3/9] Independent reader: C links Aster void fn, must match C linking C'
if [ "$have_qemu" != yes ]; then
    echo 'SKIP: no cross gcc or no qemu — the C-ABI link did not run'
else
# Aster provides a void function with an early return and a fall-through body.
cat > "$W/aster_void.ast" <<'AST'
fn logit(x: i32) -> void {
    let y: i32 = x;
    if (y > 0) { return; }
}
AST
"$A" build-obj --pic "$W/aster_void.ast" -o "$W/aster_void.o" >"$W/aster_void.log" 2>&1 \
    || { echo 'FAIL: Aster void function does not build to an object:' >&2; cat "$W/aster_void.log" >&2; exit 1; }
cat > "$W/c_caller.c" <<'C'
extern void logit(int);
int main(void){ logit(5); logit(-1); return 0; }
C
"$HOSTCC" -c "$W/c_caller.c" -o "$W/c_caller.o" >"$W/c_caller.clog" 2>&1 \
    || { echo 'FAIL: C caller does not compile:' >&2; cat "$W/c_caller.clog" >&2; exit 1; }
"$HOSTCC" "$W/aster_void.o" "$W/c_caller.o" -o "$W/hybrid" -static >"$W/hybrid.log" 2>&1 \
    || { echo 'FAIL: C caller cannot link Aster void function (ABI mismatch):' >&2; cat "$W/hybrid.log" >&2; exit 1; }
run "$W/hybrid" >/dev/null 2>&1 && hy=0 || hy=$?
[ "$hy" -gt 127 ] && hy=$((hy - 256))
[ "$hy" = 0 ] || { echo "FAIL: hybrid (C main -> Aster void fn) exited $hy, expected 0" >&2; exit 1; }
printf 'PASS: %-22s C links Aster void fn, exit %s\n' 'c_calls_aster_void' "$hy"
# The mirror: a pure-C program, same behaviour, must also exit 0.
cat > "$W/c_only.c" <<'C'
static void logit(int x){ if (x > 0) { return; } (void)x; }
int main(void){ logit(5); logit(-1); return 0; }
C
"$HOSTCC" -O2 -fwrapv "$W/c_only.c" -o "$W/c_only" >/dev/null 2>&1 \
    || { echo 'FAIL: C-only oracle does not compile' >&2; exit 1; }
run "$W/c_only" >/dev/null 2>&1 && cy=0 || cy=$?
[ "$cy" -gt 127 ] && cy=$((cy - 256))
[ "$cy" = 0 ] || { echo "FAIL: C-only oracle exited $cy, expected 0" >&2; exit 1; }
printf 'PASS: %-22s C-only twin, exit %s\n' 'c_only_void' "$cy"
fi

# ---------------------------------------------------------------------------
# [4/9] The gcc differential. `void` is a C spelling, so every case has an
# Aster source and a C source and the two must agree on the exit status under
# qemu — never a hand-computed expectation. The observable effect is a global
# the void function mutates; main returns it, so the comparison exercises the
# void call as a statement (never as a value) on both sides.
printf '%s\n' '[4/9] gcc differential: Aster and C must agree on void behaviour'
diff_n=0
if [ "$have_qemu" != yes ]; then
    echo 'SKIP: no cross gcc or no qemu — the gcc differential did not run'
else
emit_case(){ # $1 = label
    n="$1"
    printf '%s\n' "$2" > "$W/$n.ast"
    printf '%s\n' "$3" > "$W/$n.c"
}
emit_case void_basic \
'fn logit(x: i32) -> void { let y: i32 = x; if (y > 0) { return; } }
let g: i32 = 0;
fn main() -> i32 { logit(5); return g; }' \
'static int g = 0;
static void logit(int x){ int y = x; if (y > 0) { return; } }
int main(void){ logit(5); return g; }'
emit_case void_fallthrough \
'fn noop() -> void { let y: i32 = 3; }
let g: i32 = 0;
fn main() -> i32 { noop(); return g; }' \
'static int g = 0;
static void noop(void){ int y = 3; }
int main(void){ noop(); return g; }'
emit_case void_loop_if \
'fn bump() -> void { g = g + 1; return; }
fn add(n: i32) -> void { let i: i32 = 0; while (i < n) { bump(); i = i + 1; } }
let g: i32 = 0;
fn main() -> i32 { add(3); return g; }' \
'static int g = 0;
static void bump(void){ g = g + 1; }
static void add(int n){ int i = 0; while (i < n) { bump(); i = i + 1; } }
int main(void){ add(3); return g; }'
emit_case void_value_fn_calls_void \
'fn trace() -> void { g = g + 10; }
fn work(v: i32) -> i32 { trace(); return v + 1; }
let g: i32 = 0;
fn main() -> i32 { return work(4); }' \
'static int g = 0;
static void trace(void){ g = g + 10; }
static int work(int v){ trace(); return v + 1; }
int main(void){ return work(4); }'
emit_case void_maybe \
'fn maybe(v: i32) -> void { if (v > 0) { g = g + 7; } }
let g: i32 = 0;
fn main() -> i32 { maybe(1); maybe(0); return g; }' \
'static int g = 0;
static void maybe(int v){ if (v > 0) { g = g + 7; } }
int main(void){ maybe(1); maybe(0); return g; }'

DIFF_CASES='void_basic void_fallthrough void_loop_if void_value_fn_calls_void void_maybe'
failed=0
for n in $DIFF_CASES; do
    if ! "$A" build-elf "$W/$n.ast" -o "$W/$n.a64" >"$W/$n.ab.log" 2>&1; then
        echo "FAIL: $n — Aster build failed:" >&2; cat "$W/$n.ab.log" >&2; failed=1; continue
    fi
    if ! "$HOSTCC" -O2 -fwrapv "$W/$n.c" -o "$W/$n.c64" >"$W/$n.cb.log" 2>&1; then
        echo "FAIL: $n — C oracle build failed:" >&2; cat "$W/$n.cb.log" >&2; failed=1; continue
    fi
    run "$W/$n.a64" >/dev/null 2>&1 && a=0 || a=$?
    run "$W/$n.c64" >/dev/null 2>&1 && c=0 || c=$?
    [ "$a" -gt 127 ] && a=$((a - 256))
    [ "$c" -gt 127 ] && c=$((c - 256))
    if [ "$a" != "$c" ]; then
        echo "FAIL: $n — Aster exit $a, C oracle exit $c" >&2; failed=1; continue
    fi
    diff_n=$((diff_n + 1))
    printf 'PASS: %-22s exit %s (matches C)\n' "$n" "$a"
done
[ "$failed" = 0 ] || exit 1
fi

# ---------------------------------------------------------------------------
# [5/9] The refusal matrix. Every one names the reason Aster refuses; the ones
# with a C twin are refused by gcc too, so the refusals are not merely the
# compiler's own opinion. (C is strict about void as well, so most are shared;
# the untyped-let refusal is Aster's parsing rule, not a type one.)
printf '%s\n' '[5/9] Refusal matrix: what void may not be used as'
reject(){ # $1 = label, $2 = source, $3 = reason, $4 = C twin (empty = none)
    printf '%s\n' "$2" > "$W/rej.ast"
    if "$A" build-elf "$W/rej.ast" -o "$W/rej" >"$W/rej.log" 2>&1; then
        echo "FAIL: $1 — accepted, expected: $3" >&2; return 1
    fi
    if ! grep -qF "$3" "$W/rej.log"; then
        echo "FAIL: $1 — refused, but not with \"$3\":" >&2; head -2 "$W/rej.log" >&2; return 1
    fi
    if [ -n "$4" ]; then
        if [ "$have_qemu" != yes ]; then
            printf 'PASS: %-26s %s (C twin not run: no cross gcc)\n' "$1" "$3"
            return 0
        fi
        printf '%s\n' "$4" > "$W/rej.c"
        if "$HOSTCC" -O2 -fwrapv "$W/rej.c" -o "$W/rej.c64" >"$W/rej.c.log" 2>&1; then
            echo "FAIL: $1 — gcc accepted the C twin, so the refusal is Aster's alone" >&2
            return 1
        fi
        printf 'PASS: %-26s %s (gcc refuses too)\n' "$1" "$3"
        return 0
    fi
    printf 'PASS: %-26s %s\n' "$1" "$3"
    return 0
}
failed=0
rej_n=0
r(){ reject "$@" && rej_n=$((rej_n + 1)) || failed=1; }
r 'void: return a value from void fn' \
'fn f() -> void { return 5; }
fn main() -> i32 { return 0; }' \
'cannot return a value from a void function ' ''
r 'void: as a parameter type' \
'fn f(a: void) -> i32 { return 0; }
fn main() -> i32 { return 0; }' \
'void is only a function return type' \
'void f(void a){ return 0; }
int main(void){ return 0; }'
r 'void: as a local variable type' \
'fn main() -> i32 { let x: void = 0; return 0; }' \
'void is only a function return type' \
'int main(void){ void x = 0; return 0; }'
r 'void: as a struct field' \
'struct S { v: void; }
fn main() -> i32 { return 0; }' \
'void is only a function return type' \
'struct S { void v; };
int main(void){ return 0; }'
r 'void: as a type alias' \
'type V = void;
fn main() -> i32 { return 0; }' \
'a type alias cannot be void: V' ''
r 'void result: let x : i32 = voidcall' \
'fn f() -> void { return; }
fn main() -> i32 { let x: i32 = f(); return x; }' \
'expected i32, got void' \
'void f(void){}
int main(void){ int x = f(); return x; }'
r 'void result: assignment x = voidcall' \
'fn f() -> void { return; }
fn main() -> i32 { let x: i32 = 0; x = f(); return x; }' \
'expected i32, got void' \
'void f(void){}
int main(void){ int x = 0; x = f(); return x; }'
r 'void result: return voidcall in i32 fn' \
'fn f() -> void { return; }
fn main() -> i32 { return f(); }' \
'expected i32, got void' \
'void f(void){}
int main(void){ return f(); }'
r 'void result: argument g(voidcall)' \
'fn f() -> void { return; }
fn g(a: i32) -> i32 { return a; }
fn main() -> i32 { return g(f()); }' \
'expected i32, got void' \
'void f(void){}
int g(int a){ return a; }
int main(void){ return g(f()); }'
r 'void result: operator f() + 1' \
'fn f() -> void { return; }
fn main() -> i32 { let x: i32 = f() + 1; return x; }' \
'a void value cannot be used in an expression' \
'void f(void){}
int main(void){ int x = f() + 1; return x; }'
r 'void result: untyped let x = voidcall' \
'fn f() -> void { return; }
fn main() -> i32 { let x = f(); return 0; }' \
"expected ':'" ''
[ "$failed" = 0 ] || exit 1
printf '  %-30s %s\n' "refusals held" "$rej_n"

# ---------------------------------------------------------------------------
# [6/9] The shipped example against its C twin, plus a behavioural witness.
printf '%s\n' '[6/9] The shipped example against its C twin'
if [ "$have_qemu" != yes ]; then
    echo 'SKIP: no cross gcc or no qemu — the example witness did not run'
else
ex=void_return; twin=tests/void-return-twin.c
if ! "$A" build-elf "examples/$ex.ast" -o "$W/$ex" >"$W/$ex.log" 2>&1; then
    echo "FAIL: examples/$ex.ast no longer builds:" >&2; cat "$W/$ex.log" >&2; exit 1
fi
if ! "$HOSTCC" -O2 -fwrapv "$twin" -o "$W/$ex.c64" >"$W/$ex.c.log" 2>&1; then
    echo "FAIL: $twin no longer builds:" >&2; cat "$W/$ex.c.log" >&2; exit 1
fi
run "$W/$ex" >/dev/null 2>&1 && ae=0 || ae=$?
run "$W/$ex.c64" >/dev/null 2>&1 && ce=0 || ce=$?
[ "$ae" -gt 127 ] && ae=$((ae - 256))
[ "$ce" -gt 127 ] && ce=$((ce - 256))
if [ "$ae" != "$ce" ]; then
    echo "FAIL: examples/$ex.ast exit $ae, $twin exit $ce" >&2; exit 1
fi
printf 'PASS: %-22s exit %s (matches C)\n' "$ex" "$ae"
fi

# ---------------------------------------------------------------------------
# [7/9] Coverage counting: the layers have to be carrying their weight.
printf '%s\n' '[7/9] Coverage: the layers are not vacuous'
[ "$guard_count" -ge 22 ] || { echo "FAIL: only $guard_count source guards, expected at least 22" >&2; exit 1; }
[ "$rej_n" -ge 10 ] || { echo "FAIL: only $rej_n refusals held, expected at least 10" >&2; exit 1; }
printf '  %-30s %s\n' "source guards" "$guard_count"
printf '  %-30s %s\n' "refusals" "$rej_n"
printf '  %-30s %s\n' "gcc differential cases" "$diff_n"

# ---------------------------------------------------------------------------
# [8/9] Mutations. Each piece has to be load-bearing.
printf '%s\n' '[8/9] The suite can still fail (six mutations)'
mutate(){ # $1 = label, $2 = sed script
    sed "$2" src/aster.cpp > "$OUT/$1.cpp"
    if cmp -s src/aster.cpp "$OUT/$1.cpp"; then
        echo "FAIL: mutation $1 did not apply — blind" >&2; exit 1
    fi
    $CXX -std=c++17 -O2 -w "$OUT/$1.cpp" -o "$OUT/$1" 2>/dev/null \
        || { echo "FAIL: mutation $1 no longer compiles" >&2; exit 1; }
}
# (a) A void function must not return a value. The refusal is enforced at
# two sites: the dedicated Sema message (7936) and the integer/struct return
# path's checkValue (7949/7967), which would otherwise reject `got void`.
# Neutralise both so the witness builds — proving the refusal is load-bearing.
mutate m1 's|if(retType==Ty::Void){|if(false){|; s|checkValue(retType,\*s.expr,actual,"return type mismatch in function "+fn);|if(retType!=Ty::Void)checkValue(retType,*s.expr,actual,"return type mismatch in function "+fn);|'
printf '%s\n' 'fn f() -> void { return 5; }
fn main() -> i32 { return 0; }' > "$W/m1.ast"
# The original refuses `return 5;` in a void fn; the mutant accepts it, so it builds.
if "$OUT/m1" build-elf "$W/m1.ast" -o "$W/m1" >/dev/null 2>&1; then
    printf '  %-40s %s\n' 'a) a void fn may return a value' 'noticed'
else
    echo 'FAIL: mutation (a) went unnoticed — the refusal is not what blocks the value' >&2; exit 1
fi
# (b) void is a return type only — mutate the allowVoid gate so void is a general type.
mutate m2 's|if(t.k==Ty::Void\&\&!allowVoid)|if(false)|'
printf '%s\n' 'fn f(a: void) -> i32 { return 0; }
fn main() -> i32 { return 0; }' > "$W/m2.ast"
# The original refuses `a: void`; the mutant accepts it, so it builds.
if "$OUT/m2" build-elf "$W/m2.ast" -o "$W/m2" >/dev/null 2>&1; then
    printf '  %-40s %s\n' 'b) void may be a parameter' 'noticed'
else
    echo 'FAIL: mutation (b) went unnoticed — the allowVoid gate is not what blocks void-as-value' >&2; exit 1
fi
# (c) A void result may not be used as an operand — mutate isVoidUsingOp off.
mutate m3 's|if(isVoidUsingOp(e.k)){|if(false){|'
printf '%s\n' 'fn f() -> void { return; }
fn main() -> i32 { let x: i32 = f() + 1; return x; }' > "$W/m3.ast"
# The original refuses `f() + 1`; the mutant accepts it, so it builds.
if "$OUT/m3" build-elf "$W/m3.ast" -o "$W/m3" >/dev/null 2>&1; then
    printf '  %-40s %s\n' 'c) a void result may be an operand' 'noticed'
else
    echo 'FAIL: mutation (c) went unnoticed — isVoidUsingOp is not what blocks the operand' >&2; exit 1
fi
# (d) A void function may fall off the end — mutate the exception off so it must
# return explicitly; a void fn with no return now fails to compile.
mutate m4 's|if(f.retType!=Ty::Void\&\&!definitelyReturns(f.body))|if(!definitelyReturns(f.body))|'
printf '%s\n' 'fn f() -> void { let y: i32 = 3; }
fn main() -> i32 { f(); return 0; }' > "$W/m4.ast"
# The original builds; the mutant refuses the fall-through, so it does not build.
if "$OUT/m4" build-elf "$W/m4.ast" -o "$W/m4" >/dev/null 2>&1; then
    echo 'FAIL: mutation (d) went unnoticed — the void fall-through exception is inert' >&2; exit 1
fi
printf '  %-40s %s\n' 'd) a void fn must return explicitly' 'noticed'
# (e) The void result must not land in a binding/return/argument. The
# enforcement is `tyAssignable(i32, Void) -> false` (line 3037), which makes
# every `got void` refusal fire through checkValue. Making void assignable to
# anything lets the witness build — proving that refusal is load-bearing.
mutate m5 's@if(to==from)return true;@if(to==from||from==Ty::Void)return true;@'
printf '%s\n' 'fn f() -> void { return; }
fn main() -> i32 { return f(); }' > "$W/m5.ast"
# The original refuses `return f()` in an i32 fn; the mutant accepts it, so it builds.
if "$OUT/m5" build-elf "$W/m5.ast" -o "$W/m5" >/dev/null 2>&1; then
    printf '  %-40s %s\n' 'e) an i32 fn may return a void' 'noticed'
else
    echo 'FAIL: mutation (e) went unnoticed — the Sema void branch is not what blocks it' >&2; exit 1
fi
# (f) An alias may not name void — disable the alias-to-void guard (2549).
# The `$` anchor keeps the parseType gate at 1268 (`if(t.k==Ty::Void&&!allowVoid)`)
# untouched, so only the alias refusal is neutralised.
mutate m6 's|if(t.k==Ty::Void)$|if(false)|'
printf '%s\n' 'type V = void;
fn main() -> i32 { return 0; }' > "$W/m6.ast"
# The original refuses `type V = void`; the mutant accepts it, so it builds.
if "$OUT/m6" build-elf "$W/m6.ast" -o "$W/m6" >/dev/null 2>&1; then
    printf '  %-40s %s\n' 'f) an alias may name void' 'noticed'
else
    echo 'FAIL: mutation (f) went unnoticed — the alias-to-void refusal is inert' >&2; exit 1
fi

# ---------------------------------------------------------------------------
# [9/9] The byte baseline for the void example. The full example baseline is
# owned by alias-const-checks.sh; here we pin the three rows that this round
# adds (examples/void_return.ast in three modes) and require them to reproduce.
printf '%s\n' '[9/9] Byte baseline: the void example reproduces'
BASE=$(aster_baseline_file)
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
void_rows=$(grep '^void_return\.' "$BASE" | LC_ALL=C sort)
[ -n "$void_rows" ] || { echo "FAIL: no void_return rows in the frozen baseline" >&2; exit 1; }
printf '%s\n' "$void_rows" > "$W/void.rows.txt"
while IFS= read -r spec; do
    [ -z "$spec" ] && continue
    key=${spec% *}; val=${spec#* }
    mode=${key#*.}; base=${key%.*}
    case "$mode" in
        build-so) m='build-so' ;;
        build-elf) m='build-elf' ;;
        build-obj_--pic) m='build-obj --pic' ;;
    esac
    if "$A" $m "examples/$base.ast" -o "$W/$key" >/dev/null 2>&1; then
        got=$(sha256sum "$W/$key" | cut -d' ' -f1)
    else
        got=FAILED
    fi
    if [ "$got" != "$val" ]; then
        echo "FAIL: $key baseline moved: expected $val, got $got" >&2; exit 1
    fi
done < "$W/void.rows.txt"
printf '  %-30s %s\n' "void_return rows reproduced" "$(echo "$void_rows" | wc -l)"

printf '%s\n' 'PASS: all void checks'
