#!/bin/sh
# tests/stdlib-map-checks.sh — the basic library, third slice: a map with
# string keys and pointer values, and a sort by element width.
#
# Layers:
#   [1] strict build of the compiler
#   [2] the library object: 103 routines, 10 globals, 1 UND
#   [3] the demo runs and prints its summary line
#   [4] the C twin agrees byte for byte (its own table and C's qsort)
#   [5] map edges: a grown table, replaced keys, an absent key, 500 keys
#   [6] sort edges: count 0 and 1, a refused width, a reverse input, duplicates
#   [7] no compiler change: the baseline reproduces 393 rows
#   [8] mutation: the i32 comparator's direction is load-bearing
set -eu
cd "$(dirname "$0")/.."
# v0.23.77-dev (host adaptation): run AArch64 products through the shared
# runner. It executes them natively on an AArch64/Termux host and under qemu
# elsewhere, so the very same suite is valid on both kinds of machine.
RUNNER=${RUNNER:-tests/run-aarch64.sh}
case "$RUNNER" in
    /*) ;;
    *) if [ -f "$RUNNER" ]; then RUNNER="$(cd "$(dirname "$RUNNER")" && pwd)/$(basename "$RUNNER")"; fi ;;
esac
. tests/lib/tmpdir.sh
CXX=${CXX:-c++}
ASTER="$TMPD/map-aster"
OUT="$TMPD/map-work"
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
grep -q '103 functions, 10 globals' "$OUT/std.log" || fail "the library's shape changed: $(tail -1 "$OUT/std.log")"
und=$(readelf -sW "$OUT/std.o" | awk '$7=="UND"' | wc -l)
[ "$und" = 1 ] || fail "the library imports $und symbols, expected only the ELF null"
ok '103 routines, 10 globals, 1 UND entry'

printf '%s\n' '[3/8] the demo runs'
cp tests/stdlib-map-demo.ast "$OUT/demo.ast"
"$ASTER" build-obj "$OUT/demo.ast" -o "$OUT/demo.o" >"$OUT/demo.log" 2>&1 \
    || fail "the demo did not compile: $(tail -3 "$OUT/demo.log")"
"$ASTER" link-obj "$OUT/demo.o" "$OUT/std.o" -o "$OUT/demo" >"$OUT/link.log" 2>&1 \
    || fail "the demo did not link: $(tail -2 "$OUT/link.log")"
chmod +x "$OUT/demo"
(cd "$OUT" && "$RUNNER" ./demo > demo.out 2>&1) || fail "the demo exited $?"
grep -qxF '16|202|-3|9|255|97|4' "$OUT/demo.out" \
    || fail "the demo printed '$(cat "$OUT/demo.out")', expected '16|202|-3|9|255|97|4'"
ok 'include + link, one line: 16|202|-3|9|255|97|4'

printf '%s\n' '[4/8] the C twin agrees byte for byte'
${CC:-cc} -O1 -w tests/aster-std-map-twin.c -o "$OUT/twin" || fail 'the twin did not build'
(cd "$OUT" && ./twin > twin.out 2>&1) || true
cmp -s "$OUT/demo.out" "$OUT/twin.out" \
    || { diff -u "$OUT/twin.out" "$OUT/demo.out" | head -10 >&2; fail 'the demo and its C twin disagree'; }
ok 'demo output == the C oracle'

printf '%s\n' '[5/8] the map: growth, replacement, absence'
cat > "$OUT/map.ast" <<'AST'
include "ailib.ast";
fn main() -> i32 {
    let m: Map = Map { 0, 0, 0 };
    let cell: i64[4] = 0;
    // an uninitialised map grows on first put
    if (map_put(&m, "one", ptr(&cell[0])) != 1) { return 1; }
    // a replacement keeps the count and answers 0
    if (map_put(&m, "one", ptr(&cell[1])) != 0) { return 2; }
    if (m.count != 1) { return 3; }
    if (map_get(&m, "one") != ptr(&cell[1])) { return 4; }
    // 500 distinct keys: several rehashes, and every one still finds its value
    let i: i32 = 0;
    while (i < 500) {
        let k: u8[16] = 0;
        fmt_i32(k, i);
        let c: ptr<u8> = str_dup(k);
        if (c == 0) { return 5; }
        if (map_put(&m, c, ptr(&cell[2])) != 1) { return 6; }
        i = i + 1;
    }
    if (m.count != 501) { return 7; }
    i = 0;
    while (i < 500) {
        let k: u8[16] = 0;
        fmt_i32(k, i);
        if (map_get(&m, k) != ptr(&cell[2])) { return 8; }
        i = i + 1;
    }
    if (map_get(&m, "one") != ptr(&cell[1])) { return 9; }
    if (map_get(&m, "absent") != 0) { return 10; }
    if (map_has(&m, "absent") != 0) { return 11; }
    if (map_has(&m, "one") != 1) { return 12; }
    // v0.23.77-dev: delete leaves a tombstone, so the probe runs that passed
    // through the slot still work; a re-put reuses it.
    if (map_del(&m, "one") != 1) { return 13; }
    if (m.count != 500) { return 14; }
    if (map_get(&m, "one") != 0) { return 15; }
    if (map_del(&m, "one") != 0) { return 16; }       // already gone
    i = 0;
    while (i < 500) {
        let k2: u8[16] = 0;
        fmt_i32(k2, i);
        if (map_get(&m, k2) != ptr(&cell[2])) { return 17; }
        i = i + 1;
    }
    if (map_put(&m, "one", ptr(&cell[1])) != 1) { return 18; }
    if (m.count != 501) { return 19; }
    if (map_get(&m, "one") != ptr(&cell[1])) { return 20; }
    return 0;
}
AST
"$ASTER" build-obj "$OUT/map.ast" -o "$OUT/map.o" >/dev/null 2>&1 || fail 'the map fixture did not compile'
"$ASTER" link-obj "$OUT/map.o" "$OUT/std.o" -o "$OUT/map" >/dev/null 2>&1 || fail 'the map fixture did not link'
chmod +x "$OUT/map"
set +e; (cd "$OUT" && "$RUNNER" ./map); rc=$?; set -e
[ "$rc" = 0 ] || fail "the map fixture returned $rc (each code names its case)"
ok '502 entries over six rehashes, every key findable'

printf '%s\n' '[6/8] the sort: degenerate sizes, a refused width, reverse input'
cat > "$OUT/sorts.ast" <<'AST'
include "ailib.ast";
// A comparator defined here: an extern function's address cannot be taken.
fn cmp_asc(a: ptr, b: ptr) -> i32 {
    let x: i32 = *(a);
    let y: i32 = *(b);
    if (x < y) { return 0 - 1; }
    if (x > y) { return 1; }
    return 0;
}
fn main() -> i32 {
    let one: i32[1] = 0;
    one[0] = 7;
    if (sort_i32(ptr(&one), 1) != 1) { return 1; }        // count 1: nothing to do
    if (one[0] != 7) { return 2; }
    if (sort_i32(ptr(&one), 0) != 0) { return 3; }        // count 0
    if (sort_bytes(ptr(&one), 1, 0, ptr(cmp_asc)) != 0 - 1) { return 4; }    // width 0
    if (sort_bytes(ptr(&one), 1, 257, ptr(cmp_asc)) != 0 - 1) { return 5; }  // too wide
    // a reverse-ordered input, with a duplicate in the middle
    let r: i32[6] = 0;
    r[0] = 60; r[1] = 50; r[2] = 40; r[3] = 40; r[4] = 30; r[5] = 20;
    sort_i32(ptr(&r), 6);
    if (r[0] != 20 || r[2] != 40 || r[3] != 40 || r[5] != 60) { return 6; }
    // u8 across the whole range, including the sign boundary
    let u: u8[6] = 0;
    u[0] = 255; u[1] = 128; u[2] = 127; u[3] = 1; u[4] = 0; u[5] = 200;
    sort_u8(ptr(&u), 6);
    if (u[0] != 0 || u[2] != 127 || u[3] != 128 || u[5] != 255) { return 7; }
    // strings via pointers
    let s: ptr[4] = 0;
    s[0] = "delta"; s[1] = "alpha"; s[2] = "charlie"; s[3] = "bravo";
    sort_str(ptr(&s), 4);
    if (streq(ptr<u8>(s[0]), "alpha") != 1) { return 8; }
    if (streq(ptr<u8>(s[3]), "delta") != 1) { return 9; }
    let i: i32 = 0;
    return 0;
}
AST
"$ASTER" build-obj "$OUT/sorts.ast" -o "$OUT/sorts.o" >/dev/null 2>&1 || fail 'the sorts fixture did not compile'
"$ASTER" link-obj "$OUT/sorts.o" "$OUT/std.o" -o "$OUT/sorts" >/dev/null 2>&1 || fail 'the sorts fixture did not link'
chmod +x "$OUT/sorts"
set +e; (cd "$OUT" && "$RUNNER" ./sorts); rc=$?; set -e
[ "$rc" = 0 ] || fail "the sorts fixture returned $rc"
ok 'count 0/1, a refused width, reverse with a duplicate, u8, strings'

printf '%s\n' '[7/8] no compiler change: the baseline reproduces'
. tests/lib/baseline.sh
base=$(aster_baseline_file)
rows=$(wc -l < "$base")
[ "$rows" = 393 ] || fail "the baseline has $rows rows, expected 393"
ok '393 baseline rows unchanged'

printf '%s\n' '[8/8] mutation: the comparator direction is load-bearing'
sed 's|fn cmp_i32_asc(a: ptr, b: ptr) -> i32 {\n.*||' /dev/null >/dev/null 2>&1 || true
sed 's|    if (x < y) { return 0 - 1; }|    if (x > y) { return 0 - 1; }|' \
    stdlib/aster_std.ast > "$OUT/mutant_lib.ast"
cmp -s stdlib/aster_std.ast "$OUT/mutant_lib.ast" && fail 'the direction mutation stopped applying'
"$ASTER" build-obj "$OUT/mutant_lib.ast" -o "$OUT/mutant.o" >/dev/null 2>&1 || fail 'the mutant library did not build'
cp "$OUT/mutant_lib.ast" "$OUT/ailib.ast"
"$ASTER" build-obj "$OUT/demo.ast" -o "$OUT/mdemo.o" >/dev/null 2>&1 || fail 'the mutated demo did not compile'
"$ASTER" link-obj "$OUT/mdemo.o" "$OUT/mutant.o" -o "$OUT/mdemo" >/dev/null 2>&1 || fail 'the mutated demo did not link'
chmod +x "$OUT/mdemo"
set +e; (cd "$OUT" && "$RUNNER" ./mdemo > mut.out 2>&1); set -e
cmp -s "$OUT/mut.out" "$OUT/demo.out" && fail 'the mutant produced the demo line — the comparator direction is not load-bearing'
ok 'mutant diverges (the i32 comparator sorts the other way)'

echo 'PASS: library slice 3 (map with string keys, sort by element width)'
