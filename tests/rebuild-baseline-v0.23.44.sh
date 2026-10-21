#!/bin/sh
# tests/rebuild-baseline-v0.23.44.sh — re-verify the byte-identity baseline
# after the bootstrap-parser round. The rule this enforces: every line already
# in the baseline must reproduce byte for byte, and the round adds nothing —
# M3b ships the bootstrap compiler's parser stage, not an example.
#
# The round ships a stage, not a codegen change: the only source delta is the
# version constant, so nothing in the emitter moved and all 330 rows the
# v0.23.43-dev round left behind (the 309 core, the 15 carried
# fn_type/cb_table/fn_ret/call-stmt/copy rows, arena's 3, and stdlib_demo's
# 3) must reproduce unchanged. As in the v0.23.43 script there is nothing to
# filter: no example is new this round, so the comparison is the whole file
# on both sides and the totals must match exactly.
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
# always recorded FAILED for them. stdlib_demo's three rows are FAILED for the
# same structural reason — it needs the library object linked in — and are
# pinned as FAILED in the baseline. The byte comparison below is what matters.)
cp tests/baseline/v0.23.5-dev/example-hashes.txt "$OUT/expected-old.txt"
if ! diff -u "$OUT/expected-old.txt" "$OUT/hashes.txt" > "$OUT/old.diff"; then
    echo "FAIL: a pre-existing example moved — this is a regression, not a re-recording" >&2
    sed -n '1,20p' "$OUT/old.diff" >&2
    exit 1
fi
old=$(wc -l < "$OUT/expected-old.txt")
new=$(wc -l < "$OUT/hashes.txt")
[ "$old" -eq 330 ] \
    || { echo "FAIL: expected 330 baseline rows, found $old" >&2; exit 1; }
[ "$new" -eq 330 ] \
    || { echo "FAIL: expected 330 reproduced rows (round adds no example), found $new" >&2; exit 1; }
echo "OK: $old baseline lines byte-identical; $new lines reproduced ($((new-old)) new)"
cp "$OUT/hashes.txt" tests/baseline/v0.23.5-dev/example-hashes.txt
rm -rf "$OUT"
echo "baseline re-verified: tests/baseline/v0.23.5-dev/example-hashes.txt"
