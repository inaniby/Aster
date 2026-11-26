#!/bin/sh
# tests/verify-apk-nonascii-checks.sh
#
# verify-apk must accept APKs whose entry names contain non-ASCII bytes
# (e.g. UTF-8 Chinese names). Regression test for the readZip bug where the
# central-directory/local-header name comparison mixed std::string (char is
# signed on x86_64) with vector<uint8_t>: bytes >= 0x80 promoted to negative
# ints and every non-ASCII name failed with
#   "local header and central directory disagree on the name"
# even though the two copies were byte-identical. The fix compares the names
# as unsigned bytes (memcmp).
#
# The test builds a signed APK with build-apk, then inserts one Chinese-named
# entry into a *copy* of it, keeping the ZIP layout valid: the new local
# header + data go immediately before the APK Signing Block, the central
# directory gains one record, and the EOCD is updated. No binary APK is
# committed -- the tampered copy is generated on the spot with python3.
#
# A tampered APK must still FAIL overall: the added entry is not covered by
# MANIFEST.MF (v1) and the v2/v3 content digests no longer match. What the
# test asserts is that the failure moved past the name comparison:
#   1. the untouched APK verifies clean (pure-ASCII regression)
#   2. the tampered copy's section [1] (ZIP structure) passes in full, with
#      no "disagree on the name" anywhere in the output
#   3. verification reaches [2] v1 and fails there for the genuine reason
#      (the entry is not covered by MANIFEST.MF)
#   4. the same holds for a DEFLATED Chinese-named entry, not just STORED
#
# Override points (env vars): ASTER_BIN, SO, APK, PKG, LIB, ABI, KEY_DIR
set -eu
. tests/lib/tmpdir.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ASTER_BIN="${ASTER_BIN:-$TMPD/aster-verify-nonascii-test}"
SO="${SO:-$TMPD/aster-verify-nonascii.so}"
APK="${APK:-$TMPD/aster-verify-nonascii.apk}"
PKG="${PKG:-com.aster.nonascii}"
LIB="${LIB:-nonascii}"
ABI="${ABI:-arm64-v8a}"
KEY_DIR="${KEY_DIR:-$TMPD/aster-verify-nonascii-keys}"

echo "[1/4] compiling aster (strict: -Wall -Wextra -Werror)"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror -o "$ASTER_BIN" src/aster.cpp

echo "[1/4] generating the test project's debug key in $KEY_DIR"
rm -rf "$KEY_DIR" && mkdir -p "$KEY_DIR"
"$ASTER_BIN" keygen --dir "$KEY_DIR" > /dev/null

echo "[2/4] build-so examples/so_math.ast -> $SO; build-apk -> $APK"
"$ASTER_BIN" build-so examples/so_math.ast -o "$SO"
"$ASTER_BIN" build-apk "$SO" -o "$APK" \
    --package "$PKG" --libname "$LIB" --abi "$ABI" \
    --label "Aster Non-ASCII Test" --min-sdk 24 --target-sdk 34 \
    --version-code 1 --version-name "1.0" --keystore-dir "$KEY_DIR"

echo "[2/4] pure-ASCII regression: the untouched APK must verify clean"
"$ASTER_BIN" verify-apk "$APK" > "$TMPD/verify-nonascii-base.log" 2>&1
grep -q "OK (v1 + v2 + v3 signatures verified)" "$TMPD/verify-nonascii-base.log" || {
    echo "FAIL: the untouched ASCII-only APK did not verify:"; cat "$TMPD/verify-nonascii-base.log"; exit 1; }
echo "PASS: ASCII-only APK verifies (v1 + v2 + v3)"

# Insert one Chinese-named entry into a copy of the signed APK, keeping the
# ZIP layout valid (new local header + data immediately before the APK
# Signing Block, one new central-directory record, updated EOCD). The
# signatures then correctly fail -- the entry is not in MANIFEST.MF and the
# v2/v3 digests no longer match -- but section [1] must pass.
python3 - "$APK" "$TMPD" <<'PY'
import struct, sys, zlib

def insert(src_path, dst_path, name, method):
    src = open(src_path, 'rb').read()
    eocd_off = src.rfind(b'PK\x05\x06')
    assert eocd_off + 22 == len(src), 'EOCD is not at the end (archive comment?)'
    (cd_disk, cd_start_disk, n_disk, n_total, cd_size, cd_off,
     comment_len) = struct.unpack_from('<HHHHIIH', src, eocd_off + 4)
    assert n_disk == n_total and comment_len == 0
    assert cd_off + cd_size == eocd_off
    MAGIC = b'APK Sig Block 42'
    assert src[cd_off - 16:cd_off] == MAGIC, 'no signing block magic before CD'
    blk_size = struct.unpack_from('<Q', src, cd_off - 24)[0]
    sb_start = cd_off - 8 - blk_size
    assert struct.unpack_from('<Q', src, sb_start)[0] == blk_size
    content = b'verify-apk non-ASCII entry test\n'
    if method == 0:
        data, comp_size = content, len(content)
    else:
        co = zlib.compressobj(6, zlib.DEFLATED, -15)
        data = co.compress(content) + co.flush()
        comp_size = len(data)
    name_b = name.encode('utf-8')
    crc = zlib.crc32(content) & 0xFFFFFFFF
    dos_date = ((2026 - 1980) << 9) | (1 << 5) | 1  # 2026-01-01, DOS date
    local = struct.pack('<IHHHHHIIIHH', 0x04034B50, 20, 0x0800, method, 0,
                        dos_date, crc, comp_size, len(content),
                        len(name_b), 0) + name_b + data
    cd_rec = struct.pack('<IHHHHHHIIIHHHHHII', 0x02014B50, 20, 20, 0x0800,
                         method, 0, dos_date, crc, comp_size, len(content),
                         len(name_b), 0, 0, 0, 0, 0, sb_start) + name_b
    new_eocd = struct.pack('<IHHHHIIH', 0x06054B50, 0, 0, n_total + 1,
                           n_total + 1, cd_size + len(cd_rec),
                           cd_off + len(local), 0)
    out = (src[:sb_start] + local + src[sb_start:cd_off]
           + src[cd_off:eocd_off] + cd_rec + new_eocd)
    open(dst_path, 'wb').write(out)
    # python's zipfile must read the result back, non-ASCII name included.
    import zipfile
    names = zipfile.ZipFile(dst_path).namelist()
    assert name in names, 'inserted entry %r not visible to zipfile' % name

apk, tmpd = sys.argv[1], sys.argv[2]
insert(apk, tmpd + '/aster-verify-nonascii-stored.apk',
       'assets/test/\u7a97\u53e3.txt', 0)
insert(apk, tmpd + '/aster-verify-nonascii-deflated.apk',
       'assets/test/\u7a97\u53e3.txt', 8)
print('PASS: Chinese-named entries inserted (STORED + DEFLATED), layout valid')
PY

for variant in stored deflated; do
    TAMPERED="$TMPD/aster-verify-nonascii-$variant.apk"
    LOG="$TMPD/verify-nonascii-$variant.log"
    echo "[3/4] $variant Chinese entry: verify-apk must clear [1] and fail only on the (genuinely broken) signatures"
    if "$ASTER_BIN" verify-apk "$TAMPERED" > "$LOG" 2>&1; then
        echo "FAIL: a tampered APK verified clean ($variant):"; cat "$LOG"; exit 1
    fi
    grep -q "disagree on the name" "$LOG" && {
        echo "FAIL: the non-ASCII name comparison still fails ($variant):"; cat "$LOG"; exit 1; }
    grep -q "^\[2\] v1 (JAR) signature" "$LOG" || {
        echo "FAIL: verification never reached the signature checks ($variant):"; cat "$LOG"; exit 1; }
    # Section [1] must contain no FAIL line at all.
    awk '/^\[1\] ZIP structure/{s=1;next} /^\[2\] v1/{s=0} s&&/FAIL/{bad=1} END{exit bad?0:1}' "$LOG" && {
        echo "FAIL: section [1] ZIP structure failed for the $variant Chinese entry:"; cat "$LOG"; exit 1; }
    grep -q "is not covered by MANIFEST.MF" "$LOG" || {
        echo "FAIL: v1 did not fail for the genuine reason ($variant):"; cat "$LOG"; exit 1; }
    echo "PASS: $variant Chinese entry clears [1], reaches v1/v2/v3, fails only on the tampered signatures"
done

echo "[4/4] the fixed comparison is an unsigned byte comparison"
grep -qF 'std::memcmp(ze.name.data(), b.data() + localNameAt, nameLen) != 0' src/aster.cpp || {
    echo "FAIL: the readZip name comparison is not the unsigned-byte memcmp"; exit 1; }
echo "PASS: readZip compares entry names with memcmp over unsigned bytes"

echo "ALL VERIFY-APK NON-ASCII CHECKS PASSED"
