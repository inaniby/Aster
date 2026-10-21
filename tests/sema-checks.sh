#!/bin/sh
# v0.23.0-dev structural + behavioral checks for the standalone semantic pass
# (P3.1): type checking runs over the AST *before* any code is emitted, with its
# own scope stack, instead of being decided inside codegen as instructions are
# produced. Layers: strict compiler build, source guards, a proof that the pass
# really runs first, the type-rule matrix it owns, and qemu self-checks that its
# scope model matches codegen's (no false rejections).
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-sema-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/6] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

printf '%s\n' '[2/6] Source guard: a semantic pass exists and runs before codegen'
# A regression that deletes the pass, leaves it unwired, or moves the shared
# helpers back inside Codegen must fail here first.
grep -qF 'enum Kind { I32, U32, U8, U16, I64, Ptr, Bool, Struct };' src/aster.cpp \
    || { echo 'FAIL: semantic type lattice missing' >&2; exit 1; }
# v0.23.28-dev: a binding also carries the array's element type, which is what
# lets `a[i]` answer its own type instead of a hardcoded i32. v0.23.31-dev: and
# the whole dimension list (`T[N][M]`), of which `len` is the outer length —
# the stride a subscript at dimension k multiplies by is the product of the
# dimensions below it, so sema needs them all.
# v0.23.37-dev: the struct gained a function signature beside these fields
# (FuncSig funcSig; bool isFunc) and became multi-line — the head line is
# pinned here, the new fields by function-type-checks.sh's own guard.
grep -qF 'struct Binding { Ty ty=Ty::I32; uint32_t len=0; Ty elem=Ty::I32; std::vector<uint32_t> dims;' src/aster.cpp \
    || { echo 'FAIL: semantic scope binding missing (local i32[N] must carry its length, element type and dimension list)' >&2; exit 1; }
grep -qF 'void check(const Function& f){' src/aster.cpp \
    || { echo 'FAIL: per-function semantic entry point missing' >&2; exit 1; }
grep -qF 'void checkCondition(const Expr& e){' src/aster.cpp \
    || { echo 'FAIL: semantic condition rule missing' >&2; exit 1; }
grep -qF 'Sema sema{arities,globalNames,externFunctions,arrayGlobals,boolGlobals,pointerReturnFunctions,boolReturnFunctions,' src/aster.cpp \
    || { echo 'FAIL: semantic pass not constructed in compileProgram' >&2; exit 1; }
grep -qF 'sema.check(*f);' src/aster.cpp \
    || { echo 'FAIL: functions are not type-checked before codegen' >&2; exit 1; }
grep -qF 'sema.check(init);' src/aster.cpp \
    || { echo 'FAIL: the synthetic run-time initializer is not type-checked' >&2; exit 1; }
# The pass and codegen must share ONE definition of constant folding and of
# "is this a comparison", or the two passes can disagree about a program.
test "$(grep -cF 'static bool constantInteger(const Expr& e,int64_t& out){' src/aster.cpp)" -eq 1 \
    || { echo 'FAIL: constantInteger must exist exactly once (shared by the semantic pass and codegen)' >&2; exit 1; }
test "$(grep -cF 'static bool isComparison(Expr::Kind k){' src/aster.cpp)" -eq 1 \
    || { echo 'FAIL: isComparison must exist exactly once (shared by the semantic pass and codegen)' >&2; exit 1; }
printf '%s\n' 'PASS: semantic pass present, wired ahead of both codegen call sites, sharing one constant folder'

printf '%s\n' '[3/6] Proof: the pass runs before codegen, not during it'
# Codegen checks "does this function definitely return?" as its very first act,
# before emitting anything. A program with BOTH a fall-through path and a type
# error therefore used to report the fall-through; with the semantic pass in
# front, the type error wins. That difference is the observable proof that
# checking no longer happens during code generation.
cat > "$OUT/both.ast" <<'AST'
fn main() -> i32 {
    let x: i32 = 1;
    if (x == 1) { return 1; } else { x = 2; }
    let b: bool = 5;
}
AST
cat > "$OUT/fallthrough-only.ast" <<'AST'
fn main() -> i32 {
    let x: i32 = 1;
    if (x == 1) { return 1; } else { x = 2; }
}
AST
"$OUT/aster" build-elf "$OUT/both.ast" -o "$OUT/both" 2>&1 | grep -qF "type mismatch initializing 'b': expected bool" \
    || { echo 'FAIL: type error must be reported before the codegen fall-through check' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/both.ast" -o "$OUT/both" 2>&1 | grep -qF 'may fall through without returning' \
    && { echo 'FAIL: the codegen fall-through check still wins over the semantic type error' >&2; exit 1; }
# Control: with no type error, the fall-through diagnostic must still fire.
"$OUT/aster" build-elf "$OUT/fallthrough-only.ast" -o "$OUT/ft" 2>&1 | grep -qF 'may fall through without returning i32' \
    || { echo 'FAIL: fall-through checking regressed (the control case must still be rejected)' >&2; exit 1; }
printf '%s\n' 'PASS: type errors now precede codegen diagnostics; the codegen check still fires when no type error exists'

printf '%s\n' '[4/6] Type-rule matrix: the rules the semantic pass owns'
cat > "$OUT/ptr-to-i32.ast" <<'AST'
fn f(p: ptr) -> i32 { return 0; }
fn main() -> i32 { let q: ptr = f; let x: i32 = q; return 0; }
AST
cat > "$OUT/i32-to-ptr.ast" <<'AST'
fn main() -> i32 { let p: ptr = 7; return 0; }
AST
cat > "$OUT/bool-arg.ast" <<'AST'
fn f(c: bool) -> i32 { if (c) { return 1; } else { return 0; } }
fn main() -> i32 { let a: i32 = 1; return f(a); }
AST
cat > "$OUT/deref-nonptr.ast" <<'AST'
fn main() -> i32 { let x: i32 = 1; let y: i32 = *x; return 0; }
AST
cat > "$OUT/deref-assign.ast" <<'AST'
fn main() -> i32 { let x: i32 = 1; *x = 5; return 0; }
AST
cat > "$OUT/ptr-add.ast" <<'AST'
fn f(a: ptr, b: ptr) -> i32 { let c: ptr = a + b; return 0; }
AST
cat > "$OUT/ptr-sub.ast" <<'AST'
fn f(a: i32, b: ptr) -> i32 { let c: ptr = a - b; return 0; }
AST
cat > "$OUT/ptr-cmp.ast" <<'AST'
fn f(a: ptr) -> i32 { if (a > 0) { return 1; } else { return 0; } }
AST
cat > "$OUT/ptr-cmp-ne.ast" <<'AST'
fn f(a: ptr) -> i32 { if (a == 1) { return 1; } else { return 0; } }
AST
cat > "$OUT/argv-count.ast" <<'AST'
fn f(a: i32) -> i32 { return a; }
fn main() -> i32 { return f(1, 2); }
AST
cat > "$OUT/undeclared.ast" <<'AST'
fn main() -> i32 { return nope(1); }
AST
cat > "$OUT/index-scalar.ast" <<'AST'
fn main() -> i32 { let x: i32 = 1; return x[0]; }
AST
cat > "$OUT/return-array.ast" <<'AST'
fn main() -> i32 { let a: i32[4] = 0; return a; }
AST
cat > "$OUT/whole-array-assign.ast" <<'AST'
let g: i32[4] = 0;
fn main() -> i32 { g = 1; return 0; }
AST
cat > "$OUT/bounds.ast" <<'AST'
fn main() -> i32 { let a: i32[4] = 0; a[4] = 1; return 0; }
AST
"$OUT/aster" build-elf "$OUT/ptr-to-i32.ast" -o "$OUT/x" 2>&1 | grep -qF "type mismatch initializing 'x': expected i32, got ptr" \
    || { echo 'FAIL: ptr value into an i32 slot not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/i32-to-ptr.ast" -o "$OUT/x" 2>&1 | grep -qF "type mismatch initializing 'p': expected ptr" \
    || { echo 'FAIL: i32 literal into a ptr slot not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/bool-arg.ast" -o "$OUT/x" 2>&1 | grep -qF 'argument type mismatch calling f at argument 1: expected bool' \
    || { echo 'FAIL: i32 into a bool parameter not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/deref-nonptr.ast" -o "$OUT/x" 2>&1 | grep -qF 'dereference requires a ptr expression' \
    || { echo 'FAIL: dereference of a non-ptr not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/deref-assign.ast" -o "$OUT/x" 2>&1 | grep -qF 'dereference assignment requires a ptr expression' \
    || { echo 'FAIL: dereference assignment through a non-ptr not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/ptr-add.ast" -o "$OUT/x" 2>&1 | grep -qF 'invalid pointer arithmetic: ptr + ptr is not supported' \
    || { echo 'FAIL: ptr + ptr not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/ptr-sub.ast" -o "$OUT/x" 2>&1 | grep -qF 'invalid pointer arithmetic: expected ptr - i32' \
    || { echo 'FAIL: i32 - ptr not rejected' >&2; exit 1; }
# v0.23.26-dev: `==`/`!=` are now defined for a ptr (against another ptr or the
# null constant 0), so the old blanket "pointer comparison is not supported yet"
# narrowed to two answers — ordering an address, and comparing one with an
# integer that is not 0.
"$OUT/aster" build-elf "$OUT/ptr-cmp.ast" -o "$OUT/x" 2>&1 | grep -qF 'only == and != are defined for a ptr' \
    || { echo 'FAIL: pointer ordering not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/ptr-cmp-ne.ast" -o "$OUT/x" 2>&1 | grep -qF 'a ptr may only be compared with another ptr, or with the literal 0' \
    || { echo 'FAIL: ptr compared with a non-null integer not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/argv-count.ast" -o "$OUT/x" 2>&1 | grep -qF 'wrong argument count calling f: expected 1, got 2' \
    || { echo 'FAIL: wrong argument count not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/undeclared.ast" -o "$OUT/x" 2>&1 | grep -qF 'call to undeclared function: nope' \
    || { echo 'FAIL: call to an undeclared function not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/index-scalar.ast" -o "$OUT/x" 2>&1 | grep -qF 'cannot index non-array variable: x' \
    || { echo 'FAIL: indexing a scalar local not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/return-array.ast" -o "$OUT/x" 2>&1 | grep -qF 'cannot return a local array' \
    || { echo 'FAIL: returning a local array not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/whole-array-assign.ast" -o "$OUT/x" 2>&1 | grep -qF 'cannot assign to an array as a whole: g' \
    || { echo 'FAIL: whole-array assignment not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/bounds.ast" -o "$OUT/x" 2>&1 | grep -qF "array index out of bounds for 'a': index 4, length 4" \
    || { echo 'FAIL: constant out-of-bounds index not rejected by the semantic pass' >&2; exit 1; }
printf '%s\n' 'PASS: 14 type rules (ptr/i32/bool, deref, pointer arithmetic, calls, indexing, bounds) enforced ahead of codegen'

printf '%s\n' '[5/6] Acceptance: the pass models scopes the same way codegen does (qemu self-check)'
cat > "$OUT/scopes.ast" <<'AST'
let g: i32 = 100;
fn add(p: ptr, n: i32) -> i32 {
    let total: i32 = 0;
    let i: i32 = 0;
    while (i < n) {
        total = total + p[i];
        i = i + 1;
    }
    return total;
}
fn main() -> i32 {
    let a: i32[4] = 0;
    a[0] = 10; a[1] = 20; a[2] = 30; a[3] = 40;
    let sum: i32 = add(a, 4);
    // `i` is a parameter of nothing here: a for-header binding must not leak,
    // and a nested block may shadow the global without disturbing it.
    for (let i: i32 = 0; i < 2; i = i + 1) {
        let g: i32 = 5;
        sum = sum + g;
    }
    let dup: bool = g == 100;
    if (dup) { sum = sum + 1; } else { sum = sum + 1000; }
    return sum - 111;
}
AST
"$OUT/aster" build-elf "$OUT/scopes.ast" -o "$OUT/scopes" >/dev/null
"$PWD/tests/run-aarch64.sh" "$OUT/scopes"
printf '%s\n' 'PASS: for-header scope, block shadowing of a global, and ptr/array parameters all still accepted (100+10+1 == 111, exit 0)'

printf '%s\n' '[6/6] Acceptance: a program touching every type still compiles and runs (qemu self-check)'
cat > "$OUT/mixed.ast" <<'AST'
let flag: bool = 1;
fn isBig(x: i32) -> bool { return x > 10; }
fn pick(c: bool, t: i32, f: i32) -> i32 { if (c) { return t; } else { return f; } }
fn sumPtr(p: ptr, n: i32) -> i32 {
    let t: i32 = 0;
    let k: i32 = 0;
    while (k < n) {
        t = t + p[k];
        k = k + 1;
    }
    return t;
}
fn main() -> i32 {
    let a: i32[3] = 0;
    a[0] = 5; a[1] = 6; a[2] = 7;
    let total: i32 = sumPtr(a, 3);
    let r: i32 = pick(isBig(total) && flag, 2, 100);
    if (!flag || total != 18) { r = r + 1000; } else { r = r + 1; }
    return r - 3;
}
AST
"$OUT/aster" build-elf "$OUT/mixed.ast" -o "$OUT/mixed" >/dev/null
"$PWD/tests/run-aarch64.sh" "$OUT/mixed"
printf '%s\n' 'PASS: bool globals/returns/parameters, local arrays, ptr indexing and short-circuit && all accepted (exit 0)'
