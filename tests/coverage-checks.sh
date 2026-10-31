#!/bin/sh
# tests/coverage-checks.sh — line-coverage ratchet for src/aster.cpp.
#
# The byte baselines and the codegen twin pin output; they do not say how much
# of the compiler any test actually executes. This suite builds the compiler
# with --coverage at -O0, drives one deterministic corpus through the public
# CLI, and requires gcov's line coverage of src/aster.cpp to stay above a
# floor. The corpus is intentionally broad and cheap: every example through
# build-elf/build-pie/build-obj/build-obj --pic/build-so, the three link verbs,
# keygen plus build-apk/verify-apk, the -g / --bounds-check / --page-size
# paths, and the top-level error paths. It takes well under a minute because
# the instrumented compiler is built once and each CLI call is milliseconds.
#
# The floor is a ratchet, not a target: when the corpus grows, raise it. A
# lower floor is a reviewed source change. Coverage is compiler-version
# sensitive at the margin (templates and inlined helpers change the executable
# line count), which is why the floor sits a few points below the measured
# value rather than at it.
#
# gcov is optional. If it is absent the suite skips (77); a gcov that exists
# but cannot read the profile is a failure, because that is a broken tool, not
# a missing one.
set -eu
cd "$(dirname "$0")/.."
. tests/lib/verdict.sh

OUT=${OUT:-tmp-coverage-checks}
mkdir -p "$OUT/work" "$OUT/keys"
trap 'rm -rf "$OUT"' EXIT HUP INT TERM

CXX=${CXX:-c++}
major=$($CXX -dumpversion 2>/dev/null | cut -d. -f1) || major=""
if [ -n "${GCOV:-}" ]; then
    :
elif [ -n "$major" ] && command -v "gcov-$major" >/dev/null 2>&1; then
    GCOV=gcov-$major
elif command -v gcov >/dev/null 2>&1; then
    GCOV=gcov
else
    aster_skip "coverage needs gcov (none found)"
fi

printf '%s\n' '[1/3] Build src/aster.cpp with --coverage'
$CXX -std=c++17 -O0 --coverage -o "$OUT/aster" src/aster.cpp

printf '%s\n' '[2/3] Drive the corpus'
A=$OUT/aster
W=$OUT/work
for f in examples/*.ast; do
    b=$(basename "$f" .ast)
    "$A" build-elf "$f" -o "$W/$b.elf" >/dev/null 2>&1 || :
    "$A" build-pie "$f" -o "$W/$b.pie" >/dev/null 2>&1 || :
    "$A" build-obj "$f" -o "$W/$b.o" >/dev/null 2>&1 || :
    "$A" build-obj --pic "$f" -o "$W/$b.pic.o" >/dev/null 2>&1 || :
    "$A" build-so "$f" -o "$W/$b.so" >/dev/null 2>&1 || :
done
"$A" build-elf -g examples/condition.ast -o "$W/debug.elf" >/dev/null 2>&1 || :
"$A" build-elf --bounds-check examples/array_rw.ast -o "$W/bounds.elf" >/dev/null 2>&1 || :
"$A" build-elf --page-size 16384 examples/condition.ast -o "$W/page.elf" >/dev/null 2>&1 || :
"$A" build-obj --pic tests/codegen-fixtures/return_42.ast -o "$W/r42.o" >/dev/null 2>&1 || :
"$A" link-obj "$W/r42.o" -o "$W/link42" >/dev/null 2>&1 || :
"$A" link-pie "$W/r42.o" -o "$W/link42.pie" >/dev/null 2>&1 || :
"$A" link-so --soname libx.so "$W/r42.o" -o "$W/libx.so" >/dev/null 2>&1 || :
"$A" keygen --dir "$OUT/keys" --force >/dev/null 2>&1 || :
"$A" build-apk examples/native_render.ast -o "$W/app.apk" --package com.example.aster \
    --keystore-dir "$OUT/keys" >/dev/null 2>&1 || :
"$A" verify-apk "$W/app.apk" >/dev/null 2>&1 || :
"$A" >/dev/null 2>&1 || :
"$A" nope >/dev/null 2>&1 || :

printf '%s\n' '[3/3] gcov line coverage of src/aster.cpp'
if ! (cd "$OUT" && "$GCOV" -b -c aster.gcno) >"$OUT/gcov.log" 2>&1; then
    echo "FAIL: $GCOV could not read the profile (is it from the same GCC as $CXX?)" >&2
    tail -5 "$OUT/gcov.log" >&2
    exit 1
fi
line=$(awk "/^File '.*src\/aster\.cpp'/{f=1} f&&/Lines executed:/{print;exit}" "$OUT/gcov.log")
pct=$(printf '%s\n' "$line" | sed -n 's/.*Lines executed:\([0-9][0-9.]*\)%.*/\1/p')
total=$(printf '%s\n' "$line" | sed -n 's/.*of \([0-9][0-9]*\).*/\1/p')
if [ -z "$pct" ] || [ -z "$total" ]; then
    echo 'FAIL: no coverage summary for src/aster.cpp in gcov output' >&2
    tail -10 "$OUT/gcov.log" >&2
    exit 1
fi
FLOOR=80
if awk -v p="$pct" -v f="$FLOOR" 'BEGIN{exit !(p+0>=f+0)}'; then
    printf 'PASS: src/aster.cpp line coverage %s%% of %s executable lines (floor %s%%)\n' \
        "$pct" "$total" "$FLOOR"
else
    echo "FAIL: src/aster.cpp line coverage ${pct}% of $total executable lines, below the ${FLOOR}% floor" >&2
    exit 1
fi
