#!/bin/sh
# Syntax fuzzer (P4.4).
#
# The parser is the one component every input reaches, and it is the one that
# has actually taken the compiler down: v0.23.10-dev shipped with six
# `z->a = std::move(x); z->line = x->line;` sites -- reading a moved-from
# unique_ptr -- which crashed on perfectly legal programs (a negative literal,
# a `!`, a `*p = v`). The strict build was clean and the focused diagnostics
# suite passed; only the full CI caught it.
#
# This suite is the guard against that class of bug. It throws a few thousand
# generated inputs at the compiler and asserts one property:
#
#     every input either compiles (exit 0) or is rejected cleanly (exit 1).
#     Anything else -- a signal, an abort, a timeout -- is a crash.
#
# Three things make it more than a loop over random bytes:
#
#   * The corpus is four kinds deep (see tests/fuzz-gen.py): fixed seeds for
#     the paths that have crashed, mutations of real examples (half of them a
#     single edit, so the input is still nearly valid), token soup for the
#     lexer, and valid frames filled with random statements -- the last of
#     which is what gets past the parser into Sema and codegen. The suite
#     asserts a nonzero share actually COMPILES, so the corpus cannot quietly
#     degrade into "everything is rejected at the first token".
#   * Step 5 runs a subset through the two other output paths (PIC object and
#     shared object). Those carry different codegen -- PLT/GOT entries,
#     relocations, a different ELF header -- and are not exercised by the
#     build-elf path the main loop uses.
#   * Step 6 proves the suite can still fail. It injects the exact
#     move-then-deref bug back into a COPY of the source and requires the
#     fuzzer to crash it. A fuzzer that cannot fail is not evidence.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
OUT=${OUT:-tmp-fuzz-checks}
FUZZ_COUNT=${FUZZ_COUNT:-2000}
# How many inputs also take the object / shared-object paths (step 5).
FUZZ_SUBSET=${FUZZ_SUBSET:-300}
FUZZ_SEED=${FUZZ_SEED:-20261013}
# No single input may take longer than this.
FUZZ_TIMEOUT=${FUZZ_TIMEOUT:-10}
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# Step 6 DELIBERATELY crashes a compiler built from an injected bug. Without
# this, each of those crashes drops a core file into the project root -- 44 of
# them, ~39 MB, on every run, including every CI run. The crash is the point;
# the core file is not evidence of anything, because the input that caused it
# is already recorded by the suite.
ulimit -c 0 2>/dev/null || true

printf '%s\n' '[1/7] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

printf '%s\n' '[2/7] Source guard: the generator produces all four kinds of input'
[ -f tests/fuzz-gen.py ] || { echo "FAIL: tests/fuzz-gen.py missing"; exit 1; }
for kind in mutation soup skeleton SEEDS; do
    grep -q "$kind" tests/fuzz-gen.py \
        || { echo "FAIL: generator has no '$kind' corpus kind"; exit 1; }
done
echo "PASS: fixed seeds + mutation + token soup + skeleton all present"

printf '%s\n' "[3/7] Generate the corpus (seed $FUZZ_SEED, $FUZZ_COUNT inputs)"
python3 tests/fuzz-gen.py --seed "$FUZZ_SEED" --count "$FUZZ_COUNT" \
    --outdir "$OUT/corpus" --corpus examples
n=$(find "$OUT/corpus" -name '*.ast' | wc -l)
[ "$n" -eq "$FUZZ_COUNT" ] \
    || { echo "FAIL: expected $FUZZ_COUNT inputs, generated $n"; exit 1; }

printf '%s\n' '[4/7] Fuzz: every input must compile (0) or be rejected (1) -- never crash'
ok=0; rej=0; crash=0
for f in "$OUT"/corpus/*.ast; do
    rc=0
    timeout "$FUZZ_TIMEOUT" "$OUT/aster" build-elf "$f" -o "$OUT/out" >/dev/null 2>&1 || rc=$?
    case $rc in
        0) ok=$((ok + 1)) ;;
        1) rej=$((rej + 1)) ;;
        *) crash=$((crash + 1)); echo "  CRASH (exit $rc): $f" ;;
    esac
done
echo "      compiled=$ok rejected=$rej crashed=$crash"
[ "$crash" -eq 0 ] || { echo "FAIL: $crash input(s) crashed the compiler"; exit 1; }
# The corpus has to reach the compiler's interior, not bounce off the lexer:
# a run where nothing ever compiles proves very little.
[ "$ok" -gt 0 ] \
    || { echo "FAIL: no input compiled -- the corpus never reaches the parser"; exit 1; }
echo "PASS: $ok of $FUZZ_COUNT inputs compiled, $rej rejected cleanly, 0 crashed"

printf '%s\n' "[5/7] The other output paths (build-obj --pic, build-so) over $FUZZ_SUBSET inputs"
sub=0; subcrash=0
for f in "$OUT"/corpus/*.ast; do
    [ "$sub" -lt "$FUZZ_SUBSET" ] || break
    rc=0
    timeout "$FUZZ_TIMEOUT" "$OUT/aster" build-obj --pic "$f" -o "$OUT/out.o" >/dev/null 2>&1 || rc=$?
    case $rc in
        0|1) ;;
        *) subcrash=$((subcrash + 1)); echo "  CRASH (build-obj --pic, exit $rc): $f" ;;
    esac
    rc=0
    timeout "$FUZZ_TIMEOUT" "$OUT/aster" build-so "$f" -o "$OUT/out.so" >/dev/null 2>&1 || rc=$?
    case $rc in
        0|1) ;;
        *) subcrash=$((subcrash + 1)); echo "  CRASH (build-so, exit $rc): $f" ;;
    esac
    sub=$((sub + 1))
done
[ "$subcrash" -eq 0 ] \
    || { echo "FAIL: $subcrash crash(es) on the object / shared-object paths"; exit 1; }
echo "PASS: $sub inputs through build-obj --pic and build-so -- 0 crashes"

printf '%s\n' '[6/7] Proof the suite can still fail: re-inject the move-then-deref bug'
# The v0.23.10-dev bug, verbatim: move the child into the parent, THEN read
# the (now null) child's position. Injected into a COPY, never src/aster.cpp.
cp src/aster.cpp "$OUT/broken.cpp"
# The bug is spelled with whichever level `-` parses at: the prefix operators
# were moved out of primary() into the new unary() level in v0.23.27-dev, so
# the injection names that level now. (The line is pinned by a grep below, so a
# future move makes this step fail loudly instead of proving nothing.)
BEFORE='if(eat(TK::Minus)){E x=unary();E z(new Expr(Expr::Neg));z->line=x->line;z->col=x->col;z->a=std::move(x);return z;}'
AFTER='if(eat(TK::Minus)){E x=unary();E z(new Expr(Expr::Neg));z->a=std::move(x);z->line=x->line;z->col=x->col;return z;}'
grep -qF "$BEFORE" "$OUT/broken.cpp" \
    || { echo "FAIL: the injection site is gone -- update this step, do not drop it" >&2; exit 1; }
sed "s|$BEFORE|$AFTER|" \
    "$OUT/broken.cpp" > "$OUT/broken.injected" \
    || { echo "FAIL: sed injection failed"; exit 1; }
mv "$OUT/broken.injected" "$OUT/broken.cpp"
grep -q 'TK::Minus)){E x=unary();E z(new Expr(Expr::Neg));z->a=std::move(x);z->line=x->line' "$OUT/broken.cpp" \
    || { echo "FAIL: bug injection did not apply -- the proof would be vacuous"; exit 1; }
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror "$OUT/broken.cpp" -o "$OUT/broken-aster"

caught=0
for f in "$OUT"/corpus/*.ast; do
    rc=0
    timeout "$FUZZ_TIMEOUT" "$OUT/broken-aster" build-elf "$f" -o "$OUT/out" >/dev/null 2>&1 || rc=$?
    case $rc in
        0|1) ;;
        *) caught=$((caught + 1)) ;;
    esac
done
echo "      injected-bug compiler crashed on $caught input(s)"
[ "$caught" -gt 0 ] \
    || { echo "FAIL: fuzzer did not catch an injected crash -- it proves nothing"; exit 1; }
echo "PASS: the injected crash is caught ($caught inputs), so step 4's zero means something"

printf '%s\n' "[7/7] No input hung (each capped at ${FUZZ_TIMEOUT}s)"
echo "PASS: all $FUZZ_COUNT inputs finished inside the per-input cap"

echo "PASS: $FUZZ_COUNT fuzz inputs -- 0 crashes, $ok compiled, $sub also through the .o/.so paths"
