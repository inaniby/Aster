#!/bin/sh
# tests/library-core-checks.sh — the subset-safe core of the library, and what
# the self-hosted stage does with it (v0.23.77-dev).
#
# `stdlib/aster_core.ast` is the part of the library a *self-hosted* compiler
# can compile: memory, strings, integer parsing and the integer writers, with no
# struct, no f64, no local arrays and no casts — the subset
# `bootstrap/aster.ast` is written in. The full library cannot be linked into
# the self-hosting chain for exactly those reasons, so this file is the seam.
#
# Layers:
#   [1] strict build of the host compiler
#   [2] the core is a verbatim extract of `stdlib/aster_std.ast`
#   [3] the host compiles it, a consumer links against it and prints the line
#   [4] the *self-hosted stage* accepts the core and emits a running image
#   [5] the stage's image against the host's (A-26, fixed: they must match)
#   [6] no compiler change: the baseline reproduces 393 rows
set -eu
cd "$(dirname "$0")/.."
. tests/lib/tmpdir.sh
CXX=${CXX:-c++}
ASTER="$TMPD/core-aster"
OUT="$TMPD/core-work"
rm -rf "$OUT"; mkdir -p "$OUT"
fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ printf '  %-46s %s\n' "$1" 'ok'; }

printf '%s\n' '[1/6] Strictly build the host compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER" src/aster.cpp
ok 'compiler built'

printf '%s\n' '[2/6] the core is a verbatim extract'
[ -f stdlib/aster_core.ast ] || fail 'stdlib/aster_core.ast is missing'
awk '/^fn /{name=$2; sub(/\(.*/,"",name); print name}' stdlib/aster_core.ast > "$OUT/names"
n=$(wc -l < "$OUT/names")
[ "$n" -ge 18 ] || fail "the core has $n routines, expected at least 18"
while read -r name; do
    awk -v nm="fn $name(" 'index($0,nm)==1{p=1} p{print} p&&/^}/{exit}' \
        stdlib/aster_core.ast > "$OUT/body"
    [ -s "$OUT/body" ] || fail "the core's $name could not be read back"
    grep -qF -f "$OUT/body" stdlib/aster_std.ast \
        || fail "the core's $name is not byte-identical to the library's"
done < "$OUT/names"
ok "$n routines, each byte-identical to the library's"

printf '%s\n' '[3/6] the host builds it; a consumer prints the line'
"$ASTER" build-obj stdlib/aster_core.ast -o "$OUT/core.o" >"$OUT/core.log" 2>&1 \
    || fail "the core did not compile: $(tail -2 "$OUT/core.log")"
grep -q '18 functions, 0 globals' "$OUT/core.log" || fail "the core's shape changed: $(tail -1 "$OUT/core.log")"
und=$(readelf -sW "$OUT/core.o" | awk '$7=="UND"' | wc -l)
[ "$und" = 1 ] || fail "the core imports $und symbols, expected only the ELF null"
"$ASTER" build-obj tests/library-core-consumer.ast -o "$OUT/use.o" >/dev/null 2>&1 \
    || fail 'the consumer did not compile'
"$ASTER" link-obj "$OUT/use.o" "$OUT/core.o" -o "$OUT/use" >/dev/null 2>&1 \
    || fail 'the consumer did not link'
chmod +x "$OUT/use"
(cd "$OUT" && ./use > use.out 2>&1) || fail "the consumer exited $?"
grep -qxF '13|-42|8|9|101' "$OUT/use.out" || fail "the consumer printed '$(cat "$OUT/use.out")'"
ok '18 routines, 1 UND; consumer prints 13|-42|8|9|101'

printf '%s\n' '[4/6] the self-hosted stage accepts the core'
"$ASTER" build-obj bootstrap/aster.ast -o "$OUT/boot.o" >"$OUT/boot.log" 2>&1 \
    || fail "the bootstrap stage did not build: $(tail -2 "$OUT/boot.log")"
"$ASTER" link-obj "$OUT/boot.o" -o "$OUT/stage" >/dev/null 2>&1 || fail 'the stage did not link'
chmod +x "$OUT/stage"
# the stage has no linker, so the consumer's declarations are stripped and the
# core's bodies are prepended
grep -v '^extern fn' tests/library-core-consumer.ast > "$OUT/use_noext.ast"
cat stdlib/aster_core.ast "$OUT/use_noext.ast" > "$OUT/combo.ast"
(cd "$OUT" && ./stage < combo.ast > combo.elf 2>combo.err); rc=$?
[ "$rc" = 0 ] || fail "the stage refused the core: $(head -2 "$OUT/combo.err")"
[ -s "$OUT/combo.elf" ] || fail 'the stage emitted no image'
readelf -h "$OUT/combo.elf" >/dev/null 2>&1 || fail 'the stage image is not an ELF'
chmod +x "$OUT/combo.elf"
ok 'the stage compiles the core and emits an ELF'

printf '%s\n' '[5/6] A-26 gate: the stage image against the host'
(cd "$OUT" && ./combo.elf > stage.out 2>&1) || true
# A-26 was fixed in v0.23.77-dev: the store width now comes from the intrinsic
# (STRB for store_u8), so the stage's image agrees with the host's byte for
# byte. Before the fix this layer pinned the disagreement instead.
cmp -s "$OUT/use.out" "$OUT/stage.out" \
    || { diff -u "$OUT/use.out" "$OUT/stage.out" | head -10 >&2;
         fail 'the stage image disagrees with the host (A-26 regressed)'; }
ok 'the stage image matches the host byte for byte'

printf '%s\n' '[6/6] no compiler change: the baseline reproduces'
. tests/lib/baseline.sh
base=$(aster_baseline_file)
rows=$(wc -l < "$base")
[ "$rows" = 393 ] || fail "the baseline has $rows rows, expected 393"
ok '393 baseline rows unchanged'

echo 'PASS: subset-safe core (verbatim extract, host consumer, self-hosted acceptance, A-26 gate)'
