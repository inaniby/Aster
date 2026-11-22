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
# Eight corpora:
#   [2] examples/*.ast          every shipped program, standalone or link-only
#   [3] generated syntax        tests/fuzz-gen.py (seeds, mutations, soup,
#                               valid frames)
#   [4] mutated ELF objects     header/section/program-header fields, through
#                               link-obj
#   [5] mutated APKs            central-directory/local-header/EOCD/Signing
#                               Block fields, through verify-apk, plus the
#                               structured semantic mutants of
#                               tests/apk-semantic-mutate.py (each with a
#                               known expected verdict)
#   [6] mutated DER/PEM keys    ASN.1 lengths and base64 framing, through a
#                               release build-apk (the key parser path)
#   [8] mutated aster.proj and cache .meta files
#                               hand-built project/meta mutants from
#                               tests/proj-meta-mutate.py, through build,
#                               doctor and deps; a bad .meta must fail
#                               closed to a recompile, never to a crash
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
#   SAN_KEY_TIMEOUT=60 per-key cap; RSA self-checks are expensive under ASan
#   WORK=...          keep the work directory at this path (it is not removed)
#   KEEP=1            keep the temporary work directory
set -eu
. tests/lib/tmpdir.sh
cd "$(dirname "$0")/.."
ROOT=$PWD

REAL_CXX=${REAL_CXX:-${CXX:-c++}}
SAN_COUNT=${SAN_COUNT:-200}
SAN_KEY_COUNT=${SAN_KEY_COUNT:-100}
SAN_SEED=${SAN_SEED:-20261031}
SAN_TIMEOUT=${SAN_TIMEOUT:-10}
SAN_KEY_TIMEOUT=${SAN_KEY_TIMEOUT:-60}
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

printf '%s\n' '[1/9] Sanitizer toolchain and compiler'
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

printf '%s\n' '[2/9] Every shipped example through build-elf'
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

printf '%s\n' "[3/9] Generated syntax corpus ($SAN_COUNT inputs, seed $SAN_SEED)"
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

printf '%s\n' '[4/9] Mutated ELF objects through link-obj'
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

printf '%s\n' "[5/9] Mutated APKs through verify-apk"
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

# v0.23.81-dev (fuzz batch): structured, semantic APK mutants (audit §6.2).
# tests/fuzz-bin.py churns bytes at random; these mutants are built by
# parsing the ZIP/Signing-Block structure (tests/apk-semantic-mutate.py),
# so each one has a known meaning and a known expected verdict: 15 must be
# rejected (payload/manifest flips, truncation, an extra META-INF or
# payload entry, local/central extraLen disagreement, the Signing Block
# size2 disagreement -- the counter-proof for the size2 check -- a
# duplicated signer, a duplicated central-directory entry, a wrong EOCD
# cdStart, a renamed CERT.SF, a flipped CRC, and a duplicated v2 pair --
# the last one was a known gap in the fuzz batch, fixed in v0.23.81-dev by
# rejecting any Signing Block ID that appears twice) and 1 must be
# accepted: a v3 pair next to a valid v2 pair (unknown Signing Block IDs
# are ignored by design).
printf '%s\n' '      semantic APK mutants through verify-apk'
python3 tests/apk-semantic-mutate.py "$WORK/seed.apk" "$WORK/corpus-apk-semantic"
n=$(find "$WORK/corpus-apk-semantic" -name '*.apk' | wc -l)
[ "$n" -eq 16 ] || { echo "FAIL: generated $n semantic APK inputs, wanted 16"; exit 1; }
reset_counts
for f in "$WORK"/corpus-apk-semantic/*.apk; do
    rc=0
    timeout "$SAN_TIMEOUT" "$WORK/aster-asan" verify-apk "$f" \
        >/dev/null 2>"$WORK/last.err" || rc=$?
    classify apk-semantic "$f" "$rc"
done
echo "      verified=$OK rejected=$REJ crashed=$CRASH"
no_crash apk-semantic
[ "$OK" -eq 1 ] || { echo "FAIL: $OK semantic APKs verified, expected exactly 1 (v3-pair-added)"; exit 1; }
[ "$REJ" -eq 15 ] || { echo "FAIL: $REJ semantic APKs rejected, expected exactly 15"; exit 1; }
echo "PASS: 16 semantic APK mutants, 1 verified and 15 rejected cleanly"

printf '%s\n' '[6/9] Mutated DER/PEM signing keys through build-apk'
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
    timeout "$SAN_KEY_TIMEOUT" "$WORK/aster-asan" build-apk "$WORK/seed.so" \
        -o "$WORK/key-out.apk" --package com.aster.hostile --libname hostile \
        --sign-mode release --keystore "$f" \
        --cert "$WORK/keys/.aster/debug.crt.pem" \
        >/dev/null 2>"$WORK/last.err" || rc=$?
    classify key "$f" "$rc"
done
echo "      accepted=$OK rejected=$REJ crashed=$CRASH"
no_crash key
echo "PASS: $n mutated keys, $OK accepted and $REJ rejected cleanly"

printf '%s\n' '[7/9] Proof the sanitizer harness can fail: re-inject the nameLen bug'
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

printf '%s\n' '[8/9] Mutated aster.proj and cache .meta files through build/doctor/deps'
# v0.23.81-dev (fuzz batch): the project file and the cache meta are
# untrusted input too (audit §6.2), and no earlier corpus fed them to the
# compiler. tests/proj-meta-mutate.py writes 38 hand-built aster.proj
# mutants (duplicate lines, malformed settings, over-long lines, NUL bytes,
# truncation, escaping paths) and 21 cache-.meta mutants (truncated, hash
# flipped, field dropped or duplicated, NUL bytes, over-long line, a dep
# pointing nowhere, an unknown line). Every one runs through the ASan
# binary; the only accepted outcomes are 0 (accepted, or rebuilt after a
# failed-closed meta) and 1/2 (rejected with a diagnostic). The seed
# project is built once first, so the .meta mutants start from a warm cache
# and a bad meta must fail closed to a recompile: all 21 must still build.
"$WORK/aster-asan" new "$WORK/proj-seed" >/dev/null
(cd "$WORK/proj-seed" && "$WORK/aster-asan" build >"$WORK/proj-seed.log" 2>&1) \
    || { echo 'FAIL: the seed project for the proj/meta corpus did not build:'; cat "$WORK/proj-seed.log" >&2; exit 1; }
python3 tests/proj-meta-mutate.py --project "$WORK/proj-seed" --outdir "$WORK/corpus-projmeta"
n=$(find "$WORK/corpus-projmeta" -maxdepth 1 -name 'proj-*' -type d | wc -l)
[ "$n" -eq 38 ] || { echo "FAIL: generated $n aster.proj mutants, wanted 38"; exit 1; }
n=$(find "$WORK/corpus-projmeta" -maxdepth 1 -name 'meta-*' -type d | wc -l)
[ "$n" -eq 21 ] || { echo "FAIL: generated $n cache-meta mutants, wanted 21"; exit 1; }
# classify_proj <label> <dir> <rc>: 0/1/2 are clean (accepted / rejected /
# usage error); anything else -- a signal, an ASan abort, a timeout -- is a
# crash. The shared classify() only accepts 0/1, so this step has its own.
CRASH=0; CRASHES=""
classify_proj() {
    case "$3" in
        0|1|2) ;;
        *)
            CRASH=$((CRASH + 1))
            CRASHES="$CRASHES $2"
            if [ "$3" -eq 124 ]; then echo "  TIMEOUT ($1): $2"; else echo "  CRASH ($1, exit $3): $2"; fi
            sed -n '1,12p' "$WORK/last.err" 2>/dev/null || true
            ;;
    esac
}
for d in "$WORK"/corpus-projmeta/proj-*; do
    for cmd in build doctor deps; do
        rc=0
        (cd "$d" && timeout "$SAN_TIMEOUT" "$WORK/aster-asan" "$cmd" \
            >/dev/null 2>"$WORK/last.err") || rc=$?
        classify_proj "proj-$cmd" "$d" "$rc"
    done
done
[ "$CRASH" -eq 0 ] || { echo "FAIL: $CRASH aster.proj input(s) crashed or hung:$CRASHES"; exit 1; }
echo "PASS: 38 aster.proj mutants through build, doctor and deps -- 0 crashes"
ok0=0
for d in "$WORK"/corpus-projmeta/meta-*; do
    rc=0
    (cd "$d" && timeout "$SAN_TIMEOUT" "$WORK/aster-asan" build \
        >/dev/null 2>"$WORK/last.err") || rc=$?
    classify_proj "meta-build" "$d" "$rc"
    if [ "$rc" -eq 0 ]; then ok0=$((ok0 + 1)); fi
done
[ "$CRASH" -eq 0 ] || { echo "FAIL: $CRASH cache-meta input(s) crashed or hung:$CRASHES"; exit 1; }
[ "$ok0" -eq 21 ] || { echo "FAIL: only $ok0 of 21 bad-meta builds succeeded -- a bad meta must fail closed to a recompile, not fail the build"; exit 1; }
echo "PASS: 21 cache-meta mutants, all 21 rebuilt cleanly -- 0 crashes"

printf '%s\n' '[9/9] Summary'
echo "PASS: sanitizer corpora -- examples + $SAN_COUNT syntax + $SAN_COUNT objects + $SAN_COUNT APKs + 16 semantic APKs + $SAN_KEY_COUNT keys + 38 aster.proj + 21 cache-meta, 0 crashes"
