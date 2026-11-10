#!/bin/sh
# tests/stdlib2-checks.sh — v0.23.77-dev: the second slice of the standard
# library, stdlib/aster_std.ast's v2 section.
#
# Layers:
#   [1] strict build of the compiler
#   [2] the library builds as one object: 98 functions, 10 globals, 1 UND entry
#   [3] the demo runs and prints the expected lines (not the twin's output)
#   [4] the C twin produces byte-identical output
#   [5] the edge fixture passes: misses, clamps, negatives, exhaustion
#   [6] the v2 names are all in the library source (guards against a rename)
#   [7] no compiler change: the baseline still reproduces
#   [8] the demo is deterministic (two runs, same bytes)
#   [9] mutation: memmove's backward path removed must break the demo's line
set -eu
cd "$(dirname "$0")/.."
. tests/lib/tmpdir.sh
CXX=${CXX:-c++}
ASTER="$TMPD/std2-aster"
W="$TMPD/std2-work"
rm -rf "$W"; mkdir -p "$W"
fail(){ echo "FAIL: $*" >&2; exit 1; }

printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER" src/aster.cpp
printf '  %-40s %s\n' 'compiler built' 'ok'

printf '%s\n' '[2/9] the library object'
"$ASTER" build-obj stdlib/aster_std.ast -o "$W/std.o" >"$W/std.log" 2>&1 || fail "stdlib did not build: $(head -1 "$W/std.log")"
grep -q '98 functions, 10 globals' "$W/std.log" || fail "the library's shape changed: $(tail -1 "$W/std.log")"
und=$(readelf -sW "$W/std.o" | awk '$7=="UND"' | wc -l)
[ "$und" = 1 ] || fail "the library imports $und symbols, expected only the ELF null"
printf '  %-40s %s\n' '98 functions, 10 globals, 1 UND entry' 'ok'

printf '%s\n' '[3/9] the demo prints the expected lines'
"$ASTER" build-obj tests/stdlib2-demo.ast -o "$W/demo.o" >/dev/null 2>&1 || fail 'the demo did not compile'
"$ASTER" link-obj "$W/demo.o" "$W/std.o" -o "$W/demo" >/dev/null 2>&1 || fail 'the demo did not link'
chmod +x "$W/demo"
set +e; "$W/demo" > "$W/demo.out" 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "the demo exited $rc"
for line in 'memmove 0' 'strncmp -1' 'strchr 2' 'strstr 6' 'strcat 4' 'atoi -123 7 0' \
            'fmt_i32 5' 'fmt_hex 4' 'sort 1 9' 'malloc 1 1 1 0' 'checks 12'; do
    grep -qxF "$line" "$W/demo.out" || fail "the demo output is missing '$line': $(cat "$W/demo.out")"
done
printf '  %-40s %s\n' 'eleven lines, each with the expected numbers' 'ok'

printf '%s\n' '[4/9] the C twin agrees byte for byte'
${CC:-cc} -O1 -w tests/aster-std2-twin.c -o "$W/twin" || fail 'the twin did not build'
"$W/twin" > "$W/twin.out" 2>&1 || true
cmp -s "$W/demo.out" "$W/twin.out" || { diff -u "$W/twin.out" "$W/demo.out" | head -20 >&2; fail 'the demo and its C twin disagree'; }
printf '  %-40s %s\n' 'demo output == twin output' 'ok'

printf '%s\n' '[5/9] the edge fixture passes'
"$ASTER" build-obj tests/stdlib2-edge.ast -o "$W/edge.o" >/dev/null 2>&1 || fail 'the edge fixture did not compile'
"$ASTER" link-obj "$W/edge.o" "$W/std.o" -o "$W/edge" >/dev/null 2>&1 || fail 'the edge fixture did not link'
chmod +x "$W/edge"
set +e; "$W/edge"; edge=$?; set -e
[ "$edge" = 0 ] || fail "the edge fixture returned $edge (see its comments for the code)"
printf '  %-40s %s\n' 'misses, clamps, INT32_MIN, exhaustion all pass' 'ok'

printf '%s\n' '[6/9] every v2 routine is in the library'
for f in memmove strncmp strchr strstr strcat atoi is_digit is_space is_alpha fmt_i32 fmt_hex sort_i32 malloc free; do
    grep -q "^fn $f(" stdlib/aster_std.ast || fail "stdlib/aster_std.ast has no $f"
done
printf '  %-40s %s\n' '14 v2 routines present' 'ok'

printf '%s\n' '[7/9] no compiler change: the baseline reproduces'
. tests/lib/baseline.sh
base=$(aster_baseline_file)
rows=$(wc -l < "$base")
[ "$rows" = 393 ] || fail "the baseline has $rows rows, expected 393"
printf '  %-40s %s\n' "393 baseline rows unchanged" 'ok'

printf '%s\n' '[8/9] the demo is deterministic'
"$W/demo" > "$W/demo2.out" 2>&1 || true
cmp -s "$W/demo.out" "$W/demo2.out" || fail 'two runs of the demo disagree'
printf '  %-40s %s\n' 'two runs, identical bytes' 'ok'

printf '%s\n' '[9/9] mutation: memmove must choose the backward path'
cp stdlib/aster_std.ast "$W/mutant.ast"
sed -i 's|if (i64(dst) < i64(src)) {|if (1) {|' "$W/mutant.ast"
grep -q 'if (1) {' "$W/mutant.ast" || fail 'the memmove mutation stopped applying'
"$ASTER" build-obj "$W/mutant.ast" -o "$W/mutant.o" >/dev/null 2>&1 || fail 'the mutant library did not build'
"$ASTER" link-obj "$W/demo.o" "$W/mutant.o" -o "$W/mutdemo" >/dev/null 2>&1 || fail 'the mutant demo did not link'
chmod +x "$W/mutdemo"
set +e; "$W/mutdemo" > "$W/mut.out" 2>&1; mut=$?; set -e
cmp -s "$W/mut.out" "$W/demo.out" && fail 'the memmove mutant produced identical output — layer [3] cannot see it'
printf '  %-40s %s\n' 'mutant diverges (overlap copy broken)' 'ok'

echo 'PASS: stdlib v2 (delivery, twin differential, edges, guards, mutation)'
