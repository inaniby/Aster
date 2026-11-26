#!/bin/sh
# cn-link-so-gc-checks.sh -- link-so --gc-sections / --gc-keep / --strip and
# build-apk strip defaults (v0.23.82-dev: build transparency + slimming).
# Two tiny PIC objects: entry.ast holds the ANativeActivity_onCreate entry,
# one live and two dead functions, one live and one dead global; helper.ast
# holds one live and one dead function with their own globals. GC must drop
# exactly the unreachable functions and data; --gc-keep must rescue named
# entry points (dlopen/dlsym test hooks); --strip must drop .symtab/.strtab.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/build/cn-s1-s2/aster}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

if ! command -v readelf >/dev/null 2>&1; then
    echo 'SKIP: readelf is unavailable'
    exit 77
fi

cat > "$TMP/entry.ast" <<'EOF'
extern fn helper_fn() : i32;
let kept_counter: i32 = 0;
let dropped_table: i32 = 0;
fn ANativeActivity_onCreate(activity: ptr, saved: ptr, savedSize: i64) : i32 {
    return used_fn() + helper_fn();
}
fn used_fn() : i32 {
    kept_counter = kept_counter + 1;
    return kept_counter;
}
fn unused_fn() : i32 {
    return 41;
}
fn unused_reader() : i32 {
    return dropped_table;
}
EOF
cat > "$TMP/helper.ast" <<'EOF'
let helper_data: i32 = 5;
let dead_data: i32 = 9;
fn helper_fn() : i32 {
    return helper_data;
}
fn unused_helper() : i32 {
    return dead_data;
}
EOF

dynsyms() { readelf --dyn-syms -W "$1"; }
has_sym() { dynsyms "$1" | grep -qF "$2@@aster"; }
no_sym() { ! has_sym "$1" "$2"; }
has_section() { readelf -S -W "$1" | grep -qF "$2"; }
no_section() { ! has_section "$1" "$2"; }

"$ASTER_BIN" build-obj --pic "$TMP/entry.ast" -o "$TMP/entry.o" >/dev/null
"$ASTER_BIN" build-obj --pic "$TMP/helper.ast" -o "$TMP/helper.o" >/dev/null

echo '[1/6] link-so without --gc-sections keeps every function and global'
"$ASTER_BIN" link-so "$TMP/entry.o" "$TMP/helper.o" -o "$TMP/full.so" \
    --soname libgctest.so >/dev/null
for s in ANativeActivity_onCreate used_fn unused_fn unused_reader helper_fn unused_helper; do
    has_sym "$TMP/full.so" "$s" || { echo "FAIL: baseline link lost $s" >&2; exit 1; }
done
for s in kept_counter dropped_table helper_data dead_data; do
    has_sym "$TMP/full.so" "$s" || { echo "FAIL: baseline link lost $s" >&2; exit 1; }
done
full_size=$(wc -c < "$TMP/full.so" | tr -d ' ')
echo "  baseline .so: $full_size bytes, all 6 functions + 4 globals exported"

echo '[2/6] link-so --gc-sections drops only the unreachable functions and data'
"$ASTER_BIN" link-so "$TMP/entry.o" "$TMP/helper.o" -o "$TMP/gc.so" \
    --soname libgctest.so --gc-sections >/dev/null
for s in ANativeActivity_onCreate used_fn helper_fn; do
    has_sym "$TMP/gc.so" "$s" || { echo "FAIL: GC dropped live function $s" >&2; exit 1; }
done
for s in unused_fn unused_reader unused_helper; do
    no_sym "$TMP/gc.so" "$s" || { echo "FAIL: GC retained dead function $s" >&2; exit 1; }
done
for s in kept_counter helper_data; do
    has_sym "$TMP/gc.so" "$s" || { echo "FAIL: GC dropped live global $s" >&2; exit 1; }
done
for s in dropped_table dead_data; do
    no_sym "$TMP/gc.so" "$s" || { echo "FAIL: GC retained dead global $s" >&2; exit 1; }
done
gc_size=$(wc -c < "$TMP/gc.so" | tr -d ' ')
[ "$gc_size" -lt "$full_size" ] || {
    echo "FAIL: --gc-sections did not shrink the .so ($full_size -> $gc_size)" >&2; exit 1; }
printf '  .so %s -> %s bytes, 3 dead functions + 2 dead globals removed\n' "$full_size" "$gc_size"

echo '[3/6] link-so --gc-sections --gc-keep rescues named unreachable functions'
"$ASTER_BIN" link-so "$TMP/entry.o" "$TMP/helper.o" -o "$TMP/keep.so" \
    --soname libgctest.so --gc-sections --gc-keep unused_fn,unused_helper >/dev/null
for s in unused_fn unused_helper; do
    has_sym "$TMP/keep.so" "$s" || { echo "FAIL: --gc-keep did not rescue $s" >&2; exit 1; }
done
no_sym "$TMP/keep.so" unused_reader || {
    echo 'FAIL: --gc-keep rescued a function it was not asked to keep' >&2; exit 1; }
echo '  unused_fn + unused_helper kept, unused_reader still dropped'

echo '[4/6] link-so --strip drops .symtab/.strtab, plain link keeps them'
has_section "$TMP/full.so" '.symtab' || { echo 'FAIL: plain link lost .symtab' >&2; exit 1; }
"$ASTER_BIN" link-so "$TMP/entry.o" "$TMP/helper.o" -o "$TMP/stripped.so" \
    --soname libgctest.so --strip >/dev/null
no_section "$TMP/stripped.so" '.symtab' || { echo 'FAIL: --strip kept .symtab' >&2; exit 1; }
no_section "$TMP/stripped.so" '.strtab' || { echo 'FAIL: --strip kept .strtab' >&2; exit 1; }
strip_size=$(wc -c < "$TMP/stripped.so" | tr -d ' ')
[ "$strip_size" -lt "$full_size" ] || {
    echo "FAIL: --strip did not shrink the .so ($full_size -> $strip_size)" >&2; exit 1; }
printf '  .so %s -> %s bytes with --strip\n' "$full_size" "$strip_size"

echo '[5/6] link-so --gc-sections --strip combines: live exports kept, no symtab'
"$ASTER_BIN" link-so "$TMP/entry.o" "$TMP/helper.o" -o "$TMP/gc-strip.so" \
    --soname libgctest.so --gc-sections --strip >/dev/null
for s in ANativeActivity_onCreate used_fn helper_fn; do
    has_sym "$TMP/gc-strip.so" "$s" || { echo "FAIL: combined link dropped live $s" >&2; exit 1; }
done
no_sym "$TMP/gc-strip.so" unused_fn || { echo 'FAIL: combined link kept dead unused_fn' >&2; exit 1; }
no_section "$TMP/gc-strip.so" '.symtab' || { echo 'FAIL: combined link kept .symtab' >&2; exit 1; }
both_size=$(wc -c < "$TMP/gc-strip.so" | tr -d ' ')
# Combined must be no larger than either single pass; it need not be strictly
# smaller than both, because section alignment padding can absorb a small
# .text saving (on this fixture GC+strip lands exactly on the strip-only size).
[ "$both_size" -le "$gc_size" ] && [ "$both_size" -le "$strip_size" ] || {
    echo "FAIL: combined link larger than a single pass ($both_size vs gc $gc_size, strip $strip_size)" >&2; exit 1; }
printf '  combined .so: %s bytes\n' "$both_size"

echo '[6/6] build-apk strips the packaged .so by default, --no-strip keeps it'
mkdir -p "$TMP/keys"
"$ASTER_BIN" keygen --dir "$TMP/keys" >/dev/null
"$ASTER_BIN" build-apk "$TMP/gc.so" -o "$TMP/gc.apk" \
    --package com.aster.gctest --libname gctest --abi arm64-v8a \
    --label "GC Test" --min-sdk 24 --target-sdk 34 \
    --version-code 1 --version-name "1.0" --keystore-dir "$TMP/keys" >/dev/null
"$ASTER_BIN" build-apk "$TMP/gc.so" -o "$TMP/gc-nostrip.apk" --no-strip \
    --package com.aster.gctest --libname gctest --abi arm64-v8a \
    --label "GC Test" --min-sdk 24 --target-sdk 34 \
    --version-code 1 --version-name "1.0" --keystore-dir "$TMP/keys" >/dev/null
python3 - "$TMP/gc.apk" "$TMP/gc-nostrip.apk" "$TMP" <<'PY'
import sys, zipfile
for apk, want_stripped in ((sys.argv[1], True), (sys.argv[2], False)):
    data = zipfile.ZipFile(apk).read('lib/arm64-v8a/libgctest.so')
    open(sys.argv[3] + '/packaged.so', 'wb').write(data)
    import subprocess
    out = subprocess.run(['readelf', '-S', '-W', sys.argv[3] + '/packaged.so'],
                         capture_output=True, text=True).stdout
    names = [l.split()[1] for l in out.splitlines()
             if len(l.split()) > 1 and l.strip().startswith('[')]
    if want_stripped:
        assert '.symtab' not in names, 'default build-apk kept .symtab in the packaged .so'
    else:
        assert '.symtab' in names, '--no-strip build-apk dropped .symtab from the packaged .so'
print('  default build-apk: packaged .so has no .symtab; --no-strip: .symtab kept')
PY

echo 'PASS: link-so GC / gc-keep / strip and build-apk strip defaults'
