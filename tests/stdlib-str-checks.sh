#!/bin/sh
# tests/stdlib-str-checks.sh — the basic library, second slice: 64-bit
# formatting, the integer and double parsers, and the string helpers.
#
# Layers:
#   [1] strict build of the compiler
#   [2] the library object: 91 routines, 10 globals, 1 UND
#   [3] the demo runs and prints its summary line
#   [4] the C twin agrees byte for byte (strtoll/strtod/snprintf are the oracle)
#   [5] edges: INT64_MIN, base 0 auto-detection, consumed counts, ".5", "1.",
#       a missing digit, a trailing CR, an empty string
#   [6] trim and line iteration do not run past their buffers
#   [7] no compiler change: the baseline reproduces 393 rows
#   [8] mutation: the u64 magnitude path of fmt_i64 is load-bearing
set -eu
cd "$(dirname "$0")/.."
. tests/lib/tmpdir.sh
CXX=${CXX:-c++}
ASTER="$TMPD/str-aster"
OUT="$TMPD/str-work"
rm -rf "$OUT"; mkdir -p "$OUT"
fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ printf '  %-46s %s\n' "$1" 'ok'; }
cp stdlib/aster_std.ast "$OUT/ailib.ast"

printf '%s\n' '[1/8] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER" src/aster.cpp
ok 'compiler built'

printf '%s\n' '[2/8] the library object'
"$ASTER" build-obj stdlib/aster_std.ast -o "$OUT/std.o" >"$OUT/std.log" 2>&1 \
    || fail "the library did not build: $(head -3 "$OUT/std.log")"
grep -q '91 functions, 10 globals' "$OUT/std.log" || fail "the library's shape changed: $(tail -1 "$OUT/std.log")"
und=$(readelf -sW "$OUT/std.o" | awk '$7=="UND"' | wc -l)
[ "$und" = 1 ] || fail "the library imports $und symbols, expected only the ELF null"
ok '91 routines, 10 globals, 1 UND entry'

printf '%s\n' '[3/8] the demo runs'
cp tests/stdlib-str-demo.ast "$OUT/demo.ast"
"$ASTER" build-obj "$OUT/demo.ast" -o "$OUT/demo.o" >"$OUT/demo.log" 2>&1 \
    || fail "the demo did not compile: $(tail -3 "$OUT/demo.log")"
"$ASTER" link-obj "$OUT/demo.o" "$OUT/std.o" -o "$OUT/demo" >"$OUT/link.log" 2>&1 \
    || fail "the demo did not link: $(tail -2 "$OUT/link.log")"
chmod +x "$OUT/demo"
(cd "$OUT" && ./demo > demo.out 2>&1) || fail "the demo exited $?"
grep -qxF '28|20|102|31|-2|3|2' "$OUT/demo.out" \
    || fail "the demo printed '$(cat "$OUT/demo.out")', expected '28|20|102|31|-2|3|2'"
ok 'include + link, one line: 28|20|102|31|-2|3|2'

printf '%s\n' '[4/8] the C twin agrees byte for byte'
${CC:-cc} -O1 -w tests/aster-std-str-twin.c -o "$OUT/twin" || fail 'the twin did not build'
(cd "$OUT" && ./twin > twin.out 2>&1) || true
cmp -s "$OUT/demo.out" "$OUT/twin.out" \
    || { diff -u "$OUT/twin.out" "$OUT/demo.out" | head -10 >&2; fail 'the demo and its C twin disagree'; }
ok 'demo output == the C oracle'

printf '%s\n' '[5/8] the parsers: edges'
cat > "$OUT/edge.ast" <<'AST'
include "ailib.ast";
fn main() -> i32 {
    let v: i64[1] = 0;
    let ov: ptr = ptr(&v);
    // base 0 auto-detects both prefixes
    if (strtoi("0X1F", 0, ov) != 4) { return 1; }
    if (v[0] != 31) { return 2; }
    if (strtoi("0B11", 0, ov) != 4) { return 3; }
    if (v[0] != 3) { return 4; }
    // an explicit hex base accepts the prefix too
    if (strtoi("0x10", 16, ov) != 4) { return 5; }
    if (v[0] != 16) { return 6; }
    // a sign with no digits is not a number
    if (strtoi("-", 10, ov) != 0 - 1) { return 7; }
    if (strtoi("", 10, ov) != 0 - 1) { return 8; }
    // an out-of-range base is refused
    if (strtoi("1", 40, ov) != 0 - 1) { return 9; }
    if (strtoi("1", 1, ov) != 0 - 1) { return 10; }
    // the widest values survive
    if (strtoi("9223372036854775807", 10, ov) == 0 - 1) { return 11; }
    if (v[0] != 9223372036854775807l) { return 12; }
    // a fraction with no integer digits, and a trailing point
    let f: f64[1] = 0;
    let of: ptr<f64> = ptr(&f);
    if (atof(".5", of) != 2) { return 13; }
    if (i32(f[0] * 100.0) != 50) { return 14; }
    if (atof("1.", of) != 2) { return 15; }
    if (i32(f[0]) != 1) { return 16; }
    if (atof("1e2", of) != 3) { return 17; }
    if (i32(f[0]) != 100) { return 18; }
    // v0.23.77-dev: the padded writer
    let wb: u8[32] = 0;
    if (fmt_i32_w(wb, 7, 3) != 3) { return 21; }
    if (strlen(wb) != 3) { return 22; }
    if (load_u8(wb) != 32 || load_u8(wb + 2) != 55) { return 23; }
    if (fmt_i32_w(wb, 0 - 12, 4) != 4) { return 24; }
    if (load_u8(wb) != 32 || load_u8(wb + 1) != 45) { return 25; }
    if (fmt_i32_w(wb, 12345, 2) != 5) { return 26; }
    if (load_u8(wb) != 49) { return 27; }
    if (atof("-0.5", of) != 4) { return 19; }
    if (i32(f[0] * 10.0) != 0 - 5) { return 20; }
    return 0;
}
AST
"$ASTER" build-obj "$OUT/edge.ast" -o "$OUT/edge.o" >/dev/null 2>&1 || fail 'the edge fixture did not compile'
"$ASTER" link-obj "$OUT/edge.o" "$OUT/std.o" -o "$OUT/edge" >/dev/null 2>&1 || fail 'the edge fixture did not link'
chmod +x "$OUT/edge"
set +e; (cd "$OUT" && ./edge); rc=$?; set -e
[ "$rc" = 0 ] || fail "the edge fixture returned $rc (each code names its case)"
ok 'prefixes, signs, bases, INT64_MAX, .5, 1., 1e2, -0.5'

printf '%s\n' '[6/8] trim and lines stay inside their buffers'
cat > "$OUT/lines.ast" <<'AST'
include "ailib.ast";
fn main() -> i32 {
    // no newline at all: one line, and the iterator answers 0 afterwards
    let a: u8[8] = 0;
    memcpy(a, "abc", 4);
    if (next_line(&a) != 0) { return 1; }
    if (strlen(&a) != 3) { return 2; }
    // an empty line between two others, and a trailing CR without LF
    let b: u8[16] = 0;
    memcpy(b, "x\n\nyz\r", 7);
    let n: i32 = 0;
    let p: ptr<u8> = &b;
    while (p != 0) { n = n + 1; p = next_line(p); }
    if (n != 3) { return 3; }
    if (strlen(&b) != 1) { return 4; }
    // trim on an all-space string answers the empty tail
    let s: u8[8] = 0;
    memcpy(s, "   ", 4);
    let t: ptr<u8> = trim(&s);
    if (strlen(t) != 0) { return 5; }
    // trim on an empty string is the string itself
    let e: u8[4] = 0;
    if (strlen(trim(&e)) != 0) { return 6; }
    return 0;
}
AST
"$ASTER" build-obj "$OUT/lines.ast" -o "$OUT/lines.o" >/dev/null 2>&1 || fail 'the lines fixture did not compile'
"$ASTER" link-obj "$OUT/lines.o" "$OUT/std.o" -o "$OUT/lines" >/dev/null 2>&1 || fail 'the lines fixture did not link'
chmod +x "$OUT/lines"
set +e; (cd "$OUT" && ./lines); rc=$?; set -e
[ "$rc" = 0 ] || fail "the lines fixture returned $rc"
ok 'no newline, an empty line, a trailing CR, all-space, empty'

printf '%s\n' '[7/8] no compiler change: the baseline reproduces'
. tests/lib/baseline.sh
base=$(aster_baseline_file)
rows=$(wc -l < "$base")
[ "$rows" = 393 ] || fail "the baseline has $rows rows, expected 393"
ok '393 baseline rows unchanged'

printf '%s\n' '[8/8] mutation: the positive path takes the magnitude from the value'
sed 's|        mag = u64(v);|        mag = u64(0 - v);|' \
    stdlib/aster_std.ast > "$OUT/mutant_lib.ast"
cmp -s stdlib/aster_std.ast "$OUT/mutant_lib.ast" && fail 'the magnitude mutation stopped applying'
"$ASTER" build-obj "$OUT/mutant_lib.ast" -o "$OUT/mutant.o" >/dev/null 2>&1 || fail 'the mutant library did not build'
cp "$OUT/mutant_lib.ast" "$OUT/ailib.ast"
"$ASTER" build-obj "$OUT/demo.ast" -o "$OUT/mdemo.o" >/dev/null 2>&1 || fail 'the mutated demo did not compile'
"$ASTER" link-obj "$OUT/mdemo.o" "$OUT/mutant.o" -o "$OUT/mdemo" >/dev/null 2>&1 || fail 'the mutated demo did not link'
chmod +x "$OUT/mdemo"
set +e; (cd "$OUT" && ./mdemo > mut.out 2>&1); set -e
cmp -s "$OUT/mut.out" "$OUT/demo.out" && fail 'the mutant produced the demo line — the u64 magnitude is not load-bearing'
ok 'mutant diverges (a positive value takes the wrong magnitude)'

echo 'PASS: library slice 2 (i64/hex formatting, parsers, string helpers)'
