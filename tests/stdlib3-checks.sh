#!/bin/sh
# tests/stdlib3-checks.sh — v0.23.77-dev: printing a double.
#
# The library's formatters are the last piece of the floating-point work: an
# f64 is only useful in a diagnostic if the program can write it out, and
# Aster has no variadic call, so `fmt_f64(buf, v, digits)` is the shape.
#
# Layers:
#   [1] strict build of the compiler
#   [2] the library builds as one object (29 functions) and imports nothing
#   [3] the demo prints the expected lines
#   [4] the C twin agrees byte for byte (printf "%.*f" is the oracle)
#   [5] the edge fixture: clamps, zero digits, negatives, inf/nan, whole values
#   [6] the rounding rule is half-up, and the tie case is pinned
#   [7] no compiler change: the baseline reproduces 393 rows
#   [8] mutation: dropping the fraction padding must break the output
set -eu
cd "$(dirname "$0")/.."
. tests/lib/tmpdir.sh
CXX=${CXX:-c++}
ASTER="$TMPD/std3-aster"
OUT="$TMPD/std3-work"
rm -rf "$OUT"; mkdir -p "$OUT"
fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ printf '  %-46s %s\n' "$1" 'ok'; }

printf '%s\n' '[1/8] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER" src/aster.cpp
ok 'compiler built'

printf '%s\n' '[2/8] the library object'
"$ASTER" build-obj stdlib/aster_std.ast -o "$OUT/std.o" >"$OUT/std.log" 2>&1 \
    || fail "stdlib did not build: $(head -1 "$OUT/std.log")"
grep -q '98 functions, 10 globals' "$OUT/std.log" || fail "the library's shape changed: $(tail -1 "$OUT/std.log")"
und=$(readelf -sW "$OUT/std.o" | awk '$7=="UND"' | wc -l)
[ "$und" = 1 ] || fail "the library imports $und symbols, expected only the ELF null"
ok '98 functions, 10 globals, 1 UND entry'

printf '%s\n' '[3/8] the demo prints the expected lines'
"$ASTER" build-obj tests/stdlib3-demo.ast -o "$OUT/demo.o" >/dev/null 2>&1 || fail 'the demo did not compile'
"$ASTER" link-obj "$OUT/demo.o" "$OUT/std.o" -o "$OUT/demo" >/dev/null 2>&1 || fail 'the demo did not link'
chmod +x "$OUT/demo"
set +e; "$OUT/demo" > "$OUT/demo.out" 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "the demo exited $rc"
for line in '3.14' '-2.7' '3' '100.000' '0.5' '0.333333333' '0.125000000' '0.50' '0.333333' 'inf' 'nan' '-7 and 0.75' 'checks 10'; do
    grep -qxF -e "$line" "$OUT/demo.out" || fail "the demo output is missing '$line': $(cat "$OUT/demo.out")"
done
ok 'thirteen lines, each pinned'

printf '%s\n' '[4/8] the C twin agrees byte for byte'
${CC:-cc} -O1 -w tests/aster-std3-twin.c -o "$OUT/twin" || fail 'the twin did not build'
"$OUT/twin" > "$OUT/twin.out" 2>&1 || true
cmp -s "$OUT/demo.out" "$OUT/twin.out" || { diff -u "$OUT/twin.out" "$OUT/demo.out" | head -20 >&2; fail 'the demo and its C twin disagree'; }
ok 'demo output == printf output'

printf '%s\n' '[5/8] the edge fixture'
cat > "$OUT/edge.ast" <<'AST'
extern fn memcmp(a: ptr<u8>, b: ptr<u8>, n: i32) -> i32;
extern fn fmt_f64(buf: ptr<u8>, v: f64, decimals: i32) -> i32;
extern fn fmt_f32(buf: ptr<u8>, v: f32, decimals: i32) -> i32;

fn main() -> i32 {
    let b: u8[64] = 0;
    // a negative digit count is zero digits, not an error
    if (fmt_f64(b, 1.4, 0 - 3) != 1) { return 1; }
    if (memcmp(b, "1", 1) != 0) { return 2; }
    // more than nine digits is nine
    if (fmt_f64(b, 0.5, 42) != 11) { return 3; }
    if (memcmp(b, "0.500000000", 11) != 0) { return 4; }
    // a whole number keeps its point when digits are asked for
    if (fmt_f64(b, 2.0, 1) != 3) { return 5; }
    if (memcmp(b, "2.0", 3) != 0) { return 6; }
    // negative zero prints without a sign
    if (fmt_f64(b, 0.0 - 0.0, 1) != 3) { return 7; }
    if (memcmp(b, "0.0", 3) != 0) { return 8; }
    // a negative infinity keeps its sign
    if (fmt_f64(b, 0.0 - (1.0 / 0.0), 1) != 4) { return 9; }
    if (memcmp(b, "-inf", 4) != 0) { return 10; }
    // a single that is exactly representable prints exactly
    if (fmt_f32(b, f32(0.125), 3) != 5) { return 11; }
    if (memcmp(b, "0.125", 5) != 0) { return 12; }
    return 0;
}
AST
"$ASTER" build-obj "$OUT/edge.ast" -o "$OUT/edge.o" >/dev/null 2>&1 || fail 'the edge fixture did not compile'
"$ASTER" link-obj "$OUT/edge.o" "$OUT/std.o" -o "$OUT/edge" >/dev/null 2>&1 || fail 'the edge fixture did not link'
chmod +x "$OUT/edge"
set +e; "$OUT/edge"; edge=$?; set -e
[ "$edge" = 0 ] || fail "the edge fixture returned $edge (each code names its case)"
ok 'clamps, whole values, negative zero, -inf, an exact single'

printf '%s\n' '[6/8] the rounding rule'
cat > "$OUT/round.ast" <<'AST'
extern fn memcmp(a: ptr<u8>, b: ptr<u8>, n: i32) -> i32;
extern fn fmt_f64(buf: ptr<u8>, v: f64, decimals: i32) -> i32;
fn main() -> i32 {
    let b: u8[64] = 0;
    // half-up: 0.25 is exactly halfway between 0.2 and 0.3, and goes up
    fmt_f64(b, 0.25, 1);
    if (memcmp(b, "0.3", 3) != 0) { return 1; }
    // and a value just under the tie goes down
    fmt_f64(b, 0.2499999, 1);
    if (memcmp(b, "0.2", 3) != 0) { return 2; }
    // a carry out of the fraction reaches the integer part
    fmt_f64(b, 9.99, 1);
    if (memcmp(b, "10.0", 4) != 0) { return 3; }
    return 0;
}
AST
"$ASTER" build-obj "$OUT/round.ast" -o "$OUT/round.o" >/dev/null 2>&1 || fail 'the rounding fixture did not compile'
"$ASTER" link-obj "$OUT/round.o" "$OUT/std.o" -o "$OUT/round" >/dev/null 2>&1 || fail 'the rounding fixture did not link'
chmod +x "$OUT/round"
set +e; "$OUT/round"; rrc=$?; set -e
[ "$rrc" = 0 ] || fail "the rounding fixture returned $rrc (half-up, just-under, and a carry)"
ok 'half-up on a tie, down just below it, a carry into the integer part'

printf '%s\n' '[7/8] no compiler change: the baseline reproduces'
. tests/lib/baseline.sh
base=$(aster_baseline_file)
rows=$(wc -l < "$base")
[ "$rows" = 393 ] || fail "the baseline has $rows rows, expected 393"
ok '393 baseline rows unchanged'

printf '%s\n' '[8/8] mutation: the fraction must be zero-padded'
cp stdlib/aster_std.ast "$OUT/mutant.ast"
sed 's|store_u8(buf + at, 48 + i32((frac / div) % 10));|store_u8(buf + at, 48 + i32(frac % 10));|' \
    stdlib/aster_std.ast > "$OUT/mutant.ast"
cmp -s stdlib/aster_std.ast "$OUT/mutant.ast" && fail 'the padding mutation stopped applying'
"$ASTER" build-obj "$OUT/mutant.ast" -o "$OUT/mutant.o" >/dev/null 2>&1 || fail 'the mutant library did not build'
"$ASTER" link-obj "$OUT/demo.o" "$OUT/mutant.o" -o "$OUT/mutdemo" >/dev/null 2>&1 || fail 'the mutant demo did not link'
chmod +x "$OUT/mutdemo"
set +e; "$OUT/mutdemo" > "$OUT/mut.out" 2>&1; set -e
cmp -s "$OUT/mut.out" "$OUT/demo.out" && fail 'the mutant produced identical output — layer [3] cannot see the padding'
ok 'mutant diverges (fraction no longer padded)'

echo 'PASS: float formatting (delivery, twin differential, edges, rounding, mutation)'
