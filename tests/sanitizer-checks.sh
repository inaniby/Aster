#!/bin/sh
# tests/sanitizer-checks.sh
#
# ASan/UBSan over the compiler's *untrusted-input* surface (audit W9/P2.4).
#
# The other suites assert behaviour; this one asserts memory safety on inputs
# that a compiler cannot trust.  A clean exit status proves nothing if the
# process first read past a buffer, so every corpus below is run through a
# compiler built with `-fsanitize=address,undefined -fno-sanitize-recover=all`
# and the only accepted outcomes are:
#
#     0  the input was accepted
#     1  the input was rejected with a diagnostic
#
# Anything else — SIGSEGV, SIGABRT from a sanitizer, a timeout — is a failure.
# A sanitizer report is made fatal by `abort_on_error=1`, so it cannot hide
# behind the compiler's own `exit(1)`.
#
# Six corpora:
#   [2] examples/*.ast          every shipped program, standalone or link-only
#   [3] generated syntax        tests/fuzz-gen.py (seeds, mutations, soup,
#                               valid frames)
#   [4] mutated ELF objects     header/section/program-header fields, through
#                               link-obj
#   [5] mutated APKs            central-directory/local-header/EOCD/Signing
#                               Block fields, through verify-apk
#   [6] mutated DER/PEM keys    ASN.1 lengths and base64 framing, through a
#                               release build-apk (the key parser path)
#
# The corpora are deterministic: the same SAN_SEED/SAN_COUNT produce the same
# files.  Half of each binary corpus is *targeted* (one length/offset field set
# to a boundary value) and half is generic byte churn, so both "a plausible
# file with one field wrong" and "arbitrary corruption" are exercised.
#
# [7] proves the harness can fail: it re-injects the historical readZip bug
# (the missing `nameLen` bound) into a *copy* of src/aster.cpp, builds it, and
# requires ASan to abort on an APK whose central-directory nameLen is 0xffff.
# The anchor is grepped before the edit, so a future refactor fails this step
# loudly instead of making it vacuous.
#
# Env:
#   SAN_COUNT=200     mutations per binary corpus (objects, APKs, syntax)
#   SAN_KEY_COUNT=100 DER + PEM key mutations (the key path is the slowest,
#                     because a surviving key performs a full APK build)
#   SAN_SEED=20261031 base seed for every corpus
#   SAN_TIMEOUT=10    per-input cap, seconds
#   WORK=...          keep the work directory at this path (it is not removed)
#   KEEP=1            keep the temporary work directory
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD

REAL_CXX=${REAL_CXX:-${CXX:-c++}}
SAN_COUNT=${SAN_COUNT:-200}
SAN_KEY_COUNT=${SAN_KEY_COUNT:-100}
SAN_SEED=${SAN_SEED:-20261031}
SAN_TIMEOUT=${SAN_TIMEOUT:-10}
CREATED=0
if [ -n "${WORK:-}" ]; then
    case "$WORK" in
        /*) : ;;
        *) WORK="$ROOT/$WORK" ;;
    esac
    mkdir -p "$WORK"
else
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/aster-sanitizer.XXXXXX")
    CREATED=1
fi
cleanup() {
    if [ "$CREATED" -eq 1 ] && [ "${KEEP:-0}" != "1" ]; then
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT HUP INT TERM
ulimit -c 0 2>/dev/null || true

# A sanitizer report must abort, not exit 1 -- exit 1 is the compiler's own
# "rejected" status and would be indistinguishable from a clean refusal.
ASAN_OPTIONS="detect_leaks=0:abort_on_error=1"
UBSAN_OPTIONS="halt_on_error=1:abort_on_error=1"
export ASAN_OPTIONS UBSAN_OPTIONS

SAN_FLAGS="-std=c++17 -O0 -g -fsanitize=address,undefined -fno-sanitize-recover=all -Wall -Wextra -Wpedantic -Werror"

printf '%s\n' '[1/8] Sanitizer toolchain and compiler'
printf '      %s %s\n' "$REAL_CXX" "$SAN_FLAGS"
printf 'int main(void){return 0;}\n' > "$WORK/probe.cpp"
if ! $REAL_CXX $SAN_FLAGS "$WORK/probe.cpp" -o "$WORK/probe" 2>"$WORK/probe.log"; then
    echo "SKIP: ASan/UBSan toolchain unavailable: $(head -1 "$WORK/probe.log" 2>/dev/null)"
    exit 77
fi
if ! $REAL_CXX $SAN_FLAGS src/aster.cpp -o "$WORK/aster-asan" 2>"$WORK/build.log"; then
    cat "$WORK/build.log" >&2
    echo "FAIL: the sanitizer build of src/aster.cpp failed"
    exit 1
fi
"$WORK/aster-asan" --version 2>/dev/null | head -1
echo "PASS: ASan+UBSan build is live"

# classify <label> <file> <rc>
OK=0; REJ=0; CRASH=0; CRASHES=""
reset_counts() { OK=0; REJ=0; CRASH=0; CRASHES=""; }
classify() {
    label=$1; file=$2; rc=$3
    case "$rc" in
        0) OK=$((OK + 1)) ;;
        1) REJ=$((REJ + 1)) ;;
        *)
            CRASH=$((CRASH + 1))
            CRASHES="$CRASHES $file"
            if [ "$rc" -eq 124 ]; then
                echo "  TIMEOUT (${label}): $file"
            else
                echo "  CRASH (${label}, exit $rc): $file"
            fi
            sed -n '1,12p' "$WORK/last.err" 2>/dev/null || true
            ;;
    esac
}
no_crash() {
    [ "$CRASH" -eq 0 ] || { echo "FAIL: $CRASH ${1} input(s) crashed or hung:$CRASHES"; exit 1; }
}

printf '%s\n' '[2/8] Every shipped example through build-elf'
reset_counts
n=0
for f in examples/*.ast; do
    n=$((n + 1))
    rc=0
    timeout "$SAN_TIMEOUT" "$WORK/aster-asan" build-elf "$f" -o "$WORK/out.elf" \
        >/dev/null 2>"$WORK/last.err" || rc=$?
    classify example "$f" "$rc"
done
echo "      examples=$n compiled=$OK rejected=$REJ crashed=$CRASH"
no_crash example
[ "$OK" -ge 40 ] || { echo "FAIL: only $OK examples compiled; the corpus is not reaching codegen"; exit 1; }
echo "PASS: $n examples, $OK compiled and $REJ rejected cleanly"

printf '%s\n' "[3/8] Generated syntax corpus ($SAN_COUNT inputs, seed $SAN_SEED)"
python3 tests/fuzz-gen.py --seed "$SAN_SEED" --count "$SAN_COUNT" \
    --outdir "$WORK/corpus-src" --corpus examples >/dev/null
n=$(find "$WORK/corpus-src" -name '*.ast' | wc -l)
[ "$n" -eq "$SAN_COUNT" ] || { echo "FAIL: generated $n syntax inputs, wanted $SAN_COUNT"; exit 1; }
reset_counts
for f in "$WORK"/corpus-src/*.ast; do
    rc=0
    timeout "$SAN_TIMEOUT" "$WORK/aster-asan" build-elf "$f" -o "$WORK/out.elf" \
        >/dev/null 2>"$WORK/last.err" || rc=$?
    classify syntax "$f" "$rc"
done
echo "      compiled=$OK rejected=$REJ crashed=$CRASH"
no_crash syntax
[ "$OK" -gt 0 ] || { echo "FAIL: no generated input compiled; the corpus never reaches the parser"; exit 1; }
echo "PASS: $n syntax inputs, $OK compiled and $REJ rejected cleanly"

printf '%s\n' '[4/8] Mutated ELF objects through link-obj'
"$WORK/aster-asan" build-obj examples/align_global.ast -o "$WORK/seed.o" >/dev/null
rc=0
"$WORK/aster-asan" link-obj "$WORK/seed.o" -o "$WORK/seed.elf" >/dev/null 2>"$WORK/seed-o.err" || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: the unmutated object did not link (exit $rc)"; cat "$WORK/seed-o.err" >&2; exit 1; }
python3 tests/fuzz-bin.py --seed-file "$WORK/seed.o" --outdir "$WORK/corpus-o" \
    --count "$SAN_COUNT" --seed "$SAN_SEED"
n=$(find "$WORK/corpus-o" -name '*.bin' | wc -l)
[ "$n" -eq "$SAN_COUNT" ] || { echo "FAIL: generated $n object inputs, wanted $SAN_COUNT"; exit 1; }
reset_counts
for f in "$WORK"/corpus-o/*.bin; do
    rc=0
    timeout "$SAN_TIMEOUT" "$WORK/aster-asan" link-obj "$f" -o "$WORK/out.elf" \
        >/dev/null 2>"$WORK/last.err" || rc=$?
    classify object "$f" "$rc"
done
echo "      linked=$OK rejected=$REJ crashed=$CRASH"
no_crash object
echo "PASS: seed object links; $n mutations, $OK linked and $REJ rejected cleanly"

printf '%s\n' "[5/8] Mutated APKs through verify-apk"
"$WORK/aster-asan" build-so examples/so_math.ast -o "$WORK/seed.so" >/dev/null
mkdir -p "$WORK/keys"
"$WORK/aster-asan" build-apk "$WORK/seed.so" -o "$WORK/seed.apk" \
    --package com.aster.hostile --libname hostile \
    --keystore-dir "$WORK/keys" >/dev/null 2>"$WORK/seed-apk.log"
rc=0
"$WORK/aster-asan" verify-apk "$WORK/seed.apk" >/dev/null 2>"$WORK/seed-apk-verify.err" || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: the unmutated APK did not verify (exit $rc)"; cat "$WORK/seed-apk-verify.err" >&2; exit 1; }
python3 tests/fuzz-bin.py --seed-file "$WORK/seed.apk" --outdir "$WORK/corpus-apk" \
    --count "$SAN_COUNT" --seed "$SAN_SEED"
n=$(find "$WORK/corpus-apk" -name '*.bin' | wc -l)
[ "$n" -eq "$SAN_COUNT" ] || { echo "FAIL: generated $n APK inputs, wanted $SAN_COUNT"; exit 1; }
reset_counts
for f in "$WORK"/corpus-apk/*.bin; do
    rc=0
    timeout "$SAN_TIMEOUT" "$WORK/aster-asan" verify-apk "$f" \
        >/dev/null 2>"$WORK/last.err" || rc=$?
    classify apk "$f" "$rc"
done
echo "      verified=$OK rejected=$REJ crashed=$CRASH"
no_crash apk
echo "PASS: seed APK verifies; $n mutations, $OK verified and $REJ rejected cleanly"

printf '%s\n' '[6/8] Mutated DER/PEM signing keys through build-apk'
python3 - "$WORK/keys/.aster/debug.key.pem" "$WORK/seed.key.der" <<'PY'
import base64, sys
pem = open(sys.argv[1], "rb").read()
body = b"".join(line for line in pem.splitlines() if not line.startswith(b"-----"))
open(sys.argv[2], "wb").write(base64.b64decode(body))
PY
python3 tests/fuzz-bin.py --seed-file "$WORK/seed.key.der" --outdir "$WORK/corpus-der" \
    --count "$((SAN_KEY_COUNT / 2))" --seed "$SAN_SEED"
python3 tests/fuzz-bin.py --seed-file "$WORK/keys/.aster/debug.key.pem" \
    --outdir "$WORK/corpus-pem" --count "$((SAN_KEY_COUNT - SAN_KEY_COUNT / 2))" \
    --seed "$SAN_SEED"
n=$(find "$WORK/corpus-der" "$WORK/corpus-pem" -name '*.bin' | wc -l)
[ "$n" -eq "$SAN_KEY_COUNT" ] || { echo "FAIL: generated $n key inputs, wanted $SAN_KEY_COUNT"; exit 1; }
reset_counts
for f in "$WORK"/corpus-der/*.bin "$WORK"/corpus-pem/*.bin; do
    rc=0
    timeout "$SAN_TIMEOUT" "$WORK/aster-asan" build-apk "$WORK/seed.so" \
        -o "$WORK/key-out.apk" --package com.aster.hostile --libname hostile \
        --sign-mode release --keystore "$f" \
        --cert "$WORK/keys/.aster/debug.crt.pem" \
        >/dev/null 2>"$WORK/last.err" || rc=$?
    classify key "$f" "$rc"
done
echo "      accepted=$OK rejected=$REJ crashed=$CRASH"
no_crash key
echo "PASS: $n mutated keys, $OK accepted and $REJ rejected cleanly"

printf '%s\n' '[7/8] Proof the sanitizer harness can fail: re-inject the nameLen bug'
cp src/aster.cpp "$WORK/broken.cpp"
BEFORE='if (nameAt > end || nameLen > end - nameAt) { err = "a central directory entry name runs past the directory"; return false; }'
AFTER='if (false) { err = "a central directory entry name runs past the directory"; return false; }'
grep -qF "$BEFORE" "$WORK/broken.cpp" \
    || { echo "FAIL: the nameLen bound is gone -- update this step, do not drop it" >&2; exit 1; }
sed "s@$BEFORE@$AFTER@" "$WORK/broken.cpp" > "$WORK/broken.injected" \
    || { echo "FAIL: sed injection failed"; exit 1; }
mv "$WORK/broken.injected" "$WORK/broken.cpp"
grep -qF "$AFTER" "$WORK/broken.cpp" \
    || { echo "FAIL: the bug injection did not apply -- the proof would be vacuous"; exit 1; }
if ! $REAL_CXX $SAN_FLAGS "$WORK/broken.cpp" -o "$WORK/broken-asan" 2>"$WORK/broken-build.log"; then
    cat "$WORK/broken-build.log" >&2
    echo "FAIL: the injected-bug build failed"
    exit 1
fi
python3 - "$WORK/seed.apk" "$WORK/trigger.apk" <<'PY'
import struct, sys
buf = bytearray(open(sys.argv[1], "rb").read())
i = buf.find(b"PK\x01\x02")
if i < 0:
    raise SystemExit("no central directory entry in the seed APK")
struct.pack_into("<H", buf, i + 28, 0xffff)      # nameLen, the unbounded field
open(sys.argv[2], "wb").write(buf)
PY
rc=0
timeout "$SAN_TIMEOUT" "$WORK/broken-asan" verify-apk "$WORK/trigger.apk" \
    >/dev/null 2>"$WORK/negative.err" || rc=$?
caught=0
if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ] && [ "$rc" -ne 124 ] \
        && grep -qE 'AddressSanitizer|runtime error' "$WORK/negative.err"; then
    caught=1
fi
if [ "$caught" -ne 1 ]; then
    echo "FAIL: the injected out-of-bounds read was not reported (exit $rc)"; sed -n '1,20p' "$WORK/negative.err" >&2; exit 1
fi
echo "PASS: ASan caught the injected nameLen over-read (exit $rc)"

printf '%s\n' '[8/8] Summary'
echo "PASS: sanitizer corpora -- examples + $SAN_COUNT syntax + $SAN_COUNT objects + $SAN_COUNT APKs + $SAN_KEY_COUNT keys, 0 crashes"
