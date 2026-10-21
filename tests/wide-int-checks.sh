#!/bin/sh
# v0.23.2-dev structural + behavioral checks for WIDER INTEGER TYPES
# (i64, u8, u16, u32). Layers: strict compiler build, source guards that pin
# the new type lattice and the MOVK wide-literal fix, a rejection matrix for the
# misuse cases, and qemu self-checks of the real AArch64 codegen (64-bit
# arithmetic/comparison, the AArch64 MOVZ+MOVK literal materialization, narrow
# zero-extending load/store forms, unsigned condition codes + UDIV, the 8-byte
# AAPCS64 argument/return ABI, and wide/narrow globals and arrays).
#
# Each qemu self-check returns a DISTINCT non-zero code on success so a silent
# wrong-value cannot masquerade as a clean run; the harness captures the code
# and asserts it equals the expected value (so `set -e` is not tripped by the
# intentional non-zero success codes).
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-wide-int-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/8] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

printf '%s\n' '[2/8] Source guard: the unified value-lattice and width helpers exist'
grep -qF 'enum Kind { I32, U32, U8, U16, I64, Ptr, Bool, Struct };' src/aster.cpp \
    || { echo 'FAIL: unified Ty lattice missing' >&2; exit 1; }
grep -qF 'static bool tyIs64(Ty t)' src/aster.cpp \
    || { echo 'FAIL: tyIs64 helper missing' >&2; exit 1; }
grep -qF 'static bool tyIsUnsigned(Ty t)' src/aster.cpp \
    || { echo 'FAIL: tyIsUnsigned helper missing' >&2; exit 1; }
# v0.23.28-dev: tyShift became elemShiftOf. It answers log2(tySize(t)) for
# every scalar — the same numbers tyShift did — and -1 for a type whose size is
# not a power of two (a struct), which tyShift's "2 for anything I do not
# name" could not express. A struct element therefore scales by UMADDL in
# emitElemIndex instead of folding into the extended-register ADD.
grep -qF 'static int elemShiftOf(Ty t){' src/aster.cpp \
    || { echo 'FAIL: elemShiftOf helper missing' >&2; exit 1; }
# The MOVZ+MOVK literal materializer must use the unbiased MOVK base 0xf2800000
# (hw=0). The earlier 0xf2a00000 base had lsl #16 baked in, which pushed every
# chunk one shift too far and corrupted every i64 literal wider than 32 bits.
test "$(grep -cF '0xf2800000u' src/aster.cpp)" -ge 3 \
    || { echo 'FAIL: emitMov64 must use the unbiased MOVK base 0xf2800000 (lsl #0)' >&2; exit 1; }
# Narrow (zero-extending) load/store forms must be emitted for u8/u16.
grep -qF '0x39400000u' src/aster.cpp || { echo 'FAIL: LDRB (u8 load) missing' >&2; exit 1; }
grep -qF '0x79400000u' src/aster.cpp || { echo 'FAIL: LDRH (u16 load) missing' >&2; exit 1; }
grep -qF '0x39000000u' src/aster.cpp || { echo 'FAIL: STRB (u8 store) missing' >&2; exit 1; }
grep -qF '0x79000000u' src/aster.cpp || { echo 'FAIL: STRH (u16 store) missing' >&2; exit 1; }
# An incoming stack argument (the 9th and later) must be loaded with the width
# of its DECLARED parameter type. Hardcoding the 64-bit form made every i32
# example with more than eight arguments differ byte-for-byte from v0.23.1-dev
# (caught by an A/B comparison of all 82 examples against the previous release).
grep -qF 'static uint32_t loadIncomingArgT(uint32_t off,Ty t)' src/aster.cpp \
    || { echo 'FAIL: loadIncomingArgT helper missing' >&2; exit 1; }
grep -qF '0xb9400210u|((off/4)<<10)' src/aster.cpp \
    || { echo 'FAIL: incoming i32 stack argument must keep the 32-bit load' >&2; exit 1; }
# LDRH/STRH immediates are scaled by the 2-byte access size (verified against
# GAS: `ldrh w16, [x16, #8]` assembles to imm12 = 4); the byte forms are
# unscaled. A wrong scale silently moves the access onto a neighbouring slot.
grep -qF '0x794003e0u|((off/2)<<10)' src/aster.cpp \
    || { echo 'FAIL: loadStackT u16 must scale the offset by 2' >&2; exit 1; }
grep -qF '0x790003e0u|((off/2)<<10)' src/aster.cpp \
    || { echo 'FAIL: storeStackT u16 must scale the offset by 2' >&2; exit 1; }
grep -qF '0x794003e0u|(uint32_t(slot*4)<<10)' src/aster.cpp \
    || { echo 'FAIL: loadVar16 must encode slot*8 bytes as imm12 = slot*4' >&2; exit 1; }
grep -qF '0x790003e0u|(uint32_t(slot*4)<<10)' src/aster.cpp \
    || { echo 'FAIL: storeVar16 must encode slot*8 bytes as imm12 = slot*4' >&2; exit 1; }
printf '%s\n' 'PASS: Ty lattice, tyIs64/tyIsUnsigned/elemShiftOf, MOVK base and narrow LDRB/LDRH/STRB/STRH present'

printf '%s\n' '[3/8] Rejection: narrowing, unsigned-range and literal-range misuse'
# i32 value handed to a u8 parameter is a narrowing conversion -> rejected.
cat > "$OUT/narrow-arg.ast" <<'AST'
fn f(x: u8) -> i32 { return 0; }
fn main() -> i32 { let y: i32 = 300; return f(y); }
AST
if out=$("$OUT/aster" build-elf "$OUT/narrow-arg.ast" -o "$OUT/narrow-arg" 2>&1); then
    echo 'FAIL: compiler accepted an i32 argument for a u8 parameter' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF "argument type mismatch calling f at argument 1: expected u8, got i32" \
    || { echo "FAIL: wrong diagnostic for i32->u8 argument: $out" >&2; exit 1; }

# i64 value handed to an i32 parameter is a narrowing conversion -> rejected.
cat > "$OUT/i64-arg.ast" <<'AST'
fn f(x: i32) -> i32 { return 0; }
fn main() -> i32 { let y: i64 = 5; return f(y); }
AST
if out=$("$OUT/aster" build-elf "$OUT/i64-arg.ast" -o "$OUT/i64-arg" 2>&1); then
    echo 'FAIL: compiler accepted an i64 argument for an i32 parameter' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF "argument type mismatch calling f at argument 1: expected i32, got i64" \
    || { echo "FAIL: wrong diagnostic for i64->i32 argument: $out" >&2; exit 1; }

# A literal wider than i64 cannot be materialized at all.
cat > "$OUT/lit-range.ast" <<'AST'
fn main() -> i32 { let x: i64 = 10000000000000000000; return 0; }
AST
if out=$("$OUT/aster" build-elf "$OUT/lit-range.ast" -o "$OUT/lit-range" 2>&1); then
    echo 'FAIL: compiler accepted a literal wider than i64' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF "integer literal exceeds i64 range" \
    || { echo "FAIL: wrong diagnostic for over-wide literal: $out" >&2; exit 1; }

# A narrow global initializer that does not fit the slot is rejected.
cat > "$OUT/global-range.ast" <<'AST'
let g: u8 = 300;
fn main() -> i32 { return 0; }
AST
if out=$("$OUT/aster" build-elf "$OUT/global-range.ast" -o "$OUT/global-range" 2>&1); then
    echo 'FAIL: compiler accepted a u8 global initializer of 300' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF "global initializer does not fit in u8: g (300)" \
    || { echo "FAIL: wrong diagnostic for out-of-range u8 global: $out" >&2; exit 1; }
printf '%s\n' 'PASS: i32->u8 arg, i64->i32 arg, over-wide literal and out-of-range u8 global all rejected'

printf '%s\n' '[4/8] Acceptance: i64 literals, arithmetic, negative values and all comparisons (qemu)'
cat > "$OUT/i64ops.ast" <<'AST'
fn main() -> i32 {
    let a: i64 = 1000000000000;
    let b: i64 = 2000000000000;
    let s: i64 = a + b;
    let d: i64 = b - a;
    let m: i64 = a * 3;
    let q: i64 = -900000000000 / 3;
    let neg: i64 = -42;
    if (s == 3000000000000) {
        if (d == 1000000000000) {
            if (m == 3000000000000) {
                if (q == -300000000000) {
                    if (neg == -42) {
                        if (a < b) {
                            if (b > a) {
                                if (a <= a) {
                                    if (b >= a) {
                                        if (s != 0) { return 11; } else { return 0; }
                                    } else { return 0; }
                                } else { return 0; }
                            } else { return 0; }
                        } else { return 0; }
                    } else { return 0; }
                } else { return 0; }
            } else { return 0; }
        } else { return 0; }
    } else { return 0; }
}
AST
"$OUT/aster" build-elf "$OUT/i64ops.ast" -o "$OUT/i64ops"
rc=0
./tests/run-aarch64.sh "$OUT/i64ops" || rc=$?
test "$rc" -eq 11 || { echo "FAIL: i64ops expected exit 11, got $rc" >&2; exit 1; }
printf '%s\n' 'PASS: i64 add/sub/mul/div/neg, negative literal and ==/!=/</>/<=/>= all correct (exit 11)'

printf '%s\n' '[5/8] Acceptance: i64 function ABI (params, return, >8 args) and mixed locals (qemu)'
cat > "$OUT/i64chain.ast" <<'AST'
fn add3(x: i64, y: i64, z: i64) -> i64 { return x + y + z; }
fn main() -> i32 {
    let r: i64 = add3(1000000000000, 2000000000000, 500000000000);
    if (r == 3500000000000) { return 13; } else { return 0; }
}
AST
"$OUT/aster" build-elf "$OUT/i64chain.ast" -o "$OUT/i64chain"
rc=0
./tests/run-aarch64.sh "$OUT/i64chain" || rc=$?
test "$rc" -eq 13 || { echo "FAIL: i64chain expected exit 13, got $rc" >&2; exit 1; }

cat > "$OUT/reti64.ast" <<'AST'
fn get() -> i64 { return 3000000000000; }
fn getu() -> u32 { return 4000000000; }
fn main() -> i32 {
    let x: i64 = get();
    let y: u32 = getu();
    if (x == 3000000000000) {
        if (y > 1000000000) { return 51; } else { return 0; }
    } else { return 0; }
}
AST
"$OUT/aster" build-elf "$OUT/reti64.ast" -o "$OUT/reti64"
rc=0
./tests/run-aarch64.sh "$OUT/reti64" || rc=$?
test "$rc" -eq 51 || { echo "FAIL: reti64 expected exit 51, got $rc" >&2; exit 1; }

cat > "$OUT/manyi64.ast" <<'AST'
fn sum9(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64, i: i64) -> i64 {
    return a + b + c + d + e + f + g + h + i;
}
fn main() -> i32 {
    let r: i64 = sum9(100000000000, 200000000000, 300000000000, 400000000000, 500000000000, 600000000000, 700000000000, 800000000000, 900000000000);
    if (r == 4500000000000) { return 52; } else { return 0; }
}
AST
"$OUT/aster" build-elf "$OUT/manyi64.ast" -o "$OUT/manyi64"
rc=0
./tests/run-aarch64.sh "$OUT/manyi64" || rc=$?
test "$rc" -eq 52 || { echo "FAIL: manyi64 expected exit 52, got $rc" >&2; exit 1; }
printf '%s\n' 'PASS: i64 3-arg return (13), i64/u32 returns (51), 9-arg stack ABI (52) all correct'

printf '%s\n' '[6/8] Acceptance: narrow unsigned types (u8/u16/u32) with wrap, UDIV and unsigned cmp (qemu)'
cat > "$OUT/u8test.ast" <<'AST'
fn main() -> i32 {
    let a: u8 = 200; let b: u8 = 55;
    let s: u8 = a + b;
    let ov: u8 = a + b + 1;
    let x: u8 = 250; let y: u8 = 5;
    let q: u8 = x / 10;
    if (s == 255) {
        if (ov == 0) {
            if (x > y) {
                if (q == 25) { return 21; } else { return 0; }
            } else { return 0; }
        } else { return 0; }
    } else { return 0; }
}
AST
"$OUT/aster" build-elf "$OUT/u8test.ast" -o "$OUT/u8test"
rc=0
./tests/run-aarch64.sh "$OUT/u8test" || rc=$?
test "$rc" -eq 21 || { echo "FAIL: u8test expected exit 21, got $rc" >&2; exit 1; }

cat > "$OUT/u16test.ast" <<'AST'
fn main() -> i32 {
    let a: u16 = 60000; let b: u16 = 5000;
    let s: u16 = a + b;
    let ov: u16 = a + b + 1;
    let x: u16 = 65000; let y: u16 = 100;
    let q: u16 = x / 100;
    if (s == 65000) {
        if (ov == 65001) {
            if (x > y) {
                if (q == 650) { return 22; } else { return 0; }
            } else { return 0; }
        } else { return 0; }
    } else { return 0; }
}
AST
"$OUT/aster" build-elf "$OUT/u16test.ast" -o "$OUT/u16test"
rc=0
./tests/run-aarch64.sh "$OUT/u16test" || rc=$?
test "$rc" -eq 22 || { echo "FAIL: u16test expected exit 22, got $rc" >&2; exit 1; }

cat > "$OUT/u32test.ast" <<'AST'
fn main() -> i32 {
    let big: u32 = 4000000000;
    let small: u32 = 1000000000;
    let q: u32 = big / small;
    let diff: u32 = big - small;
    if (big > small) {
        if (q == 4) {
            if (diff == 3000000000) { return 33; } else { return 0; }
        } else { return 0; }
    } else { return 0; }
}
AST
"$OUT/aster" build-elf "$OUT/u32test.ast" -o "$OUT/u32test"
rc=0
./tests/run-aarch64.sh "$OUT/u32test" || rc=$?
test "$rc" -eq 33 || { echo "FAIL: u32test expected exit 33, got $rc" >&2; exit 1; }
printf '%s\n' 'PASS: u8 (21), u16 (22), u32 (33) arithmetic, wrap, unsigned compare and UDIV all correct'

printf '%s\n' '[7/8] Acceptance: wide/narrow globals and array element types (qemu)'
cat > "$OUT/gtest.ast" <<'AST'
let gi: i64 = 3000000000000;
let gu: u32 = 4000000000;
let gu8: u8 = 250;
let gu16: u16 = 65000;
fn main() -> i32 {
    if (gi == 3000000000000) {
        if (gu > 1000000000) {
            if (gu8 == 250) {
                if (gu16 == 65000) {
                    let l: i64 = gi + 1;
                    if (l == 3000000000001) { return 41; } else { return 0; }
                } else { return 0; }
            } else { return 0; }
        } else { return 0; }
    } else { return 0; }
}
AST
"$OUT/aster" build-elf "$OUT/gtest.ast" -o "$OUT/gtest"
rc=0
./tests/run-aarch64.sh "$OUT/gtest" || rc=$?
test "$rc" -eq 41 || { echo "FAIL: gtest expected exit 41, got $rc" >&2; exit 1; }

cat > "$OUT/arrtest.ast" <<'AST'
fn main() -> i32 {
    let a: i32[4] = 0;
    let b: u8[4] = 0;
    let c: i64[2] = 0;
    a[0] = 10; a[1] = 20; a[2] = 30; a[3] = 40;
    b[0] = 200; b[1] = 100;
    c[0] = 1000000000000; c[1] = 2000000000000;
    if (a[0] + a[3] == 50) {
        if (b[0] - b[1] == 100) {
            if (c[0] + c[1] == 3000000000000) { return 42; } else { return 0; }
        } else { return 0; }
    } else { return 0; }
}
AST
"$OUT/aster" build-elf "$OUT/arrtest.ast" -o "$OUT/arrtest"
rc=0
./tests/run-aarch64.sh "$OUT/arrtest" || rc=$?
test "$rc" -eq 42 || { echo "FAIL: arrtest expected exit 42, got $rc" >&2; exit 1; }
printf '%s\n' 'PASS: i64/u32/u8/u16 globals (41) and i32/u8/i64 array elements (42) all correct'

printf '%s\n' '[8/8] Regression: narrow slot-grid scaling and the incoming stack-argument width (qemu)'
# A u16 local must land in its OWN 8-byte slot. With the LDRH/STRH immediate
# left unscaled the access moved to byte slot*16, which is the next slot's
# home — the u16 in slot 1 was then overwritten by the i32 in slot 2, and both
# read back fine in isolation (which is why this needs a neighbouring i32).
cat > "$OUT/u16slot.ast" <<'AST'
fn main() -> i32 {
    let p0: i32 = 111;
    let a: u16 = 300;
    let b: i32 = 7;
    let c: i32 = 42;
    if (p0 == 111) {
        if (a == 300) {
            if (b == 7) {
                if (c == 42) { return 61; } else { return 0; }
            } else { return 0; }
        } else { return 0; }
    } else { return 0; }
}
AST
"$OUT/aster" build-elf "$OUT/u16slot.ast" -o "$OUT/u16slot"
rc=0
./tests/run-aarch64.sh "$OUT/u16slot" || rc=$?
test "$rc" -eq 61 || { echo "FAIL: u16slot expected exit 61, got $rc" >&2; exit 1; }

# The 9th argument travels in an 8-byte stack slot. Both the caller's copy into
# the outgoing area and the callee's read of it use the halfword forms, so a
# wrong scale there shows up as a wrong value rather than as a crash.
cat > "$OUT/u16arg.ast" <<'AST'
fn f9(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32, h: i32, p: u16) -> i32 {
    return p;
}
fn main() -> i32 {
    let base: i32 = f9(1, 2, 3, 4, 5, 6, 7, 8, 60000);
    let hi: i32 = f9(1, 2, 3, 4, 5, 6, 7, 8, 65535);
    if (base == 60000) {
        if (hi == 65535) { return 62; } else { return 0; }
    } else { return 0; }
}
AST
"$OUT/aster" build-elf "$OUT/u16arg.ast" -o "$OUT/u16arg"
rc=0
./tests/run-aarch64.sh "$OUT/u16arg" || rc=$?
test "$rc" -eq 62 || { echo "FAIL: u16arg expected exit 62, got $rc (u16 stack argument corrupted)" >&2; exit 1; }
printf '%s\n' 'PASS: u16 slot-grid scaling (61) and u16 stack argument (62) both correct'
