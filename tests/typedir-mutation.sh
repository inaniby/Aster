#!/usr/bin/env bash
# Typed IR mutation witness (P3.1 follow-up, v0.23.53-dev).
#
# The Typed IR contract has two halves that must both be real: `annotate` fills
# every reachable Expr's `type` with Sema's answer, and gen()'s entry guard
# aborts the moment a node's `type` disagrees with Codegen's own exprType.
# A guard nobody can fire is decoration, and an annotate nobody reads is dead
# code. This suite corrupts each half in turn -- on a throwaway copy of
# aster.cpp, never the real source -- and requires the other half to catch it:
#
#   mutation 1: annotate writes Ty::I64 into every node -> the guard must abort
#               with "TypedIR MISMATCH" (the write is consumed).
#   mutation 2: annotate is stubbed out before it writes -> every node keeps
#               the default I32 -> the guard must abort on the first node whose
#               resolved type is not I32 (the read is consumed).
#
# The probe leads with an i64 struct field on purpose: with an all-i32 probe,
# mutation 2 would leave Field nodes "correct by accident" (default I32 ==
# i32) and fail for the wrong reason. An i64 field makes the default wrong.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/src/aster.cpp"
OUT="${OUT:-$(mktemp -d)}"
CXX="${CXX:-g++}"
STRICT="-std=c++17 -O2 -Wall -Wextra -pedantic -Werror"
trap 'rm -rf "$OUT"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

# The guard must exist before anything else is worth measuring.
grep -q 'TypedIR MISMATCH' "$SRC" \
    || fail "the gen() contract guard is gone from src/aster.cpp"

# The probe: an i64 struct field read first (the mutation-2 discriminator),
# then an i32 field store and a literal return (the mutation-1
# discriminators -- their resolved types are not I64).
# The probe's statement order is the whole trick, so it is pinned here:
#   `let a: i32 = 1;`  -- an i32 literal first, so mutation 1 (every node
#                        written as I64) trips the guard on the very first
#                        checked node, before any wrong-type address math can
#                        produce a confusing error of its own.
#   `let v: i64 = p.big;` -- an i64 field read, so mutation 2 (annotate gone,
#                        every node left at the I32 default) trips the guard
#                        here: the default is wrong for this node, while it
#                        would be accidentally right for the i32 field below.
cat >"$OUT/probe.ast" <<'AST'
struct P { big: i64, small: i32 }
fn main() -> i32 {
    let p: P;
    let a: i32 = 1;
    let v: i64 = p.big;
    p.small = 4;
    return 0;
}
AST

# Baseline: pristine source builds strict and the probe compiles silently.
"$CXX" $STRICT "$SRC" -o "$OUT/aster" 2>/dev/null || fail "strict build of pristine source"
"$OUT/aster" build-obj "$OUT/probe.ast" -o "$OUT/probe.o" >/dev/null 2>&1 \
    || fail "pristine compiler rejected the probe"
echo "PASS: pristine strict build and probe clean"

# Mutation 1: annotate writes a wrong type into every node. The gen-entry
# contract guard must abort with TypedIR MISMATCH, not silently generate.
cp "$SRC" "$OUT/mut1.cpp"
sed -i 's/^        e\.type=t;$/        e.type=Ty::I64;  \/\/ MUTATION1/' "$OUT/mut1.cpp"
grep -q 'MUTATION1' "$OUT/mut1.cpp" || fail "mutation 1 did not apply"
"$CXX" $STRICT "$OUT/mut1.cpp" -o "$OUT/aster_mut1" 2>/dev/null || fail "mutation 1 failed to build"
if "$OUT/aster_mut1" build-obj "$OUT/probe.ast" -o "$OUT/p1.o" >"$OUT/m1.log" 2>&1; then
    fail "mutation 1 (annotate writes Ty::I64) was NOT caught -- guard/annotate not consumed"
fi
grep -q 'TypedIR MISMATCH' "$OUT/m1.log" \
    || fail "mutation 1 failed for the wrong reason: $(tail -1 "$OUT/m1.log")"
echo "PASS: mutation 1 (annotate corruption) caught by the contract guard"

# Mutation 2: annotate never runs (stubbed to return before writing e.type), so
# every node keeps the default I32. The guard must abort on the i64 field read.
cp "$SRC" "$OUT/mut2.cpp"
sed -i 's/^    Ty annotateExpr(Expr& e){$/    Ty annotateExpr(Expr\& e){ if(true) return Ty::I32;  \/\/ MUTATION2: no annotate/' "$OUT/mut2.cpp"
grep -q 'MUTATION2' "$OUT/mut2.cpp" || fail "mutation 2 did not apply"
"$CXX" $STRICT "$OUT/mut2.cpp" -o "$OUT/aster_mut2" 2>/dev/null || fail "mutation 2 failed to build"
if "$OUT/aster_mut2" build-obj "$OUT/probe.ast" -o "$OUT/p2.o" >"$OUT/m2.log" 2>&1; then
    fail "mutation 2 (annotate removed) was NOT caught -- e.type not consumed"
fi
grep -q 'TypedIR MISMATCH' "$OUT/m2.log" \
    || fail "mutation 2 failed for the wrong reason: $(tail -1 "$OUT/m2.log")"
echo "PASS: mutation 2 (annotate removed) caught by the contract guard"

echo "PASS: Typed IR mutation witness -- annotate and the contract guard are both consumed"
