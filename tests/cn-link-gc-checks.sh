#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/build/cn-s1-s2/aster}
RUNNER=${RUNNER:-$ROOT/tests/run-aarch64.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

if ! command -v readelf >/dev/null 2>&1; then
    echo 'SKIP: readelf is unavailable'
    exit 77
fi

echo '[1/3] standard-library link keeps the historical whole-object output'
"$ASTER_BIN" build-obj stdlib/aster_std.ast -o "$TMP/std.o" >/dev/null
"$ASTER_BIN" build-obj examples/stdlib_demo.ast -o "$TMP/demo.o" >/dev/null
"$ASTER_BIN" link-obj "$TMP/demo.o" "$TMP/std.o" -o "$TMP/full" >/dev/null
"$ASTER_BIN" link-obj "$TMP/demo.o" "$TMP/std.o" -o "$TMP/gc" --gc-sections >/dev/null

full_size=$(wc -c < "$TMP/full" | tr -d ' ')
gc_size=$(wc -c < "$TMP/gc" | tr -d ' ')
[ "$gc_size" -lt "$full_size" ] || {
    echo "FAIL: --gc-sections did not reduce the executable ($full_size -> $gc_size)" >&2
    exit 1
}
readelf -sW "$TMP/full" | grep -E '[[:space:]]sort_i32$' >/dev/null || {
    echo 'FAIL: the whole-object link no longer contains the unused sort routine' >&2
    exit 1
}
if readelf -sW "$TMP/gc" | grep -E '[[:space:]]sort_i32$' >/dev/null; then
    echo 'FAIL: --gc-sections retained an unreachable standard-library function' >&2
    exit 1
fi
printf '  file size %s -> %s bytes, unreachable routine removed\n' "$full_size" "$gc_size"

echo '[2/3] the pruned image still has the same runtime output'
"$RUNNER" "$TMP/full" > "$TMP/full.out"
"$RUNNER" "$TMP/gc" > "$TMP/gc.out"
cmp "$TMP/full.out" "$TMP/gc.out"

echo '[3/3] debug links retain complete text for valid DWARF'
"$ASTER_BIN" build-obj -g stdlib/aster_std.ast -o "$TMP/std-g.o" >/dev/null
"$ASTER_BIN" build-obj -g examples/stdlib_demo.ast -o "$TMP/demo-g.o" >/dev/null
"$ASTER_BIN" link-obj "$TMP/demo-g.o" "$TMP/std-g.o" -o "$TMP/gc-g" --gc-sections >/dev/null
readelf -sW "$TMP/gc-g" | grep -E '[[:space:]]sort_i32$' >/dev/null || {
    echo 'FAIL: a debug link pruned text and invalidated its DWARF mapping' >&2
    exit 1
}
readelf -SW "$TMP/gc-g" | grep -q '\.debug_info' || {
    echo 'FAIL: debug link lost .debug_info' >&2
    exit 1
}

echo 'PASS: function-level link pruning (manual --gc-sections, bilingual-safe debug fallback)'
