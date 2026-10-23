#!/bin/sh
# v0.22.50-dev structural + behavioral checks for FOR loops:
#   for (init; cond; step) { body }
# desugars to { init; while (cond) { body; step; } } — the initializer runs once
# in the loop's own scope, the step sits between the body and the back-edge, and
# continue branches to the step (not the condition). Layers: strict compiler
# build, source guards, a rejection matrix for the misuse cases, and qemu
# self-checks of the real code shape (nested loops, mixed while/for continue
# targets, empty clauses, and for over a local array).
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-for-loop-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/7] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

printf '%s\n' '[2/7] Source guard: for is a first-class statement with a deferred continue target'
# A regression that drops the for statement kind, the clause grammar, the
# step placement, or the continue-to-step patching must fail here first.
grep -qF 'else if(x=="for")k=TK::For;' src/aster.cpp \
    || { echo 'FAIL: for keyword missing from the lexer' >&2; exit 1; }
grep -qF 'For, Break, Continue' src/aster.cpp \
    || { echo 'FAIL: Stmt::For missing from the statement kinds' >&2; exit 1; }
grep -qF 'std::vector<Stmt> forInit, forStep;' src/aster.cpp \
    || { echo 'FAIL: for initializer/step slots missing from Stmt' >&2; exit 1; }
grep -qF "expected '(' after for" src/aster.cpp \
    || { echo 'FAIL: for header grammar diagnostics missing' >&2; exit 1; }
grep -qF 'for condition cannot be empty' src/aster.cpp \
    || { echo 'FAIL: empty-condition rejection missing' >&2; exit 1; }
grep -qF 'for step cannot declare a variable' src/aster.cpp \
    || { echo 'FAIL: let-in-step rejection missing' >&2; exit 1; }
# v0.22.51-dev: for/if/while conditions share emitCondition, whose fallback
# message is the shared one. v0.23.25-dev grew it a third kind: an integer
# condition is legal now (zero is false), so the refusal covers ptr/struct.
grep -qF 'condition must be a comparison, a bool expression, or an integer' src/aster.cpp \
    || { echo 'FAIL: for condition type check missing' >&2; exit 1; }
grep -qF 'for(size_t at:loops.back().continues)patchBranch(at,stepAt);' src/aster.cpp \
    || { echo 'FAIL: continue-to-step patching missing from Stmt::For' >&2; exit 1; }
# v0.23.49-dev: the while/for continue push now indexes the loop by label
# (loopIndexFor) so a labeled break/continue can reach an enclosing loop; for an
# unlabeled loop loopIndexFor returns loops.size()-1 == loops.back(), so the
# deferred continue target still lands on the while condition.
grep -qF 'loops[loopIndexFor(s)].continues.push_back(code.size());' src/aster.cpp \
    || { echo 'FAIL: deferred continue sites missing (while must keep branching to its condition)' >&2; exit 1; }
grep -qF 'for(size_t at:loops.back().continues)patchBranch(at,loopStart);' src/aster.cpp \
    || { echo 'FAIL: while continue target must stay the loop condition' >&2; exit 1; }
# The step-7 self-check indexes a local array from inside a for loop, so the
# frame base encoding is part of this suite's contract too (sh bit must be 0).
# Five since v0.23.31-dev: the fourth is emitElemAddr's, the one place a local
# array's element address is computed, shared by a read, a store and &a[i]
# (v0.23.28-dev), and the fifth is emitIndexAddr's — a subscript chain's own
# local base, added by the multi-dimensional round.
test "$(grep -cF '0x91000000u|(uint32_t(slot*8)<<10)' src/aster.cpp)" -eq 5 \
    || { echo 'FAIL: local-array frame base must use the sh=0 ADD encoding (0x91000000)' >&2; exit 1; }
printf '%s\n' 'PASS: for statement kind, clause grammar, step placement and both continue targets present'

printf '%s\n' '[3/7] Rejection matrix'
cat > "$OUT/no-paren.ast" <<'AST'
fn main() -> i32 { for let i: i32 = 0; i < 3; i = i + 1) { return 0; } return 1; }
AST
cat > "$OUT/bad-init.ast" <<'AST'
fn main() -> i32 { for (5; i < 3; i = i + 1) { return 0; } return 1; }
AST
cat > "$OUT/empty-cond.ast" <<'AST'
fn main() -> i32 { for (let i: i32 = 0; ; i = i + 1) { return 0; } return 1; }
AST
cat > "$OUT/let-step.ast" <<'AST'
fn main() -> i32 { for (let i: i32 = 0; i < 3; let j: i32 = 1) { return 0; } return 1; }
AST
# v0.23.25-dev: an integer for-condition is legal now (zero is false), so the
# non-comparison case that is still refused is a pointer — `for (...; p; ...)`.
cat > "$OUT/non-compare-cond.ast" <<'AST'
fn f(p: ptr) -> i32 { for (let i: i32 = 0; p; i = i + 1) { return 0; } return 1; }
fn main() -> i32 { return 0; }
AST
cat > "$OUT/break-outside.ast" <<'AST'
fn main() -> i32 { break; return 0; }
AST
cat > "$OUT/continue-outside.ast" <<'AST'
fn main() -> i32 { continue; return 0; }
AST
cat > "$OUT/leaked-var.ast" <<'AST'
fn main() -> i32 { for (let i: i32 = 0; i < 3; i = i + 1) { } return i; }
AST
cat > "$OUT/missing-semi.ast" <<'AST'
fn main() -> i32 { for (let i: i32 = 0 i < 3; i = i + 1) { return 0; } return 1; }
AST
"$OUT/aster" build-elf "$OUT/no-paren.ast" -o "$OUT/no-paren" 2>&1 | grep -q "expected '(' after for" \
    || { echo 'FAIL: missing ( in for header not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/bad-init.ast" -o "$OUT/bad-init" 2>&1 | grep -q "expected 'let', assignment, or ';' in for initializer" \
    || { echo 'FAIL: invalid for initializer not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/empty-cond.ast" -o "$OUT/empty-cond" 2>&1 | grep -q 'for condition cannot be empty' \
    || { echo 'FAIL: empty for condition not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/let-step.ast" -o "$OUT/let-step" 2>&1 | grep -q 'for step cannot declare a variable' \
    || { echo 'FAIL: let in for step not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/non-compare-cond.ast" -o "$OUT/non-compare-cond" 2>&1 | grep -q 'condition must be a comparison, a bool expression, or an integer' \
    || { echo 'FAIL: non-comparison for condition not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/break-outside.ast" -o "$OUT/break-outside" 2>&1 | grep -q 'break used outside a loop' \
    || { echo 'FAIL: break outside a loop not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/continue-outside.ast" -o "$OUT/continue-outside" 2>&1 | grep -q 'continue used outside a loop' \
    || { echo 'FAIL: continue outside a loop not rejected' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/leaked-var.ast" -o "$OUT/leaked-var" 2>&1 | grep -q 'unknown variable: i' \
    || { echo 'FAIL: for-initialized variable must not outlive the loop' >&2; exit 1; }
"$OUT/aster" build-elf "$OUT/missing-semi.ast" -o "$OUT/missing-semi" 2>&1 | grep -q "expected ';'" \
    || { echo 'FAIL: missing semicolon after for initializer not rejected' >&2; exit 1; }
printf '%s\n' 'PASS: header grammar, empty condition, let-in-step, condition type, loop-exterior break/continue, scope leak, missing semicolon all rejected'

printf '%s\n' '[4/7] Acceptance: the initializer runs once and the step advances the variable (qemu self-check)'
cat > "$OUT/sum.ast" <<'AST'
fn main() -> i32 {
    let total: i32 = 0;
    for (let i: i32 = 1; i < 6; i = i + 1) {
        total = total + i;
    }
    return total - 15;
}
AST
"$OUT/aster" build-elf "$OUT/sum.ast" -o "$OUT/sum" >/dev/null
"$PWD/tests/run-aarch64.sh" "$OUT/sum"
printf '%s\n' 'PASS: 1+2+3+4+5 summed through a for loop == 15 (exit 0)'

printf '%s\n' '[5/7] Acceptance: continue lands on the step, break exits (qemu self-check)'
cat > "$OUT/flow.ast" <<'AST'
fn main() -> i32 {
    let total: i32 = 0;
    for (let i: i32 = 0; i < 10; i = i + 1) {
        if (i == 3) { continue; } else { total = total + 0; }
        if (i == 7) { break; } else { total = total + i; }
    }
    return total - 18;
}
AST
"$OUT/aster" build-elf "$OUT/flow.ast" -o "$OUT/flow" >/dev/null
"$PWD/tests/run-aarch64.sh" "$OUT/flow"
printf '%s\n' 'PASS: continue still runs i = i + 1 (0+1+2+4+5+6 == 18), break stops at 7 (exit 0)'

printf '%s\n' '[6/7] Acceptance: empty initializer/step and assignment-form initializer (qemu self-check)'
cat > "$OUT/clauses.ast" <<'AST'
fn main() -> i32 {
    let i: i32 = 0;
    let total: i32 = 0;
    for (; i < 5;) {
        total = total + 10;
        i = i + 1;
    }
    for (i = 0; i < 3; i = i + 1) {
        total = total + 1;
    }
    return total - 53;
}
AST
"$OUT/aster" build-elf "$OUT/clauses.ast" -o "$OUT/clauses" >/dev/null
"$PWD/tests/run-aarch64.sh" "$OUT/clauses"
printf '%s\n' 'PASS: empty init/step and an assignment initializer both work (5*10 + 3 == 53, exit 0)'

printf '%s\n' '[7/7] Acceptance: nested and mixed loops, plus for over a local array (qemu self-check)'
cat > "$OUT/nested.ast" <<'AST'
fn main() -> i32 {
    let total: i32 = 0;
    for (let i: i32 = 0; i < 4; i = i + 1) {
        for (let j: i32 = 0; j < 3; j = j + 1) {
            total = total + 1;
        }
    }
    let n: i32 = 0;
    while (n < 2) {
        for (let k: i32 = 0; k < 5; k = k + 1) {
            if (k == 3) { continue; } else { total = total + 1; }
        }
        total = total + 10;
        n = n + 1;
    }
    let a: i32[4] = 0;
    for (let m: i32 = 0; m < 4; m = m + 1) {
        a[m] = m * 5;
    }
    for (let q: i32 = 0; q < 4; q = q + 1) {
        total = total + a[q];
    }
    return total - 70;
}
AST
"$OUT/aster" build-elf "$OUT/nested.ast" -o "$OUT/nested" >/dev/null
"$PWD/tests/run-aarch64.sh" "$OUT/nested"
printf '%s\n' 'PASS: nested for (12) + while/for mix with continue-to-step (28) + for over a local array (30) == 70 (exit 0)'
