#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-array-bounds-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
printf '%s\n' '[1/6] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

printf '%s\n' '[2/6] Source guard: constant folder and bounds check are wired into both index paths'
# The v0.22.48 feature: constant folding (constantInteger) plus a bounds check
# (checkArrayBounds) invoked from BOTH the read path (Expr::Index) and the
# write path (Stmt::IndexAssign). A regression that drops either call site, or
# the folder itself, must fail here before any behavioral test runs.
grep -qF 'static bool constantInteger' src/aster.cpp \
    || { echo 'FAIL: constant folder (constantInteger) missing from src/aster.cpp' >&2; exit 1; }
grep -qF 'void checkArrayBounds' src/aster.cpp \
    || { echo 'FAIL: checkArrayBounds missing from src/aster.cpp' >&2; exit 1; }
grep -qF 'checkArrayBounds(e.name,*e.a)' src/aster.cpp \
    || { echo 'FAIL: bounds check not invoked on the array READ path (Expr::Index)' >&2; exit 1; }
grep -qF 'checkArrayBounds(s.name,*s.idx)' src/aster.cpp \
    || { echo 'FAIL: bounds check not invoked on the array WRITE path (Stmt::IndexAssign)' >&2; exit 1; }
printf '%s\n' 'PASS: both index paths route through the constant-folding bounds check'

printf '%s\n' '[3/6] Rejection: constant out-of-bounds READ on a fixed-size global array'
cat > "$OUT/oob-read.ast" <<'AST'
let values: i32[4] = 0;
fn main() -> i32 { return values[2 + 2]; }
AST
if out=$("$OUT/aster" build-obj "$OUT/oob-read.ast" -o "$OUT/oob-read.o" 2>&1); then
    echo 'FAIL: compiler accepted an out-of-bounds constant read values[2+2] on i32[4]' >&2
    exit 1
fi
printf '%s\n' "$out" | grep -qF "array index out of bounds for 'values': index 4, length 4" \
    || { echo "FAIL: wrong diagnostic for out-of-bounds read: $out" >&2; exit 1; }
test ! -e "$OUT/oob-read.o" || { echo 'FAIL: compiler emitted an object for rejected input' >&2; exit 1; }
printf '%s\n' 'PASS: values[2+2] on i32[4] rejected with name/index/length diagnostic'

printf '%s\n' '[4/6] Rejection: constant out-of-bounds WRITE and negative index'
cat > "$OUT/oob-write.ast" <<'AST'
let values: i32[4] = 0;
fn main() -> i32 { values[-1] = 7; return 0; }
AST
if out=$("$OUT/aster" build-obj "$OUT/oob-write.ast" -o "$OUT/oob-write.o" 2>&1); then
    echo 'FAIL: compiler accepted an out-of-bounds constant write values[-1] on i32[4]' >&2
    exit 1
fi
printf '%s\n' "$out" | grep -qF "array index out of bounds for 'values': index -1, length 4" \
    || { echo "FAIL: wrong diagnostic for out-of-bounds write: $out" >&2; exit 1; }
printf '%s\n' 'PASS: values[-1] = 7 on i32[4] rejected (negative index caught)'

printf '%s\n' '[5/6] Rejection: pointer-typed global runtime initializer'
cat > "$OUT/ptr-global-init.ast" <<'AST'
fn get_ptr() -> ptr { return "x"; }
let value: i32 = get_ptr();
fn main() -> i32 { return value; }
AST
if out=$("$OUT/aster" build-obj "$OUT/ptr-global-init.ast" -o "$OUT/ptr-global-init.o" 2>&1); then
    echo 'FAIL: compiler accepted a ptr-typed initializer for an i32 global' >&2
    exit 1
fi
printf '%s\n' "$out" | grep -qF "type mismatch initializing global 'value': expected i32, got ptr" \
    || { echo "FAIL: wrong diagnostic for ptr global initializer: $out" >&2; exit 1; }
printf '%s\n' "PASS: global 'let value: i32 = get_ptr()' rejected (would truncate a pointer to 32 bits)"

printf '%s\n' '[6/6] Acceptance: in-bounds constant index still compiles and runs'
cat > "$OUT/valid.ast" <<'AST'
let values: i32[4] = 0;
fn main() -> i32 {
    values[1 + 2] = 9;
    let i: i32 = 2;
    values[i + 1] = values[3];
    if (values[3] == 9) { return 0; } else { return 1; }
}
AST
"$OUT/aster" build-elf "$OUT/valid.ast" -o "$OUT/valid"
./tests/run-aarch64.sh "$OUT/valid"
printf '%s\n' 'PASS: values[1+2] = 9 / values[i+1] = values[3] on i32[4] accepted and executed correctly'
