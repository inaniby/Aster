#!/bin/sh
# v0.22.49-dev checks for POINTER INDEXING: p[i] on a ptr-typed local (or
# parameter) is *(p + i*4) — one i32 element stride — on both the read and the
# write path. Layers: strict compiler build, source guards, rejection matrix,
# and qemu self-checks (parameter pointers, pointer aliases of arrays, dynamic
# indexes, and a pointer viewing a global array).
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-pointer-index-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/5] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

printf '%s\n' '[2/5] Source guard: ptr-typed base is loaded into X16, then scaled by 4'
# The read path loads the base with LDR X16, [SP, #slot*8] and the write path
# mirrors it; both then fold the index scale into ADD X16, X16, Wr, UXTW #2.
# A regression that reverts to "cannot index non-array variable" for ptr slots,
# or drops the 4-byte stride, must fail here first.
grep -qF 'loadVar64(kGlobalBase,slot)' src/aster.cpp \
    || { echo 'FAIL: pointer-index base load (LDR X16, [SP, #slot*8]) missing' >&2; exit 1; }
grep -qF 'const bool localPtr=slot>=0&&!localArray&&pointerSlots.count(slot)&&pointerSlots.at(slot);' src/aster.cpp \
    || { echo 'FAIL: localPtr classification missing from Stmt::IndexAssign' >&2; exit 1; }
grep -qF 'if(pointerSlots.count(slot)&&pointerSlots.at(slot)){' src/aster.cpp \
    || { echo 'FAIL: pointer-index branch missing from Expr::Index' >&2; exit 1; }
printf '%s\n' 'PASS: both index paths recognize ptr-typed bases and use the 4-byte stride'

printf '%s\n' '[3/5] Rejection matrix'
cat > "$OUT/ptr-index.ast" <<'AST'
fn f(p: ptr, i: ptr) -> i32 { return p[i]; }
fn main() -> i32 { return 0; }
AST
if out=$("$OUT/aster" build-elf "$OUT/ptr-index.ast" -o "$OUT/ptr-index" 2>&1); then
    echo 'FAIL: compiler accepted a ptr-typed index' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF "pointer indexing is not supported yet" \
    || { echo "FAIL: wrong diagnostic for ptr index: $out" >&2; exit 1; }

cat > "$OUT/ptr-value.ast" <<'AST'
fn f(p: ptr, q: ptr) -> i32 { p[0] = q; return 0; }
fn main() -> i32 { return 0; }
AST
if out=$("$OUT/aster" build-elf "$OUT/ptr-value.ast" -o "$OUT/ptr-value" 2>&1); then
    echo 'FAIL: compiler accepted storing a ptr through p[i]' >&2; exit 1
fi
# v0.23.28-dev: the refusal is now the ordinary element-type rule rather than a
# blanket one. `p[0]` on a *ptr* still names an i32 — only a `ptr[N]`'s element
# is a ptr — so the diagnostic names the element type instead of the feature.
printf '%s\n' "$out" | grep -qF "type mismatch assigning array element of 'p': expected i32, got ptr" \
    || { echo "FAIL: wrong diagnostic for ptr value store: $out" >&2; exit 1; }

cat > "$OUT/scalar.ast" <<'AST'
fn main() -> i32 { let x: i32 = 0; return x[0]; }
AST
if out=$("$OUT/aster" build-elf "$OUT/scalar.ast" -o "$OUT/scalar" 2>&1); then
    echo 'FAIL: compiler accepted indexing a scalar local' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF "cannot index non-array variable: x" \
    || { echo "FAIL: wrong diagnostic for scalar indexing: $out" >&2; exit 1; }
printf '%s\n' 'PASS: ptr index / ptr value store / scalar index all rejected'

printf '%s\n' '[4/5] Acceptance: read and write through parameter and alias pointers (qemu self-check)'
cat > "$OUT/rw.ast" <<'AST'
fn aster_read(p: ptr, i: i32) -> i32 { return p[i]; }
fn aster_write(p: ptr, i: i32, v: i32) -> i32 { p[i] = v; return v; }
fn main() -> i32 {
    let a: i32[4] = 0;
    a[0] = 100;
    a[1] = 200;
    a[2] = 300;
    a[3] = 400;
    let w: i32 = aster_write(a, 2, 999);
    let q: ptr = a;
    q[3] = 777;
    if (aster_read(a, 0) != 100) { return 1; } else { }
    if (aster_read(a, 1) != 200) { return 2; } else { }
    if (aster_read(a, 2) != 999) { return 3; } else { }
    if (aster_read(a, 3) != 777) { return 4; } else { }
    if (q[1] != 200) { return 5; } else { }
    if (w != 999) { return 6; } else { }
    return 0;
}
AST
"$OUT/aster" build-elf "$OUT/rw.ast" -o "$OUT/rw"
./tests/run-aarch64.sh "$OUT/rw"
printf '%s\n' 'PASS: p[i] reads and p[i] = v writes through params and aliases (exit 0)'

printf '%s\n' '[5/5] Acceptance: a pointer views a global array and a dynamic index (qemu self-check)'
cat > "$OUT/global.ast" <<'AST'
let g: i32[4] = 0;
fn main() -> i32 {
    g[0] = 5;
    g[1] = 6;
    g[2] = 7;
    g[3] = 8;
    let p: ptr = g;
    let i: i32 = 0;
    let sum: i32 = 0;
    while (i < 4) { sum = sum + p[i]; i = i + 1; }
    p[2] = 70;
    if (sum != 26) { return 1; } else { }
    if (g[2] != 70) { return 2; } else { }
    if (p[3] != 8) { return 3; } else { }
    return 0;
}
AST
"$OUT/aster" build-elf "$OUT/global.ast" -o "$OUT/global"
./tests/run-aarch64.sh "$OUT/global"
printf '%s\n' 'PASS: p[i] over a global array sums 5+6+7+8 and p[2]=70 lands in g[2] (exit 0)'
