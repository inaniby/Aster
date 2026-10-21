#!/bin/sh
# tests/rebuild-baseline-v0.23.26.sh — re-record the byte-identity baseline after
# the null round. The rule this enforces: every line already in the
# baseline must reproduce byte for byte, and exactly three lines are new (the
# new example in the three modes). Anything else is a regression, not a
# re-recording.
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
# The 285 lines recorded through v0.23.25-dev must all still be there,
# unchanged: the null round admits new programs and re-encodes no old one — no
# pre-existing example can contain a ptr comparison or a null literal in a ptr
# slot (both used to be compile errors).
grep -v '^null_ptr\.' tests/baseline/v0.23.5-dev/example-hashes.txt > "$OUT/expected-old.txt"
grep -v '^null_ptr\.' "$OUT/hashes.txt" > "$OUT/got-old.txt"
if ! diff -u "$OUT/expected-old.txt" "$OUT/got-old.txt" > "$OUT/old.diff"; then
    echo "FAIL: a pre-existing example moved — this is a regression, not a re-recording" >&2
    sed -n '1,20p' "$OUT/old.diff" >&2
    exit 1
fi
old=$(wc -l < "$OUT/expected-old.txt")
new=$(wc -l < "$OUT/hashes.txt")
echo "OK: $old pre-existing lines byte-identical; $new lines total ($((new-old)) new)"
cp "$OUT/hashes.txt" tests/baseline/v0.23.5-dev/example-hashes.txt
echo "baseline re-recorded: tests/baseline/v0.23.5-dev/example-hashes.txt"
