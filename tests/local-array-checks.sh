#!/bin/sh
# v0.22.49-dev structural + behavioral checks for LOCAL ARRAYS (function-scope
# i32[N]). Layers: strict compiler build, source guards, rejection matrix for
# the misuse cases, and qemu self-checks of the real frame layout (packed
# 4-byte elements inside the 8-byte-per-slot grid, array name decaying to its
# frame address when passed to a ptr parameter, and the base offset being
# correct for an array that does NOT sit in slot 0).
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-local-array-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/8] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

printf '%s\n' '[2/8] Source guard: local arrays are allocated, initialized and indexed in the frame'
# A regression that drops the frame allocation, the per-element initialization,
# or either index path must fail here before any behavioral test runs.
grep -qF 'std::map<int,uint32_t> localArrayLength' src/aster.cpp \
    || { echo 'FAIL: localArrayLength (slot -> element count) missing from src/aster.cpp' >&2; exit 1; }
grep -qF 'is too large: length ' src/aster.cpp \
    || { echo 'FAIL: local-array frame limit diagnostic missing' >&2; exit 1; }
# v0.23.18-dev: the slot packing stopped being ceil(N/2) the moment element
# types were recorded. A local T[N] now reserves ceil(N*sizeof(T)/8) slots with
# the elements at their natural width, which for i32 is the same number as
# before — (4N+7)/8 == (N+1)/2 for every N — so the i32 frame layout and every
# byte of i32 output is unchanged; only the packing formula, the element-width
# store base and the slotElemTypes record are new, and those are guarded here.
grep -qF 'const uint32_t esz=tySize(elem);' src/aster.cpp \
    || { echo 'FAIL: local-array element width (esz) missing from Stmt::Let' >&2; exit 1; }
grep -qF 'const uint32_t slots=(uint32_t)(((uint64_t)s.count*esz+7u)/8u);' src/aster.cpp \
    || { echo 'FAIL: local-array slot packing (ceil(N*sizeof(T)/8)) missing from Stmt::Let' >&2; exit 1; }
grep -qF 'const uint32_t strBase=esz==1?0x39000000u:esz==2?0x79000000u:esz==8?0xf9000000u:0xb9000000u;' src/aster.cpp \
    || { echo 'FAIL: element-width store base (STRB/STRH/STR X/STR W) missing from Stmt::Let' >&2; exit 1; }
grep -qF 'STR[W|H|B] WZR / STR XZR' src/aster.cpp \
    || { echo 'FAIL: zero-initialization store for local arrays missing' >&2; exit 1; }
grep -qF 'slotElemTypes[slot]=elem;' src/aster.cpp \
    || { echo 'FAIL: local-array element type is not recorded in slotElemTypes' >&2; exit 1; }
# Five base materializations (name decay, the shared element-address emitter,
# the two store paths through a subscript, and the chain path's own base) must
# use the 0x91.. ADD base: the sh bit (bit 22) has to stay 0, or the slot*8
# offset is silently scaled by 4096 — invisible in slot 0, fatal in any other.
# v0.23.28-dev added the fourth, emitElemAddr's, when every element address
# started being computed in one place; v0.23.31-dev added the fifth,
# emitIndexAddr's, where a subscript chain materializes the same local base
# (after its subscripts, because one of them can put a global's address in X16).
test "$(grep -cF '0x91000000u|(uint32_t(slot*8)<<10)' src/aster.cpp)" -eq 5 \
    || { echo 'FAIL: expected exactly five ADD Xd, SP, #slot*8 encodings with sh=0 (0x91000000 base)' >&2; exit 1; }
grep -qF 'cannot return a local array' src/aster.cpp \
    || { echo 'FAIL: dangling-frame guard (returning a local array) missing' >&2; exit 1; }
printf '%s\n' 'PASS: local-array allocation, initialization and both index paths present'

printf '%s\n' '[3/8] Rejection: non-constant local array initializer'
cat > "$OUT/nonconst.ast" <<'AST'
fn get() -> i32 { return 3; }
fn main() -> i32 { let a: i32[4] = get(); return a[0]; }
AST
if out=$("$OUT/aster" build-elf "$OUT/nonconst.ast" -o "$OUT/nonconst" 2>&1); then
    echo 'FAIL: compiler accepted a non-constant local array initializer' >&2
    exit 1
fi
printf '%s\n' "$out" | grep -qF "array initializer must be a constant expression: a" \
    || { echo "FAIL: wrong diagnostic for non-constant initializer: $out" >&2; exit 1; }
printf '%s\n' 'PASS: let a: i32[4] = get() rejected (frame init must be compile-time constant)'

printf '%s\n' '[4/8] Rejection: constant out-of-bounds indexes on a LOCAL array'
cat > "$OUT/oob-read.ast" <<'AST'
fn main() -> i32 { let a: i32[4] = 0; return a[4]; }
AST
if out=$("$OUT/aster" build-elf "$OUT/oob-read.ast" -o "$OUT/oob-read" 2>&1); then
    echo 'FAIL: compiler accepted an out-of-bounds read a[4] on local i32[4]' >&2
    exit 1
fi
printf '%s\n' "$out" | grep -qF "array index out of bounds for 'a': index 4, length 4" \
    || { echo "FAIL: wrong diagnostic for out-of-bounds local read: $out" >&2; exit 1; }
test ! -e "$OUT/oob-read" || { echo 'FAIL: compiler emitted an image for rejected input' >&2; exit 1; }
cat > "$OUT/oob-write.ast" <<'AST'
fn main() -> i32 { let a: i32[4] = 0; a[-1] = 7; return 0; }
AST
if out=$("$OUT/aster" build-elf "$OUT/oob-write.ast" -o "$OUT/oob-write" 2>&1); then
    echo 'FAIL: compiler accepted an out-of-bounds write a[-1] on local i32[4]' >&2
    exit 1
fi
printf '%s\n' "$out" | grep -qF "array index out of bounds for 'a': index -1, length 4" \
    || { echo "FAIL: wrong diagnostic for out-of-bounds local write: $out" >&2; exit 1; }
printf '%s\n' 'PASS: a[4] read and a[-1] write on local i32[4] rejected with name/index/length'

printf '%s\n' '[5/8] Rejection: misuse matrix (whole assign, scalar index, bool element, zero length, shadowed bounds, return array)'
cat > "$OUT/whole.ast" <<'AST'
fn main() -> i32 { let a: i32[4] = 0; a = 1; return 0; }
AST
if out=$("$OUT/aster" build-elf "$OUT/whole.ast" -o "$OUT/whole" 2>&1); then
    echo 'FAIL: compiler accepted a whole-array assignment' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF "cannot assign to an array as a whole: a" \
    || { echo "FAIL: wrong diagnostic for whole-array assignment: $out" >&2; exit 1; }

cat > "$OUT/scalar.ast" <<'AST'
fn main() -> i32 { let x: i32 = 0; return x[0]; }
AST
if out=$("$OUT/aster" build-elf "$OUT/scalar.ast" -o "$OUT/scalar" 2>&1); then
    echo 'FAIL: compiler accepted indexing a scalar local' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF "cannot index non-array variable: x" \
    || { echo "FAIL: wrong diagnostic for scalar indexing: $out" >&2; exit 1; }

# v0.23.28-dev: `let p: ptr[2] = 0;` used to be refused here ("local pointer
# arrays are not supported") — that element type is legal now, and it has its
# own suite. The matrix keeps its size with the rule that replaced it as the
# interesting local-array misuse: an element keeps the array's element TYPE, so
# a bool literal cannot be stored in an i32 array.
cat > "$OUT/ptarr.ast" <<'AST'
fn main() -> i32 { let a: i32[2] = 0; a[0] = true; return a[0]; }
AST
if out=$("$OUT/aster" build-elf "$OUT/ptarr.ast" -o "$OUT/ptarr" 2>&1); then
    echo 'FAIL: compiler accepted a bool literal into an i32 local array element' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF "type mismatch assigning array element of 'a': expected i32, got bool" \
    || { echo "FAIL: wrong diagnostic for a bool element write: $out" >&2; exit 1; }

cat > "$OUT/zero.ast" <<'AST'
fn main() -> i32 { let a: i32[0] = 0; return 0; }
AST
if out=$("$OUT/aster" build-elf "$OUT/zero.ast" -o "$OUT/zero" 2>&1); then
    echo 'FAIL: compiler accepted a zero-length local array' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF "local array length must be between 1 and 1000: a" \
    || { echo "FAIL: wrong diagnostic for zero-length array: $out" >&2; exit 1; }

# A local array shadows a same-named global array: the bounds check must use
# the LOCAL length (2), not the global one (8).
cat > "$OUT/shadow.ast" <<'AST'
let g: i32[8] = 0;
fn main() -> i32 { let g: i32[2] = 0; return g[5]; }
AST
if out=$("$OUT/aster" build-elf "$OUT/shadow.ast" -o "$OUT/shadow" 2>&1); then
    echo 'FAIL: compiler accepted g[5] against a shadowing local i32[2]' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF "array index out of bounds for 'g': index 5, length 2" \
    || { echo "FAIL: shadowed bounds check used the wrong length: $out" >&2; exit 1; }

# The frame dies with the function: returning a local array's address would
# hand the caller a dangling pointer, so it is a compile error (returning an
# ELEMENT stays legal).
cat > "$OUT/ret-array.ast" <<'AST'
fn f() -> ptr { let a: i32[2] = 0; return a; }
fn main() -> i32 { return 0; }
AST
if out=$("$OUT/aster" build-elf "$OUT/ret-array.ast" -o "$OUT/ret-array" 2>&1); then
    echo 'FAIL: compiler accepted returning a local array' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF "cannot return a local array (its frame storage does not outlive the call): a" \
    || { echo "FAIL: wrong diagnostic for returning a local array: $out" >&2; exit 1; }
printf '%s\n' 'PASS: whole-assign / scalar-index / bool-element / zero-length / shadowed-bounds / return-array all rejected'

printf '%s\n' '[6/8] Acceptance: dynamic index loop over a local array (qemu self-check)'
cat > "$OUT/loop.ast" <<'AST'
fn main() -> i32 {
    let a: i32[4] = 0;
    a[0] = 10;
    a[1] = 20;
    a[2] = a[0] + a[1];
    a[3] = a[2] * 2;
    let i: i32 = 0;
    let sum: i32 = 0;
    while (i < 4) { sum = sum + a[i]; i = i + 1; }
    if (sum == 120) { return 0; } else { return 1; }
}
AST
"$OUT/aster" build-elf "$OUT/loop.ast" -o "$OUT/loop"
./tests/run-aarch64.sh "$OUT/loop"
printf '%s\n' 'PASS: 10+20+30+60 summed through a dynamic-index while loop == 120 (exit 0)'

printf '%s\n' '[7/8] Acceptance: local array decays to its frame address (ptr argument, odd length)'
cat > "$OUT/decay.ast" <<'AST'
fn addAll(p: ptr, n: i32) -> i32 {
    let k: i32 = 0;
    let total: i32 = 0;
    while (k < n) { total = total + *(p + k * 4); k = k + 1; }
    return total;
}
fn main() -> i32 {
    // Odd length: 3 elements occupy ceil(3/2) = 2 frame slots; the 4th byte
    // pair is padding and must never be observed by addAll.
    let a: i32[3] = 7;
    a[0] = 1;
    a[1] = 2;
    a[2] = 3;
    if (addAll(a, 3) == 6) { return 0; } else { return 1; }
}
AST
"$OUT/aster" build-elf "$OUT/decay.ast" -o "$OUT/decay"
./tests/run-aarch64.sh "$OUT/decay"
printf '%s\n' 'PASS: addAll(a, 3) over an odd-length local array == 6 (exit 0)'

printf '%s\n' '[8/8] Acceptance: base offset when the array is NOT in slot 0 (qemu self-check)'
# Regression: v0.22.49-dev first materialized the frame base with the 0x91400000
# ADD encoding, whose sh bit (bit 22) scales the imm12 field by 4096 — so the
# base was SP + (slot*8 << 12). Every earlier test happened to declare the array
# first (slot 0, offset 0), which masked the bug; any array behind another local
# wrote far outside the 8 KiB frame. The sh=0 encoding (0x91000000) is guarded
# above; this run proves the frame layout end to end.
cat > "$OUT/offset.ast" <<'AST'
fn main() -> i32 {
    let total: i32 = 0;
    let a: i32[4] = 0;
    let i: i32 = 0;
    while (i < 4) { a[i] = i * 5; i = i + 1; }
    i = 0;
    while (i < 4) { total = total + a[i]; i = i + 1; }
    if (total == 30) { return 0; } else { return 1; }
}
AST
"$OUT/aster" build-elf "$OUT/offset.ast" -o "$OUT/offset"
./tests/run-aarch64.sh "$OUT/offset"
printf '%s\n' 'PASS: i32[4] behind a scalar local (slot 1) reads/writes its own frame bytes (0+5+10+15 == 30, exit 0)'
