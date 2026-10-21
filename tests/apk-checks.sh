#!/bin/sh
# tests/apk-checks.sh
#
# End-to-end check for Aster's native APK packager (build-apk):
#   1. compile aster with the same strict flags used for release (-Werror)
#   2. source guards for the v2 (APK Signing Block) implementation
#   3. build-so a sample AArch64 library from Aster source (.ast), then build-apk
#      wraps it into a self-contained, v1 + v2 dual-signed NativeActivity APK
#   4. validate_apk.py re-derives every invariant (ZIP/CRC, layout, 4K alignment,
#      binary AXML fields, the full v1 JAR signature chain incl. openssl verify,
#      and the whole v2 APK Signing Block: structure, RSA signature, and a
#      from-scratch recomputation of the chunked content digest)
#   5. mutation checks: tampering that v1 cannot see but v2 must catch, stripping
#      the v2 block (downgrade attack), corrupting the v2 signature, and removing
#      the anti-stripping attribute from the compiler itself
#   6. reproducibility + the packaged .so must equal build-so's output
#
# No external Android toolchain (aapt / d8 / apksigner / zipalign / NDK) is involved.
# Since v0.23.4 every build is signed with a key from a keystore directory, never
# with one baked into the binary, so all builds pass --keystore-dir.
#
# Override points (env vars): ASTER_BIN, SO, APK, PKG, LIB, ABI, KEY_DIR
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ASTER_BIN="${ASTER_BIN:-/tmp/aster-apk-test}"
SO="${SO:-/tmp/aster-apk-test.so}"
APK="${APK:-/tmp/aster-apk-test.apk}"
PKG="${PKG:-com.aster.apktest}"
LIB="${LIB:-apktest}"
ABI="${ABI:-arm64-v8a}"
KEY_DIR="${KEY_DIR:-/tmp/aster-apk-keys}"

echo "[1/7] compiling aster (strict: -Wall -Wextra -Werror)"
c++ -std=c++17 -O2 -Wall -Wextra -Werror -o "$ASTER_BIN" src/aster.cpp

# The test project's debug key. Generating it up front keeps every build below
# signed by the same key, which is what makes the reproducibility check meaningful.
echo "[1/7] generating the test project's debug key in $KEY_DIR"
rm -rf "$KEY_DIR" && mkdir -p "$KEY_DIR"
"$ASTER_BIN" keygen --dir "$KEY_DIR" > /dev/null

echo "[2/7] v2 source guards"
python3 - <<'PY'
import sys
src = open('src/aster.cpp').read()
needles = [
    # APK Signing Block framing
    ('namespace APKv2', 'v2 signing module'),
    ('0x7109871a', 'v2 block ID'),
    ("'A','P','K',' ','S','i','g',' ','B','l','o','c','k',' ','4','2'", 'APK Sig Block 42 magic'),
    ('(uint64_t)(pair.size() + 24)', 'block size = pairs + 24'),
    # signature algorithm: deterministic PKCS#1 v1.5 + SHA-256, matching rsaSign()
    ('kAlgRsaPkcs1Sha256 = 0x0103', 'algorithm ID 0x0103'),
    # chunked content digest framing, straight out of the v2 spec
    ('0xa5', 'chunk prefix byte'),
    ('0x5a', 'top-level digest prefix byte'),
    ('kChunk = 1024u * 1024u', '1 MiB chunk size'),
    # the subtle EOCD rule: digest the record with the CD offset pointing at the
    # Signing Block, then write the record with the real CD offset
    ('eocdForDigest = makeEocd((uint32_t)sbStart)', 'EOCD digested with CD offset = Signing Block start'),
    ('makeEocd((uint32_t)(sbStart + sb.size()))', 'EOCD written with the real CD offset'),
    # anti-stripping: v1 has to declare that a v2 signature exists
    ('X-Android-APK-Signed: 2', 'anti-stripping attribute'),
    # the v2 public key is lifted out of the certificate, never duplicated
    ('certSubjectPublicKeyInfo', 'public key taken from the certificate'),
    # --- v0.23.4: the key is a parameter, not a constant baked into the binary
    ('struct SigningKey', 'signing key abstraction'),
    ('rsaSign(const std::vector<uint8_t>& hash, const SigningKey& key)', 'rsaSign takes a key, not a global'),
    ('static bool rsaVerify(', 'rsaVerify: Aster can check a signature, not only make one'),
    ('debugKeyFor(', 'per-project debug key'),
    ('release signing key not provided', 'release mode fails closed without a key'),
    ('--sign-mode', 'sign-mode CLI option'),
    ('--keystore-dir', 'keystore-dir CLI option'),
    ('static int keygenCommand(', 'aster keygen'),
    ('millerRabin', 'prime generation for keygen'),
    ('namespace Verify', 'the built-in APK verifier'),
    ('Verify::verify(apk, log)', 'build-apk verifies the APK it just built'),
]
missing = [what for needle, what in needles if needle not in src]
if missing:
    print('FAIL: v2 source guards missing: %s' % missing)
    sys.exit(1)
# v3 must NOT be implemented (deliberate: v3 only adds key rotation, which a
# per-project debug key has no use for -- see ROADMAP v0.23.3-dev).
for bad in ('0xf05368c0', '0x1b93ad61'):
    if bad in src:
        print('FAIL: unexpected v3 signature code in the packager (%s)' % bad)
        sys.exit(1)
# nor may any key material still be compiled in: since v0.23.4 every APK is
# signed with a key Aster is given, so there is nothing left to hardcode.
for bad, what in (('AsterDevKey', 'the embedded v0.23.3 development key'),
                  ('aster_apk_key.h', 'a header holding key material')):
    if bad in src:
        print('FAIL: %s is still in the packager' % what)
        sys.exit(1)
import os
if os.path.exists('src/aster_apk_key.h'):
    print('FAIL: src/aster_apk_key.h still exists')
    sys.exit(1)
print('PASS: all %d v2 source guards present, no v3 code, no embedded key' % len(needles))
PY

echo "[3/7] build-so examples/so_math.ast -> $SO"
"$ASTER_BIN" build-so examples/so_math.ast -o "$SO"

echo "[3/7] build-apk $SO -> $APK"
"$ASTER_BIN" build-apk "$SO" -o "$APK" \
    --package "$PKG" --libname "$LIB" --abi "$ABI" \
    --label "Aster APK Test" --min-sdk 24 --target-sdk 34 \
    --version-code 1 --version-name "1.0" --keystore-dir "$KEY_DIR"

echo "[3/7] validating APK (v1 + v2)"
python3 tests/validate_apk.py "$APK" --package "$PKG" --libname "$LIB" --abi "$ABI"
# validate_apk.py exits 0 on ALL CHECKS PASSED, 1 on failure.

# --- native_activity example: external NDK imports + full manifest semantics ---
# This exercises the auto-emitted DT_NEEDED (liblog.so via __android_log_print) and
# verifies the binary AXML attributes encode real string values, not pool index 0.
echo "[3/7] build-so examples/native_activity.ast -> /tmp/aster-native.so"
"$ASTER_BIN" build-so examples/native_activity.ast -o /tmp/aster-native.so

echo "[3/7] build-apk /tmp/aster-native.so -> /tmp/aster-native.apk"
"$ASTER_BIN" build-apk /tmp/aster-native.so -o /tmp/aster-native.apk \
    --package com.aster.nativeapp --libname nativeapp --abi "$ABI" \
    --label "Aster Native" --min-sdk 24 --target-sdk 34 \
    --version-code 1 --version-name "1.0" --keystore-dir "$KEY_DIR"

echo "[3/7] validating native APK (DT_NEEDED auto-emit + manifest semantics)"
python3 tests/validate_apk.py /tmp/aster-native.apk \
    --package com.aster.nativeapp --libname nativeapp --abi "$ABI"

# --- native_render example: software rendering via ANativeWindow + FuncAddr callback ---
# Exercises the newer capabilities: taking a function's address to populate the
# ANativeActivity callbacks table, reading/writing 64-bit pointers (load_ptr / *p=ptr),
# global-array addressing, and auto DT_NEEDED for libandroid (ANativeWindow_*). Unlike the
# log-only example this draws a visible gradient frame, so the app can be verified by eye
# on a device without adb logcat.
echo "[3/7] build-so examples/native_render.ast -> /tmp/aster-render.so"
"$ASTER_BIN" build-so examples/native_render.ast -o /tmp/aster-render.so

echo "[3/7] build-apk /tmp/aster-render.so -> /tmp/aster-render.apk"
"$ASTER_BIN" build-apk /tmp/aster-render.so -o /tmp/aster-render.apk \
    --package com.aster.renderapp --libname renderapp --abi "$ABI" \
    --label "Aster Render" --min-sdk 24 --target-sdk 34 \
    --version-code 1 --version-name "1.0" --keystore-dir "$KEY_DIR"

echo "[3/7] validating render APK (FuncAddr callback + libandroid DT_NEEDED + manifest)"
python3 tests/validate_apk.py /tmp/aster-render.apk \
    --package com.aster.renderapp --libname renderapp --abi "$ABI"

# --- one-step path: build-apk accepts .ast directly (v0.22.47-dev) ---
# Compilation and packaging stay separate concerns, but the common "source ->
# installable APK" case no longer needs a manual build-so first. The .so is
# still built with the identical pipeline (kept here via --emit-so) and must
# validate byte-for-byte like the two-step build.
echo "[3/7] build-apk examples/so_math.ast -> /tmp/aster-direct.apk (no separate build-so)"
"$ASTER_BIN" build-apk examples/so_math.ast -o /tmp/aster-direct.apk \
    --package "$PKG" --libname "$LIB" --abi "$ABI" \
    --label "Aster APK Test" --min-sdk 24 --target-sdk 34 \
    --version-code 1 --version-name "1.0" --keystore-dir "$KEY_DIR" \
    --emit-so /tmp/aster-direct.so

echo "[3/7] validating one-step APK + emitted .so"
python3 tests/validate_apk.py /tmp/aster-direct.apk --package "$PKG" --libname "$LIB" --abi "$ABI"

echo "[3/7] one-step APK must package the same code as the two-step build"
# The one-step path compiles with DT_SONAME lib<libname>.so (matching the path the
# .so is packaged at), so the reference is the two-step build with the same soname.
"$ASTER_BIN" build-so examples/so_math.ast -o /tmp/aster-ref.so --soname "lib$LIB.so"
python3 - <<'PY'
import zipfile
a = zipfile.ZipFile('/tmp/aster-direct.apk').read('lib/arm64-v8a/libapktest.so')
b = open('/tmp/aster-ref.so', 'rb').read()
assert a == b, 'one-step .so differs from the two-step build with the same DT_SONAME'
print('PASS: one-step .so is byte-identical to the two-step build with the same DT_SONAME')
PY

# ---------------------------------------------------------------------------
# [4/7] APK mutation checks. Each mutation produces an APK that must be rejected
# by validate_apk.py. Without these, the v2 checks could pass on a block that is
# never actually consulted.
# ---------------------------------------------------------------------------
echo "[4/7] v2 mutation: flip a byte no v1 digest covers"
# The 4 KiB alignment padding between AndroidManifest.xml and the .so lies inside
# the region v2 protects (everything before the Signing Block) but outside every
# entry payload, so every CRC-32 and every MANIFEST/SF digest still passes. Only
# the v2 chunked content digest can see this edit.
python3 - <<'PY'
import struct
raw = open('/tmp/aster-apk-test.apk', 'rb').read()
MAG = b"APK Sig Block 42"
i = raw.find(MAG)
sb_start = i + 16 - (struct.unpack_from('<Q', raw, i - 8)[0] + 8)
# walk the local file headers to find the gap between entries
offs = []
p = raw.find(b"PK\x03\x04")
while p != -1 and p < sb_start:
    nl, el = struct.unpack_from('<HH', raw, p + 26)
    end = p + 30 + nl + el + struct.unpack_from('<I', raw, p + 18)[0]
    offs.append((p, end))
    p = raw.find(b"PK\x03\x04", end)
gaps = [(offs[k][1], offs[k + 1][0]) for k in range(len(offs) - 1) if offs[k + 1][0] > offs[k][1]]
assert gaps, 'expected alignment padding between two entries'
off = gaps[0][0]
m = bytearray(raw)
m[off] ^= 0xFF
open('/tmp/aster-v2-padding.apk', 'wb').write(bytes(m))
print('   flipped alignment-padding byte at offset %d' % off)
PY
if python3 tests/validate_apk.py /tmp/aster-v2-padding.apk > /tmp/aster-v2-padding.log 2>&1; then
    echo "FAIL: padding-byte tampering was accepted (v2 digest is not being checked)"; exit 1
fi
grep -q "v2 CHUNKED_SHA256 content digest mismatch" /tmp/aster-v2-padding.log || {
    echo "FAIL: padding-byte tampering was rejected, but not by the v2 digest:"; cat /tmp/aster-v2-padding.log; exit 1; }
echo "PASS: padding-byte tampering rejected by the v2 content digest (v1 cannot see it)"

echo "[4/7] v2 mutation: strip the Signing Block (downgrade to v1)"
python3 - <<'PY'
import struct
raw = open('/tmp/aster-apk-test.apk', 'rb').read()
MAG = b"APK Sig Block 42"
i = raw.find(MAG)
sb_end = i + 16
blk = struct.unpack_from('<Q', raw, sb_end - 24)[0]
sb_start = sb_end - (blk + 8)
eocd = raw.rfind(b"PK\x05\x06")
out = bytearray(raw[:sb_start] + raw[sb_end:])
off = eocd - (sb_end - sb_start)
# an attacker would also repoint the EOCD at the Central Directory so the ZIP
# still opens; do that, so this really is the classic downgrade attack
out[off + 16:off + 20] = struct.pack('<I', sb_start)
open('/tmp/aster-v2-stripped.apk', 'wb').write(bytes(out))
PY
if python3 tests/validate_apk.py /tmp/aster-v2-stripped.apk > /tmp/aster-v2-stripped.log 2>&1; then
    echo "FAIL: an APK with the v2 block stripped was accepted"; exit 1
fi
echo "PASS: v2-stripped APK rejected (anti-stripping attribute makes the downgrade visible)"

echo "[4/7] v2 mutation: corrupt the v2 signature bytes"
python3 - <<'PY'
import struct
raw = open('/tmp/aster-apk-test.apk', 'rb').read()
MAG = b"APK Sig Block 42"
i = raw.find(MAG)
sb_end = i + 16
blk = struct.unpack_from('<Q', raw, sb_end - 24)[0]
sb_start = sb_end - (blk + 8)
v2base = sb_start + 8 + 8 + 4
signer_off = v2base + 4 + 4
sd_len = struct.unpack_from('<I', raw, signer_off)[0]
el_off = signer_off + 4 + sd_len + 4            # signatures sequence -> first element
sig_off = el_off + 12
out = bytearray(raw)
for k in range(sig_off, sig_off + 8):
    out[k] ^= 0xAA
open('/tmp/aster-v2-badsig.apk', 'wb').write(bytes(out))
print('   corrupted 8 bytes of the 0x0103 signature at offset %d' % sig_off)
PY
if python3 tests/validate_apk.py /tmp/aster-v2-badsig.apk > /tmp/aster-v2-badsig.log 2>&1; then
    echo "FAIL: an APK with a corrupted v2 signature was accepted"; exit 1
fi
grep -q "v2 signature over signed-data did not verify" /tmp/aster-v2-badsig.log || {
    echo "FAIL: corrupted signature rejected for the wrong reason:"; cat /tmp/aster-v2-badsig.log; exit 1; }
echo "PASS: corrupted v2 signature rejected by the RSASSA-PKCS1-v1_5 verify"

# ---------------------------------------------------------------------------
# [5/7] compiler mutation: drop the anti-stripping attribute from CERT.SF and
# prove the validator notices. Without this the [6g] check could pass because
# the attribute is never really required.
# ---------------------------------------------------------------------------
echo "[5/7] compiler mutation: build aster without X-Android-APK-Signed"
rm -rf /tmp/aster-apk-mut && mkdir -p /tmp/aster-apk-mut
cp src/aster.cpp /tmp/aster-apk-mut/
python3 - <<'PY'
p = '/tmp/aster-apk-mut/aster.cpp'
s = open(p).read()
old = '    sf += "X-Android-APK-Signed: 2\\r\\n";\n'
assert old in s, 'anti-stripping attribute anchor not found'
open(p, 'w').write(s.replace(old, ''))
PY
c++ -std=c++17 -O2 -Wall -Wextra -Werror -o /tmp/aster-apk-mut-bin /tmp/aster-apk-mut/aster.cpp
/tmp/aster-apk-mut-bin build-so examples/so_math.ast -o /tmp/aster-apk-mut.so > /dev/null
rm -f /tmp/aster-apk-mut.apk
# Since v0.23.4 build-apk verifies the APK in memory before writing it, so the
# mutated compiler has to reject its own output without producing a file at all.
if /tmp/aster-apk-mut-bin build-apk /tmp/aster-apk-mut.so -o /tmp/aster-apk-mut.apk \
    --package "$PKG" --libname "$LIB" --abi "$ABI" \
    --label "Aster APK Test" --min-sdk 24 --target-sdk 34 \
    --version-code 1 --version-name "1.0" --keystore-dir "$KEY_DIR" > /dev/null 2>/tmp/aster-apk-mut.err; then
    echo "FAIL: the mutated compiler accepted its own APK (self-verification has no teeth)"; exit 1
fi
grep -q "X-Android-APK-Signed" /tmp/aster-apk-mut.err || {
    echo "FAIL: mutated build rejected for the wrong reason:"; cat /tmp/aster-apk-mut.err; exit 1; }
if [ -e /tmp/aster-apk-mut.apk ]; then
    echo "FAIL: build-apk wrote an APK it had just rejected"; exit 1
fi
echo "PASS: build-apk refuses to write an APK that fails its own signature check"
# ...and the independent validator agrees, once the self-check is bypassed.
/tmp/aster-apk-mut-bin build-apk /tmp/aster-apk-mut.so -o /tmp/aster-apk-mut.apk \
    --package "$PKG" --libname "$LIB" --abi "$ABI" \
    --label "Aster APK Test" --min-sdk 24 --target-sdk 34 \
    --version-code 1 --version-name "1.0" --keystore-dir "$KEY_DIR" --no-verify > /dev/null
if python3 tests/validate_apk.py /tmp/aster-apk-mut.apk > /tmp/aster-apk-mut.log 2>&1; then
    echo "FAIL: an APK without the anti-stripping attribute was accepted"; exit 1
fi
grep -q "X-Android-APK-Signed" /tmp/aster-apk-mut.log || {
    echo "FAIL: mutated APK rejected for the wrong reason:"; cat /tmp/aster-apk-mut.log; exit 1; }
echo "PASS: missing anti-stripping attribute rejected (the [6g] guard has teeth)"

# ---------------------------------------------------------------------------
# [6/7] reproducibility: the same inputs must produce the same APK twice. Aster's
# v2 signature uses RSASSA-PKCS1-v1_5 (no salt, no nonce), so unlike the PSS
# variants (0x0101/0x0102) the whole APK stays bit-for-bit reproducible.
# ---------------------------------------------------------------------------
echo "[6/7] reproducibility: two builds of the same input must be byte-identical"
"$ASTER_BIN" build-apk "$SO" -o /tmp/aster-repro1.apk \
    --package "$PKG" --libname "$LIB" --abi "$ABI" \
    --label "Aster APK Test" --min-sdk 24 --target-sdk 34 \
    --version-code 1 --version-name "1.0" --keystore-dir "$KEY_DIR" > /dev/null
"$ASTER_BIN" build-apk "$SO" -o /tmp/aster-repro2.apk \
    --package "$PKG" --libname "$LIB" --abi "$ABI" \
    --label "Aster APK Test" --min-sdk 24 --target-sdk 34 \
    --version-code 1 --version-name "1.0" --keystore-dir "$KEY_DIR" > /dev/null
cmp /tmp/aster-repro1.apk /tmp/aster-repro2.apk
echo "PASS: build-apk is deterministic (PKCS#1 v1.5, not PSS)"

# ---------------------------------------------------------------------------
# [7/7] the .so inside the APK must be the .so build-so produced -- packaging
# must not touch the code.
# ---------------------------------------------------------------------------
echo "[7/7] the packaged .so is byte-identical to build-so's output"
python3 - <<'PY'
import zipfile
a = zipfile.ZipFile('/tmp/aster-apk-test.apk').read('lib/arm64-v8a/libapktest.so')
b = open('/tmp/aster-apk-test.so', 'rb').read()
assert a == b, 'the .so inside the APK differs from build-so output'
print('PASS: packaged .so == build-so output (%d bytes)' % len(b))
PY

echo "ALL APK CHECKS PASSED"
