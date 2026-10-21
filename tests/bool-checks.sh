#!/bin/sh
# v0.22.51-dev structural + behavioral checks for the bool type, the logical
# operators (&& || !) and else-if chains.
#
# bool is a first-class type: comparisons are ordinary bool expressions (no
# longer restricted to if/while conditions), && and || short-circuit, ! negates,
# and bool is NOT implicitly convertible to or from i32. `else if (c) { }`
# desugars to `else { if (c) { } }`, so a chain nests to the same shape the
# explicit form already produced. Since v0.23.22-dev the `else` is optional,
# so the else-less `if` -- once rejected here -- is an accepted shape.
# Layers: strict compiler build, source guards,
# a rejection matrix for every type-misuse case, qemu self-checks of the real
# code shape, and a bit-level check of the CSET encoding.
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-bool-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/8] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

printf '%s\n' '[2/8] Source guard: bool type, logical operators, else-if sugar'
# A regression that drops the bool keyword, the And/Or/Not expression kinds,
# the short-circuit code shape, the CSET encoding, or the else-if desugaring
# must fail here first, before any behavioral check runs.
grep -qF 'else if(x=="bool")k=TK::Bool;' src/aster.cpp \
    || { echo 'FAIL: bool keyword missing from the lexer' >&2; exit 1; }
grep -qF 'Lt, Le, Gt, Ge, Plus, Minus, Star, Slash, LBracket, RBracket, At, And, Or, Not,' src/aster.cpp \
    || { echo 'FAIL: And/Or/Not tokens missing from the token kinds' >&2; exit 1; }
grep -qF 'Eq, Ne, Lt, Le, Gt, Ge, And, Or, Not,' src/aster.cpp \
    || { echo 'FAIL: And/Or/Not missing from the expression kinds' >&2; exit 1; }
grep -qF 'bool isBool=false;' src/aster.cpp \
    || { echo 'FAIL: bool flag missing from Stmt/Global' >&2; exit 1; }
grep -qF 'std::vector<bool> paramBool;' src/aster.cpp \
    || { echo 'FAIL: bool parameter slots missing from Function' >&2; exit 1; }
grep -qF 'bool returnBool=false;' src/aster.cpp \
    || { echo 'FAIL: bool return slot missing from Function' >&2; exit 1; }
grep -qF 'E logical(){' src/aster.cpp \
    || { echo 'FAIL: logical-operator grammar level missing from the parser' >&2; exit 1; }
grep -qF 'bool exprIsBool(const Expr& e) const {' src/aster.cpp \
    || { echo 'FAIL: bool expression classification missing' >&2; exit 1; }
grep -qF 'int genBool(const Expr& e){' src/aster.cpp \
    || { echo 'FAIL: bool materialization missing from codegen' >&2; exit 1; }
grep -qF 'emit(movInt(t,isAnd?0:1));' src/aster.cpp \
    || { echo 'FAIL: short-circuit prologue missing (&& / || must preload the deciding value)' >&2; exit 1; }
grep -qF 'patchCond(jump,isAnd?0:1,code.size());' src/aster.cpp \
    || { echo 'FAIL: short-circuit skip branch missing' >&2; exit 1; }
# 0x1a9f07e0 is CSINC with Rn = Rm = WZR (31) and op2 = 01 — i.e. CSET. The low
# three bits (0xe0) are part of Rn/Rm; dropping them silently turns the encode
# into `csinc wD, w24, wzr`, which materializes whatever w24 happens to hold.
grep -qF 'static uint32_t csetBool(int reg,int cond){return 0x1a9f07e0u|(uint32_t(cond^1)<<12)|uint32_t(reg);}' src/aster.cpp \
    || { echo 'FAIL: CSET encoding missing or damaged (Rn/Rm = WZR must stay in the base word)' >&2; exit 1; }
# CMP Wn, #0 is SUBS with Rd = WZR.  Leaving Rd at 0 encodes `subs w0, Wn, #0`,
# which overwrites w0 — a live expression temporary — with Wn's value.
grep -qF 'static uint32_t cmpZero(int reg){return 0x71000000u|(uint32_t(reg)<<5)|31u;}' src/aster.cpp \
    || { echo 'FAIL: cmpZero must discard its result (Rd = WZR), not write w0' >&2; exit 1; }
# Comparisons must keep the original CMP + conditional-branch shape so that
# every pre-existing if/while/for compiles byte-identically.
grep -qF 'int emitCondition(const Expr& c,size_t& at){' src/aster.cpp \
    || { echo 'FAIL: emitCondition fast path missing' >&2; exit 1; }
grep -qF 'return comparisonCond(c.k,tyIsUnsigned(ta)||tyIsUnsigned(tb))^1;' src/aster.cpp \
    || { echo 'FAIL: emitCondition must keep the CMP + conditional-branch shape for comparisons' >&2; exit 1; }
# v0.23.25-dev: the condition refusal message grew a third kind ("or an
# integer") when integer truthiness arrived; the ptr/struct refusal it covers
# is asserted in the rejection matrix below and in condition-checks.sh.
grep -qF 'condition must be a comparison, a bool expression, or an integer' src/aster.cpp \
    || { echo 'FAIL: the shared condition refusal message is missing' >&2; exit 1; }
# else-if: the mandatory else is followed by another if statement (not a block).
grep -qF 'Stmt ifStatement(){' src/aster.cpp \
    || { echo 'FAIL: ifStatement() helper missing' >&2; exit 1; }
grep -qF 'if(eat(TK::If)){std::vector<Stmt> eb;eb.push_back(ifStatement());s.elseBody=std::move(eb);}' src/aster.cpp \
    || { echo 'FAIL: else-if desugaring missing' >&2; exit 1; }
printf '%s\n' 'PASS: bool type, And/Or/Not, short-circuiting, CSET encoding and else-if sugar present'

printf '%s\n' '[3/8] Rejection matrix: bool is not interchangeable with i32'
cat > "$OUT/bool-init-i32.ast" <<'AST'
fn main() -> i32 { let b: bool = 5; return 0; }
AST
cat > "$OUT/i32-init-bool.ast" <<'AST'
fn main() -> i32 { let a: i32 = 1; let b: i32 = 2; let x: i32 = a < b; return 0; }
AST
cat > "$OUT/ptr-condition.ast" <<'AST'
fn f(p: ptr) -> i32 { if (p) { return 0; } else { return 1; } }
fn main() -> i32 { return 0; }
AST
cat > "$OUT/chained.ast" <<'AST'
fn main() -> i32 { let a: i32 = 1; let b: i32 = 2; let c: i32 = 3; if (a < b < c) { return 0; } else { return 1; } }
AST
cat > "$OUT/and-i32.ast" <<'AST'
fn main() -> i32 { let a: i32 = 1; let b: i32 = 2; let y: bool = a && b; return 0; }
AST
cat > "$OUT/not-i32.ast" <<'AST'
fn main() -> i32 { let a: i32 = 1; let y: bool = !a; return 0; }
AST
cat > "$OUT/i32-return-bool.ast" <<'AST'
fn f(a: i32) -> i32 { return a < 10; }
fn main() -> i32 { return f(1); }
AST
cat > "$OUT/bool-return-i32.ast" <<'AST'
fn f(a: i32) -> bool { return a; }
fn main() -> i32 { if (f(1)) { return 0; } else { return 1; } }
AST
cat > "$OUT/bool-arg-i32.ast" <<'AST'
fn f(c: bool) -> i32 { if (c) { return 1; } else { return 0; } }
fn main() -> i32 { let a: i32 = 1; return f(a); }
AST
cat > "$OUT/bool-global-init.ast" <<'AST'
let flag: bool = 2;
fn main() -> i32 { return 0; }
AST
cat > "$OUT/bool-assign-i32.ast" <<'AST'
fn main() -> i32 { let b: bool = 1; b = 7; return 0; }
AST
cat > "$OUT/main-bool.ast" <<'AST'
fn main() -> bool { return 1; }
AST
"$OUT/aster" build-elf "$OUT/bool-init-i32.ast" -o "$OUT/x" 2>&1 | grep -qF "type mismatch initializing 'b': expected bool" \
    || { echo 'FAIL: bool variable initialized from an i32 not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/i32-init-bool.ast" -o "$OUT/x" 2>&1 | grep -qF "type mismatch initializing 'x': expected i32, got bool" \
    || { echo 'FAIL: i32 variable initialized from a comparison not rejected' >&2; exit 1; }
# v0.23.25-dev: an i32 condition is no longer a refusal — integer truthiness
# made `if (x)` legal (condition-checks.sh tests it behaviourally). What is
# still refused is a condition that is neither a comparison, a bool nor an
# integer: a pointer.
"$OUT/aster" build-elf "$OUT/ptr-condition.ast" -o "$OUT/x" 2>&1 | grep -qF 'condition must be a comparison, a bool expression, or an integer' \
    || { echo 'FAIL: a ptr condition not rejected (a ptr is not a truthy type)' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/chained.ast" -o "$OUT/x" 2>&1 | grep -qF 'chained comparisons are not supported' \
    || { echo 'FAIL: chained comparison not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/and-i32.ast" -o "$OUT/x" 2>&1 | grep -qF '&& and || require bool operands (&&)' \
    || { echo 'FAIL: && on i32 operands not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/not-i32.ast" -o "$OUT/x" 2>&1 | grep -qF "'!' requires a bool operand" \
    || { echo 'FAIL: ! on an i32 operand not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/i32-return-bool.ast" -o "$OUT/x" 2>&1 | grep -qF 'return type mismatch in function f: expected i32, got bool' \
    || { echo 'FAIL: returning a bool from an i32 function not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/bool-return-i32.ast" -o "$OUT/x" 2>&1 | grep -qF 'return type mismatch in function f: expected bool' \
    || { echo 'FAIL: returning an i32 from a bool function not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/bool-arg-i32.ast" -o "$OUT/x" 2>&1 | grep -qF 'argument type mismatch calling f at argument 1: expected bool' \
    || { echo 'FAIL: passing an i32 to a bool parameter not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/bool-global-init.ast" -o "$OUT/x" 2>&1 | grep -qF 'bool global initializer must be 0 or 1' \
    || { echo 'FAIL: bool global initialized with a non-0/1 constant not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/bool-assign-i32.ast" -o "$OUT/x" 2>&1 | grep -qF "type mismatch assigning variable: b (expected bool)" \
    || { echo 'FAIL: assigning an i32 to a bool variable not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/main-bool.ast" -o "$OUT/x" 2>&1 | grep -qF 'main must return i32' \
    || { echo 'FAIL: bool main not rejected' >&2; exit 1; }
printf '%s\n' 'PASS: 13 bool/else-if misuse cases rejected with actionable diagnostics'

printf '%s\n' '[4/8] Acceptance: bool variables, comparison results and && (qemu self-check)'
cat > "$OUT/and.ast" <<'AST'
fn main() -> i32 {
    let a: i32 = 3;
    let b: i32 = 5;
    let both: bool = a < b && b > a;
    let none: bool = a > b && b < a;
    let r: i32 = 0;
    if (both) { r = r + 10; } else { r = r + 100; }
    if (none) { r = r + 100; } else { r = r + 20; }
    // A bare bool variable is a valid loop condition (not a comparison): the
    // loop test goes through genBool + CMP #0 rather than the CMP/branch shape.
    let guard: bool = 0;
    let n: i32 = 0;
    while (!guard) {
        n = n + 1;
        if (n == 3) { guard = 1; } else { guard = 0; }
    }
    return r + n - 33;
}
AST
"$OUT/aster" build-elf "$OUT/and.ast" -o "$OUT/and" >/dev/null
"$PWD/tests/run-aarch64.sh" "$OUT/and"
printf '%s\n' 'PASS: a bool variable holds a comparison && comparison (10 + 20 == 30) and drives a while condition (3 passes) — 33, exit 0'

printf '%s\n' '[5/8] Acceptance: ! and || , and short-circuit evaluation (qemu self-check)'
cat > "$OUT/short.ast" <<'AST'
let calls: i32 = 0;
fn bump() -> bool { calls = calls + 1; return 1; }
fn main() -> i32 {
    let a: i32 = 1;
    let b: i32 = 2;
    let lf: bool = a < b;
    let neg: bool = !lf;
    let r: i32 = 0;
    if (neg) { r = r + 100; } else { r = r + 1; }
    let o: bool = a > b || b > a;
    if (o) { r = r + 2; } else { r = r + 100; }
    if (!o) { r = r + 100; } else { r = r + 4; }
    let skipped: bool = a > b && bump();
    let skipped2: bool = a < b || bump();
    if (skipped) { r = r + 100; } else { r = r + 8; }
    if (skipped2) { r = r + 16; } else { r = r + 100; }
    let taken: bool = a < b && bump();
    if (taken) { r = r + 32; } else { r = r + 100; }
    return r + calls - 64;
}
AST
"$OUT/aster" build-elf "$OUT/short.ast" -o "$OUT/short" >/dev/null
"$PWD/tests/run-aarch64.sh" "$OUT/short"
printf '%s\n' 'PASS: ! and || evaluate correctly; bump() runs once (1+2+4+8+16+32 == 63) and only for the deciding && (exit 0)'

printf '%s\n' '[6/8] Acceptance: bool returns, bool parameters and bool globals (qemu self-check)'
cat > "$OUT/signature.ast" <<'AST'
let flag: bool = 1;
fn isBig(x: i32) -> bool { return x > 10; }
fn pick(c: bool, t: i32, f: i32) -> i32 { if (c) { return t; } else { return f; } }
fn main() -> i32 {
    let a: i32 = pick(isBig(20), 5, 9);
    let b: i32 = pick(isBig(3), 5, 9);
    let c: i32 = 0;
    if (flag) { c = c + 1; } else { c = c + 100; }
    flag = 0;
    if (flag) { c = c + 100; } else { c = c + 2; }
    return a + b + c - 17;
}
AST
"$OUT/aster" build-elf "$OUT/signature.ast" -o "$OUT/signature" >/dev/null
"$PWD/tests/run-aarch64.sh" "$OUT/signature"
printf '%s\n' 'PASS: bool return feeds a bool parameter directly; bool global reads and writes work (5+9+3 == 17, exit 0)'

printf '%s\n' '[7/8] Acceptance: else-if chains, and the else-less if (qemu self-check)'
# v0.23.22-dev made `else` optional. This suite used to pin the opposite rule
# here -- an `if` without an else was rejected with "expected else branch" --
# and that rejection was deleted with the restriction. The early-return guard
# is now the idiomatic shape; the fall-through it must still reject (a
# then-only return with no way out) lives in tests/syntax-relief-checks.sh
# [6/7], together with the rest of the optional-else contract.
cat > "$OUT/guard.ast" <<'AST'
fn main() -> i32 {
    let a: i32 = 1;
    if (a == 1) { return 0; }
    return 1;
}
AST
"$OUT/aster" build-elf "$OUT/guard.ast" -o "$OUT/guard" >/dev/null
"$PWD/tests/run-aarch64.sh" "$OUT/guard"
printf '%s\n' 'PASS: an if without an else is a legal early-return guard (a == 1, exit 0)'
cat > "$OUT/chain.ast" <<'AST'
fn main() -> i32 {
    let n: i32 = 3;
    let r: i32 = 0;
    if (n == 1) { r = 1; }
    else if (n == 2) { r = 2; }
    else if (n == 3) { r = 3; }
    else if (n == 4) { r = 4; }
    else { r = 100; }
    let hot: bool = n > 2;
    if (hot) { r = r + 10; }
    else if (n > 100) { r = r + 100; }
    else { r = r + 100; }
    let m: i32 = 7;
    if (m == 1) { r = r + 100; }
    else if (m == 7) { if (m > 5) { r = r + 5; } else { r = r + 100; } }
    else { r = r + 100; }
    return r - 18;
}
AST
"$OUT/aster" build-elf "$OUT/chain.ast" -o "$OUT/chain" >/dev/null
"$PWD/tests/run-aarch64.sh" "$OUT/chain"
printf '%s\n' 'PASS: a four-arm chain picks the third arm (3); a bool variable drives an else-if; nesting inside an arm works (3+10+5 == 18, exit 0)'

printf '%s\n' '[8/8] Bit-level: comparisons materialize through CSET (Rn = Rm = WZR)'
"$OUT/aster" build-elf "$OUT/and.ast" -o "$OUT/cset" >/dev/null
python3 - "$OUT/cset" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
assert b[:4] == b'\x7fELF'
shoff, = struct.unpack_from('<Q', b, 40)
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
def sh(i):
    o = shoff + i * shentsize
    name, _t, _f, addr, off, size = struct.unpack_from('<IIQQQQ', b, o)
    return name, addr, off, size
strbase = sh(shstrndx)[2]
def nm(n):
    return b[strbase + n:b.index(b'\0', strbase + n)].decode()
text = None
for i in range(shnum):
    n, addr, off, size = sh(i)
    if nm(n) == '.text':
        text = (addr, off, size)
assert text is not None, 'no .text section'
addr, off, size = text
words = struct.unpack_from('<%dI' % (size // 4), b, off)
# CSINC (op2 = 01) with Rn = Rm = WZR is CSET: 0x1a9f07e0 | (cond^1) << 12 | Rd.
CSET = 0x1a9f07e0
MASK = 0xffff0fe0        # sf/op/S/opcode, Rm, op2, Rn — everything CSET fixes
csets = [w for w in words if (w & MASK) == CSET]
assert csets, 'no CSET instruction in .text — comparisons are not bool expressions'
# The historical bug: dropping the low three bits (0xe0) of the base word moves
# Rn from WZR (31) to w24, so the "bool" would be whatever w24 holds.
damaged = [w for w in words if (w & MASK) == 0x1a9f0700]
assert not damaged, 'CSINC with Rn = w24 found: CSET base word lost its 0xe0 bits'
conds = {0: 'eq', 1: 'ne', 10: 'ge', 11: 'lt', 12: 'gt', 13: 'le'}
shown = ', '.join('cset w%d, %s' % (w & 31, conds.get((w >> 12) & 15 ^ 1, '?'))
                  for w in csets[:4])
print('PASS: %d CSET instruction(s) in .text — %s' % (len(csets), shown))
PY
