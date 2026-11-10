#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-f64-short-circuit-checks}
rm -rf "$OUT"; mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT HUP INT TERM
CXX=${CXX:-c++}
"$CXX" -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"
"$OUT/aster" build-elf tests/f64-short-circuit.ast -o "$OUT/f64" >/dev/null 2>&1
chmod +x "$OUT/f64"
set +e
sh tests/run-aarch64.sh "$OUT/f64" >"$OUT/out" 2>"$OUT/err"
st=$?
set -e
[ "$st" = 0 ] || { echo "FAIL: float short-circuit program exited $st" >&2; exit 1; }
[ "$(cat "$OUT/out")" = 11 ] || { echo "FAIL: expected 11, got: $(cat "$OUT/out")" >&2; exit 1; }
echo 'PASS: repeated f64 && comparisons'
