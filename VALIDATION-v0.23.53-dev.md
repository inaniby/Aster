# Validation Report — v0.23.53-dev

**Feature: Typed IR (P3.1 follow-up) — every reachable expression carries its
resolved type from the semantic pass into code generation, and a contract guard
at gen()'s entry makes the two resolvers' agreement mechanical instead of
aspirational.** v0.23.0-dev moved type checking ahead of code generation and
left the two passes each answering "what type is this expression node?" for
itself — `Sema::typeOf` and `Codegen::exprType`, "two resolvers, one contract",
kept honest by a comment and by the tests. This round is a **pure refactor**:
it changes no emitted byte of any of the 82 examples (§6), and the full CI is
green with zero drift.

```
// the round in one shape — sema annotates, codegen reads, the guard compares:
//   Sema::annotateExpr   e.type = typeOf(e);  recurse a/b/args
//   Codegen gen()        if (e.type != exprType(e)) abort("TypedIR MISMATCH")
//   structural reads     Field base, Index bases, Cond arm type <- e.type
// the bootstrap, self-compiled with the guard live on every non-arithmetic
// node: 35881 instructions, 210 functions, 644 globals, zero aborts.
```

## 1. Why this round exists

Two resolvers of one question is a structural hazard even when both are
correct. The comment above `Codegen::exprType` — *"two passes must not
disagree"* — is the whole enforcement mechanism, and a comment cannot fail a
build. Every divergence between the two answers is silent until it produces a
wrong instruction or a wrong rejection, and the only thing standing between a
future edit to one resolver and a confusing bug is that the other one happens
to still agree.

The tests are a real net — 82 examples, 106 suites, a byte baseline — but they
are a net for *today's* divergence, not a contract. The Typed IR closes the
gap mechanically in three moves: the semantic pass **annotates** every
reachable `Expr` with the type it resolved; codegen **reads** the annotation
where it used to recompute one; and gen()'s entry **guard** compares the
annotation against a fresh `exprType` call on every node it emits, aborting the
compile on the first disagreement. The round is deliberately not a
re-architecture: `exprType` stays (it is the guard's oracle, and the arithmetic
family still reads it), `FuncSig` stays beside the type system as it has since
v0.23.37-dev, and the annotation is one new field.

## 2. What shipped

**One new field, beside the old one.** `Expr` already carried a `Ty ty` — but
that member means *"the type this Cast targets"* and *"the type-form argument
of SizeOf/Len"*, not *"this node's type"*. Reusing it would have changed the
meaning of existing code; the new `Expr::type` (default `Ty::I32`) is additive
and means exactly one thing. Nothing else about `Expr` moved, so no AST shape,
fingerprint or example byte is affected.

**`Sema::annotateExpr(Expr&)` fills every reachable node.** It answers
`typeOf(e)` for the node, stores it in `e.type`, and recurses through `a`, `b`
and `args` — the only edges an `Expr` has. `checkStmt` calls it at every site
that touches an expression: the twelve statement-expression sites, the three
index sites, the `if`/`while`/`for` conditions, and each `switch` case
expression. Coverage is therefore **by construction**: any node a statement
reaches is annotated when the statement is checked, and the node's children are
annotated with it. The const-boundary problem the plan anticipated — `check`
takes `const Function&` — dissolves on its own: `s.expr` is a
`const unique_ptr<Expr>&`, but `*s.expr` invokes `unique_ptr::operator*() const`
and yields a non-const `Expr&`, so `checkStmt` can annotate through a const
signature with no signature changes at all.

**Codegen reads the annotation at the structural sites.** Four places that
recomputed a type now read the one annotate wrote: `gen(Field)`'s base type
(`e.a->type`, where the old code called `exprType(*e.a)`), `gen(Index)`'s array
base and pointer base, and `gen(Cond)`'s arm type. These are the sites whose
inputs are *structural* — a struct lvalue, a `ptr<S>`, an array — never
arithmetic, which is what makes them safe to read from the annotation (§4).

**The guard.** gen()'s entry compares `e.type` against `exprType(e)` for every
node and aborts with `TypedIR MISMATCH kind=… type=… exprType=…` on the first
disagreement. It is `fprintf` + `abort`, not `assert`: the failure mode being
guarded against — two resolvers quietly disagreeing — must stay loud in an
`NDEBUG` build too, because that is exactly the build a release ships.

## 3. The evidence chain

**The bootstrap self-compile is the coverage proof.** `bootstrap/aster.ast`
(222 KB of Aster) compiles to 35,881 instructions across 210 functions and 644
globals with the guard live on every non-arithmetic node — and it never fires.
210 functions is every node kind the compiler can emit: a node kind that
`checkStmt` reaches but `annotateExpr` never fills would leave the default
`I32` in place, and the guard would abort on the first function that used it.
Zero aborts across 210 functions is the strongest coverage statement available
without instrumenting the compiler itself.

**The byte baseline is the equivalence proof.** All 348 recorded example rows
reproduce byte-for-byte (§6) — 82 examples × their output modes. A read site
that answered differently from the `exprType` it replaced would move bytes
somewhere in there; nothing moved.

**The mutation witness is the "the guard is real" proof.** A guard that has
never fired is indistinguishable from a guard that cannot fire.
`tests/typedir-mutation.sh` (§5) corrupts each half of the contract on a
throwaway copy of the source and requires the other half to catch it. Both
mutations are caught, by the guard, with the expected message.

## 4. The one disagreement the guard found — and why it was left alone

The guard's first firing during development was not a bug in the annotation.
It was a **long-standing disagreement between the two resolvers, visible for
the first time because something finally compared them mechanically**: for the
arithmetic and bitwise family — `Add`, `Sub`, `Mul`, `Div`, `Mod`, `Neg`,
`BitAnd`, `BitOr`, `BitXor` — `Sema::typeOf` answers `I32` unconditionally,
while `Codegen::exprType` answers `promoteInt(a, b)`, the wider operand. For
`i64a + i64b` the two answers are `i32` and `i64`.

Unifying is not free, and the cost is behavioral, not cosmetic:

- **Teaching Sema to promote would reject programs that compile today.**
  `checkCall` refuses a narrowing argument (`if (wt < wf) return false` — an
  `i64` argument to an `i32` parameter is an error), so `f(i64a + i64b)` with
  `f` taking `i32` is accepted now and would become a compile error.
- **Teaching Codegen to answer `I32` would change emitted instructions** for
  every i64 arithmetic expression in every program.

Both are behavior changes wearing a refactor's clothes, and this round is a
refactor. So the disagreement is **recorded, not resolved**: the guard exempts
the arithmetic family by name, the code comment at the exemption says why and
points here, `annotate` still fills those nodes' `type` with the Sema answer,
and Codegen keeps reading `exprType` for them. Unifying the arithmetic width —
deciding which of the two answers is right and accepting whichever behavior
change follows — is future work, now with a failing guard waiting to tell the
next editor exactly where the seam is.

## 5. What the suites prove

**New: `tests/typedir-mutation.sh` [3/3]** — the Typed IR mutation witness,
registered in `ci.sh`. It builds the compiler strictly three times (pristine,
then two corrupted copies under a `mktemp` directory — `src/aster.cpp` itself
is never touched, so the suite is safe beside the others) and requires:

1. the pristine build accepts the probe silently;
2. **mutation 1** — annotate writes `Ty::I64` into every node — aborts with
   `TypedIR MISMATCH`;
3. **mutation 2** — annotate is stubbed out before it writes, so every node
   keeps the `I32` default — aborts with `TypedIR MISMATCH` on the probe's
   i64 field read.

The probe's statement order is load-bearing and pinned by comment in the
suite. An `i32` literal comes first, so mutation 1 trips the guard on the very
first checked node, before any wrong-type address arithmetic can produce a
confusing error of its own. Then an `i64` field read — `let v: i64 = p.big;` —
is mutation 2's discriminator: the `I32` default is wrong exactly there, while
it would be *accidentally right* on the `i32` field that follows, which is how
the first draft of the probe failed (mutation 2 was caught, but by a
`structFieldOf` error rather than by the guard). The struct field separator is
a comma, not a semicolon — the first draft of the probe did not even parse.

**Everything resident stays green.** `sema-checks.sh` [6/6] and the full
106-suite CI: zero failures, zero skips on a host with the cross toolchain.

## 6. Baseline: not one byte moved

348 of 348 rows byte-identical. This is the expected result and it is asserted,
not assumed: the eight suites that read
`tests/baseline/v0.23.5-dev/example-hashes.txt` re-derive every row they cover
from the freshly built compiler. A refactor that moved a byte would fail there
before it reached this report.

## 7. Reproduction

```sh
# 0) the strict build (zero warnings, as always)
g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o aster

# 1) the bootstrap self-compile — the coverage proof (guard live, zero aborts)
./aster build-obj bootstrap/aster.ast -o /tmp/boot.o
#   -> emitted AArch64 ELF64 ET_REL object (35881 instructions, 210 functions,
#      644 globals)

# 2) the mutation witness — corrupt each half of the contract, require the
#    other half to catch it (three strict builds, ~60s)
sh tests/typedir-mutation.sh

# 3) the semantic pass's own suite
sh tests/sema-checks.sh

# 4) the full CI
LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc sh tests/ci.sh
```

## 8. Files

- `src/aster.cpp` — `0.23.53-dev`; `Expr` gains `type` (default `I32`, beside
  the existing `ty`); `Sema::annotateExpr` fills it from `typeOf` and recurses
  through `a`/`b`/`args`; `checkStmt` calls it at every expression-touching
  site; gen()'s entry guard aborts on `e.type != exprType(e)` for every
  non-arithmetic kind (the arithmetic family is exempt by name, with the
  reason in the comment — §4); four structural read sites (`gen(Field)`'s base,
  `gen(Index)`'s two bases, `gen(Cond)`'s arm type) now read the annotation.
- `tests/typedir-mutation.sh` — the new **[3/3]** mutation witness (§5).
- `tests/ci.sh` — registers the new suite.
- `tests/integer-cast-checks.sh`, `tests/literals-checks.sh` — the asserted
  version string follows the bump.
- `FEATURE_STATUS.md` — Typed IR moves from `planned (P3.1 follow-up)` to
  shipped, with the arithmetic exemption stated in the row.
- `ROADMAP.md` — the v0.23.53-dev row.
- `VERSION_HISTORY.md`, `README.md` — the version, the entry, and this report.
