#!/bin/sh
# tests/rebuild-baseline-v0.23.34.sh — re-record the byte-identity baseline
# after the lifecycle round. The rule this enforces: every line already in
# the baseline must reproduce byte for byte, and the round adds only the
# lifecycle example (examples/lifecycle.ast, three rows — one per build mode).
# Anything else is a regression, not a re-recording.
#
# The .eh_frame round is the natural second half of the debug-information
# slice: `-g` now emits a DWARF v4 .eh_frame (and .eh_frame_hdr) next to the
# line program and the .debug_info the two prior rounds already emitted. None
# of it can reach a program built without -g, and that is the whole claim: the
# unwind table is written after every section that existed before, the section
# indices that allocate it are numbered last, and the compiler takes none of
# the new code paths unless the build asked for debug info. A program built the
# ordinary way therefore emits exactly the bytes it always did — including an
# ordinary build of a source that *also* gets built with -g elsewhere, which is
# why this corpus hashes the default modes only. The .eh_frame work reuses the
# same patch-site / relocation mechanism the .debug_info round built, so it
# lands on all four write paths and both linkers without moving a byte of the
# default output.
# The byte comparison is a line-by-line diff of two files written in the order
# `examples/*.ast` globs, so it is only reproducible if that order is: in an
# en_US.UTF-8 locale the shell sorts `condition.ast` before `c_ptr_*.ast`
# (the underscore is elided), in the C locale after, and the baseline recorded
# here is the C one. Pinning the collation keeps the round trip independent of
# whoever runs it — otherwise a machine with a different LANG reports every
# example as moved when not one byte changed.
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
# Everything recorded before this round must still be there, unchanged. The
# multi-dimensional example's three rows are part of that set now — v0.23.31-dev
# recorded them. This round adds exactly one example, examples/lifecycle.ast,
# whose three rows are filtered out below so the pre-existing 303 rows are the
# only thing the diff inspects.
cp tests/baseline/v0.23.5-dev/example-hashes.txt "$OUT/expected-old.txt"
cp "$OUT/hashes.txt" "$OUT/got-old.txt"
# v0.23.34-dev: drop the lifecycle example (this round's own addition) from
# both sides before comparing — the baseline has it too, but it must not count
# toward the "pre-existing unchanged" guarantee.
grep -v '^lifecycle\.' "$OUT/expected-old.txt" > "$OUT/expected-old.filtered.txt"
grep -v '^lifecycle\.' "$OUT/got-old.txt" > "$OUT/got-old.filtered.txt"
if ! diff -u "$OUT/expected-old.filtered.txt" "$OUT/got-old.filtered.txt" > "$OUT/old.diff"; then
    echo "FAIL: a pre-existing example moved — this is a regression, not a re-recording" >&2
    sed -n '1,20p' "$OUT/old.diff" >&2
    exit 1
fi
old=$(wc -l < "$OUT/expected-old.filtered.txt")
new=$(wc -l < "$OUT/got-old.filtered.txt")
total=$(wc -l < "$OUT/hashes.txt")
[ "$old" -eq 303 ] \
    || { echo "FAIL: expected 303 pre-existing rows, found $old" >&2; exit 1; }
[ "$new" -eq 303 ] \
    || { echo "FAIL: expected 303 filtered rows (round adds only lifecycle), found $new" >&2; exit 1; }
[ "$total" -eq 306 ] \
    || { echo "FAIL: expected 306 rows total (lifecycle adds 3), found $total" >&2; exit 1; }
echo "OK: $old pre-existing lines byte-identical; $total lines total ($((total-old)) new)"
cp "$OUT/hashes.txt" tests/baseline/v0.23.5-dev/example-hashes.txt
rm -rf "$OUT"
echo "baseline re-recorded: tests/baseline/v0.23.5-dev/example-hashes.txt"
