#!/bin/sh
# v0.23.20-dev (round 4, segment B) — a focused adversarial audit of the
# compiler's "other faces": the dimensions round 4's narrow-value work did NOT
# touch, checked the same way the narrow-value suite checks its own: every case
# has an Aster source AND an equivalent C source, the C source is the oracle,
# both are built and run under qemu, and the two 8-bit exit codes must match.
# No expected number is written by hand.
#
# Why this exists.  Round 4's headline fix closed the NARROW-VALUE path
# (u8/u16/i64 arguments, returns, struct fields, arrays) with gcc-differential
# coverage.  But "the other faces" — bool, rodata/string layout, global init
# order, struct fields, and multi-file link signature consistency — were only
# *claimed* clean by the round-4 diagnosis.  This audit turns that claim into a
# checked-in asset by probing the residual edges each face still had:
#
#   * string rodata, read byte-by-byte from INSIDE a user function (every
#     existing string test either loads byte 0 in main or hands the literal to
#     an external C strlen/memcmp — none indexes a string pointer passed to an
#     Aster-defined function);
#   * two distinct rodata literals addressed independently by offset (proves the
#     literals do not collide and both bases are correct);
#   * a narrow u8 ARGUMENT carried across an Aster<->Aster link-obj boundary
#     (segment A proved the narrow-argument ABI only against gcc via a .so; the
#     pure-Aster multi-file path — the thing the linker actually stitches
#     together for real programs — was never exercised with a narrow parameter).
#
# faces that are deliberately NOT re-probed here, because a dedicated,
# already-resident suite covers them (this audit's [4/4] asserts those suites
# still exist, so the coverage map cannot silently rot):
#   bool            -> tests/bool-checks.sh (type-strict; bool<->i32 conversion
#                     is rejected, so the narrow-arg class cannot arise)
#   rodata layout   -> tests/c-string-literals-structural.sh + e2e-c-string-literals.sh
#                     (strlen/memcmp across the C boundary, embedded NUL, escapes)
#   global init     -> tests/global-deep-checks.sh + runtime_init_order_* (single
#                     and CROSS-file runtime initialization)
#   struct fields   -> tests/narrow-value-coverage.sh [3/4] u8_struct_field
#                     (struct { i32, u8 } laid out and read, gcc-differential)
#   link signatures -> tests/linker-checks.sh (i32/ptr across link-obj) +
#                     c_struct_abi (struct across the C boundary)
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-other-faces-audit}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
printf '%s\n' '[1/4] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
printf '%s\n' '[2/4] Locate an AArch64 C compiler (the independent oracle)'
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
if [ -z "$HOSTCC" ]; then
    echo "SKIP: other-faces audit needs an AArch64 C compiler (none found)"
    exit 0
fi
printf 'int main(){return 0;}\n' > "$W/hostprobe.c"
if ! "$HOSTCC" -O2 -fwrapv "$W/hostprobe.c" -o "$W/hostprobe" 2>/dev/null \
   || ! readelf -h "$W/hostprobe" 2>/dev/null | grep -q 'AArch64'; then
    echo "SKIP: $HOSTCC does not emit AArch64 ELF (cross-compile toolchain missing)"
    exit 0
fi

# ---------------------------------------------------------------------------
printf '%s\n' '[3/4] Differential battery: Aster vs gcc on the residual edges'
cat > "$W/cases.txt" <<'CASES_EOF'
1~string_byte_index_across_call
fn at(s: ptr, i: i32) -> i32 { return load_u8(s + i); }
fn main() -> i32 { return at("ABC", 1); }
@C@
int at(const char* s, int i){ return (unsigned char)s[i]; }
int main(void){ return at("ABC", 1); }
@@@
2~two_string_literals_offset
fn main() -> i32 { let a: ptr = "XY"; let b: ptr = "ZW"; return load_u8(a + 0) + load_u8(b + 1); }
@C@
int main(void){ const char* a = "XY"; const char* b = "ZW"; return (unsigned char)a[0] + (unsigned char)b[1]; }
@@@
CASES_EOF

awk -v W="$W" '
  BEGIN { RS="@@@\n"; n=0 }
  {
    s = $0
    if (s !~ /^[0-9]/) next
    nl = index(s, "\n")
    if (nl <= 0) next
    hdr = substr(s, 1, nl - 1)
    split(hdr, hh, "~"); code = hh[1]
    rest = substr(s, nl + 1)
    cpos = index(rest, "@C@")
    if (cpos <= 0) next
    ast = substr(rest, 1, cpos - 1)
    csrc = substr(rest, cpos + 3)
    printf "%s", ast  > (W "/c" code ".ast")
    printf "%s", csrc > (W "/c" code ".c")
    print code >> (W "/codelist.txt")
    n++
  }
  END { close(W "/codelist.txt") }
' "$W/cases.txt"
printf '%s\n' "PASS: $(wc -l < "$W/codelist.txt") differential cases split into Aster + C pairs"

diff_ok=0; diff_bad=0
while read -r code; do
    if ! "$OUT/aster" build-elf "$W/c$code.ast" -o "$W/c$code.a64" >"$W/c$code.aster.log" 2>&1; then
        echo "FAIL: case $code: Aster did not compile:" >&2
        tail -n 5 "$W/c$code.aster.log" >&2
        exit 1
    fi
    if ! "$HOSTCC" -O2 -fwrapv "$W/c$code.c" -o "$W/c$code.cbin" >"$W/c$code.c.log" 2>&1; then
        echo "FAIL: case $code: C oracle did not compile:" >&2
        tail -n 5 "$W/c$code.c.log" >&2
        exit 1
    fi
    agot=0; sh tests/run-aarch64.sh "$W/c$code.a64" >/dev/null 2>&1 || agot=$?
    cgot=0; sh tests/run-aarch64.sh "$W/c$code.cbin" >/dev/null 2>&1 || cgot=$?
    if [ "$agot" != "$cgot" ]; then
        echo "FAIL: case $code: Aster exit $agot != gcc exit $cgot (rodata/string edge mismatch)" >&2
        diff_bad=$((diff_bad + 1))
    else
        diff_ok=$((diff_ok + 1))
    fi
done < "$W/codelist.txt"
if [ "$diff_bad" -ne 0 ]; then
    echo "FAIL: $diff_bad differential case(s) disagree with gcc" >&2
    exit 1
fi
printf 'PASS: %d Aster rodata/string edges match aarch64 gcc exactly (byte index across a call, two literals by offset)\n' "$diff_ok"

# [3b] Narrow u8 ARGUMENT across an Aster<->Aster link-obj boundary.  Segment A
# proved the narrow-argument ABI only against gcc via a .so; this is the pure
# Aster multi-file path the linker actually stitches for real programs, and it
# is cross-asserted against a gcc<->gcc link so a layout disagreement on either
# side is caught.
printf '%s\n' '[3b] Narrow u8 parameter across an Aster<->Aster link-obj (cross-asserted with gcc)'
cat > "$W/np_def.ast" <<'AST'
fn add_one(x: u8) -> u8 { return x + 1; }
AST
cat > "$W/np_main.ast" <<'AST'
extern fn add_one(x: u8) -> u8;
fn main() -> i32 { return add_one(200); }
AST
cat > "$W/np_def.c" <<'C'
unsigned char add_one(unsigned char x){ return x + 1; }
C
cat > "$W/np_main.c" <<'C'
extern unsigned char add_one(unsigned char);
int main(void){ return add_one(200); }
C
"$OUT/aster" build-obj "$W/np_def.ast"  -o "$W/np_def.o"  >"$W/np_def.log"  2>&1 \
    || { echo "FAIL: Aster could not build np_def.o:"  >&2; cat "$W/np_def.log"  >&2; exit 1; }
"$OUT/aster" build-obj "$W/np_main.ast" -o "$W/np_main.o" >"$W/np_main.log" 2>&1 \
    || { echo "FAIL: Aster could not build np_main.o:" >&2; cat "$W/np_main.log" >&2; exit 1; }
"$OUT/aster" link-obj "$W/np_def.o" "$W/np_main.o" -o "$W/np_linked" >"$W/np_link.log" 2>&1 \
    || { echo "FAIL: Aster could not link-obj the narrow-parameter TUs:" >&2; cat "$W/np_link.log" >&2; exit 1; }
"$HOSTCC" -O2 -fwrapv -c "$W/np_def.c"  -o "$W/np_def.c.o"  >"$W/np_def.c.log"  2>&1 \
    || { echo "FAIL: gcc could not compile np_def.c:"  >&2; cat "$W/np_def.c.log"  >&2; exit 1; }
"$HOSTCC" -O2 -fwrapv -c "$W/np_main.c" -o "$W/np_main.c.o" >"$W/np_main.c.log" 2>&1 \
    || { echo "FAIL: gcc could not compile np_main.c:" >&2; cat "$W/np_main.c.log" >&2; exit 1; }
"$HOSTCC" -O2 -fwrapv "$W/np_def.c.o" "$W/np_main.c.o" -o "$W/np_cbin" >"$W/np_clink.log" 2>&1 \
    || { echo "FAIL: gcc could not link the narrow-parameter TUs:" >&2; cat "$W/np_clink.log" >&2; exit 1; }
agot=0; sh tests/run-aarch64.sh "$W/np_linked" >/dev/null 2>&1 || agot=$?
cgot=0; sh tests/run-aarch64.sh "$W/np_cbin"   >/dev/null 2>&1 || cgot=$?
if [ "$agot" != "$cgot" ] || [ "$agot" != "201" ]; then
    echo "FAIL: narrow u8 across link-obj: Aster exit $agot, gcc exit $cgot (expected 201)" >&2
    exit 1
fi
printf 'PASS: u8 argument survives an Aster<->Aster link-obj and agrees with gcc (200 + 1 == 201)\n'

# ---------------------------------------------------------------------------
printf '%s\n' '[4/4] Coverage-map assertion: the dedicated suites for the other faces still exist'
for s in bool-checks.sh c-string-literals-structural.sh e2e-c-string-literals.sh \
         global-deep-checks.sh struct-checks.sh linker-checks.sh \
         narrow-value-coverage.sh; do
    [ -f "tests/$s" ] || { echo "FAIL: coverage suite missing: tests/$s" >&2; exit 1; }
done
# The struct-with-narrow-field edge that mirrors the narrow-argument bug must
# keep its resident gcc-differential case; if it is edited out, the other faces
# stop being guarded against the exact failure mode round 4 found.
grep -qF 'struct S { a: i32, b: u8 }' tests/narrow-value-coverage.sh \
    || { echo "FAIL: u8_struct_field differential case missing from narrow-value-coverage.sh" >&2; exit 1; }
# The cross-file runtime-init edge (a global initialized from an extern global)
# must keep its example pair, or init-order regressions go unseen.
[ -f examples/runtime_init_order_defs.ast ] && [ -f examples/runtime_init_order_main.ast ] \
    || { echo "FAIL: cross-file runtime-init examples missing" >&2; exit 1; }
printf 'PASS: 7 dedicated suites present; u8_struct_field and cross-file init-order edges still guarded\n'
