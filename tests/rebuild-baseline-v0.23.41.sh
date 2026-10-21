#!/bin/sh
# tests/rebuild-baseline-v0.23.41.sh — re-record the byte-identity baseline
# after the heap round. The rule this enforces: every line already in the
# baseline must reproduce byte for byte, and the round adds only its one
# example (examples/arena.ast, three rows — one per build mode). Anything else
# is a regression, not a re-recording.
#
# The round adds mmap/brk — the first intrinsics whose *result* is an address
# — and widens the shared syscallInsn staging to carry an i64 argument at full
# width and read a 64-bit answer. Both changes sit inside the helper the four
# v0.23.40-dev syscall intrinsics (and write) already funnel through, so the
# question this baseline exists to answer is whether they moved any existing
# byte: for every pre-existing intrinsic the arguments are at most a ptr or an
# i32, where the widened tests make the same decision the old ones did, and
# the result width is still W for every i32-answering call. So the 324 rows
# recorded by v0.23.40-dev (309 pre-existing + fn_type's 3 + cb_table/fn_ret's
# 6 + call-stmt's 3 + copy's 3) must all reproduce unchanged, and only arena
# is new.
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
# Everything recorded before this round must still be there, unchanged. The
# fn_type, cb_table, fn_ret, call-stmt and copy examples' rows are part of that
# set now. This round adds exactly one example, examples/arena.ast, whose three
# rows are filtered out below so the pre-existing 324 rows are the only thing
# the diff inspects.
cp tests/baseline/v0.23.5-dev/example-hashes.txt "$OUT/expected-old.txt"
cp "$OUT/hashes.txt" "$OUT/got-old.txt"
# v0.23.41-dev: drop this round's own addition (and fn_type/cb_table/fn_ret/
# call-stmt/copy, which the baseline carries but this round did not add) from
# both sides before comparing, so the diff inspects only what every earlier
# round recorded.
for side in expected-old got-old; do
    grep -v '^fn_type\.' "$OUT/$side.txt" \
        | grep -v '^cb_table\.' | grep -v '^fn_ret\.' | grep -v '^call-stmt\.' \
        | grep -v '^copy\.' | grep -v '^arena\.' > "$OUT/$side.filtered.txt"
done
if ! diff -u "$OUT/expected-old.filtered.txt" "$OUT/got-old.filtered.txt" > "$OUT/old.diff"; then
    echo "FAIL: a pre-existing example moved — this is a regression, not a re-recording" >&2
    sed -n '1,20p' "$OUT/old.diff" >&2
    exit 1
fi
old=$(wc -l < "$OUT/expected-old.filtered.txt")
new=$(wc -l < "$OUT/got-old.filtered.txt")
total=$(wc -l < "$OUT/hashes.txt")
[ "$old" -eq 309 ] \
    || { echo "FAIL: expected 309 pre-existing rows, found $old" >&2; exit 1; }
[ "$new" -eq 309 ] \
    || { echo "FAIL: expected 309 filtered rows (round adds only arena), found $new" >&2; exit 1; }
[ "$total" -eq 327 ] \
    || { echo "FAIL: expected 327 rows total (arena adds 3), found $total" >&2; exit 1; }
echo "OK: $old pre-existing lines byte-identical; $total lines total ($((total-old)) new)"
cp "$OUT/hashes.txt" tests/baseline/v0.23.5-dev/example-hashes.txt
rm -rf "$OUT"
echo "baseline re-recorded: tests/baseline/v0.23.5-dev/example-hashes.txt"
