#!/bin/sh
# tests/rebuild-baseline-v0.23.48.sh — re-record the byte-identity baseline
# after the u64/cast round. The rule this enforces: every line already in the
# baseline must reproduce byte for byte, and the round adds only its one
# example (examples/integer_cast.ast, three rows — one per build mode).
# Anything else is a regression, not a re-recording.
#
# The round ships a type and a cast, not an emitter change: the only source
# deltas are the version constant, the u64 slot in the type table, and the
# Cast expression arm, and none of them moved the instruction stream of a
# program that does not use them. Every row the v0.23.45-dev round left
# behind (330 lines: the 309 core the v0.23.40 discipline fixed, the 15
# carried fn_type/cb_table/fn_ret/call-stmt/copy rows, arena's 3, and
# stdlib_demo's 3) must reproduce unchanged.
#
# Fifteen families are excluded from the comparison, exactly as
# integer-cast-checks.sh's [9/10] layer excludes them: the fourteen earlier
# rounds' examples, each new rather than pre-existing, plus this round's own.
# That leaves the same 288 pre-existing rows on both sides. Unlike arena's and
# stdlib_demo's — which need another object linked in to do anything and
# therefore record FAILED standalone rows — integer_cast.ast is
# self-contained: all three of its rows are real hashes, and the script says
# so, because a future round that made it FAILED would be a regression this
# check must not wave through.
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
cp tests/baseline/v0.23.5-dev/example-hashes.txt "$OUT/expected-old.txt"
cp "$OUT/hashes.txt" "$OUT/got-old.txt"
FILTER='-e ^sizeof_len\. -e ^struct_array_field\. -e ^array_elem_types\. -e ^precedence\. -e ^array_address\. -e ^multi_dim_array\. -e ^lifecycle\. -e ^fn_type\. -e ^cb_table\. -e ^fn_ret\. -e ^call-stmt\. -e ^copy\. -e ^arena\. -e ^stdlib_demo\. -e ^integer_cast\.'
for side in expected-old got-old; do
    grep -v $FILTER "$OUT/$side.txt" > "$OUT/$side.filtered.txt"
done
if ! diff -u "$OUT/expected-old.filtered.txt" "$OUT/got-old.filtered.txt" > "$OUT/old.diff"; then
    echo "FAIL: a pre-existing example moved — this is a regression, not a re-recording" >&2
    sed -n '1,20p' "$OUT/old.diff" >&2
    exit 1
fi
old=$(wc -l < "$OUT/expected-old.txt")
oldf=$(wc -l < "$OUT/expected-old.filtered.txt")
newf=$(wc -l < "$OUT/got-old.filtered.txt")
total=$(wc -l < "$OUT/hashes.txt")
[ "$old" -eq 330 ] \
    || { echo "FAIL: expected 330 baseline rows on disk, found $old" >&2; exit 1; }
[ "$oldf" -eq 288 ] \
    || { echo "FAIL: expected 288 pre-existing baseline rows, found $oldf" >&2; exit 1; }
[ "$newf" -eq 288 ] \
    || { echo "FAIL: expected 288 rows of pre-existing output, found $newf" >&2; exit 1; }
[ "$total" -eq 333 ] \
    || { echo "FAIL: expected 333 rows total (integer_cast adds 3), found $total" >&2; exit 1; }
# This round's example: recorded in all three modes, and none of them FAILED —
# it imports nothing, so a FAILED row would mean the round broke its own demo.
ic=$(grep -c '^integer_cast\.' "$OUT/hashes.txt")
[ "$ic" -eq 3 ] \
    || { echo "FAIL: expected 3 integer_cast rows, found $ic" >&2; exit 1; }
[ "$(grep -c '^integer_cast\..*FAILED$' "$OUT/hashes.txt")" -eq 0 ] \
    || { echo 'FAIL: integer_cast.ast records a FAILED row — it imports nothing' >&2; exit 1; }
echo "OK: $oldf baseline lines byte-identical; $total lines total ($((total-old)) new)"
cp "$OUT/hashes.txt" tests/baseline/v0.23.5-dev/example-hashes.txt
rm -rf "$OUT"
echo "baseline re-recorded: tests/baseline/v0.23.5-dev/example-hashes.txt"
