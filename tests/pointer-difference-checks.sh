#!/bin/sh
# v0.23.57-dev checks for POINTER DIFFERENCE: `p - q` between two pointers
# yields the signed element count, striding at each pointer's element width (4
# bytes for i32 and an untyped `ptr`, 1 for u8, 8 for i64, and the struct size
# for ptr<S>). Layers: strict compiler build, source guards, rejection matrix,
# qemu self-checks covering every stride (power-of-two shift and struct divide),
# and a gcc differential is provided separately by e2e-c-ptr-difference.sh.
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-pointer-difference-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/6] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

printf '%s\n' '[2/6] Source guard: ptr - ptr byte gap divided by the element stride'
# The new code path takes the 64-bit byte difference (SUB X) and divides it by
# the element stride: an arithmetic shift for a power-of-two stride and a signed
# divide for a struct stride that is not. The element type is resolved by the
# shared ptrStrideType helper (the same one emitElemAddr uses for p[i]).
grep -qF 'ptrStrideType' src/aster.cpp \
    || { echo 'FAIL: ptrStrideType helper missing' >&2; exit 1; }
grep -qF 'const Ty elem=ptrStrideType(exprType(*e.a));' src/aster.cpp \
    || { echo 'FAIL: pointer-difference codegen does not resolve the element stride' >&2; exit 1; }
grep -qF '0x93400000u|(uint32_t(sh)<<16)|0xfc00u' src/aster.cpp \
    || { echo 'FAIL: power-of-two stride does not fold into ASR X, #sh' >&2; exit 1; }
grep -qF '0x9ac00c00u' src/aster.cpp \
    || { echo 'FAIL: struct (non-power-of-two) stride does not use signed SDIV' >&2; exit 1; }
grep -qF 'pointer difference requires two pointers to the same element type' src/aster.cpp \
    || { echo 'FAIL: element-type mismatch diagnostic for pointer difference missing' >&2; exit 1; }
printf '%s\n' 'PASS: pointer difference takes the byte gap and divides by the element stride'

printf '%s\n' '[3/6] Rejection matrix'
# ptr + ptr is still rejected (unchanged behaviour).
cat > "$OUT/plus.ast" <<'AST'
fn f(a: ptr, b: ptr) -> ptr { return a + b; }
fn main() -> i32 { return 0; }
AST
if out=$("$OUT/aster" build-elf "$OUT/plus.ast" -o "$OUT/plus" 2>&1); then
    echo 'FAIL: compiler accepted ptr + ptr' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF 'invalid pointer arithmetic: ptr + ptr is not supported' \
    || { echo "FAIL: wrong diagnostic for ptr + ptr: $out" >&2; exit 1; }

# i32 - ptr is still rejected.
cat > "$OUT/i32minusptr.ast" <<'AST'
fn f(a: i32, b: ptr) -> i32 { return a - b; }
fn main() -> i32 { return 0; }
AST
if out=$("$OUT/aster" build-elf "$OUT/i32minusptr.ast" -o "$OUT/i32minusptr" 2>&1); then
    echo 'FAIL: compiler accepted i32 - ptr' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF 'invalid pointer arithmetic: expected ptr - i32' \
    || { echo "FAIL: wrong diagnostic for i32 - ptr: $out" >&2; exit 1; }

# Element-type mismatch: ptr<i32> - ptr<u8> (different strides) is rejected.
cat > "$OUT/mismatch.ast" <<'AST'
fn f(a: ptr<i32>, b: ptr<u8>) -> i32 { return a - b; }
fn main() -> i32 { return 0; }
AST
if out=$("$OUT/aster" build-elf "$OUT/mismatch.ast" -o "$OUT/mismatch" 2>&1); then
    echo 'FAIL: compiler accepted ptr<i32> - ptr<u8>' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF 'pointer difference requires two pointers to the same element type' \
    || { echo "FAIL: wrong diagnostic for stride mismatch: $out" >&2; exit 1; }

# Element-type mismatch: ptr<i32> - ptr<Row> (scalar vs struct) is rejected.
cat > "$OUT/mix.ast" <<'AST'
struct Row { a: i32, b: i32 }
fn f(a: ptr<i32>, b: ptr<Row>) -> i32 { return a - b; }
fn main() -> i32 { return 0; }
AST
if out=$("$OUT/aster" build-elf "$OUT/mix.ast" -o "$OUT/mix" 2>&1); then
    echo 'FAIL: compiler accepted ptr<i32> - ptr<Row>' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF 'pointer difference requires two pointers to the same element type' \
    || { echo "FAIL: wrong diagnostic for scalar/struct mismatch: $out" >&2; exit 1; }
printf '%s\n' 'PASS: ptr + ptr, i32 - ptr, and stride mismatches all rejected'

printf '%s\n' '[4/6] Acceptance: every stride via qemu self-check (power-of-two shifts)'
# Untyped ptr and ptr<i32> both stride 4 bytes; u8 strides 1; i64 strides 8.
cat > "$OUT/strides.ast" <<'AST'
fn main() -> i32 {
    let a: i32[8] = 0;
    let u_p: ptr = a;
    let u_q: ptr = a + 16;
    if (u_q - u_p != 4) { return 1; }
    if (u_p - u_q != -4) { return 2; }
    let t_p: ptr<i32> = &a;
    let t_q: ptr<i32> = &a + 16;
    if (t_q - t_p != 4) { return 3; }
    if (t_p - t_q != -4) { return 4; }
    let b: u8[8] = 0;
    let ub_p: ptr<u8> = &b;
    let ub_q: ptr<u8> = &b + 6;
    if (ub_q - ub_p != 6) { return 5; }
    let c: i64[8] = 0;
    let ic_p: ptr<i64> = &c;
    let ic_q: ptr<i64> = &c + 40;
    if (ic_q - ic_p != 5) { return 6; }
    return 0;
}
AST
"$OUT/aster" build-elf "$OUT/strides.ast" -o "$OUT/strides"
./tests/run-aarch64.sh "$OUT/strides"
printf '%s\n' 'PASS: untyped/i32 (ASR #2), u8 (no shift), i64 (ASR #3) strides (exit 0)'

printf '%s\n' '[5/6] Acceptance: struct strides via qemu self-check (ASR #3 and SDIV)'
# Row is 8 bytes (power-of-two shift); V3 is 12 bytes (signed divide).
cat > "$OUT/structs.ast" <<'AST'
struct Row { a: i32, b: i32 }
struct V3 { x: i32, y: i32, z: i32 }
struct WrapR { rs: Row[4] }
struct WrapV { vs: V3[4] }
fn main() -> i32 {
    let wr: WrapR;
    let rp: ptr<Row> = &wr.rs[0];
    let rq: ptr<Row> = &wr.rs[3];
    if (rq - rp != 3) { return 1; }
    let wv: WrapV;
    let vp: ptr<V3> = &wv.vs[0];
    let vq: ptr<V3> = &wv.vs[3];
    if (vq - vp != 3) { return 2; }
    return 0;
}
AST
"$OUT/aster" build-elf "$OUT/structs.ast" -o "$OUT/structs"
./tests/run-aarch64.sh "$OUT/structs"
printf '%s\n' 'PASS: Row (ASR #3) and V3 (SDIV by 12) struct strides (exit 0)'

printf '%s\n' '[6/6] Acceptance: cross-category and self-contained element count'
# An untyped ptr and a ptr<i32> share the 4-byte stride, so their difference is
# allowed (same stride) and equals the index gap. A self-contained count over a
# parameter array confirms the result is usable as an ordinary i32.
cat > "$OUT/cross.ast" <<'AST'
fn count(p: ptr, q: ptr<i32>) -> i32 { return p - q; }
fn main() -> i32 {
    let a: i32[8] = 0;
    let lo: ptr = a;
    let hi: ptr<i32> = &a + 20;
    if (count(hi, lo) != 5) { return 1; }
    if (count(lo, hi) != -5) { return 2; }
    return 0;
}
AST
"$OUT/aster" build-elf "$OUT/cross.ast" -o "$OUT/cross"
./tests/run-aarch64.sh "$OUT/cross"
printf '%s\n' 'PASS: cross-category (untyped vs ptr<i32>) difference (exit 0)'
printf '%s\n' 'ALL POINTER-DIFFERENCE CHECKS PASSED'
