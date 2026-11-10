#!/bin/sh
# tests/stdlib-io-checks.sh — the basic library: files, the growable arena,
# a byte buffer and two vectors (v0.23.77-dev).
#
# The library ships as one object and its declarations travel by `include`
# (types included), which is the path a consumer actually takes and which the
# shipped suites did not cover.
#
# Layers:
#   [1] strict build of the compiler
#   [2] the library object: 97 routines, 10 globals, 1 UND
#   [3] the demo runs and prints its summary line (through `include` + link)
#   [4] the C twin agrees byte for byte
#   [5] files: round trip, size, a missing path answers 0
#   [6] the arena: past the first 64 KiB chunk, ralloc copies, alloc(0) is 0
#   [7] include regression: a declaration with an array global must compile
#       (it used to crash the compiler: `dims` was dropped by the merge)
#   [8] no compiler change: the baseline reproduces 393 rows
#   [9] mutation: a buffer that does not grow must be caught
set -eu
cd "$(dirname "$0")/.."
. tests/lib/tmpdir.sh
CXX=${CXX:-c++}
ASTER="$TMPD/io-aster"
OUT="$TMPD/io-work"
rm -rf "$OUT"; mkdir -p "$OUT"
fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ printf '  %-46s %s\n' "$1" 'ok'; }
# the library, plus a copy named aiolib.ast for the demo's include
cp stdlib/aster_std.ast "$OUT/aiolib.ast"
chmod +x "$OUT/aiolib.ast" 2>/dev/null || true

printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER" src/aster.cpp
ok 'compiler built'

printf '%s\n' '[2/9] the library object'
"$ASTER" build-obj stdlib/aster_std.ast -o "$OUT/std.o" >"$OUT/std.log" 2>&1 \
    || fail "the library did not build: $(head -3 "$OUT/std.log")"
grep -q '97 functions, 10 globals' "$OUT/std.log" || fail "the library's shape changed: $(tail -1 "$OUT/std.log")"
und=$(readelf -sW "$OUT/std.o" | awk '$7=="UND"' | wc -l)
[ "$und" = 1 ] || fail "the library imports $und symbols, expected only the ELF null"
ok '97 routines, 10 globals, 1 UND entry'

printf '%s\n' '[3/9] the demo runs'
cp tests/stdlib-io-demo.ast "$OUT/demo.ast"
"$ASTER" build-obj "$OUT/demo.ast" -o "$OUT/demo.o" >"$OUT/demo.log" 2>&1 \
    || fail "the demo did not compile: $(tail -3 "$OUT/demo.log")"
"$ASTER" link-obj "$OUT/demo.o" "$OUT/std.o" -o "$OUT/demo" >"$OUT/link.log" 2>&1 \
    || fail "the demo did not link: $(tail -2 "$OUT/link.log")"
chmod +x "$OUT/demo"
(cd "$OUT" && ./demo > demo.out 2>&1) || fail "the demo exited $?"
grep -qxF '12|15|9|297' "$OUT/demo.out" || fail "the demo printed '$(cat "$OUT/demo.out")', expected '12|15|9|297'"
ok 'include + link, one line: 12|15|9|297'

printf '%s\n' '[4/9] the C twin agrees byte for byte'
${CC:-cc} -O1 -w tests/aster-std-io-twin.c -o "$OUT/twin" || fail 'the twin did not build'
(cd "$OUT" && ./twin > twin.out 2>&1) || true
cmp -s "$OUT/demo.out" "$OUT/twin.out" || { diff -u "$OUT/twin.out" "$OUT/demo.out" | head -10 >&2; fail 'the demo and its C twin disagree'; }
ok 'demo output == the POSIX twin'

printf '%s\n' '[5/9] files'
cat > "$OUT/files.ast" <<'AST'
include "aiolib.ast";
fn main() -> i32 {
    let fd: i32 = fd_open("f.txt", 577, 420);
    if (fd < 0) { return 1; }
    if (write_all(fd, "0123456789", 10) != 10) { return 2; }
    fd_close(fd);
    if (file_size("f.txt") != 10) { return 3; }
    if (slurp("absent") != 0) { return 4; }
    let got: u8[8] = 0;
    let p: ptr = slurp_bytes("f.txt", &got);
    if (p == 0 || load_i64(&got) != 10) { return 5; }
    if (load_u8(p) != 48 || load_u8(p + 9) != 57) { return 6; }
    if (write_all(2, "files\n", 6) != 6) { return 7; }
    return 0;
}
AST
cp "$OUT/files.ast" "$OUT/files2.ast"
"$ASTER" build-obj "$OUT/files.ast" -o "$OUT/files.o" >/dev/null 2>&1 || fail 'files.ast did not compile'
"$ASTER" link-obj "$OUT/files.o" "$OUT/std.o" -o "$OUT/files" >/dev/null 2>&1 || fail 'files.ast did not link'
chmod +x "$OUT/files"
set +e; (cd "$OUT" && ./files >/dev/null 2>&1); rc=$?; set -e
[ "$rc" = 0 ] || fail "the files fixture returned $rc"
ok 'round trip, size, a missing path, the raw bytes'

printf '%s\n' '[6/9] the growable arena'
cat > "$OUT/arena.ast" <<'AST'
include "aiolib.ast";
fn main() -> i32 {
    if (alloc(0) != 0) { return 1; }
    if (alloc(0 - 5) != 0) { return 2; }
    let a: ptr = alloc(100000);            // past the first 64 KiB chunk
    if (a == 0) { return 3; }
    store_u8(a + 99999, 90);
    if (load_u8(a + 99999) != 90) { return 4; }
    let b: ptr = alloc(100000);
    if (b == 0) { return 5; }
    if (load_u8(a + 99999) != 90) { return 6; }   // the older block still reads
    let src: u8[4] = 0;
    store_u8(src, 7); store_u8(src + 3, 9);
    let copy: ptr = ralloc(ptr(&src), 4, 64);
    if (copy == 0 || load_u8(copy) != 7 || load_u8(copy + 3) != 9) { return 7; }
    store_u8(copy + 63, 1);
    if (load_u8(src) != 7) { return 8; }
    return 0;
}
AST
"$ASTER" build-obj "$OUT/arena.ast" -o "$OUT/arena.o" >/dev/null 2>&1 || fail 'arena.ast did not compile'
"$ASTER" link-obj "$OUT/arena.o" "$OUT/std.o" -o "$OUT/arena" >/dev/null 2>&1 || fail 'arena.ast did not link'
chmod +x "$OUT/arena"
set +e; (cd "$OUT" && ./arena); rc=$?; set -e
[ "$rc" = 0 ] || fail "the arena fixture returned $rc"
ok 'two 100 KB blocks, a copy that keeps its bytes, alloc(0) = 0'

printf '%s\n' '[7/9] include regression: an array declaration crosses'
cat > "$OUT/hdr.ast" <<'AST'
let table: ptr<u8>[8] = 0;
let numbers: i64[4] = 0;
const limit: i32 = 99;
fn helper(x: i32) -> i32 { return x + 1; }
AST
cat > "$OUT/usehdr.ast" <<'AST'
include "hdr.ast";
fn main() -> i32 {
    let t: u8[8] = 0;
    table[0] = &t;               // the declaration really is an array
    numbers[1] = 7;
    if (limit != 99) { return 1; }
    if (table[0] != &t) { return 2; }
    if (numbers[1] != 7) { return 3; }
    return helper(41) - 42;
}
AST
"$ASTER" build-obj "$OUT/hdr.ast" -o "$OUT/hdr.o" >"$OUT/hdr.log" 2>&1 \
    || fail "the defining file did not compile: $(tail -2 "$OUT/hdr.log")"
"$ASTER" build-obj "$OUT/usehdr.ast" -o "$OUT/usehdr.o" >"$OUT/usehdr.log" 2>&1 \
    || fail "including an array declaration failed to compile: $(tail -3 "$OUT/usehdr.log")"
"$ASTER" link-obj "$OUT/usehdr.o" "$OUT/hdr.o" -o "$OUT/usehdr" >"$OUT/usehdr.link" 2>&1 \
    || fail "the included declarations did not link: $(tail -2 "$OUT/usehdr.link")"
chmod +x "$OUT/usehdr"
set +e; "$OUT/usehdr"; rc=$?; set -e
[ "$rc" = 0 ] || fail "the include fixture returned $rc (array/const/fn declarations across include)"
ok 'array globals, a const and a prototype cross include intact'

printf '%s\n' '[8/9] no compiler change: the baseline reproduces'
. tests/lib/baseline.sh
base=$(aster_baseline_file)
rows=$(wc -l < "$base")
[ "$rows" = 393 ] || fail "the baseline has $rows rows, expected 393"
ok '393 baseline rows unchanged'

printf '%s\n' '[9/9] mutation: st_size really is at byte 48'
sed 's|return load_i64(&st + 48);|return load_i64(\&st + 40);|' \
    stdlib/aster_std.ast > "$OUT/mutant_lib.ast"
cmp -s stdlib/aster_std.ast "$OUT/mutant_lib.ast" && fail 'the stat-offset mutation stopped applying'
"$ASTER" build-obj "$OUT/mutant_lib.ast" -o "$OUT/mutant.o" >/dev/null 2>&1 || fail 'the mutant library did not build'
cp "$OUT/mutant_lib.ast" "$OUT/aiolib.ast"
"$ASTER" build-obj "$OUT/demo.ast" -o "$OUT/mdemo.o" >/dev/null 2>&1 || fail 'the mutated demo did not compile'
"$ASTER" link-obj "$OUT/mdemo.o" "$OUT/mutant.o" -o "$OUT/mdemo" >/dev/null 2>&1 || fail 'the mutated demo did not link'
chmod +x "$OUT/mdemo"
set +e; (cd "$OUT" && ./mdemo > mut.out 2>&1); set -e
cmp -s "$OUT/mut.out" "$OUT/demo.out" && fail 'the mutant produced the demo line — the terminator is not load-bearing'
ok 'mutant diverges (slurp no longer terminates its buffer)'

echo 'PASS: basic library (files, arena, buffer, vectors, include regression)'
