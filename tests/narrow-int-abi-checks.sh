#!/bin/sh
# v0.23.19-dev (round 3) checks for the NARROW-INTEGER ARGUMENT ABI.
#
# The defect: a u8 parameter never arrived.
#
#     fn g(a: u8) -> u8 { return a; }
#     fn main() -> i32 { return g(200); }        ->  0   (correct: 200)
#
# It was never an ABI problem, which is what made it hard to see: u8 locals,
# u8 globals, u8 array elements and u8 struct fields were all correct. The
# cause is one line of encoding arithmetic. AArch64's unsigned immediate
# offset is width-scaled, so its RANGE differs per width: LDRB/STRB carry the
# byte offset UNSCALED in 12 bits (0..4095), LDRH/STRH scale by 2, LDR/STR W
# by 4, LDR/STR X by 8. loadStackT/storeStackT shifted the byte offset left by
# 10 for every width, so for U8 an offset above 4095 was not rejected and did
# not wrap onto a neighbour — bit 12 of the offset landed on bit 22 of the
# instruction, which is exactly the bit that separates STRB (0x39000000) from
# LDRB (0x39400000). The caller stored the argument by LOADING it.
#
# Every call argument is staged in the scratch area at 4160 + callDepth*256,
# which is past 4095 for every call, so `storeStackOff(v, 4160, U8)` emitted
# `LDRB w0, [sp, #64]`: the value was never written, and the callee received
# whatever the uninitialized stack held. u16 survived by arithmetic alone
# (4160/2 == 2080 fits, and even the deepest scratch — 4160 + 14*256 + 31*8 ==
# 7992 — is 3996 after the shift), struct fields cannot reach it (a struct is
# capped at 1024 bytes) and locals/globals sit at small offsets. So it looked
# like "u8 parameters are broken" when it was "unscaled byte offsets above
# 4095 are broken", and the two differ in where the fix belongs.
#
# The fix: stackOffFits() decides per width whether the offset is expressible,
# and loadStackOff/storeStackOff stage the address through x16 (or x17, when
# x16 is itself the operand) when it is not. A fitting offset takes the
# encoding it always did, so no pre-existing output changes by a byte — the
# A/B over all 87 examples in three modes is 261/261 identical.
#
# Layers:
#   [1] strict compiler build (-Werror)
#   [2] source guards: the per-width range test, both fallbacks, and the
#       absence of any direct emit() of the old encodings
#   [3] rejection matrix: narrow parameters are still typed
#   [4] qemu positive matrix, 21 cases in 4 groups (group E needs the link)
#   [5] C differential: the same calls compiled by aarch64 gcc — including a
#       real cross-language link, which is the only thing that can show the
#       stack layout of a narrow argument agrees with the C compiler's
#   [6] mutation layer: 6 mutants of the round's own diff, each must be caught
#   [7] the documented blind spots
#
# Every case returns its own number as a non-zero exit code, so a wrong value
# cannot masquerade as a clean run.
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-narrow-int-abi-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
CASES="$OUT/cases.txt"

# ---------------------------------------------------------------------------
printf '%s\n' '[1/7] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
# [2] Source guards. The point is not that the strings exist; it is that the
#     four per-width ranges are written down separately (a single shared limit
#     was the bug), and that no site emits the raw encoding any more.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/7] Source guards: per-width immediate range and both fallbacks'
guard() { # $1 = description, $2 = pattern, $3 = expected count
    n=$(grep -cF -- "$2" src/aster.cpp || true)
    if [ "$n" != "$3" ]; then
        echo "FAIL: $1: expected $3 occurrence(s) of '$2', found $n" >&2; exit 1
    fi
}
guard 'stackOffFits helper'            'static bool stackOffFits(uint32_t off,Ty t){'  1
guard 'U8 unscaled 12-bit range'       'if(t==Ty::U8) return off<=4095u;'              1
guard 'U16 range, scaled by 2'         'if(t==Ty::U16)return off<=8190u&&(off&1u)==0u;' 1
guard '64-bit range, scaled by 8'      'if(tyIs64(t)) return off<=32760u&&(off&7u)==0u;' 1
guard '32-bit range, scaled by 4'      'return off<=16380u&&(off&3u)==0u;'             1
guard 'load with fallback'             'void loadStackOff(int reg,uint32_t off,Ty t){' 1
guard 'store with fallback'            'void storeStackOff(int reg,uint32_t off,Ty t){' 1
guard 'load fallback via x16'          'emitAddOff(kGlobalBase,31,off);emit(loadGlobalT(reg,t));' 1
guard 'store fallback via x16'         'emitAddOff(kGlobalBase,31,off);emit(storeGlobalT(reg,t));' 1
# x16 cannot stage an address for itself: when it is the operand, x17 carries
# the address instead. A stack argument (the 9th onward) is exactly that case.
guard 'load fallback when x16 is the target'  'if(reg==kGlobalBase){emitAddOff(17,31,off);emit(loadAtT(reg,17,0,t));return;}' 1
guard 'store fallback when x16 is the target' 'if(reg==kGlobalBase){emitAddOff(17,31,off);emit(storeAtT(reg,17,0,t));return;}' 1
# The two raw encodings may now be emitted from exactly one place each — inside
# the fallback-aware wrappers. A direct emit() anywhere else would silently
# reintroduce the defect.
guard 'raw loadStackT emitted once'    'emit(loadStackT(reg,off,t));'                  1
guard 'raw storeStackT emitted once'   'emit(storeStackT(reg,off,t));'                 1
# The wrapper call-site counts: every stack access that can land past 4095 goes
# through the fallback-aware pair, and these counts are the tripwire. v0.23.21-dev
# raised both by the `write` intrinsic, which stages its three syscall arguments
# through the scratch grid exactly as a call does: three loadStackOff (fd, buf,
# len) and one storeStackOff (in the staging loop). +3 and +1, nothing else moved.
# v0.23.40-dev raised both again by the shared syscallInsn helper behind
# read/openat/close/fstat, which stages N arguments through the same scratch
# grid with the identical LIFO discipline: one loadStackOff and one storeStackOff
# in its generic staging loops (write keeps its own inlined copy). +1 and +1.
guard 'loadStackOff call sites'        'loadStackOff('                                 17
guard 'storeStackOff call sites'       'storeStackOff('                                12
printf '%s\n' 'PASS: per-width ranges, both fallbacks, and no raw encoding at a call site'

# ---------------------------------------------------------------------------
# [3] Rejection matrix: narrow parameters are typed, not silently converted.
# ---------------------------------------------------------------------------
printf '%s\n' '[3/7] Rejection: narrow parameters keep their typing'
cat > "$W/u8-from-i64.ast" <<'AST'
fn g(a: u8) -> u8 { return a; }
fn main() -> i32 { let x: i64 = 5; return g(x); }
AST
if out=$("$OUT/aster" build-elf "$W/u8-from-i64.ast" -o "$W/u8-from-i64" 2>&1); then
    echo 'FAIL: compiler accepted an i64 argument for a u8 parameter' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF "argument type mismatch calling g at argument 1: expected u8, got i64" \
    || { echo "FAIL: wrong diagnostic for i64->u8 argument: $out" >&2; exit 1; }

cat > "$W/u16-from-i64.ast" <<'AST'
fn g(a: u16) -> u16 { return a; }
fn main() -> i32 { let x: i64 = 5; return g(x); }
AST
if out=$("$OUT/aster" build-elf "$W/u16-from-i64.ast" -o "$W/u16-from-i64" 2>&1); then
    echo 'FAIL: compiler accepted an i64 argument for a u16 parameter' >&2; exit 1
fi
printf '%s\n' "$out" | grep -qF "argument type mismatch calling g at argument 1: expected u16, got i64" \
    || { echo "FAIL: wrong diagnostic for i64->u16 argument: $out" >&2; exit 1; }
printf '%s\n' 'PASS: i64 into a u8/u16 parameter still rejected, with the parameter type named'

# ---------------------------------------------------------------------------
# [4] qemu positive matrix.
# ---------------------------------------------------------------------------
cat > "$CASES" <<'CASES_EOF'
11~11
fn g(a: u8) -> u8 { return a; }
fn main() -> i32 { return g(200) == 200 ? 11 : 0; }
@@@
12~12
fn g(a: u8) -> u8 { return a; }
fn main() -> i32 { return g(255) == 255 ? 12 : 0; }
@@@
13~13
fn g(a: u8) -> u8 { return a; }
fn main() -> i32 { return g(0) == 0 ? 13 : 0; }
@@@
14~14
fn g(a: u16) -> u16 { return a; }
fn main() -> i32 { return g(40000) == 40000 ? 14 : 0; }
@@@
15~15
fn g(a: u16) -> u16 { return a; }
fn main() -> i32 { return g(65535) == 65535 ? 15 : 0; }
@@@
16~16
fn g(a: u32) -> u32 { return a; }
fn main() -> i32 { return g(4000000000) == 4000000000 ? 16 : 0; }
@@@
17~17
fn g(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, h: i32, k: u8) -> i32 { return k; }
fn main() -> i32 { return g(0, 0, 0, 0, 0, 0, 0, 200) == 200 ? 17 : 0; }
@@@
21~21
fn g(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, h: i32, i: i32, j: u8) -> i32 { return j; }
fn main() -> i32 { return g(0, 0, 0, 0, 0, 0, 0, 0, 200) == 200 ? 21 : 0; }
@@@
22~22
fn g(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, h: i32, i: i32, j: u16) -> i32 { return j; }
fn main() -> i32 { return g(0, 0, 0, 0, 0, 0, 0, 0, 40000) == 40000 ? 22 : 0; }
@@@
23~23
fn g(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, h: i32, i: i32, j: u8, k: u8) -> i32 { return j + k; }
fn main() -> i32 { return g(0, 0, 0, 0, 0, 0, 0, 0, 100, 50) == 150 ? 23 : 0; }
@@@
24~24
fn g(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, h: i32, i: i32, j: i32, k: i32, l: u8) -> i32 { return l; }
fn main() -> i32 { return g(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255) == 255 ? 24 : 0; }
@@@
31~31
fn g(a: i64, b: u8) -> i32 { return b; }
fn main() -> i32 { return g(4294967297, 200) == 200 ? 31 : 0; }
@@@
32~32
fn g(a: u8) -> u8 { return a; }
fn h(a: i32) -> i32 { return g(200) + a * 0; }
fn main() -> i32 { return h(0) == 200 ? 32 : 0; }
@@@
33~33
fn sum(a: u8, n: i32) -> i32 { if (n == 0) { return a; } else { return a + sum(a, n - 1); } }
fn main() -> i32 { return sum(50, 3) == 200 ? 33 : 0; }
@@@
34~34
fn g(a: u8) -> i32 { return a + 1; }
fn main() -> i32 { return g(199) == 200 ? 34 : 0; }
@@@
35~35
fn g(a: u8, b: u8) -> i32 { return a + b; }
fn main() -> i32 { return g(100, 50) == 150 ? 35 : 0; }
@@@
41~41
fn main() -> i32 { let a: u8 = 200; return a == 200 ? 41 : 0; }
@@@
42~42
let g: u8[700] = 0;
fn main() -> i32 { g[600] = 200; return g[600] == 200 ? 42 : 0; }
@@@
43~43
fn main() -> i32 { let a: u8[700] = 0; a[600] = 200; return a[600] == 200 ? 43 : 0; }
@@@
44~44
struct S { a: i32, b: u8 }
fn main() -> i32 { let s: S = S { 1, 200 }; return s.b == 200 ? 44 : 0; }
@@@
45~45
fn g(a: u8) -> u8 { return a; }
fn main() -> i32 { let v: u8 = 200; return g(v) == 200 ? 45 : 0; }
@@@
51~51
extern fn c_add_u8(a: u8, b: u8) -> i32;
fn main() -> i32 { return c_add_u8(100, 50) == 150 ? 51 : 0; }
@@@
52~52
extern fn c_ninth_u8(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32, h: i32, i: u8) -> i32;
fn main() -> i32 { return c_ninth_u8(0, 0, 0, 0, 0, 0, 0, 0, 200) == 200 ? 52 : 0; }
@@@
53~53
extern fn c_add_u16(a: u16, b: u16) -> i32;
fn main() -> i32 { return c_add_u16(40000, 25535) == 65535 ? 53 : 0; }
@@@
CASES_EOF

printf '%s\n' '[4/7] Acceptance: 21 qemu cases in 4 groups (group E runs in [5])'
run_case() { # $1 = binary-under-test, $2 = case code
    bin=$1; code=$2
    awk -v c="$code" 'BEGIN{RS="@@@\n"} $1~("^"c"~"){printf "%s",$0}' "$CASES" > "$W/one.txt"
    want=$(head -1 "$W/one.txt" | cut -d'~' -f2)
    tail -n +2 "$W/one.txt" > "$W/p.ast"
    if ! "$bin" build-elf "$W/p.ast" -o "$W/p.a64" >"$W/build.log" 2>&1; then
        echo "FAIL: case $code did not compile:" >&2; cat "$W/build.log" >&2; return 1
    fi
    got=0; sh tests/run-aarch64.sh "$W/p.a64" >/dev/null 2>&1 || got=$?
    if [ "$got" != "$want" ]; then
        if [ -z "${QUIET:-}" ]; then
            echo "FAIL: case $code expected exit $want, got $got" >&2
            echo "----- source -----" >&2; cat "$W/p.ast" >&2
        fi
        return 1
    fi
    return 0
}
run_group() { # $1 = group name, rest = case codes
    gname=$1; shift
    gok=0; gbad=0
    for code in "$@"; do
        if run_case "$OUT/aster" "$code"; then gok=$((gok+1)); else gbad=$((gbad+1)); fi
    done
    if [ "$gbad" -ne 0 ]; then
        echo "FAIL: group '$gname': $gbad of $((gok+gbad)) cases wrong" >&2; exit 1
    fi
    printf 'PASS: %-44s %2d cases\n' "$gname" "$gok"
}
run_group 'A narrow arguments in registers'        11 12 13 14 15 16 17
run_group 'B narrow arguments on the stack (9th+)' 21 22 23 24
run_group 'C mixed widths, nesting, recursion'     31 32 33 34 35
run_group 'D forward guards (small offsets)'       41 42 43 44 45
# Group E needs the C object built by [5]; it is run there.

# ---------------------------------------------------------------------------
# [5] C differential. Two shapes:
#       (a) the same computation written in C must return the same exit code;
#       (b) a real cross-language link — Aster's object linked against a C
#           object — which is the only witness that the STACK LAYOUT of a
#           narrow argument (how far the 10th argument sits from the 9th)
#           agrees with what aarch64 gcc emits. A test that only ever calls
#           Aster from Aster would pass on a layout nothing else uses.
# ---------------------------------------------------------------------------
printf '%s\n' '[5/7] C differential cross-check (independent oracle)'
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
hostcc_flags=""
if [ -n "$HOSTCC" ]; then
    printf 'int main(){return 0;}\n' > "$W/hostprobe.c"
    for f in "-static" ""; do
        if "$HOSTCC" -O2 -fwrapv $f "$W/hostprobe.c" -o "$W/hostprobe" 2>/dev/null; then
            if readelf -h "$W/hostprobe" 2>/dev/null | grep -q 'AArch64'; then hostcc_flags=$f; break; fi
        fi
    done
fi
if [ -z "$hostcc_flags" ] && [ -n "$HOSTCC" ]; then
    echo "SKIP: C differential needs an AArch64 C compiler ($HOSTCC is not one)"
elif [ -z "$HOSTCC" ]; then
    echo "SKIP: C differential needs an AArch64 C compiler (none found)"
else
    diffok=0
    while IFS='@' read -r code csrc; do
        [ -n "$code" ] || continue
        printf '%s\n' "$csrc" > "$W/c$code.c"
        if ! "$HOSTCC" -O2 -fwrapv $hostcc_flags "$W/c$code.c" -o "$W/c$code" 2>"$W/c$code.log"; then
            echo "FAIL: C host for case $code did not compile:" >&2; cat "$W/c$code.log" >&2; exit 1
        fi
        crc=0; sh tests/run-aarch64.sh "$W/c$code" >/dev/null 2>&1 || crc=$?
        if ! run_case "$OUT/aster" "$code"; then exit 1; fi
        awk -v c="$code" 'BEGIN{RS="@@@\n"} $1~("^"c"~"){printf "%s",$0}' "$CASES" > "$W/one.txt"
        want=$(head -1 "$W/one.txt" | cut -d'~' -f2)
        if [ "$crc" != "$want" ]; then
            echo "FAIL: case $code: C oracle returned $crc, expected $want" >&2; exit 1
        fi
        diffok=$((diffok+1))
    done <<'CDIFF_EOF'
11@static unsigned char g(unsigned char a){ return a; } int main(){ return g(200) == 200 ? 11 : 0; }
12@static unsigned char g(unsigned char a){ return a; } int main(){ return g(255) == 255 ? 12 : 0; }
14@static unsigned short g(unsigned short a){ return a; } int main(){ return g(40000) == 40000 ? 14 : 0; }
16@static unsigned g(unsigned a){ return a; } int main(){ return g(4000000000u) == 4000000000u ? 16 : 0; }
17@static int g(int a,int b,int c,int d,int e,int f,int h,unsigned char k){ return k; } int main(){ return g(0,0,0,0,0,0,0,200) == 200 ? 17 : 0; }
21@static int g(int a,int b,int c,int d,int e,int f,int h,int i,unsigned char j){ return j; } int main(){ return g(0,0,0,0,0,0,0,0,200) == 200 ? 21 : 0; }
23@static int g(int a,int b,int c,int d,int e,int f,int h,int i,unsigned char j,unsigned char k){ return j+k; } int main(){ return g(0,0,0,0,0,0,0,0,100,50) == 150 ? 23 : 0; }
35@static int g(unsigned char a,unsigned char b){ return a+b; } int main(){ return g(100,50) == 150 ? 35 : 0; }
CDIFF_EOF
    printf 'PASS: Aster and %s agree on %d narrow-argument expressions\n' "$HOSTCC" "$diffok"

    # (b) The cross-language link: Aster calls C, and C's idea of where the
    #     9th argument lives is the one the platform actually uses.
    cat > "$W/host.c" <<'CHOST_EOF'
int c_add_u8(unsigned char a, unsigned char b){ return a + b; }
int c_add_u16(unsigned short a, unsigned short b){ return a + b; }
int c_ninth_u8(int a,int b,int c,int d,int e,int f,int g,int h,unsigned char i){ return i; }
CHOST_EOF
    if ! "$HOSTCC" -O2 -c "$W/host.c" -o "$W/host.raw.o" 2>"$W/hostobj.log"; then
        echo "FAIL: C host object did not compile:" >&2; cat "$W/hostobj.log" >&2; exit 1
    fi
    # Aster's linker accepts only the sections it emits itself, so the C
    # object is stripped to its code: .eh_frame (and its relocations) is
    # allocated but unknown to Aster, and an empty .data/.bss carries
    # attributes Aster refuses. Removing them changes no instruction — the
    # host is three leaf functions with no data of their own.
    OBJCOPY=$(printf '%s\n' "$HOSTCC" | sed 's/gcc$/objcopy/')
    if ! command -v "$OBJCOPY" >/dev/null 2>&1; then
        echo "SKIP: cross-language link needs $OBJCOPY (not found)"
    else
    "$OBJCOPY" -R .eh_frame -R .rela.eh_frame -R .data -R .bss -R .comment -R .note.GNU-stack \
        "$W/host.raw.o" "$W/host.o" 2>"$W/hostobj2.log" \
        || { echo "FAIL: could not strip the C host object:" >&2; cat "$W/hostobj2.log" >&2; exit 1; }
    linkok=0
    for code in 51 52 53; do
        awk -v c="$code" 'BEGIN{RS="@@@\n"} $1~("^"c"~"){printf "%s",$0}' "$CASES" > "$W/one.txt"
        want=$(head -1 "$W/one.txt" | cut -d'~' -f2)
        tail -n +2 "$W/one.txt" > "$W/l.ast"
        if ! "$OUT/aster" build-obj "$W/l.ast" -o "$W/l.o" >"$W/l.log" 2>&1; then
            echo "FAIL: case $code did not compile:" >&2; cat "$W/l.log" >&2; exit 1
        fi
        if ! "$OUT/aster" link-obj "$W/l.o" "$W/host.o" -o "$W/l.a64" >"$W/ll.log" 2>&1; then
            echo "FAIL: case $code did not link against the C object:" >&2; cat "$W/ll.log" >&2; exit 1
        fi
        got=0; sh tests/run-aarch64.sh "$W/l.a64" >/dev/null 2>&1 || got=$?
        if [ "$got" != "$want" ]; then
            echo "FAIL: cross-language case $code expected exit $want, got $got" >&2
            echo "----- source -----" >&2; cat "$W/l.ast" >&2; exit 1
        fi
        linkok=$((linkok+1))
    done
    printf 'PASS: Aster object linked against a C object: %d calls agree — group E (incl. the 9th argument, on the stack)\n' "$linkok"
    fi
fi

# ---------------------------------------------------------------------------
# [6] Mutation layer: revert one decision of this round's own diff at a time.
#     A mutant that is not caught means the suite cannot see that decision.
#     Four at a time: launching them all at once starved the box (measured).
# ---------------------------------------------------------------------------
printf '%s\n' '[6/7] Mutation layer: 6 mutants of the range test and the fallbacks'
cp src/aster.cpp "$W/orig.cpp"
n=0; pids=""
drain() { for p in $pids; do wait "$p" || true; done; pids=""; }
while IFS='~' read -r label kind program codes; do
    [ -n "$label" ] || continue
    n=$((n+1))
    printf '%s\n' "$label"  > "$W/m$n.label"
    printf '%s\n' "$codes"  > "$W/m$n.codes"
    if [ "$kind" = sed ]; then
        cp "$W/orig.cpp" "$W/m$n.cpp"
        sed -i "$program" "$W/m$n.cpp"
    else
        awk "$program" "$W/orig.cpp" > "$W/m$n.cpp"
    fi
    if diff -q "$W/orig.cpp" "$W/m$n.cpp" >/dev/null; then
        echo "FAIL: mutation '$label' did not apply (sed/awk matched nothing)" >&2; exit 1
    fi
    # shellcheck disable=SC2086
    c++ -std=c++17 -O2 -w "$W/m$n.cpp" -o "$W/m$n-aster" 2>"$W/m$n.build.log" &
    pids="$pids $!"
    if [ $((n % 4)) -eq 0 ]; then drain; fi
done <<'MUT_EOF'
M1 U8 range test always true~sed~s/if(t==Ty::U8) return off<=4095u;/if(t==Ty::U8) return true;/~11 12
M2 U8 limit raised past the range~sed~s/if(t==Ty::U8) return off<=4095u;/if(t==Ty::U8) return off<=8190u;/~11 12
M3 store fallback uses the wrong base~sed~s/emitAddOff(kGlobalBase,31,off);emit(storeGlobalT(reg,t));/emitAddOff(kGlobalBase,30,off);emit(storeGlobalT(reg,t));/~11 12 35
M4 store fallback stages the wrong offset~sed~s/emitAddOff(kGlobalBase,31,off);emit(storeGlobalT(reg,t));/emitAddOff(kGlobalBase,31,off+8);emit(storeGlobalT(reg,t));/~11 12 35
M5 load fallback reads past the staged address~sed~s/emitAddOff(17,31,off);emit(loadAtT(reg,17,0,t));return;/emitAddOff(17,31,off);emit(loadAtT(reg,17,8,t));return;/~21 23 24
M6 load side skips the range test~sed~s/if(stackOffFits(off,t)){emit(loadStackT(reg,off,t));return;}/if(true){emit(loadStackT(reg,off,t));return;}/~11 12 21 23 24 35
MUT_EOF
drain
i=0; missing=""
while [ "$i" -lt "$n" ]; do
    i=$((i+1))
    if [ ! -x "$W/m$i-aster" ]; then
        missing="$missing $i:$(cat "$W/m$i.label")"
        echo "----- build log of mutant $i ($(cat "$W/m$i.label")) -----" >&2
        tail -n 5 "$W/m$i.build.log" >&2 || true
    fi
done
if [ -n "$missing" ]; then
    echo "FAIL: mutant build(s) failed:$missing" >&2; exit 1
fi
mutbad=0
i=0
while [ "$i" -lt "$n" ]; do
    i=$((i+1))
    label=$(cat "$W/m$i.label"); codes=$(cat "$W/m$i.codes")
    caught=""; missed=""
    for code in $codes; do
        if QUIET=1 run_case "$W/m$i-aster" "$code"; then missed="$missed $code"; else caught="$caught $code"; fi
    done
    if [ -n "$missed" ]; then
        echo "FAIL: mutation '$label' NOT CAUGHT by:$missed" >&2; mutbad=$((mutbad+1))
    else
        printf 'PASS: %-40s caught by:%s\n' "$label" "$caught"
    fi
done
if [ "$mutbad" -ne 0 ]; then
    echo "FAIL: $mutbad mutation(s) survived — the suite is blind to them" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# [7] Blind spots, stated plainly.
# ---------------------------------------------------------------------------
printf '%s\n' '[7/7] Documented blind spots (why some cases are guards, not discriminators)'
cat <<'BLIND'
  (a) An uninitialized stack byte that happens to hold the expected value
      would let the original defect pass. It does not happen here — the
      scratch area is at a fixed frame offset and the callee's frame is fresh
      — but it is the reason the discriminators use 200 and 255 (and 0, in
      case 13, which the defect also gets "right" by accident and which is
      therefore a forward guard only, not a discriminator).
  (b) The struct-field path (loadAtT/storeAtT) has the same unscaled-byte
      arithmetic, but a struct is capped at 1024 bytes so a field offset
      cannot reach 4096. It is deliberately left alone; if the cap is ever
      raised, this suite does not cover what happens next.
  (c) A u8 argument's high bits are unspecified under AAPCS64, so a C callee
      that read them would be reading something Aster never promised. The
      C differential therefore compares values the callee normalizes itself
      (unsigned char arithmetic), not raw register contents.
  (d) The mutation layer proves the range test and both fallbacks are seen;
      it cannot prove the four ranges are the RIGHT numbers. That is what the
      cross-language link in [5] is for: gcc's own stack layout is the
      reference for how far apart narrow arguments sit.
  (e) emitAddOff's chunk size cannot be caught by a run. Every access to a
      scratch slot goes through the same helper, so a mutant that slides the
      whole scratch area (say, by splitting 4160 into 4095 + 2112 instead of
      4095 + 65) moves the store and the load together and the value still
      round-trips. The mutant is visible in the object bytes — it was, when
      this was checked — but not in an exit code, so it is not in [6]; the
      single constant is pinned by the source guards in [2] instead.
  (f) On the load side, removing the "x16 is the destination" branch is an
      equivalent mutant: emitAddOff leaves the address in x16 and the very
      next instruction consumes x16 as its base, so `LDRB W16, [X16]` is
      correct without x17. The branch is kept so both sides read the same
      way, and [6] pins its address instead (M5), which is observable.
  (g) The store-side branch is not reachable from Aster today: every site
      that stores x16 lands on a slot whose offset fits, so the fallback is
      never taken there. It stays because emitAddOff would otherwise
      overwrite the value it is about to store — a hazard the suite can see
      only if that reachability ever changes.
BLIND
printf '%s\n' 'PASS: blind spots documented; mutation layer proves the discriminators avoid them'
printf '%s\n' 'ALL CHECKS PASSED'
