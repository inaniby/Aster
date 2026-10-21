#!/bin/sh
# tests/rebuild-baseline-v0.23.42.sh — re-record the byte-identity baseline
# after the standard-library round. The rule this enforces: every line
# already in the baseline must reproduce byte for byte, and the round adds
# only its one example (examples/stdlib_demo.ast, three rows — one per build
# mode). Anything else is a regression, not a re-recording.
#
# The round ships a library, not a codegen change: the only source delta is
# the version constant, so nothing in the emitter moved and every row the
# v0.23.41-dev round left behind (327 lines: the 309 core the v0.23.40
# discipline fixed, the 15 carried fn_type/cb_table/fn_ret/call-stmt/copy
# rows, and arena's 3 from the heap round) must reproduce unchanged. The new
# demo joins no baseline family either — its witness is the differential
# against tests/aster-std-twin.c, not the A/B.
#
# The byte comparison is a line-by-line diff of two files written in the order
# `examples/*.ast` globs, so it is only reproducible if that order is fixed:
# in an en_US.UTF-8 locale the shell sorts `condition.ast` before `c_ptr_*.ast`
# (the underscore is elided), in the C locale after, and the baseline recorded
# here is the C one. Pinning the collation keeps the round trip independent of
# whoever runs it.
LC_ALL=C
export LC_ALL
set -eu
cd "$(dirname "$0")/.."
OUT=tmp-baseline
rm -rf "$OUT"; mkdir -p "$OUT"
g++ -std=c++17 -O2 -Wall -Wextra -Werror -o "$OUT/aster" src/aster.cpp
: > "$OUT/hashes.txt"
for mode in build-so build-elf "build-obj --pic"; do
    tag=$(echo "$mode" | tr ' ' '_')
    for f in examples/*.ast; do
        b=$(basename "$f" .ast)
        # shellcheck disable=SC2086
        if "$OUT/aster" $mode "$f" -o "$OUT/$b.$tag" >/dev/null 2>&1; then
            printf '%s %s\n' "$b.$tag" "$(sha256sum "$OUT/$b.$tag" | cut -d' ' -f1)" >> "$OUT/hashes.txt"
        else
            printf '%s FAILED\n' "$b.$tag" >> "$OUT/hashes.txt"
        fi
    done
done
# (A FAILED row is not a regression here: 48 examples import symbols only a
# link with another object or a libc can supply, and build-elf on its own has
# always recorded FAILED for them. The byte comparison below is what matters.)
# stdlib_demo is this round's own addition — it needs the library object
# linked in to do anything, so its standalone rows are FAILED/irrelevant and
# are dropped from both sides, exactly as arena was dropped by the v0.23.41
# script. The fn_type/cb_table/fn_ret/call-stmt/copy rows stay in the
# comparison this round: the v0.23.41 script dropped them as carried rows
# verified by their own suites, but with the baseline carrying them a full
# 327-line comparison costs nothing and catches more.
cp tests/baseline/v0.23.5-dev/example-hashes.txt "$OUT/expected-old.txt"
cp "$OUT/hashes.txt" "$OUT/got-old.txt"
for side in expected-old got-old; do
    grep -v '^stdlib_demo\.' "$OUT/$side.txt" > "$OUT/$side.filtered.txt"
done
if ! diff -u "$OUT/expected-old.filtered.txt" "$OUT/got-old.filtered.txt" > "$OUT/old.diff"; then
    echo "FAIL: a pre-existing example moved — this is a regression, not a re-recording" >&2
    sed -n '1,20p' "$OUT/old.diff" >&2
    exit 1
fi
old=$(wc -l < "$OUT/expected-old.filtered.txt")
new=$(wc -l < "$OUT/got-old.filtered.txt")
total=$(wc -l < "$OUT/hashes.txt")
[ "$old" -eq 327 ] \
    || { echo "FAIL: expected 327 baseline rows, found $old" >&2; exit 1; }
[ "$new" -eq 327 ] \
    || { echo "FAIL: expected 327 reproduced rows (round adds only stdlib_demo), found $new" >&2; exit 1; }
[ "$total" -eq 330 ] \
    || { echo "FAIL: expected 330 rows total (stdlib_demo adds 3), found $total" >&2; exit 1; }
echo "OK: $old baseline lines byte-identical; $total lines total ($((total-old)) new)"
cp "$OUT/hashes.txt" tests/baseline/v0.23.5-dev/example-hashes.txt
rm -rf "$OUT"
echo "baseline re-recorded: tests/baseline/v0.23.5-dev/example-hashes.txt"
