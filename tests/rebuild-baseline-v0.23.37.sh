#!/bin/sh
# tests/rebuild-baseline-v0.23.37.sh — re-record the byte-identity baseline
# after the function-type round. The rule this enforces: every line already in
# the baseline must reproduce byte for byte, and the round adds only the
# fn_type example (examples/fn_type.ast, three rows — one per build mode).
# Anything else is a regression, not a re-recording.
#
# The round is new *syntax* — a function pointer that carries a signature
# `fn(P1,..,Pn) -> R` — and it deliberately touches no existing code path: the
# signature rides beside the ptr, a bare `ptr` still stages every scalar
# argument at 64-bit width and still answers i32, and an indirect call through
# a bare ptr walks exactly the instructions it always did. That is the whole
# claim this baseline proves, so the 309 rows recorded by v0.23.35-dev (306
# pre-existing + the sizeof_len example's 3) must all reproduce unchanged, and
# only fn_type is new.
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
# sizeof_len example's three rows are part of that set now — v0.23.35-dev
# recorded them. This round adds exactly one example, examples/fn_type.ast,
# whose three rows are filtered out below so the pre-existing 309 rows are the
# only thing the diff inspects.
cp tests/baseline/v0.23.5-dev/example-hashes.txt "$OUT/expected-old.txt"
cp "$OUT/hashes.txt" "$OUT/got-old.txt"
# v0.23.37-dev: drop the fn_type example (this round's own addition) from
# the new side before comparing — the baseline does not have it yet, so only
# the new file needs the filter.
grep -v '^fn_type\.' "$OUT/expected-old.txt" > "$OUT/expected-old.filtered.txt"
grep -v '^fn_type\.' "$OUT/got-old.txt" > "$OUT/got-old.filtered.txt"
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
    || { echo "FAIL: expected 309 filtered rows (round adds only fn_type), found $new" >&2; exit 1; }
[ "$total" -eq 312 ] \
    || { echo "FAIL: expected 312 rows total (fn_type adds 3), found $total" >&2; exit 1; }
echo "OK: $old pre-existing lines byte-identical; $total lines total ($((total-old)) new)"
cp "$OUT/hashes.txt" tests/baseline/v0.23.5-dev/example-hashes.txt
rm -rf "$OUT"
echo "baseline re-recorded: tests/baseline/v0.23.5-dev/example-hashes.txt"
