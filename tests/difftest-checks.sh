#!/bin/sh
# tests/difftest-checks.sh — the differential harness: Aster against a C oracle.
#
# Every round that touched code generation found a wrong-code bug by hand (the
# F-01 stack window, an f64 argument copied to the stack, a negated float losing
# its family). This suite makes that class of bug the machine's job: one
# traversal emits the *same* program in Aster and in C syntax, both are compiled
# and run, and their output is compared. A disagreement is a compiler bug.
#
# Layers:
#   [1] strict build of the compiler
#   [2] the generator is deterministic (same seed, same bytes)
#   [3] family 0 — u32 expressions (wrapping arithmetic, shifts, bitwise)
#   [4] family 1 — i64 expressions
#   [5] family 2 — call shapes: nine scalars, a 12-byte and a 24-byte aggregate
#   [6] the harness has teeth: a mutated compiler must be caught
#   [7] no compiler change: the baseline reproduces 393 rows
set -eu
cd "$(dirname "$0")/.."
# v0.23.77-dev (host adaptation): run AArch64 products through the shared
# runner. It executes them natively on an AArch64/Termux host and under qemu
# elsewhere, so the very same suite is valid on both kinds of machine.
RUNNER=${RUNNER:-tests/run-aarch64.sh}
case "$RUNNER" in
    /*) ;;
    *) if [ -f "$RUNNER" ]; then RUNNER="$(cd "$(dirname "$RUNNER")" && pwd)/$(basename "$RUNNER")"; fi ;;
esac
. tests/lib/tmpdir.sh
CXX=${CXX:-c++}
ASTER="$TMPD/diff-aster"
GEN="$TMPD/diff-gen"
OUT="$TMPD/diff-work"
SEEDS=24
rm -rf "$OUT"; mkdir -p "$OUT"
fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ printf '  %-46s %s\n' "$1" 'ok'; }

printf '%s\n' '[1/7] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER" src/aster.cpp
ok 'compiler built'

printf '%s\n' '[2/7] the generator'
"$ASTER" build-elf tests/difftest/gen.ast -o "$GEN" >/dev/null 2>&1 || fail 'the generator did not compile'
chmod +x "$GEN"
"$RUNNER" "$GEN" aster 7 0 > "$OUT/det1.ast"
"$RUNNER" "$GEN" aster 7 0 > "$OUT/det2.ast"
cmp -s "$OUT/det1.ast" "$OUT/det2.ast" || fail 'the generator is not deterministic for one seed'
"$RUNNER" "$GEN" aster 8 0 > "$OUT/det3.ast"
cmp -s "$OUT/det1.ast" "$OUT/det3.ast" && fail 'two seeds emitted the same program'
"$RUNNER" "$GEN" c 7 0 > "$OUT/det1.c"
[ -s "$OUT/det1.c" ] || fail 'the C side emitted nothing'
ok 'deterministic per seed, different across seeds, both languages emitted'

# run_family <family> <label>
run_family(){
    fam=$1; label=$2; agree=0
    seed=1
    while [ "$seed" -le "$SEEDS" ]; do
        "$RUNNER" "$GEN" aster "$seed" "$fam" > "$OUT/p.ast"
        "$RUNNER" "$GEN" c     "$seed" "$fam" > "$OUT/p.c"
        "$ASTER" build-elf "$OUT/p.ast" -o "$OUT/p.elf" >"$OUT/build.log" 2>&1 \
            || fail "$label seed $seed: Aster refused the program: $(tail -1 "$OUT/build.log")"
        ${CC:-cc} -O0 -w "$OUT/p.c" -o "$OUT/p.cbin" || fail "$label seed $seed: the C twin did not build"
        chmod +x "$OUT/p.elf"
        set +e
        "$RUNNER" "$OUT/p.elf" > "$OUT/a.out" 2>&1; arc=$?
        "$OUT/p.cbin" > "$OUT/c.out" 2>&1; crc=$?
        set -e
        if ! cmp -s "$OUT/a.out" "$OUT/c.out" || [ "$arc" != "$crc" ]; then
            echo "  seed $seed: aster=$(cat "$OUT/a.out" | tr -d '\n') rc=$arc  c=$(cat "$OUT/c.out" | tr -d '\n') rc=$crc" >&2
            fail "$label seed $seed disagrees (program: $OUT/p.ast)"
        fi
        agree=$((agree+1))
        seed=$((seed+1))
    done
    ok "$agree seeds agree (output and exit status)"
}

printf '%s\n' '[3/7] family 0: u32 expressions'
run_family 0 'u32'

printf '%s\n' '[4/7] family 1: i64 expressions'
run_family 1 'i64'

printf '%s\n' '[5/7] family 2: call shapes'
run_family 2 'calls'

printf '%s\n' '[6/7] the harness has teeth: a mutated compiler is caught'
sed 's|else                      base=wide?0xca000000u:0x4a000000u;   // EOR|else                      base=wide?0xca000000u:0x2a000000u;   // EOR->ORR (mutant)|' \
    src/aster.cpp > "$OUT/mutant.cpp"
cmp -s src/aster.cpp "$OUT/mutant.cpp" && fail 'the EOR mutation stopped applying'
$CXX -std=c++17 -O2 -w "$OUT/mutant.cpp" -o "$OUT/mutant" || fail 'the mutant compiler did not build'
caught=0
seed=1
while [ "$seed" -le 8 ]; do
    "$RUNNER" "$GEN" aster "$seed" 0 > "$OUT/m.ast"
    "$RUNNER" "$GEN" c     "$seed" 0 > "$OUT/m.c"
    "$OUT/mutant" build-elf "$OUT/m.ast" -o "$OUT/m.elf" >/dev/null 2>&1 || { seed=$((seed+1)); continue; }
    ${CC:-cc} -O0 -w "$OUT/m.c" -o "$OUT/m.cbin" || { seed=$((seed+1)); continue; }
    chmod +x "$OUT/m.elf"
    set +e
    "$RUNNER" "$OUT/m.elf" > "$OUT/ma.out" 2>&1
    "$OUT/m.cbin" > "$OUT/mc.out" 2>&1
    set -e
    cmp -s "$OUT/ma.out" "$OUT/mc.out" || caught=$((caught+1))
    seed=$((seed+1))
done
[ "$caught" -gt 0 ] || fail 'the mutant compiled every seed identically — the harness cannot see an EOR/ORR swap'
ok "mutant caught on $caught of 8 seeds"

printf '%s\n' '[7/7] no compiler change: the baseline reproduces'
. tests/lib/baseline.sh
base=$(aster_baseline_file)
rows=$(wc -l < "$base")
[ "$rows" = 393 ] || fail "the baseline has $rows rows, expected 393"
ok '393 baseline rows unchanged'

echo 'PASS: differential harness (u32, i64, call shapes; the oracle is C)'
