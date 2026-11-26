#!/bin/sh
# tests/apk-icon-checks.sh
#
# aster.proj `icon <path>` configures the APK launcher icon, and
# build-apk accepts the same thing as --icon <path>.
#
# The built-in icon is a generated 192x192 PNG. A configured icon replaces
# it byte for byte: the resource name (drawable/ic_launcher), the table
# entry, the manifest reference and the ZIP path
# (res/drawable-nodpi/ic_launcher.png) are all unchanged, so only the
# pixels differ. Without `icon` the behaviour is exactly what it was.
#
# A configured icon has to be a real PNG. A missing file, a non-PNG, or a
# structurally broken PNG (bad chunk CRC, truncated) is a hard error: the
# build fails and no APK is written. Silently falling back to the built-in
# icon would ship the wrong icon without anyone noticing.
#
# Checks:
#   1. strict compiler build, test key, test PNG (64x64 solid red RGBA,
#      deliberately unlike the built-in 192x192 indexed "A" glyph)
#   2. source guards for the icon plumbing
#   3. build-apk --icon: the configured PNG is packaged byte-identical,
#      verify-apk passes
#   4. aster build with `icon assets/icon.png` in aster.proj (subdirectory
#      path): same, through the project build
#   5. no icon configured: the built-in icon is used unchanged, verify-apk
#      passes
#   6. error cases (missing file, non-PNG, bad CRC, truncated PNG) all fail
#      with a clear message and write no APK
#
# Override points (env vars): ASTER_BIN, KEY_DIR
set -eu
. tests/lib/tmpdir.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ASTER_BIN="${ASTER_BIN:-$TMPD/aster-apk-icon-test}"
KEY_DIR="${KEY_DIR:-$TMPD/aster-apk-icon-keys}"

echo "[1/6] compiling aster (strict: -Wall -Wextra -Werror)"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror -o "$ASTER_BIN" src/aster.cpp

echo "[1/6] generating the test project's debug key in $KEY_DIR"
rm -rf "$KEY_DIR" && mkdir -p "$KEY_DIR"
"$ASTER_BIN" keygen --dir "$KEY_DIR" > /dev/null

echo "[1/6] generating the test PNG (64x64 solid red RGBA)"
python3 - "$TMPD" <<'PY'
import struct, sys, zlib
def chunk(t, data):
    c = t + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)
w, h = 64, 64
raw = b''.join(b'\x00' + b'\xff\x00\x00\xff' * w for _ in range(h))
z = zlib.compress(raw)
ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', z) + chunk(b'IEND', b'')
open(sys.argv[1] + '/red64.png', 'wb').write(png)
print('test PNG written:', len(png), 'bytes')
PY

echo "[2/6] source guards: icon plumbing"
grep -qF 'std::string icon;' src/aster.cpp || { echo 'FAIL: ProjectSpec.icon missing'; exit 1; }
grep -qF 'else if(k=="icon")' src/aster.cpp || { echo 'FAIL: parseProjectFile icon key missing'; exit 1; }
grep -qF 'const std::vector<uint8_t>& iconBytes = {}' src/aster.cpp || { echo 'FAIL: buildApk iconBytes parameter missing'; exit 1; }
grep -qF 'static std::pair<int,int> validate(const std::vector<uint8_t>& png, const std::string& what)' src/aster.cpp || { echo 'FAIL: PNG::validate missing'; exit 1; }
grep -qF 'static std::vector<uint8_t> loadIconBytes(' src/aster.cpp || { echo 'FAIL: loadIconBytes missing'; exit 1; }
echo "PASS: icon plumbing present in source"

echo "[3/6] build-apk --icon: configured PNG packaged byte-identical, verify-apk passes"
"$ASTER_BIN" build-so examples/so_math.ast -o "$TMPD/icon.so"
"$ASTER_BIN" build-apk "$TMPD/icon.so" -o "$TMPD/icon.apk" \
    --package com.aster.icontest --libname icontest --abi arm64-v8a \
    --label "Icon Test" --icon "$TMPD/red64.png" --keystore-dir "$KEY_DIR" > "$TMPD/icon-build.log" 2>&1
grep -q "using launcher icon .* (64x64)" "$TMPD/icon-build.log" || {
    echo 'FAIL: build did not report using the icon:'; cat "$TMPD/icon-build.log"; exit 1; }
python3 - "$TMPD/icon.apk" "$TMPD/red64.png" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
got = z.read('res/drawable-nodpi/ic_launcher.png')
want = open(sys.argv[2], 'rb').read()
assert got == want, 'icon in APK differs from the configured PNG'
print('PASS: icon in APK is byte-identical to the configured PNG')
PY
"$ASTER_BIN" verify-apk "$TMPD/icon.apk" > "$TMPD/icon-verify.log" 2>&1
grep -q "OK (v1 + v2 + v3 signatures verified)" "$TMPD/icon-verify.log" || {
    echo 'FAIL: custom-icon APK did not verify:'; cat "$TMPD/icon-verify.log"; exit 1; }
echo "PASS: build-apk --icon packages the configured PNG, verify-apk passes"

echo "[4/6] aster build with icon in aster.proj (subdirectory path)"
mkdir -p "$TMPD/proj" && cd "$TMPD/proj"
ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" new --apk IconApp > /dev/null
mkdir -p IconApp/assets && cp "$TMPD/red64.png" IconApp/assets/icon.png
printf 'icon assets/icon.png\n' >> IconApp/aster.proj
cd IconApp
ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build > "$TMPD/proj-build.log" 2>&1
grep -q "using launcher icon assets/icon.png (64x64)" "$TMPD/proj-build.log" || {
    echo 'FAIL: project build did not report using the icon:'; cat "$TMPD/proj-build.log"; exit 1; }
python3 - "build/IconApp.apk" "$TMPD/red64.png" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
got = z.read('res/drawable-nodpi/ic_launcher.png')
want = open(sys.argv[2], 'rb').read()
assert got == want, 'icon in APK differs from the configured PNG'
print('PASS: project build packaged the configured PNG byte-identical')
PY
ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" verify-apk "build/IconApp.apk" > "$TMPD/proj-verify.log" 2>&1
grep -q "OK (v1 + v2 + v3 signatures verified)" "$TMPD/proj-verify.log" || {
    echo 'FAIL: project-built custom-icon APK did not verify:'; cat "$TMPD/proj-verify.log"; exit 1; }
echo "PASS: aster build with icon in aster.proj packages the configured PNG, verify-apk passes"
cd "$ROOT"

echo "[5/6] no icon configured: the built-in icon is used unchanged"
mkdir -p "$TMPD/plain" && cd "$TMPD/plain"
ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" new --apk PlainApp > /dev/null
cd PlainApp
ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build > "$TMPD/plain-build.log" 2>&1
grep -q "using launcher icon" "$TMPD/plain-build.log" && {
    echo 'FAIL: build without icon reported using one:'; cat "$TMPD/plain-build.log"; exit 1; }
python3 - "build/PlainApp.apk" "$TMPD/red64.png" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
got = z.read('res/drawable-nodpi/ic_launcher.png')
want = open(sys.argv[2], 'rb').read()
assert got != want, 'icon in APK equals the test PNG although none was configured'
assert got[:8] == b'\x89PNG\r\n\x1a\n', 'built-in icon is not a PNG'
print('PASS: built-in icon present (%d bytes), not the test PNG' % len(got))
PY
ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" verify-apk "build/PlainApp.apk" > "$TMPD/plain-verify.log" 2>&1
grep -q "OK (v1 + v2 + v3 signatures verified)" "$TMPD/plain-verify.log" || {
    echo 'FAIL: default-icon APK did not verify:'; cat "$TMPD/plain-verify.log"; exit 1; }
echo "PASS: no icon configured keeps the built-in icon, verify-apk passes"
cd "$ROOT"

echo "[6/6] error cases: missing file, non-PNG, bad CRC, truncated PNG"
# Missing file.
mkdir -p "$TMPD/err-missing" && cd "$TMPD/err-missing"
ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" new --apk MissApp > /dev/null
printf 'icon no-such-icon.png\n' >> MissApp/aster.proj
cd MissApp
if ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build > "$TMPD/err-missing.log" 2>&1; then
    echo 'FAIL: build with a missing icon file succeeded'; exit 1
fi
grep -q "cannot open input: no-such-icon.png" "$TMPD/err-missing.log" || {
    echo 'FAIL: missing icon file did not name the file:'; cat "$TMPD/err-missing.log"; exit 1; }
test ! -e build/MissApp.apk || { echo 'FAIL: APK was written despite the missing icon'; exit 1; }
echo "PASS: missing icon file fails with a clear error, no APK written"
cd "$ROOT"
# Not a PNG.
mkdir -p "$TMPD/err-notpng" && cd "$TMPD/err-notpng"
ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" new --apk NotPngApp > /dev/null
printf 'this is not a png at all, just text\n' > NotPngApp/fake.png
printf 'icon fake.png\n' >> NotPngApp/aster.proj
cd NotPngApp
if ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build > "$TMPD/err-notpng.log" 2>&1; then
    echo 'FAIL: build with a non-PNG icon succeeded'; exit 1
fi
grep -q "not a valid PNG (missing PNG signature)" "$TMPD/err-notpng.log" || {
    echo 'FAIL: non-PNG icon did not report the signature:'; cat "$TMPD/err-notpng.log"; exit 1; }
test ! -e build/NotPngApp.apk || { echo 'FAIL: APK was written despite the non-PNG icon'; exit 1; }
echo "PASS: non-PNG icon fails with a clear error, no APK written"
cd "$ROOT"
# Bad CRC (flip a byte in the IDAT chunk's CRC) and truncated PNG (no IEND).
python3 - "$TMPD" <<'PY'
import struct, sys, zlib
def chunk(t, data):
    c = t + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)
w, h = 32, 32
raw = b''.join(b'\x00' + b'\x00\xff\x00\xff' * w for _ in range(h))
z = zlib.compress(raw)
ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)
good = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', z) + chunk(b'IEND', b'')
bad = bytearray(good)
# The IDAT CRC is the 4 bytes right before the IEND chunk (12 bytes at the end).
bad[-13] ^= 0xFF
open(sys.argv[1] + '/bad-crc.png', 'wb').write(bad)
open(sys.argv[1] + '/trunc.png', 'wb').write(good[:-12])
print('bad-CRC and truncated test PNGs written')
PY
mkdir -p "$TMPD/err-badcrc" && cd "$TMPD/err-badcrc"
ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" new --apk BadCrcApp > /dev/null
cp "$TMPD/bad-crc.png" BadCrcApp/bad.png
printf 'icon bad.png\n' >> BadCrcApp/aster.proj
cd BadCrcApp
if ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build > "$TMPD/err-badcrc.log" 2>&1; then
    echo 'FAIL: build with a bad-CRC icon succeeded'; exit 1
fi
grep -q "not a valid PNG (IDAT chunk CRC mismatch)" "$TMPD/err-badcrc.log" || {
    echo 'FAIL: bad-CRC icon did not report the CRC:'; cat "$TMPD/err-badcrc.log"; exit 1; }
test ! -e build/BadCrcApp.apk || { echo 'FAIL: APK was written despite the bad-CRC icon'; exit 1; }
echo "PASS: bad-CRC icon fails with a clear error, no APK written"
cd "$ROOT"
mkdir -p "$TMPD/err-trunc" && cd "$TMPD/err-trunc"
ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" new --apk TruncApp > /dev/null
cp "$TMPD/trunc.png" TruncApp/trunc.png
printf 'icon trunc.png\n' >> TruncApp/aster.proj
cd TruncApp
if ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build > "$TMPD/err-trunc.log" 2>&1; then
    echo 'FAIL: build with a truncated icon succeeded'; exit 1
fi
grep -q "not a valid PNG (missing IEND)" "$TMPD/err-trunc.log" || {
    echo 'FAIL: truncated icon did not report the missing IEND:'; cat "$TMPD/err-trunc.log"; exit 1; }
test ! -e build/TruncApp.apk || { echo 'FAIL: APK was written despite the truncated icon'; exit 1; }
echo "PASS: truncated icon fails with a clear error, no APK written"
cd "$ROOT"

echo "[6/6] the packaged icon is the one buildApk was given"
grep -qF 'std::vector<uint8_t> icon = iconBytes.empty() ? PNG::build(192, 192) : iconBytes;' src/aster.cpp || {
    echo 'FAIL: buildApk does not use the supplied icon bytes'; exit 1; }
echo "PASS: buildApk uses the supplied icon bytes, built-in otherwise"

echo "ALL APK ICON CHECKS PASSED"
