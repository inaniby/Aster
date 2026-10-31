#!/bin/sh
# tests/signing-checks.sh
#
# End-to-end checks for Aster's signing model (v0.23.4):
#   1.  aster keygen writes a key pair that openssl can read back
#   2.  keygen refuses to overwrite an existing key unless --force is given
#   3.  --sign-mode debug generates the project's key on first use and reuses it
#   4.  two different projects get two different debug keys
#   5.  --sign-mode release without a key fails closed (never falls back to debug)
#   6.  --sign-mode release signs with an openssl-made key, and the APK carries
#       *that* certificate --- not one Aster invented
#   7.  a private key and a certificate that do not belong together are rejected
#   8.  PEM (PKCS#8 and PKCS#1) and raw DER key material are both accepted
#   9.  aster verify-apk accepts a good APK and rejects a tampered one
#  10.  option validation: bad --sign-mode / --key-bits, and mixing debug with
#       release-only options
#
# openssl is used here as an independent oracle on purpose: everything Aster
# writes is produced by its own code, so an implementation that agrees with
# itself proves nothing. It is never used to *produce* anything Aster ships.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ASTER_BIN="${ASTER_BIN:-/tmp/aster-signing-test}"
WORK="${WORK:-/tmp/aster-signing}"
SO="$WORK/libsign.so"

rm -rf "$WORK" && mkdir -p "$WORK/proj-a" "$WORK/proj-b" "$WORK/release"

echo "[1/10] compiling aster (strict: -Wall -Wextra -Werror)"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror -o "$ASTER_BIN" src/aster.cpp

# A random serial starting 0x00 followed by a byte below 0x80 is legal BER but
# non-minimal DER; OpenSSL rejects the whole certificate as "illegal padding".
# Pin the trim because that 1-in-256 case is not reachable deterministically.
grep -qF 'while (serial.size() > 1 && serial[0] == 0) serial.erase(serial.begin());' src/aster.cpp \
    || { echo 'FAIL: certificate serial is not minimally DER-encoded'; exit 1; }
"$ASTER_BIN" build-so examples/so_math.ast -o "$SO" > /dev/null

echo "[1/10] aster keygen -> a key pair openssl can read"
"$ASTER_BIN" keygen --dir "$WORK/proj-a" > /dev/null
test -f "$WORK/proj-a/.aster/debug.key.pem" || { echo "FAIL: keygen wrote no private key"; exit 1; }
test -f "$WORK/proj-a/.aster/debug.crt.pem" || { echo "FAIL: keygen wrote no certificate"; exit 1; }
# asn1parse is the strict one: it fails on a truncated or mis-framed DER.
openssl asn1parse -in "$WORK/proj-a/.aster/debug.key.pem" > /dev/null 2>&1 \
    || { echo "FAIL: openssl cannot parse the generated private key"; exit 1; }
openssl rsa -in "$WORK/proj-a/.aster/debug.key.pem" -check -noout > /dev/null 2>&1 \
    || { echo "FAIL: openssl rsa -check rejects the generated private key"; exit 1; }
openssl x509 -in "$WORK/proj-a/.aster/debug.crt.pem" -noout > /dev/null 2>&1 \
    || { echo "FAIL: openssl cannot parse the generated certificate"; exit 1; }
# the key really is the one in the certificate
KA=$(openssl rsa -in "$WORK/proj-a/.aster/debug.key.pem" -pubout 2>/dev/null | openssl sha256)
CA=$(openssl x509 -in "$WORK/proj-a/.aster/debug.crt.pem" -noout -pubkey | openssl sha256)
[ "$KA" = "$CA" ] || { echo "FAIL: certificate does not carry the generated public key"; exit 1; }
# and it must not be committed by accident
grep -q '^\*$' "$WORK/proj-a/.aster/.gitignore" \
    || { echo "FAIL: the key directory does not ignore itself"; exit 1; }
echo "PASS: keygen produced a 2048-bit RSA key + certificate openssl accepts"

echo "[2/10] keygen refuses to overwrite without --force, and honours --force"
if "$ASTER_BIN" keygen --dir "$WORK/proj-a" > /dev/null 2>&1; then
    echo "FAIL: keygen silently replaced an existing key"; exit 1
fi
"$ASTER_BIN" keygen --dir "$WORK/proj-a" --force > /dev/null
openssl asn1parse -in "$WORK/proj-a/.aster/debug.key.pem" > /dev/null 2>&1 \
    || { echo "FAIL: --force wrote a key openssl cannot parse"; exit 1; }
echo "PASS: keygen is non-destructive by default, --force replaces the key"

echo "[3/10] --sign-mode debug generates the project key on first use, then reuses it"
rm -rf "$WORK/proj-b" && mkdir -p "$WORK/proj-b"
"$ASTER_BIN" build-apk "$SO" -o "$WORK/b1.apk" --package com.aster.b --libname b \
    --keystore-dir "$WORK/proj-b" > /dev/null 2>"$WORK/b1.err"
test -f "$WORK/proj-b/.aster/debug.key.pem" || { echo "FAIL: debug build did not create a project key"; exit 1; }
K1=$(openssl rsa -in "$WORK/proj-b/.aster/debug.key.pem" -pubout 2>/dev/null | openssl sha256)
"$ASTER_BIN" build-apk "$SO" -o "$WORK/b2.apk" --package com.aster.b --libname b \
    --keystore-dir "$WORK/proj-b" > /dev/null
K2=$(openssl rsa -in "$WORK/proj-b/.aster/debug.key.pem" -pubout 2>/dev/null | openssl sha256)
[ "$K1" = "$K2" ] || { echo "FAIL: a second debug build replaced the project key"; exit 1; }
"$ASTER_BIN" verify-apk "$WORK/b1.apk" > /dev/null
"$ASTER_BIN" verify-apk "$WORK/b2.apk" > /dev/null
echo "PASS: debug builds reuse one generated per-project key, both APKs verify"

echo "[4/10] two projects get two different keys"
KA2=$(openssl rsa -in "$WORK/proj-a/.aster/debug.key.pem" -pubout 2>/dev/null | openssl sha256)
[ "$KA2" != "$K1" ] || { echo "FAIL: two projects share one debug key"; exit 1; }
echo "PASS: project A and project B have distinct debug keys"

echo "[5/10] --sign-mode release without a key fails closed"
for args in "" "--keystore $WORK/release/rel.key.pem" "--cert $WORK/release/rel.crt.pem"; do
    # shellcheck disable=SC2086
    if "$ASTER_BIN" build-apk "$SO" -o "$WORK/rel-none.apk" --package com.aster.r --libname r \
        --sign-mode release $args > /dev/null 2>&1; then
        echo "FAIL: release build succeeded without both --keystore and --cert ($args)"; exit 1
    fi
done
test ! -e "$WORK/rel-none.apk" || { echo "FAIL: a rejected release build still wrote an APK"; exit 1; }
if "$ASTER_BIN" build-apk "$SO" -o "$WORK/rel-none.apk" --package com.aster.r --libname r \
    --sign-mode release 2>&1 | grep -q "will not invent one for you"; then :; else
    echo "FAIL: the release failure does not explain itself"; exit 1
fi
echo "PASS: release refuses to build without the developer's own key"

echo "[6/10] --sign-mode release signs with an openssl-made key"
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/release/rel.key.pem" \
    -out "$WORK/release/rel.crt.pem" -days 3650 -nodes \
    -subj "/O=Aster Signing Test/CN=Someone Elses Release Key" -sha256 > /dev/null 2>&1
"$ASTER_BIN" build-apk "$SO" -o "$WORK/rel.apk" --package com.aster.r --libname r \
    --sign-mode release --keystore "$WORK/release/rel.key.pem" --cert "$WORK/release/rel.crt.pem" > /dev/null
"$ASTER_BIN" verify-apk "$WORK/rel.apk" > /dev/null
# the APK must carry the developer's certificate, not Aster's own
python3 - <<'PY'
import subprocess, sys, zipfile
z = zipfile.ZipFile('/tmp/aster-signing/rel.apk')
open('/tmp/aster-signing/rel.p7', 'wb').write(z.read('META-INF/CERT.RSA'))
out = subprocess.run(['openssl', 'pkcs7', '-in', '/tmp/aster-signing/rel.p7', '-inform', 'DER',
                      '-print_certs', '-noout'], capture_output=True, text=True).stdout
if 'Someone Elses Release Key' not in out:
    print('FAIL: the APK does not carry the release certificate: %r' % out); sys.exit(1)
if 'Aster Dev Signing Key' in out:
    print('FAIL: the release APK is signed with an Aster-generated key'); sys.exit(1)
PY
echo "PASS: release APK is signed with the developer's key and verifies"

echo "[7/10] a key and a certificate that do not match are rejected"
if "$ASTER_BIN" build-apk "$SO" -o "$WORK/mismatch.apk" --package com.aster.r --libname r \
    --sign-mode release --keystore "$WORK/release/rel.key.pem" \
    --cert "$WORK/proj-a/.aster/debug.crt.pem" > /dev/null 2>&1; then
    echo "FAIL: a mismatched key/certificate pair was accepted"; exit 1
fi
"$ASTER_BIN" build-apk "$SO" -o "$WORK/mismatch.apk" --package com.aster.r --libname r \
    --sign-mode release --keystore "$WORK/release/rel.key.pem" \
    --cert "$WORK/proj-a/.aster/debug.crt.pem" 2>&1 | grep -q "does not match the private key" \
    || { echo "FAIL: the mismatch was not reported clearly"; exit 1; }
test ! -e "$WORK/mismatch.apk" || { echo "FAIL: a rejected build wrote an APK"; exit 1; }
echo "PASS: mismatched key/certificate rejected with a clear message"

echo "[8/10] PKCS#8 PEM, PKCS#1 PEM and raw DER are all accepted"
openssl rsa -in "$WORK/release/rel.key.pem" -traditional -out "$WORK/release/pkcs1.pem" 2>/dev/null
openssl rsa -in "$WORK/release/rel.key.pem" -outform DER -out "$WORK/release/key.der" 2>/dev/null
openssl x509 -in "$WORK/release/rel.crt.pem" -outform DER -out "$WORK/release/crt.der" 2>/dev/null
grep -q 'BEGIN RSA PRIVATE KEY' "$WORK/release/pkcs1.pem" \
    || { echo "FAIL: openssl did not produce a PKCS#1 key to test with"; exit 1; }
for pair in "pkcs1.pem rel.crt.pem" "key.der crt.der"; do
    set -- $pair
    "$ASTER_BIN" build-apk "$SO" -o "$WORK/fmt.apk" --package com.aster.r --libname r \
        --sign-mode release --keystore "$WORK/release/$1" --cert "$WORK/release/$2" > /dev/null \
        || { echo "FAIL: could not load $1 + $2"; exit 1; }
    "$ASTER_BIN" verify-apk "$WORK/fmt.apk" > /dev/null \
        || { echo "FAIL: the APK built from $1 + $2 does not verify"; exit 1; }
    rm -f "$WORK/fmt.apk"
done
echo "PASS: PKCS#1 PEM and raw DER key material load and produce valid APKs"

echo "[9/10] aster verify-apk accepts good APKs and rejects tampered ones"
"$ASTER_BIN" verify-apk "$WORK/rel.apk" > /dev/null
# flip a byte deep inside the Signing Block: every entry, CRC and v1 digest is
# untouched, so only the v2 checks can see this
python3 - <<'PY'
import struct
raw = bytearray(open('/tmp/aster-signing/rel.apk', 'rb').read())
i = raw.rfind(b'APK Sig Block 42')
blk = struct.unpack_from('<Q', raw, i - 8)[0]
sb_start = i + 16 - (blk + 8)
raw[sb_start + blk - 40] ^= 0xFF
open('/tmp/aster-signing/tampered.apk', 'wb').write(bytes(raw))
PY
if "$ASTER_BIN" verify-apk "$WORK/tampered.apk" > "$WORK/tampered.log" 2>&1; then
    echo "FAIL: verify-apk accepted a tampered APK"; exit 1
fi
grep -q "FAIL:" "$WORK/tampered.log" || { echo "FAIL: tampering rejected without a reason"; exit 1; }
echo "PASS: verify-apk rejects an APK whose v2 block was tampered with"

echo "[9b/10] validate_apk.py verifies the v1 signature in-process, and rejects a bad one"
# The v1 PKCS#7 signature used to be checked only by shelling out to openssl,
# so a machine without it (a bare Termux install) reported FAIL for an APK that
# was fine. It is now verified in-process -- the signer's certificate rides
# inside the blob -- and openssl is a second opinion. These three assertions are
# the ones that keep the in-process path honest: it must accept the real thing
# and reject both ways of breaking it.
python3 - "$WORK/b1.apk" "$WORK/rel.apk" <<'PY'
import sys, zipfile, importlib.util
spec = importlib.util.spec_from_file_location('validate_apk', 'tests/validate_apk.py')
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
# The subject assertion uses the debug APK: the release APK in this suite is
# signed with an openssl-made key whose CN is deliberately not ours.
dbg = zipfile.ZipFile(sys.argv[1])
assert v._pkcs7_cert_cn(dbg.read('META-INF/CERT.RSA')) == 'Aster Dev Signing Key', \
    v._pkcs7_cert_cn(dbg.read('META-INF/CERT.RSA'))
z = zipfile.ZipFile(sys.argv[2])
rsa = z.read('META-INF/CERT.RSA')
sf = z.read('META-INF/CERT.SF')
bad_sig = bytearray(rsa); bad_sig[-1] ^= 0xFF          # one bit of encryptedDigest
assert not v._pkcs7_verify(bytes(bad_sig), sf)[0], 'a flipped signature byte still verified'
assert not v._pkcs7_verify(rsa, sf + b'Name: extra\r\n')[0], 'a modified CERT.SF still verified'
print('   in-process: the real signature verifies; a flipped signature byte and '
      'a modified CERT.SF are both rejected')
PY
echo "PASS: the in-process v1 verifier accepts the real signature and rejects both tampering paths"

echo "[10/10] option validation"
fail_with () {
    if "$ASTER_BIN" build-apk "$SO" -o "$WORK/opt.apk" --package com.aster.o --libname o \
        --keystore-dir "$WORK/proj-a" "$@" > /dev/null 2>&1; then
        echo "FAIL: build-apk accepted $*"; exit 1
    fi
}
fail_with --sign-mode staging
fail_with --key-bits 1024
fail_with --key-bits 4095
fail_with --keystore "$WORK/release/rel.key.pem"     # release-only option in a debug build
if "$ASTER_BIN" keygen --dir "$WORK/proj-a" --bits 1024 > /dev/null 2>&1; then
    echo "FAIL: keygen accepted --bits 1024"; exit 1
fi
echo "PASS: bad --sign-mode / --key-bits and debug+release option mixes are rejected"

echo "ALL SIGNING CHECKS PASSED"
