#!/bin/sh
# tests/rebuild-baseline-v0.23.27.sh — re-record the byte-identity baseline
# after the precedence round. The rule this enforces: every line already in the
# baseline must reproduce byte for byte, and exactly three lines are new (the
# new example in the three output modes). Anything else is a regression, not a
# re-recording.
#
# The precedence round is four corrections to how an expression is *read*, and
# none of them can change the bytes of a program that compiled before: no
# shipped example mixes `&&` with `||`, none writes `*x.y` or `-x.y`, no
# program could previously contain `a < b == c` (it did not compile), and no
# shipped example initializes a narrow local with an out-of-range constant.
# That is a claim about the corpus, not about the compiler, so this script
# exists to keep it honest: if one of those four assumptions stops holding,
# the diff below names the example.
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
# Everything recorded before this round must still be there, unchanged.
grep -v '^precedence\.' tests/baseline/v0.23.5-dev/example-hashes.txt > "$OUT/expected-old.txt"
grep -v '^precedence\.' "$OUT/hashes.txt" > "$OUT/got-old.txt"
if ! diff -u "$OUT/expected-old.txt" "$OUT/got-old.txt" > "$OUT/old.diff"; then
    echo "FAIL: a pre-existing example moved — this is a regression, not a re-recording" >&2
    sed -n '1,20p' "$OUT/old.diff" >&2
    exit 1
fi
old=$(wc -l < "$OUT/expected-old.txt")
new=$(wc -l < "$OUT/hashes.txt")
[ "$old" -eq 288 ] \
    || { echo "FAIL: expected 288 pre-existing rows, found $old" >&2; exit 1; }
[ "$new" -eq 291 ] \
    || { echo "FAIL: expected 291 rows total (288 + 3 new), found $new" >&2; exit 1; }
echo "OK: $old pre-existing lines byte-identical; $new lines total ($((new-old)) new)"
cp "$OUT/hashes.txt" tests/baseline/v0.23.5-dev/example-hashes.txt
rm -rf "$OUT"
echo "baseline re-recorded: tests/baseline/v0.23.5-dev/example-hashes.txt"
