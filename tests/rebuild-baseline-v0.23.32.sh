#!/bin/sh
# tests/rebuild-baseline-v0.23.32.sh — re-record the byte-identity baseline
# after the .debug_info round. The rule this enforces: every line already in
# the baseline must reproduce byte for byte, and the round adds none at all.
# Anything else is a regression, not a re-recording.
#
# The .debug_info round is the fourth of the four candidates and the one
# toolchain round among them: `-g` now emits a DWARF v4 .debug_info (names,
# types and addresses) next to the line program v0.23.12-dev already emitted.
# None of it can reach a program built without -g, and that is the whole
# claim: the DIEs are written after every section that existed before, the
# section indices that allocate them are numbered last, and the compiler takes
# none of the new code paths unless the build asked for debug info. A program
# built the ordinary way therefore emits exactly the bytes it always did —
# including an ordinary build of a source that *also* gets built with -g
# elsewhere, which is why this corpus hashes the default modes only.
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
# Everything recorded before this round must still be there, unchanged. The
# multi-dimensional example's three rows are part of that set now — v0.23.31-dev
# recorded them, and this round adds no example of its own.
cp tests/baseline/v0.23.5-dev/example-hashes.txt "$OUT/expected-old.txt"
cp "$OUT/hashes.txt" "$OUT/got-old.txt"
if ! diff -u "$OUT/expected-old.txt" "$OUT/got-old.txt" > "$OUT/old.diff"; then
    echo "FAIL: a pre-existing example moved — this is a regression, not a re-recording" >&2
    sed -n '1,20p' "$OUT/old.diff" >&2
    exit 1
fi
old=$(wc -l < "$OUT/expected-old.txt")
new=$(wc -l < "$OUT/hashes.txt")
[ "$old" -eq 303 ] \
    || { echo "FAIL: expected 303 pre-existing rows, found $old" >&2; exit 1; }
[ "$new" -eq 303 ] \
    || { echo "FAIL: expected 303 rows total (the round adds no example), found $new" >&2; exit 1; }
echo "OK: $old pre-existing lines byte-identical; $new lines total ($((new-old)) new)"
cp "$OUT/hashes.txt" tests/baseline/v0.23.5-dev/example-hashes.txt
rm -rf "$OUT"
echo "baseline re-recorded: tests/baseline/v0.23.5-dev/example-hashes.txt"
