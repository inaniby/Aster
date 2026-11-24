#!/bin/sh
# tests/cn-embed-checks.sh
#
# B-P2: `@embed("path")` / `@embed_len("path")` in the bilingual frontend.
#
#   [1] the parser accepts both forms in both languages and both spellings
#       lower to one shared AST (the standalone cn-parse dump).
#   [2] a bilingual probe builds, runs under qemu, and the Chinese and
#       English spellings of the same file produce byte-identical objects
#       (the blob symbol is namespaced by the source path, which is the
#       same file here — two different paths mint different symbols by
#       design, mainline v0.23.81-dev H-4/C-2).
#   [3] the same file embedded twice (address and length) is one blob.
#   [4] the optional alignment: the blob starts on its boundary, the
#       maximum of two requests wins, and bad alignments are refused
#       exactly as the mainline refuses them.
#   [5] missing / empty / directory assets and malformed `@embed` forms
#       are diagnostics, not silence.
#   [6] an imported file resolves its `@embed` against its own directory,
#       not its importer's (the B-P1 rule: a package file is an
#       independent TU and does not inherit the importer's paths).
#   [7] the per-source cache treats an embedded asset as a build input:
#       editing the asset recompiles only the TU that embeds it, and the
#       rebuilt program reads the new bytes.
#   [8] the multi-asset shape (one file owning several blobs, as
#       AsterUI's assets/embeds.ast does): every blob has the asset's
#       size, and the accessors read the assets' bytes.
#
# Alignment points with the mainline: the blob is a fromEmbed string
# global named `__aster_embed_<sanitized-basename>_h<12-hex>_<n>`; a
# path is relative to the file that wrote it, or to --embed-dir when
# given; `@embed_len` folds to the byte count at lowering time, so it
# is a literal in a const global initializer; the 16 MiB ceiling and
# the empty-file refusal are the mainline's. Difference: the mainline
# resolves and reads at parse time, the bilingual frontend at lowering
# time (the parser records the path and the owning file; the lowering
# reads the bytes into the TU's globals). An `@embed` in an enum
# initializer is not supported: that lowering runs without global
# storage, like a string literal there.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/build/cn-s1-s2/aster}
if [ ! -x "$ASTER_BIN" ]; then
    echo "set ASTER_BIN to a built Aster executable" >&2
    exit 2
fi
RUNNER=${RUNNER:-$ROOT/tests/run-aarch64.sh}
# AArch64 guests run natively on an AArch64 host and under qemu-aarch64
# elsewhere. Without either, execution checks SKIP cleanly (cf.
# bootstrap-loop-checks.sh) instead of failing with Exec format error.
if [ "$(uname -m)" = aarch64 ] || [ "$(uname -m)" = arm64 ] \
    || command -v qemu-aarch64 >/dev/null 2>&1; then
    CAN_RUN=1
else
    CAN_RUN=0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

run_status() { # $1 = program, $2 = expected exit code
    if [ "$CAN_RUN" -eq 0 ]; then
        printf '  SKIP: %s needs qemu-aarch64 or AArch64 Linux\n' "$1"
        return 0
    fi
    rc=0; "$RUNNER" "$1" || rc=$?
    [ "$rc" = "$2" ] || { echo "FAIL: $1 exited $rc, expected $2" >&2; exit 1; }
}

expect_fail() { # $1 = label, $2 = needle, $3... = command
    label=$1; needle=$2; shift 2
    if "$@" > "$TMP/fail.out" 2> "$TMP/fail.err"; then
        echo "FAIL: $label was accepted" >&2; exit 1
    fi
    grep -q "$needle" "$TMP/fail.err" || {
        echo "FAIL: $label was refused for the wrong reason (want '$needle'):" >&2
        cat "$TMP/fail.err" >&2; exit 1; }
    printf '  %-40s %s\n' "$label" 'refused'
}

# ---------------------------------------------------------------------------
printf '%s\n' '[1/8] parser: @embed / @embed_len share one AST in both languages'
c++ -std=c++17 -Wall -Wextra -Wpedantic -Werror \
    "$ROOT/src/cn_parse_main.cpp" "$ROOT/src/cn_parser.cpp" "$ROOT/src/cn_lexer.cpp" \
    -o "$TMP/aster-cn-parse"
cat > "$TMP/parse-zh.ast" <<'SRC'
// aster:language=zh
常量 g_data_len: 整数 = @embed_len("data.bin")
方法 data_ptr(): 指针
    返回 @embed("data.bin", 16)
结束 方法
方法 启动方法(): 整数
    返回 g_data_len
结束 方法
SRC
cat > "$TMP/parse-en.ast" <<'SRC'
// aster:language=en
const g_data_len: i32 = @embed_len("data.bin");
fn data_ptr() -> ptr {
    return @embed("data.bin", 16);
}
fn main() -> i32 {
    return g_data_len;
}
SRC
"$TMP/aster-cn-parse" "$TMP/parse-zh.ast" > "$TMP/zh.ast.out"
"$TMP/aster-cn-parse" "$TMP/parse-en.ast" > "$TMP/en.ast.out"
cmp "$TMP/zh.ast.out" "$TMP/en.ast.out" || {
    echo 'FAIL: Chinese and English @embed sources differ in the AST' >&2
    diff "$TMP/zh.ast.out" "$TMP/en.ast.out" >&2; exit 1; }
grep -q '(EmbedLen "\\"data.bin\\"")' "$TMP/zh.ast.out" || {
    echo 'FAIL: @embed_len did not dump as EmbedLen' >&2; exit 1; }
grep -q '(Embed "\\"data.bin\\"" (IntegerLiteral "16"))' "$TMP/zh.ast.out" || {
    echo 'FAIL: @embed with alignment did not dump as Embed + IntegerLiteral' >&2; exit 1; }
cat > "$TMP/parse-foo.ast" <<'SRC'
// aster:language=en
fn main() -> i32 {
    return @foo("data.bin");
}
SRC
expect_fail '@unknown in expression position' "expected 'embed' or 'embed_len'" \
    "$TMP/aster-cn-parse" "$TMP/parse-foo.ast"
cat > "$TMP/parse-bad.ast" <<'SRC'
// aster:language=en
fn main() -> i32 {
    return @embed("data.bin";
}
SRC
if "$TMP/aster-cn-parse" "$TMP/parse-bad.ast" > /dev/null 2> "$TMP/parse-bad.err"; then
    echo 'FAIL: unclosed @embed was accepted' >&2; exit 1
fi
grep -q "expected ')' after the file path" "$TMP/parse-bad.err" || {
    echo 'FAIL: unclosed @embed was refused for the wrong reason:' >&2
    cat "$TMP/parse-bad.err" >&2; exit 1; }

# ---------------------------------------------------------------------------
printf '%s\n' '[2/8] backend: one asset, both languages, byte-identical objects'
printf 'A\001\002\003\004' > "$TMP/data.bin"
cat > "$TMP/probe.ast" <<'SRC'
// aster:language=zh
常量 g_data_len: 整数 = @embed_len("data.bin")
方法 data_ptr(): 指针
    返回 @embed("data.bin")
结束 方法
方法 data_len(): 整数
    返回 g_data_len
结束 方法
方法 启动方法(): 整数
    变量 p: 指针 = data_ptr()
    返回 load_u8(p) + data_len()
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe-zh.o"
cat > "$TMP/probe.ast" <<'SRC'
// aster:language=en
const g_data_len: i32 = @embed_len("data.bin");
fn data_ptr() -> ptr {
    return @embed("data.bin");
}
fn data_len() -> i32 {
    return g_data_len;
}
fn main() -> i32 {
    let p: ptr = data_ptr();
    return load_u8(p) + data_len();
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/probe.ast" -o "$TMP/probe-en.o"
cmp "$TMP/probe-zh.o" "$TMP/probe-en.o" || {
    echo 'FAIL: Chinese and English @embed objects differ' >&2; exit 1; }
syms=$(readelf -sW "$TMP/probe-en.o" | grep -c '__aster_embed_' || true)
[ "$syms" = 1 ] || { echo "FAIL: probe produced $syms blobs, expected one" >&2; exit 1; }
readelf -sW "$TMP/probe-en.o" | grep -q '__aster_embed_probe_ast_h[0-9a-f]\{12\}_0' || {
    echo 'FAIL: blob symbol is not namespaced per source file' >&2
    readelf -sW "$TMP/probe-en.o" | grep '__aster_embed_' >&2; exit 1; }
"$ASTER_BIN" link-obj "$TMP/probe-en.o" -o "$TMP/probe"
run_status "$TMP/probe" 70

# ---------------------------------------------------------------------------
printf '%s\n' '[3/8] dedup: one path is one blob'
cat > "$TMP/dedup.ast" <<'SRC'
// aster:language=en
const g_len: i32 = @embed_len("data.bin");
fn first() -> ptr {
    return @embed("data.bin");
}
fn second() -> ptr {
    return @embed("data.bin");
}
fn main() -> i32 {
    return load_u8(first()) + load_u8(second()) + g_len;
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/dedup.ast" -o "$TMP/dedup.o"
syms=$(readelf -sW "$TMP/dedup.o" | grep -c '__aster_embed_' || true)
[ "$syms" = 1 ] || { echo "FAIL: dedup produced $syms blobs, expected one" >&2; exit 1; }
"$ASTER_BIN" link-obj "$TMP/dedup.o" -o "$TMP/dedup"
run_status "$TMP/dedup" 135

# ---------------------------------------------------------------------------
printf '%s\n' '[4/8] alignment: boundary, maximum wins, bad alignments refused'
printf 'A' > "$TMP/a.bin"
printf 'BC' > "$TMP/b.bin"
cat > "$TMP/align.ast" <<'SRC'
// aster:language=en
fn a_ptr() -> ptr {
    return @embed("a.bin", 1);
}
fn b_ptr() -> ptr {
    return @embed("b.bin", 64);
}
fn main() -> i32 {
    return load_u8(a_ptr()) + load_u8(b_ptr());
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/align.ast" -o "$TMP/align.o"
b_off=$(readelf -sW "$TMP/align.o" | awk '/__aster_embed_.*_1$/ {print $2}')
[ -n "$b_off" ] || { echo 'FAIL: no second blob symbol' >&2; exit 1; }
[ $((0x$b_off % 64)) -eq 0 ] || {
    echo "FAIL: 64-aligned blob starts at offset 0x$b_off" >&2; exit 1; }
printf '  %-40s %s\n' '64-aligned blob at offset 0x'"$b_off" 'ok'
# Same file twice, 8 then 64: one blob, and the section carries the maximum.
cat > "$TMP/align-max.ast" <<'SRC'
// aster:language=en
fn lo() -> ptr {
    return @embed("b.bin", 8);
}
fn hi() -> ptr {
    return @embed("b.bin", 64);
}
fn main() -> i32 {
    return load_u8(lo()) + load_u8(hi());
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/align-max.ast" -o "$TMP/align-max.o"
syms=$(readelf -sW "$TMP/align-max.o" | grep -c '__aster_embed_' || true)
[ "$syms" = 1 ] || { echo "FAIL: align-max produced $syms blobs, expected one" >&2; exit 1; }
ro_align=$(readelf -SW "$TMP/align-max.o" | awk '/\.rodata/ {print $NF}')
[ "$ro_align" = 64 ] || {
    echo "FAIL: .rodata alignment is $ro_align, expected 64" >&2; exit 1; }
cat > "$TMP/align-bad3.ast" <<'SRC'
// aster:language=en
fn main() -> i32 {
    let p: ptr = @embed("a.bin", 3);
    return load_u8(p);
}
SRC
expect_fail '@embed alignment 3' 'embedded alignment must be a power of two' \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/align-bad3.ast" -o "$TMP/align-bad3.o"
cat > "$TMP/align-bad8192.ast" <<'SRC'
// aster:language=en
fn main() -> i32 {
    let p: ptr = @embed("a.bin", 8192);
    return load_u8(p);
}
SRC
expect_fail '@embed alignment 8192' 'embedded alignment must not exceed 4096 bytes' \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/align-bad8192.ast" -o "$TMP/align-bad8192.o"
cat > "$TMP/align-len.ast" <<'SRC'
// aster:language=en
fn main() -> i32 {
    return @embed_len("a.bin", 8);
}
SRC
expect_fail '@embed_len with alignment' 'embed_len takes no alignment argument' \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/align-len.ast" -o "$TMP/align-len.o"

# ---------------------------------------------------------------------------
printf '%s\n' '[5/8] error paths: missing, empty, directory, non-string path'
cat > "$TMP/err-missing.ast" <<'SRC'
// aster:language=en
fn main() -> i32 {
    let p: ptr = @embed("nope.bin");
    return load_u8(p);
}
SRC
expect_fail 'missing asset' 'cannot open embedded file' \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/err-missing.ast" -o "$TMP/err-missing.o"
: > "$TMP/empty.bin"
cat > "$TMP/err-empty.ast" <<'SRC'
// aster:language=en
fn main() -> i32 {
    let p: ptr = @embed("empty.bin");
    return load_u8(p);
}
SRC
expect_fail 'empty asset' 'embedded file is empty' \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/err-empty.ast" -o "$TMP/err-empty.o"
mkdir -p "$TMP/adir"
cat > "$TMP/err-dir.ast" <<'SRC'
// aster:language=en
fn main() -> i32 {
    let p: ptr = @embed("adir");
    return load_u8(p);
}
SRC
expect_fail 'directory asset' 'embedded file is a directory' \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/err-dir.ast" -o "$TMP/err-dir.o"
cat > "$TMP/err-num.ast" <<'SRC'
// aster:language=en
fn main() -> i32 {
    let p: ptr = @embed(42);
    return load_u8(p);
}
SRC
expect_fail '@embed with a number path' 'expected a file path' \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/err-num.ast" -o "$TMP/err-num.o"

# ---------------------------------------------------------------------------
printf '%s\n' '[6/8] an imported file resolves @embed against its own directory'
mkdir -p "$TMP/import/sub"
printf 'Z' > "$TMP/import/sub/helper.bin"
printf 'A' > "$TMP/import/helper.bin"
cat > "$TMP/import/sub/helper.ast" <<'SRC'
// aster:language=en
fn helper_first() -> i32 {
    let p: ptr = @embed("helper.bin");
    return load_u8(p);
}
SRC
cat > "$TMP/import/main.ast" <<'SRC'
// aster:language=en
include "sub/helper.ast";
fn main() -> i32 {
    return helper_first();
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/import/main.ast" -o "$TMP/import/main.o"
"$ASTER_BIN" link-obj "$TMP/import/main.o" -o "$TMP/import/prog"
run_status "$TMP/import/prog" 90
rm "$TMP/import/sub/helper.bin"
if "$ASTER_BIN" build-cn-obj --language en "$TMP/import/main.ast" -o "$TMP/import/main2.o" \
    > /dev/null 2> "$TMP/import/neg.err"; then
    echo 'FAIL: import resolved @embed against the importer directory' >&2; exit 1
fi
grep -q 'sub/helper.bin' "$TMP/import/neg.err" || {
    echo 'FAIL: missing imported asset was refused for the wrong reason:' >&2
    cat "$TMP/import/neg.err" >&2; exit 1; }

# ---------------------------------------------------------------------------
printf '%s\n' '[7/8] project cache: an asset edit recompiles only its TU'
mkdir -p "$TMP/cache/src"
printf 'kind exe\n[language]\ndefault = "en"\nsrc/main.ast\nsrc/data.ast\n' > "$TMP/cache/aster.proj"
cat > "$TMP/cache/src/main.ast" <<'SRC'
extern fn data_ptr() -> ptr;
extern fn data_len() -> i32;
fn main() -> i32 {
    let p: ptr = data_ptr();
    return load_u8(p) + data_len();
}
SRC
cat > "$TMP/cache/src/data.ast" <<'SRC'
const g_data_len: i32 = @embed_len("data.bin");
fn data_ptr() -> ptr {
    return @embed("data.bin");
}
fn data_len() -> i32 {
    return g_data_len;
}
SRC
printf 'A\001\002\003\004' > "$TMP/cache/src/data.bin"
(cd "$TMP/cache" && "$ASTER_BIN" build > build1.log 2>&1) || {
    echo 'FAIL: the cache project did not build:' >&2; cat "$TMP/cache/build1.log" >&2; exit 1; }
grep -q '(2 compiled, 0 reused)' "$TMP/cache/build1.log" || {
    echo 'FAIL: the first cache build did not compile both sources:' >&2
    cat "$TMP/cache/build1.log" >&2; exit 1; }
run_status "$TMP/cache/build/cache" 70
(cd "$TMP/cache" && "$ASTER_BIN" build > build2.log 2>&1) || {
    echo 'FAIL: the cache rebuild failed:' >&2; cat "$TMP/cache/build2.log" >&2; exit 1; }
grep -q '(0 compiled, 2 reused)' "$TMP/cache/build2.log" || {
    echo 'FAIL: the cache rebuild did not reuse both objects:' >&2
    cat "$TMP/cache/build2.log" >&2; exit 1; }
printf 'B\001\002\003\004' > "$TMP/cache/src/data.bin"
(cd "$TMP/cache" && "$ASTER_BIN" build > build3.log 2>&1) || {
    echo 'FAIL: the build after the asset edit failed:' >&2
    cat "$TMP/cache/build3.log" >&2; exit 1; }
grep -q '(1 compiled, 1 reused)' "$TMP/cache/build3.log" || {
    echo 'FAIL: the asset edit did not recompile exactly its TU:' >&2
    cat "$TMP/cache/build3.log" >&2; exit 1; }
run_status "$TMP/cache/build/cache" 71

# ---------------------------------------------------------------------------
printf '%s\n' '[8/8] multi-asset file: sizes and bytes, as in assets/embeds.ast'
printf 'A' > "$TMP/multi-a.bin"
printf 'BC' > "$TMP/multi-b.bin"
printf 'DEF' > "$TMP/multi-c.bin"
cat > "$TMP/multi.ast" <<'SRC'
// aster:language=en
const g_a_len: i32 = @embed_len("multi-a.bin");
const g_b_len: i32 = @embed_len("multi-b.bin");
const g_c_len: i32 = @embed_len("multi-c.bin");
fn a_ptr() -> ptr {
    return @embed("multi-a.bin");
}
fn b_ptr() -> ptr {
    return @embed("multi-b.bin");
}
fn c_ptr() -> ptr {
    return @embed("multi-c.bin");
}
fn main() -> i32 {
    return load_u8(a_ptr()) + g_a_len + load_u8(b_ptr()) + g_b_len + load_u8(c_ptr()) + g_c_len;
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/multi.ast" -o "$TMP/multi.o"
syms=$(readelf -sW "$TMP/multi.o" | grep -c '__aster_embed_' || true)
[ "$syms" = 3 ] || { echo "FAIL: multi-asset probe produced $syms blobs, expected 3" >&2; exit 1; }
sizes=$(readelf -sW "$TMP/multi.o" | awk '/__aster_embed_/ {print $3}' | sort -n | tr '\n' ' ')
[ "$sizes" = '1 2 3 ' ] || {
    echo "FAIL: blob sizes are '$sizes', expected '1 2 3 '" >&2; exit 1; }
"$ASTER_BIN" link-obj "$TMP/multi.o" -o "$TMP/multi"
run_status "$TMP/multi" 205

echo 'PASS: bilingual @embed checks'
