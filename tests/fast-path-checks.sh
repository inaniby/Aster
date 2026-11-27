#!/bin/sh
# tests/fast-path-checks.sh
#
# Phase 0: no-change APK fast path (incremental-design §7.1).
#
#   [1] compile aster with the same strict flags used for release (-Werror)
#   [2] source guards for the fingerprint + sidecar plumbing
#   [3] `aster build` on a small bilingual APK project: a cold build writes
#       build/.cache/last-apk.json (version 1) and the warm rebuild takes
#       the fast path — same APK bytes, same summary line, no link/sign
#       work — in both the parallel and the --jobs 1 (serial) TU loops
#   [4] every fingerprint input change defeats the fast path, and the
#       rebuild after it takes the fast path again: a source change, a
#       --no-strip flag change, a different signing key, a different icon
#   [5] sidecar failure modes fail closed, never an error: unknown version,
#       garbage contents, and a deleted APK each fall back to a normal
#       link+sign, and the sidecar is rewritten
#   [6] standalone `aster build-apk` takes the same fast path (its sidecar
#       sits next to the output), and a --label change defeats it
#   [7] the fast-path-reused APK still verifies (v1 + v2 + v3)
#
# No external Android toolchain is involved. Keys are pre-generated with
# `aster keygen` into scratch directories (ASTER_KEY_DIR), so no build
# prints a key-generation notice and the signing key is identical across
# the cold/warm comparison — which is what makes the APK byte comparison
# meaningful.
#
# Override points (env vars): ASTER_BIN, KEY_DIR, KEY_DIR2
set -eu
. tests/lib/tmpdir.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ASTER_BIN="${ASTER_BIN:-$TMPD/aster-fast-path}"
KEY_DIR="${KEY_DIR:-$TMPD/aster-fast-path-keys}"
KEY_DIR2="${KEY_DIR2:-$TMPD/aster-fast-path-keys2}"
PROJ="$TMPD/fast-path-proj"
APK="$PROJ/build/fastpath.apk"
SIDECAR="$PROJ/build/.cache/last-apk.json"
SO_APK="$TMPD/fast-path-standalone.apk"

fail() { echo "FAIL: $*" >&2; exit 1; }

# build_proj <log> [extra build args...] — build in $PROJ with KEY_DIR.
build_proj() {
    log=$1; shift
    (cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build --verbose "$@" > "$log" 2>&1) ||
        { echo "FAIL: build failed (log $log):" >&2; cat "$log" >&2; exit 1; }
}
# build_proj_key <keydir> <log> [extra build args...]
build_proj_key() {
    kd=$1; log=$2; shift 2
    (cd "$PROJ" && ASTER_KEY_DIR="$kd" "$ASTER_BIN" build --verbose "$@" > "$log" 2>&1) ||
        { echo "FAIL: build failed (log $log):" >&2; cat "$log" >&2; exit 1; }
}
apk_sha() { sha256sum "$1" | cut -d' ' -f1; }
expect_hit() { # $1 = log
    grep -q 'aster: verbose: fast-path: reused ' "$1" ||
        fail "expected the fast path in $1"; }
expect_miss() { # $1 = log
    if grep -q 'aster: verbose: fast-path: reused ' "$1"; then
        fail "fast path fired unexpectedly in $1"
    fi
}
summary_line() { grep 'built bilingual project' "$1"; }

echo "[1/7] compiling aster (strict: -Wall -Wextra -Werror)"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER_BIN" src/aster.cpp

echo "[1/7] generating the test project's debug keys"
rm -rf "$KEY_DIR" "$KEY_DIR2" && mkdir -p "$KEY_DIR" "$KEY_DIR2"
"$ASTER_BIN" keygen --dir "$KEY_DIR" > /dev/null
"$ASTER_BIN" keygen --dir "$KEY_DIR2" > /dev/null

echo "[2/7] source guards: fingerprint + sidecar plumbing"
for needle in \
    'kApkFastPathVersion' \
    'apkFastPathFingerprint' \
    'apkFastPathCertSha256' \
    'last-apk.json' \
    'fast-path: reused ' \
    'apkFastPathHit' \
    'apkFastPathRecord' \
    'TuWorkResult' ; do
    grep -qF "$needle" src/aster.cpp || fail "source guard missing: $needle"
done
printf '  %-40s %s\n' 'fingerprint + sidecar plumbing present' 'ok'

echo "[3/7] cold build writes the sidecar; warm rebuilds take the fast path"
rm -rf "$PROJ" && mkdir -p "$PROJ/src"
cat > "$PROJ/aster.proj" <<'PROJ'
kind apk
package com.example.fastpath
name fastpath
label 计数器
src/main.ast
src/counter.ast
PROJ
cat > "$PROJ/src/counter.ast" <<'SRC'
变量 计数: 整数 = 41
方法 增加(步长: 整数): 整数
    计数 = 计数 + 步长
    返回 计数
结束 方法
SRC
cat > "$PROJ/src/main.ast" <<'SRC'
方法 ANativeActivity_onCreate(活动: 指针, 保存状态: 指针, 保存大小: 整数): 整数
    返回 增加(1)
结束 方法
SRC
build_proj "$TMPD/cold.log"
expect_miss "$TMPD/cold.log"
grep -q '(2 compiled, 0 reused)' "$TMPD/cold.log" || fail "cold build did not compile both sources"
[ -f "$APK" ] || fail "cold build wrote no APK"
[ -f "$SIDECAR" ] || fail "cold build wrote no last-apk.json sidecar"
grep -q '"version": 1' "$SIDECAR" || fail "sidecar is not version 1"
grep -q "\"apk_sha256\": \"$(apk_sha "$APK")\"" "$SIDECAR" ||
    fail "sidecar apk_sha256 does not match the cold APK"
SHA_COLD=$(apk_sha "$APK")

build_proj "$TMPD/warm.log"
expect_hit "$TMPD/warm.log"
[ "$(apk_sha "$APK")" = "$SHA_COLD" ] || fail "warm APK differs from the cold APK"
summary_line "$TMPD/warm.log" > "$TMPD/summary-warm.txt"
grep -q '(0 compiled, 2 reused)' "$TMPD/warm.log" ||
    fail "warm build did not report 0 compiled, 2 reused"
# The summary line of a fast-path build is byte-identical to the summary
# line of the same warm build without the fast path: delete the sidecar,
# rebuild (a miss), and compare both the verbose summary line and the
# whole non-verbose stdout (a single line — this is what the plugin's
# build-summary parser reads).
rm -f "$SIDECAR"
build_proj "$TMPD/warm-miss.log"
expect_miss "$TMPD/warm-miss.log"
summary_line "$TMPD/warm-miss.log" > "$TMPD/summary-miss.txt"
cmp -s "$TMPD/summary-warm.txt" "$TMPD/summary-miss.txt" ||
    fail "summary line differs between fast-path and normal warm builds"
rm -f "$SIDECAR"
(cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build > "$TMPD/nv-miss.out" 2>"$TMPD/nv-miss.err") ||
    fail "non-verbose warm build (miss) failed"
(cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build > "$TMPD/nv-hit.out" 2>"$TMPD/nv-hit.err") ||
    fail "non-verbose warm build (hit) failed"
# A normal warm build prints the linker's own line plus the summary; a
# fast-path build prints only the summary (there was no link to report).
# The summary line — the one the plugin's build-summary parser reads —
# is byte-identical between the two.
grep -q '^Aster v.*: linked .* into shared object' "$TMPD/nv-miss.out" ||
    fail "normal warm build printed no linker line"
[ "$(wc -l < "$TMPD/nv-miss.out")" = 2 ] ||
    fail "normal warm build did not print exactly two lines"
[ "$(wc -l < "$TMPD/nv-hit.out")" = 1 ] ||
    fail "non-verbose fast-path build printed more than one line"
tail -n 1 "$TMPD/nv-miss.out" > "$TMPD/nv-miss-summary.txt"
cmp -s "$TMPD/nv-miss-summary.txt" "$TMPD/nv-hit.out" ||
    fail "summary line differs between fast-path and normal warm builds"
grep -q 'built bilingual project .* (0 compiled, 2 reused)' "$TMPD/nv-hit.out" ||
    fail "non-verbose fast-path build printed the wrong summary"

build_proj_key "$KEY_DIR" "$TMPD/warm-j1.log" --jobs 1
expect_hit "$TMPD/warm-j1.log"
[ "$(apk_sha "$APK")" = "$SHA_COLD" ] || fail "serial warm APK differs from the cold APK"
printf '  %-40s %s\n' 'cold/warm/--jobs 1: same APK, same summary' 'ok'

echo "[4/7] each fingerprint input change defeats the fast path"
# (a) source change
sed -i 's/增加(1)/增加(2)/' "$PROJ/src/main.ast"
build_proj "$TMPD/srcchange.log"
expect_miss "$TMPD/srcchange.log"
SHA_SRC=$(apk_sha "$APK")
[ "$SHA_SRC" != "$SHA_COLD" ] || fail "source change did not change the APK"
build_proj "$TMPD/srcchange2.log"
expect_hit "$TMPD/srcchange2.log"
[ "$(apk_sha "$APK")" = "$SHA_SRC" ] || fail "rebuild after source change differs"
printf '  %-40s %s\n' 'source change: miss, then hit again' 'ok'
# (b) flag change
build_proj "$TMPD/nostrip.log" --no-strip
expect_miss "$TMPD/nostrip.log"
SHA_STRIP=$(apk_sha "$APK")
[ "$SHA_STRIP" != "$SHA_SRC" ] || fail "--no-strip did not change the APK"
build_proj "$TMPD/nostrip2.log" --no-strip
expect_hit "$TMPD/nostrip2.log"
[ "$(apk_sha "$APK")" = "$SHA_STRIP" ] || fail "rebuild with --no-strip differs"
build_proj "$TMPD/stripback.log"
expect_miss "$TMPD/stripback.log"
[ "$(apk_sha "$APK")" = "$SHA_SRC" ] || fail "back to default flags did not restore the APK"
printf '  %-40s %s\n' 'flag change: miss, then hit again' 'ok'
# (c) key change
build_proj_key "$KEY_DIR2" "$TMPD/key2.log"
expect_miss "$TMPD/key2.log"
SHA_KEY2=$(apk_sha "$APK")
[ "$SHA_KEY2" != "$SHA_SRC" ] || fail "key change did not change the APK"
build_proj_key "$KEY_DIR2" "$TMPD/key2b.log"
expect_hit "$TMPD/key2b.log"
[ "$(apk_sha "$APK")" = "$SHA_KEY2" ] || fail "rebuild with the second key differs"
build_proj_key "$KEY_DIR" "$TMPD/key1.log"
expect_miss "$TMPD/key1.log"
[ "$(apk_sha "$APK")" = "$SHA_SRC" ] || fail "back to the first key did not restore the APK"
printf '  %-40s %s\n' 'key change: miss, then hit again' 'ok'
# (d) icon change
python3 - "$PROJ" <<'PY'
import sys, zlib, struct
def png(path, r, g, b):
    def chunk(t, d):
        c = t + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0)
    raw = b"".join(b"\x00" + bytes([r, g, b]) * 16 for _ in range(16))
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
png(sys.argv[1] + "/icon-a.png", 30, 58, 104)
png(sys.argv[1] + "/icon-b.png", 200, 30, 30)
PY
printf 'icon icon-a.png\n' >> "$PROJ/aster.proj"
build_proj "$TMPD/icon-a.log"
expect_miss "$TMPD/icon-a.log"
SHA_ICON_A=$(apk_sha "$APK")
[ "$SHA_ICON_A" != "$SHA_SRC" ] || fail "adding an icon did not change the APK"
build_proj "$TMPD/icon-a2.log"
expect_hit "$TMPD/icon-a2.log"
[ "$(apk_sha "$APK")" = "$SHA_ICON_A" ] || fail "rebuild with icon-a differs"
sed -i 's/icon-a.png/icon-b.png/' "$PROJ/aster.proj"
build_proj "$TMPD/icon-b.log"
expect_miss "$TMPD/icon-b.log"
SHA_ICON_B=$(apk_sha "$APK")
[ "$SHA_ICON_B" != "$SHA_ICON_A" ] || fail "swapping the icon did not change the APK"
build_proj "$TMPD/icon-b2.log"
expect_hit "$TMPD/icon-b2.log"
[ "$(apk_sha "$APK")" = "$SHA_ICON_B" ] || fail "rebuild with icon-b differs"
sed -i '/^icon /d' "$PROJ/aster.proj"
printf '  %-40s %s\n' 'icon change: miss, then hit again' 'ok'

echo "[5/7] sidecar failure modes fail closed"
python3 - "$SIDECAR" <<'PY'
import sys, json
d = json.load(open(sys.argv[1]))
d["version"] = 99
json.dump(d, open(sys.argv[1], "w"))
PY
build_proj "$TMPD/ver99.log"
expect_miss "$TMPD/ver99.log"
grep -q '"version": 1' "$SIDECAR" || fail "unknown-version sidecar was not rewritten as version 1"
[ "$(apk_sha "$APK")" = "$SHA_SRC" ] || fail "unknown-version fallback changed the APK"
printf 'this is not json {{{' > "$SIDECAR"
build_proj "$TMPD/garbage.log"
expect_miss "$TMPD/garbage.log"
grep -q '"version": 1' "$SIDECAR" || fail "garbage sidecar was not rewritten as version 1"
[ "$(apk_sha "$APK")" = "$SHA_SRC" ] || fail "garbage-sidecar fallback changed the APK"
rm -f "$APK"
build_proj "$TMPD/noapk.log"
expect_miss "$TMPD/noapk.log"
[ -f "$APK" ] || fail "deleted APK was not rebuilt"
[ "$(apk_sha "$APK")" = "$SHA_SRC" ] || fail "rebuilt APK after deletion differs"
build_proj "$TMPD/hit-again.log"
expect_hit "$TMPD/hit-again.log"
printf '  %-40s %s\n' 'unknown version / garbage / missing APK: miss, no error' 'ok'

echo "[6/7] standalone build-apk takes the same fast path"
SO_FILE=$(ls "$PROJ"/build/.cache/*.so | head -n 1)
[ -n "$SO_FILE" ] || fail "no .so found for the standalone build-apk check"
rm -f "$SO_APK" "$SO_APK.last-apk.json"
(cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build-apk "$SO_FILE" -o "$SO_APK" \
    --package com.example.fastpath --libname fastpath --verbose > "$TMPD/bapk1.log" 2>&1) ||
    { echo "FAIL: standalone build-apk failed:" >&2; cat "$TMPD/bapk1.log" >&2; exit 1; }
if grep -q 'aster: verbose: fast-path: reused ' "$TMPD/bapk1.log"; then
    fail "standalone build-apk took the fast path with no sidecar"
fi
SHA_BAPK=$(apk_sha "$SO_APK")
[ -f "$SO_APK.last-apk.json" ] || fail "standalone build-apk wrote no sidecar"
(cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build-apk "$SO_FILE" -o "$SO_APK" \
    --package com.example.fastpath --libname fastpath --verbose > "$TMPD/bapk2.log" 2>&1) ||
    { echo "FAIL: standalone build-apk rebuild failed:" >&2; cat "$TMPD/bapk2.log" >&2; exit 1; }
expect_hit "$TMPD/bapk2.log"
[ "$(apk_sha "$SO_APK")" = "$SHA_BAPK" ] || fail "standalone warm APK differs"
(cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build-apk "$SO_FILE" -o "$SO_APK" \
    --package com.example.fastpath --libname fastpath --label "Other Label" --verbose > "$TMPD/bapk3.log" 2>&1) ||
    { echo "FAIL: standalone build-apk with --label failed:" >&2; cat "$TMPD/bapk3.log" >&2; exit 1; }
expect_miss "$TMPD/bapk3.log"
[ "$(apk_sha "$SO_APK")" != "$SHA_BAPK" ] || fail "--label change did not change the standalone APK"
printf '  %-40s %s\n' 'build-apk: hit, and --label defeats it' 'ok'

echo "[7/7] the fast-path-reused APK still verifies"
build_proj "$TMPD/verify-prep.log"
expect_hit "$TMPD/verify-prep.log"
"$ASTER_BIN" verify-apk "$APK" > "$TMPD/verify.log" 2>&1 ||
    { echo "FAIL: the fast-path-reused APK did not verify:" >&2; cat "$TMPD/verify.log" >&2; exit 1; }
printf '  %-40s %s\n' 'verify-apk passes on the reused APK' 'ok'

echo "PASS: fast-path-checks"
