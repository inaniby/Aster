#!/bin/sh
# tests/narrow-memory-checks.sh — halfword and quadword memory access, differentially.
#
# v0.23.23-dev adds four intrinsics to the raw-memory family that began with
# load_u8/store_u8: `load_u16`/`store_u16` (LDRH/STRH) and `load_i64`/
# `store_i64` (LDR X/STR X). The byte pair made memory reachable one byte at a
# time; these are the two widths real data actually arrives in.
#
# Why i64 matters most: assembling a quadword through the byte pair meant
# eight loads, seven shifts and seven ors — and `<< 32` on an i32 is a 32-bit
# shift, so `1 << 32` is 1 (verified: the shift count wraps, the high half is
# silently lost). A comparison against the same assembled value could never
# see that. One `load_i64` is one LDR, and it cannot be wrong that way.
#
# The contracts (each pinned by a case or a rejection below):
#   load_u16(p)  -> i32   zero-extended, 0..65535      (load_u8's shape, one width up)
#   store_u16(p, v) -> i32  writes v & 0xFFFF, answers the ORIGINAL v
#   load_i64(p)  -> i64   the full 64-bit value
#   store_i64(p, v) -> i64  writes eight bytes, answers the ORIGINAL v; an i32
#                          v widens by sign-extension, exactly as storing it
#                          into an i64 local does — and bool is rejected, as no
#                          i64 slot accepts it either.
# "Answers the original v" is the byte pair's documented contract (store_u8
# returns the original i32), NOT C's assignment-expression value, so the C
# twins below separate the store from the value capture wherever the answer is
# observed. That distinction is the whole point of u16_trunc.
#
# The discipline that matters (carried over from write-output-checks.sh and
# syntax-relief-checks.sh): every behavioural case has an Aster source AND a C
# source, and the oracle is aarch64-linux-gnu-gcc -O2 -fwrapv under qemu —
# never a hand-computed expectation. A wrong expectation cannot make a case
# pass; every observable is arithmetic (a self-comparison would prove nothing).
#
# Layers: strict build; source guards pinning each intrinsic in all three
# dispatch sites (sema, callType, gen) together with its shadow guard and its
# encoding; the differential battery (widths, truncation, zero- and sign-
# extension, narrowing, loops, helpers, aliasing, and the shadow rule); the
# rejection matrix; the coverage map of regressions that must stay resident;
# and a mutation layer that puts each dispatch site's damage back and requires
# the battery to go red.

set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-narrow-memory-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# [1/7] Strictly build the Aster compiler
printf '%s\n' '[1/7] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
# [2/7] Source guards. Each of the four intrinsics must be dispatched in all
# three sites — sema's checkCall, codegen's callType (where its answer type
# lives) and codegen's gen (where the instruction is emitted) — and every
# dispatch must carry the shadow guard, because a program's own definition of
# the same name always wins (the v0.23.21-dev `write` collision). The
# encodings are pinned too: LDRH/STRH are new on the pointer-dereference path,
# and LDR X/STR X must exist there in addition to load_ptr's own.
printf '%s\n' '[2/7] Source guards: four intrinsics, three sites, encodings'
for n in load_u16 store_u16 load_i64 store_i64; do
    grep -qF "if(e.name==\"$n\"&&!functionArities.count(e.name)){" src/aster.cpp \
        || { echo "FAIL: gen no longer dispatches $n (or lost its shadow guard)" >&2; exit 1; }
    grep -qF "if(e.name==\"$n\"&&!arities.count(e.name)){" src/aster.cpp \
        || { echo "FAIL: sema no longer checks $n (or lost its shadow guard)" >&2; exit 1; }
done
grep -qF 'if((e.name=="load_i64"||e.name=="store_i64")&&!functionArities.count(e.name))return Ty::I64;' src/aster.cpp \
    || { echo 'FAIL: callType no longer answers i64 for the quadword intrinsics' >&2; exit 1; }
grep -qF 'emit(0x79400000u|(uint32_t(a)<<5)|uint32_t(a)); // LDRH Wa, [Xa]' src/aster.cpp \
    || { echo 'FAIL: the LDRH emission is missing from the intrinsic path' >&2; exit 1; }
grep -qF 'emit(0x79000000u|(uint32_t(a)<<5)|uint32_t(v)); // STRH Wv, [Xa]' src/aster.cpp \
    || { echo 'FAIL: the STRH emission is missing from the intrinsic path' >&2; exit 1; }
grep -qF 'emit(0xf9000000u|(uint32_t(a)<<5)|uint32_t(v)); // STR Xv, [Xa]' src/aster.cpp \
    || { echo 'FAIL: the STR X emission is missing from the intrinsic path' >&2; exit 1; }
# load_ptr already emits LDR X with this comment; load_i64 must add a second.
if [ "$(grep -cF '// LDR Xa, [Xa]' src/aster.cpp)" -lt 2 ]; then
    echo 'FAIL: load_i64 does not emit its own LDR X (only load_ptr has one)' >&2; exit 1
fi
# The widening call: store_i64 must generate its value in an i64 context, or
# a negative i32 is stored zero-extended. Without this exact text the
# i64_widen_neg case below would silently agree with a broken compiler.
grep -qF 'int v=gen(*e.args[1],Ty::I64);int a=gen(*e.args[0]);' src/aster.cpp \
    || { echo 'FAIL: store_i64 no longer generates its value at 64-bit width' >&2; exit 1; }
echo 'OK: guards hold — four intrinsics dispatched in three sites, encodings pinned'

# ---------------------------------------------------------------------------
# [3/7] Locate the tools: an AArch64 C compiler (the independent oracle) and
# something to run AArch64 ELFs with. The battery compares against gcc, so
# without both it SKIPs cleanly; the guards above already ran.
printf '%s\n' '[3/7] Locate an AArch64 C compiler and a runner'
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
if [ -z "$HOSTCC" ]; then
    echo "SKIP: narrow-memory coverage needs an AArch64 C compiler (none found)"
    exit 0
fi
printf 'int main(){return 0;}\n' > "$W/hostprobe.c"
if ! "$HOSTCC" -O2 -fwrapv "$W/hostprobe.c" -o "$W/hostprobe" 2>/dev/null \
   || ! readelf -h "$W/hostprobe" 2>/dev/null | grep -q 'AArch64'; then
    echo "SKIP: $HOSTCC does not emit AArch64 ELF (cross-compile toolchain missing)"
    exit 0
fi
if ! command -v qemu-aarch64 >/dev/null 2>&1 && [ "$(uname -m)" != "aarch64" ]; then
    echo "SKIP: narrow-memory coverage needs qemu-aarch64 (or an AArch64 host)"
    exit 0
fi
run(){ sh tests/run-aarch64.sh "$@"; }

# ---------------------------------------------------------------------------
# [4/7] Differential battery. Each case writes $W/<name>.ast and
# $W/<name>.c, compiles both, runs both, and compares exit statuses — the
# oracle is gcc, nobody writes a number down.
#
# The battery is width-complete:
#   u16 — round trip, truncation past 16 bits, zero-extension (i32 and i64
#         consumers), an unaligned offset, a loop, a helper;
#   i64 — round trip, the 2^32 value the old shift-and-or lost, i32 widening
#         (negative and positive), narrowing back to i32, a literal's bytes,
#         read-modify-write, a loop at 1e9 scale, a helper with a ptr param;
#   aliasing — a halfword store observed through a quadword load (endianness);
#   shadowing — each intrinsic shadowed by a user function, a same-signature
#         shadow, and a partial shadow (store shadowed, load still intrinsic).
printf '%s\n' '[4/7] Differential battery: every width, against the C oracle'
CASES="u16_round u16_trunc u16_zero_ext u16_zero_ext_i64 u16_offset u16_loop u16_helper \
i64_round i64_high32 i64_widen_neg i64_widen_pos i64_narrow_i32 i64_string i64_rmw \
i64_loop i64_helper i64_call_arith alias_mixed \
shadow_load_u16 shadow_load_i64 shadow_store_u16 shadow_store_i64 shadow_same_sig partial_shadow"

emit_case(){
    n="$1"
    case "$n" in
    u16_round)
        ast='let blob: u8[8] = 0;
fn main() -> i32 {
    let a: i32 = store_u16(blob, 0xBEEF);
    let b: i32 = load_u16(blob);
    return (a % 251) + (b % 251);
}'
        c='static unsigned char blob[8] __attribute__((aligned(8)));
int main(void){
    int a = 0xBEEF; *(unsigned short*)blob = 0xBEEF;
    unsigned short b = *(unsigned short*)blob;
    return (a%251)+(int)(b%251);
}' ;;
    u16_trunc)
        # A value wider than 16 bits keeps only its low half in memory, and
        # the store answers the ORIGINAL i32 — not the truncated half, which
        # is what C's assignment expression would yield. The twin separates
        # the store from the captured value for exactly that reason.
        ast='let blob: u8[8] = 0;
fn main() -> i32 {
    let c: i32 = store_u16(blob + 2, 0x1BEEF);
    let d: i32 = load_u16(blob + 2);
    return (c % 251) + (d % 251);
}'
        c='static unsigned char blob[8] __attribute__((aligned(8)));
int main(void){
    int c = 0x1BEEF;                        /* the store answers the original */
    *(unsigned short*)(blob+2) = 0x1BEEF;   /* the memory keeps the low half */
    unsigned short d = *(unsigned short*)(blob+2);
    return (c%251)+(int)(d%251);
}' ;;
    u16_zero_ext)
        # 0xFFFF must read back as 65535, not -1: LDRH zero-extends. A
        # sign-extending halfword load (LDRSH) would fail this case.
        ast='let blob: u8[8] = 0;
fn main() -> i32 {
    let a: i32 = store_u16(blob, 0xFFFF);
    return load_u16(blob) % 251;
}'
        c='static unsigned char blob[8] __attribute__((aligned(8)));
int main(void){
    *(unsigned short*)blob = 0xFFFF;
    unsigned short v = *(unsigned short*)blob;
    return (int)(v%251);
}' ;;
    u16_zero_ext_i64)
        # The same zero-extended halfword consumed at 64-bit width: the upper
        # half of the i64 must be zero, not a replica of bit 15.
        ast='let blob: u8[8] = 0;
fn main() -> i32 {
    let a: i32 = store_u16(blob, 0xFFFF);
    let x: i64 = load_u16(blob);
    return x % 251;
}'
        c='static unsigned char blob[8] __attribute__((aligned(8)));
int main(void){
    *(unsigned short*)blob = 0xFFFF;
    unsigned short v = *(unsigned short*)blob;
    long long x = v;
    return (int)(x%251);
}' ;;
    u16_offset)
        # An odd byte offset: pointer arithmetic is byte-granular and the
        # hardware grants unaligned halfword access, so blob+3 must work.
        # The twin uses memcpy so the oracle itself never assumes alignment.
        ast='let blob: u8[8] = 0;
fn main() -> i32 {
    let a: i32 = store_u16(blob + 3, 0xBEEF);
    let b: i32 = load_u16(blob + 3);
    return (a % 251) + (b % 251);
}'
        c='#include <string.h>
static unsigned char blob[8] __attribute__((aligned(8)));
int main(void){
    int a = 0xBEEF;
    unsigned short sv = 0xBEEF;
    memcpy(blob+3, &sv, 2);
    unsigned short dv;
    memcpy(&dv, blob+3, 2);
    return (a%251)+(int)(dv%251);
}' ;;
    u16_loop)
        ast='let blob: u8[16] = 0;
fn main() -> i32 {
    let i: i32 = 0;
    let s: i32 = 0;
    while (i < 8) {
        let r: i32 = store_u16(blob + i * 2, i * i);
        s = s + load_u16(blob + i * 2) + (r % 251);
        i = i + 1;
    }
    return s % 251;
}'
        c='static unsigned char blob[16] __attribute__((aligned(8)));
int main(void){
    int i=0, s=0;
    while(i<8){
        unsigned short sv = (unsigned short)(i*i);
        *(unsigned short*)(blob+i*2) = sv;
        unsigned short lv = *(unsigned short*)(blob+i*2);
        s = s + (int)lv + (int)(sv%251);
        i = i+1;
    }
    return s%251;
}' ;;
    u16_helper)
        ast='let blob: u8[8] = 0;
fn round(hi: i32, lo: i32) -> i32 {
    let r: i32 = store_u16(blob, (hi * 256) + lo);
    return load_u16(blob) + (r % 251);
}
fn main() -> i32 { return round(52, 18) % 251; }'
        c='static unsigned char blob[8] __attribute__((aligned(8)));
static int round(int hi, int lo){
    int r = (hi*256)+lo;
    *(unsigned short*)blob = (unsigned short)r;
    unsigned short v = *(unsigned short*)blob;
    return (int)v + (r%251);
}
int main(void){ return round(52,18)%251; }' ;;
    i64_round)
        ast='let blob: u8[16] = 0;
fn main() -> i32 {
    let a: i64 = store_i64(blob, 0x0123456789ABCDEF);
    let b: i64 = load_i64(blob);
    return (a % 251) + (b % 251);
}'
        c='static unsigned char blob[16] __attribute__((aligned(8)));
int main(void){
    long long a = 0x0123456789ABCDEFLL;
    *(long long*)blob = a;
    long long b = *(long long*)blob;
    return (int)((a%251)+(b%251));
}' ;;
    i64_high32)
        # 2^32 is the exact value the old byte-assembly lost: `hi << 32` on
        # an i32 is `hi << 0`, so the high word came back as the low word.
        # This case is that trap, pinned.
        ast='let blob: u8[16] = 0;
fn main() -> i32 {
    let a: i64 = store_i64(blob, 0x100000000);
    let b: i64 = load_i64(blob);
    return (a % 251) + (b % 251);
}'
        c='static unsigned char blob[16] __attribute__((aligned(8)));
int main(void){
    long long a = 0x100000000LL;
    *(long long*)blob = a;
    long long b = *(long long*)blob;
    return (int)((a%251)+(b%251));
}' ;;
    i64_widen_neg)
        # The sign-extension case: -1 stored through an i32 argument must
        # land as eight 0xFF bytes. Zero-extension would store
        # 0x00000000FFFFFFFF and this case would see 4294967295, not -1.
        ast='let blob: u8[16] = 0;
fn main() -> i32 {
    let neg: i32 = -1;
    let g: i64 = store_i64(blob, neg);
    let h: i64 = load_i64(blob);
    return (g % 251) + (h % 251);
}'
        c='static unsigned char blob[16] __attribute__((aligned(8)));
int main(void){
    int neg = -1;
    long long g = neg;
    *(long long*)blob = g;
    long long h = *(long long*)blob;
    return (int)((g%251)+(h%251));
}' ;;
    i64_widen_pos)
        ast='let blob: u8[16] = 0;
fn main() -> i32 {
    let pos: i32 = 2147483647;
    let g: i64 = store_i64(blob, pos);
    let h: i64 = load_i64(blob);
    return (g % 251) + (h % 251);
}'
        c='static unsigned char blob[16] __attribute__((aligned(8)));
int main(void){
    int pos = 2147483647;
    long long g = pos;
    *(long long*)blob = g;
    long long h = *(long long*)blob;
    return (int)((g%251)+(h%251));
}' ;;
    i64_narrow_i32)
        # The documented narrowing: an i64 read into an i32 local keeps the
        # low 32 bits, exactly as any i64-to-i32 conversion in the language.
        ast='let blob: u8[16] = 0;
fn main() -> i32 {
    let a: i64 = store_i64(blob, 0x0123456789ABCDEF);
    let x: i32 = load_i64(blob);
    return (a % 251) + (x % 251);
}'
        c='static unsigned char blob[16] __attribute__((aligned(8)));
int main(void){
    long long a = 0x0123456789ABCDEFLL;
    *(long long*)blob = a;
    int x = (int)*(long long*)blob;
    return (int)((a%251)+(x%251));
}' ;;
    i64_string)
        # The pointer may address .rodata: a string literal's bytes read at
        # quadword width. The twin copies the bytes so the oracle makes no
        # alignment promise about a literal.
        ast='fn main() -> i32 {
    let v: i64 = load_i64("abcdefgh");
    return v % 251;
}'
        c='#include <string.h>
int main(void){
    long long v;
    memcpy(&v, "abcdefgh", 8);
    return (int)(v%251);
}' ;;
    i64_rmw)
        ast='let blob: u8[16] = 0;
fn main() -> i32 {
    let a: i64 = store_i64(blob, 0x100000000);
    let b: i64 = store_i64(blob, load_i64(blob) + 1);
    let c: i64 = load_i64(blob);
    return (a % 251) + (b % 251) + (c % 251);
}'
        c='static unsigned char blob[16] __attribute__((aligned(8)));
int main(void){
    long long a = 0x100000000LL;
    *(long long*)blob = a;
    long long nv = *(long long*)blob + 1;
    *(long long*)blob = nv;
    long long b = nv;
    long long c = *(long long*)blob;
    return (int)((a%251)+(b%251)+(c%251));
}' ;;
    i64_loop)
        # 1e9 scale: every stored value except the first exceeds i32, so the
        # 64-bit path is exercised on every iteration, and the accumulator
        # carries an X register across the loop.
        ast='let blob: u8[32] = 0;
fn main() -> i32 {
    let i: i32 = 0;
    let s: i64 = 0;
    while (i < 4) {
        let v: i64 = i;
        let w: i64 = v * 1000000000;
        let r: i64 = store_i64(blob + i * 8, w);
        s = s + load_i64(blob + i * 8) + (r % 251);
        i = i + 1;
    }
    return s % 251;
}'
        c='static unsigned char blob[32] __attribute__((aligned(8)));
int main(void){
    int i=0; long long s=0;
    while(i<4){
        long long v = i;
        long long w = v*1000000000;
        *(long long*)(blob+i*8) = w;
        long long lv = *(long long*)(blob+i*8);
        s = s + lv + (w%251);
        i = i+1;
    }
    return (int)(s%251);
}' ;;
    i64_helper)
        ast='let blob: u8[16] = 0;
fn bump(p: ptr, x: i64) -> i64 { return store_i64(p, load_i64(p) + x); }
fn main() -> i32 {
    let a: i64 = store_i64(blob, 0x1000000000);
    let b: i64 = bump(blob, 1);
    let c: i64 = load_i64(blob);
    return (a % 251) + (b % 251) + (c % 251);
}'
        c='static unsigned char blob[16] __attribute__((aligned(8)));
static long long bump(void *p, long long x){
    long long nv = *(long long*)p + x;
    *(long long*)p = nv;
    return nv;
}
int main(void){
    long long a = 0x1000000000LL;
    *(long long*)blob = a;
    long long b = bump(blob, 1);
    long long c = *(long long*)blob;
    return (int)((a%251)+(b%251)+(c%251));
}' ;;
    i64_call_arith)
        # A call result feeding arithmetic directly, consumed at i32 width:
        # the modulo must run at 64 bits because the *operand* is i64, not
        # because a let declared an i64. This is the path callType's i64
        # answer feeds (wideOp's operand types) — without it the modulo runs
        # on the low 32 bits alone and the value is wrong.
        ast='let blob: u8[16] = 0;
fn main() -> i32 {
    let a: i64 = store_i64(blob, 0x0123456789ABCDEF);
    let m: i32 = load_i64(blob) % 251;
    let n: i32 = load_i64(blob) % 7;
    return (m + n) % 251;
}'
        c='static unsigned char blob[16] __attribute__((aligned(8)));
int main(void){
    long long a = 0x0123456789ABCDEFLL;
    *(long long*)blob = a;
    long long v = *(long long*)blob;
    int m = (int)(v%251);
    int n = (int)(v%7);
    return (m+n)%251;
}' ;;
    alias_mixed)
        # A halfword store observed through a quadword load: the little-
        # endian layout of the two bytes is what a wrong width or a wrong
        # offset would break.
        ast='let blob: u8[16] = 0;
fn main() -> i32 {
    let a: i32 = store_u16(blob + 6, 0xCAFE);
    let b: i64 = load_i64(blob);
    return (a % 251) + (b % 251);
}'
        c='#include <string.h>
static unsigned char blob[16] __attribute__((aligned(8)));
int main(void){
    int a = 0xCAFE;
    *(unsigned short*)(blob+6) = 0xCAFE;
    long long b;
    memcpy(&b, blob, 8);
    return (a%251)+(int)(b%251);
}' ;;
    shadow_load_u16)
        ast='fn load_u16(p: ptr) -> i32 { return 7; }
fn main() -> i32 { return load_u16("x") % 251; }'
        c='static int load_u16(const char *p){ (void)p; return 7; }
int main(void){ return load_u16("x")%251; }' ;;
    shadow_load_i64)
        ast='fn load_i64(p: ptr) -> i64 { return 42; }
fn main() -> i32 { let q: ptr = "xyz"; let v: i64 = load_i64(q); return v % 251; }'
        c='static long long load_i64(const char *p){ (void)p; return 42; }
int main(void){ const char *q = "xyz"; long long v = load_i64(q); return (int)(v%251); }' ;;
    shadow_store_u16)
        ast='fn store_u16(p: ptr, v: i32) -> i32 { return v + 1; }
let blob: u8[8] = 0;
fn main() -> i32 { return store_u16(blob, 41) % 251; }'
        c='static unsigned char blob[8] __attribute__((aligned(8)));
static int store_u16(void *p, int v){ (void)p; return v+1; }
int main(void){ return store_u16(blob, 41)%251; }' ;;
    shadow_store_i64)
        ast='fn store_i64(p: ptr, v: i64) -> i64 { return v + 1; }
let blob: u8[16] = 0;
fn main() -> i32 { let r: i64 = store_i64(blob, 41); return r % 251; }'
        c='static unsigned char blob[16] __attribute__((aligned(8)));
static long long store_i64(void *p, long long v){ (void)p; return v+1; }
int main(void){ long long r = store_i64(blob, 41); return (int)(r%251); }' ;;
    shadow_same_sig)
        # The signature matches the intrinsic's exactly — the user's
        # function must still win, and no memory may be touched.
        ast='fn load_i64(p: ptr) -> i64 { return 123456789; }
fn main() -> i32 { let q: ptr = "abcdefgh"; let v: i64 = load_i64(q); return v % 251; }'
        c='static long long load_i64(const char *p){ (void)p; return 123456789; }
int main(void){ const char *q = "abcdefgh"; long long v = load_i64(q); return (int)(v%251); }' ;;
    partial_shadow)
        # store_u16 is shadowed, load_u16 is not: the guard is per name, not
        # a global switch. The user's store leaves memory untouched, and the
        # intrinsic load still reads it.
        ast='fn store_u16(p: ptr, v: i32) -> i32 { return v * 2; }
let blob: u8[8] = 0;
fn main() -> i32 {
    let a: i32 = store_u16(blob, 21);
    let b: i32 = load_u16(blob);
    return (a + b) % 251;
}'
        c='#include <string.h>
static unsigned char blob[8] __attribute__((aligned(8)));
static int store_u16(void *p, int v){ (void)p; return v*2; }
static int load_u16(const void *p){ unsigned short v; memcpy(&v, p, 2); return (int)v; }
int main(void){
    int a = store_u16(blob, 21);
    int b = load_u16(blob);
    return (a+b)%251;
}' ;;
    *)
        echo "internal error: no such case '$n'" >&2
        return 1
        ;;
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
    printf 'PASS: %-18s exit %s (matches C)\n' "$n" "$a"
}

for n in $CASES; do emit_case "$n"; done
failed=0
for n in $CASES; do check_case "$n" || failed=1; done
[ "$failed" = 0 ] || exit 1

# ---------------------------------------------------------------------------
# [5/7] Rejection matrix. The argument contract of each intrinsic, with the
# diagnostic that names the offending argument. store_i64 rejects a bool
# second argument — the byte store does not, but no i64 slot accepts a bool,
# and neither does this store.
printf '%s\n' '[5/7] Rejections: the argument contracts are enforced'
reject(){ # reject <name> <source> <expected message fragment>
    printf '%s\n' "$2" > "$W/rej.ast"
    if "$OUT/aster" build-elf "$W/rej.ast" -o "$W/rej.a64" >"$W/rej.log" 2>&1; then
        echo "FAIL: $1 — was accepted" >&2; return 1
    fi
    if ! grep -q "$3" "$W/rej.log"; then
        echo "FAIL: $1 — wrong diagnostic:" >&2; cat "$W/rej.log" >&2; return 1
    fi
    printf 'PASS: rejected — %s\n' "$1"
}
reject "load_u16 on an integer" \
    'fn main() -> i32 { let x: i32 = load_u16(5); return x; }' \
    "load_u16 expects a ptr argument"
reject "load_u16 with two arguments" \
    'let blob: u8[8] = 0;
fn main() -> i32 { let x: i32 = load_u16(blob, blob); return x; }' \
    "load_u16 expects exactly one ptr argument"
reject "store_u16 on an integer destination" \
    'fn main() -> i32 { let x: i32 = store_u16(5, 7); return x; }' \
    "store_u16 first argument must be ptr"
reject "store_u16 with a string value" \
    'let blob: u8[8] = 0;
fn main() -> i32 { let x: i32 = store_u16(blob, "s"); return x; }' \
    "store_u16 second argument must be i32"
reject "load_i64 on an integer" \
    'fn main() -> i32 { let x: i64 = load_i64(5); return x % 251; }' \
    "load_i64 expects a ptr argument"
reject "store_i64 with a string value" \
    'let blob: u8[8] = 0;
fn main() -> i32 { let x: i64 = store_i64(blob, "s"); return x % 251; }' \
    "store_i64 second argument must be i64"
reject "store_i64 with a bool value" \
    'let blob: u8[8] = 0;
fn main() -> i32 { let b: bool = 1 < 2; let x: i64 = store_i64(blob, b); return x % 251; }' \
    "store_i64 second argument must be i64"
reject "store_i64 with one argument" \
    'let blob: u8[8] = 0;
fn main() -> i32 { let x: i64 = store_i64(blob); return x % 251; }' \
    "store_i64 expects (ptr, i64)"

# ---------------------------------------------------------------------------
# [6/7] Coverage map. Each named case reproduces a failure mode the feature
# actually has (or a contract a future edit could silently break): the width
# round trips, the 2^32 trap, the truncation-and-answer contract, the sign-
# extension, the zero-extension, and the per-name shadow rule. If a case is
# deleted without the map being updated, the map fails — that is the point of
# naming them.
printf '%s\n' '[6/7] Coverage map: the contract regressions stay resident'
for c in u16_round u16_trunc u16_zero_ext u16_zero_ext_i64 i64_round i64_high32 \
         i64_widen_neg i64_narrow_i32 i64_call_arith shadow_load_u16 shadow_same_sig partial_shadow; do
    case " $CASES " in
        *" $c "*) printf 'PASS: coverage map holds — %s\n' "$c" ;;
        *) echo "FAIL: coverage map lost $c (it pins a contract, not a decoration)" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# [7/7] Mutation layer. Put each site's damage back and require the battery to
# go red — a check that passes on a damaged compiler is not checking anything.
# Seven mutants: four intrinsic dispatches disabled (the case must stop
# compiling), the callType i64 answer removed (i64_rmw must disagree with the
# oracle), the store_i64 widening call reverted (i64_widen_neg must disagree),
# and the load_u16 shadow guard removed (shadow_load_u16 must disagree).
printf '%s\n' '[7/7] Mutation: the checks above must fail on a damaged compiler'
build_mutant(){ # build_mutant <tag> <sed-expr>
    m="$1"
    if ! sed "$2" src/aster.cpp > "$OUT/$m.cpp"; then
        echo "FAIL: mutation $m sed failed" >&2; exit 1
    fi
    if cmp -s src/aster.cpp "$OUT/$m.cpp"; then
        echo "FAIL: mutation $m did not change the source (the guard is stale)" >&2; exit 1
    fi
    if ! ${CXX:-c++} -std=c++17 -O0 -w "$OUT/$m.cpp" -o "$OUT/$m.aster" 2>"$OUT/$m.err"; then
        echo "FAIL: mutant $m does not build" >&2; sed -n '1,3p' "$OUT/$m.err" >&2; exit 1
    fi
}
must_not_compile(){ # must_not_compile <tag> <probe>
    if "$OUT/$1.aster" build-elf "$W/$2.ast" -o "$OUT/$1.a64" >/dev/null 2>&1; then
        echo "FAIL: under mutation $1, $2 still compiled — the battery does not test it" >&2; exit 1
    fi
    printf '  %-42s %s is a compile error again\n' "$1" "$2"
}
must_diverge(){ # must_diverge <tag> <probe> — compiles, but disagrees with gcc
    if ! "$OUT/$1.aster" build-elf "$W/$2.ast" -o "$OUT/$1.a64" >/dev/null 2>&1; then
        echo "FAIL: under mutation $1, $2 no longer compiles — unexpected" >&2; exit 1
    fi
    run "$W/$2.c64" >/dev/null 2>&1 && c=0 || c=$?
    run "$OUT/$1.a64" >/dev/null 2>&1 && a=0 || a=$?
    [ "$a" -gt 127 ] && a=$((a-256))
    [ "$c" -gt 127 ] && c=$((c-256))
    if [ "$a" = "$c" ]; then
        echo "FAIL: under mutation $1, $2 still matches the C oracle — the case does not test it" >&2; exit 1
    fi
    printf '  %-42s %s now disagrees with the C oracle\n' "$1" "$2"
}

build_mutant m1 's/if(e.name=="load_u16"&&!functionArities.count(e.name)){/if(false){/'
must_not_compile m1 u16_round
build_mutant m2 's/if(e.name=="load_i64"&&!functionArities.count(e.name)){/if(false){/'
must_not_compile m2 i64_round
build_mutant m3 's/if(e.name=="store_u16"&&!functionArities.count(e.name)){/if(false){/'
must_not_compile m3 u16_trunc
build_mutant m4 's/if(e.name=="store_i64"&&!functionArities.count(e.name)){/if(false){/'
must_not_compile m4 i64_widen_neg
# m5: callType stops answering I64 for the quadword intrinsics, so the
# arithmetic that consumes a load_i64 result loses its i64 operand width.
# The first draft expected a run-time divergence (must_diverge), but
# v0.23.53-dev's gen-entry guard compares the annotated type against
# exprType on every node — Sema still answers i64, codegen's callType now
# answers i32, and the guard aborts the compile with TypedIR MISMATCH
# (measured: kind=3 type=i64 exprType=i32). The damage is still caught, one
# layer earlier and louder, so the expectation is the compile-time abort. If
# the guard is ever removed, this row fails and the mutation must be
# re-pointed at an emission-site width instead — which is exactly the
# discipline the mutation layer exists to enforce.
build_mutant m5 's/if((e.name=="load_i64"||e.name=="store_i64")&&!functionArities.count(e.name))return Ty::I64;//'
must_not_compile m5 i64_call_arith
build_mutant m6 's/int v=gen(\*e.args\[1\],Ty::I64);int a=gen(\*e.args\[0\]);/int v=gen(*e.args[1]);int a=gen(*e.args[0]);/'
must_diverge m6 i64_widen_neg
build_mutant m7 's/if(e.name=="load_u16"&&!functionArities.count(e.name)){/if(e.name=="load_u16"){/'
must_diverge m7 shadow_load_u16

printf '%s\n' 'ALL NARROW-MEMORY CHECKS PASSED'
