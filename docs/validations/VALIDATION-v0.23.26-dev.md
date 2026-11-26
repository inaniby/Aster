# Validation Report — v0.23.26-dev

**Feature: a pointer can finally be tested for null.** The user asked the
question directly after the conditions round — *"null和非null可以判断吗"* — and
the honest answer was no, in three ways at once: `if (p)` was refused (a ptr is
not a truthy type, v0.23.25-dev's rule), `p == 0` was refused by three copies of
"pointer comparison is not supported yet", and there was no way even to *write*
a null, because `let p: ptr = 0;`, `f(0)` and `return 0;` from a `-> ptr`
function were all type errors. This round closes all three with one idea: **the
literal `0` in a pointer context is the null pointer constant**, as in C, and
`==`/`!=` answer whether two addresses are the same or whether an address is
nothing.

```
$ ./aster build-elf examples/null_ptr.ast -o null_ptr && ./null_ptr
$ echo $?
33                                     # matches the gcc twin of the same program — §7
```

## 1. Why this round exists: three halves of one gap

A round that fixed only the comparison would have shipped `p == 0` with no way
to produce a null except a zero global in `.bss` — legal before this round, and
the only spelling that existed. The three halves:

1. **`==` was refused for a `ptr`.** Three copies of
   `pointer comparison is not supported yet`: sema's `typeOf`, and codegen's
   `genBool` and `emitCondition`.
2. **There was no null to compare against.** `let p: ptr = 0;`,
   `argument type mismatch calling f at argument 1: expected ptr`, and
   `return type mismatch in function h`.
3. **Truthiness was not the way out.** The conditions round had just refused
   `if (p)` on purpose, and that rule was right: an address is not a truth
   value.

So the round is one concept — a null pointer constant — applied at every gate a
pointer can be entered through, plus the equality test that consumes it.

## 2. The feature: one predicate, four gates, two passes

**The predicate.** `isNullConstant` is three conditions: the node is a `Num`, it
is *not* a bool literal, and its value is `0`. The middle one is the whole
reason the function exists — `false` is a `Num` whose value is also `0`, and a
predicate written as `e.n==0` would let a bool be an address. Mutant m3 deletes
the `boolLit` test and requires `let p: ptr = false;` to compile, which is what
proves the refusal is live rather than incidental.

**The gates.** Four positions admit the constant — a local (`let p: ptr = 0;`),
an assignment (`p = 0;`), an argument (`f(0)`) and a return
(`fn h() -> ptr { return 0; }`) — in **both** passes, because sema is the rule
and codegen is its defensive twin and a rule enforced in only one of them is a
rule waiting to rot. Two general assignment rules carry the rest:
`tyAssignable` on the value lattice, and sema's `ptrToAssignable`, which gained
the `Expr` parameter it needed to tell `0` from any other integer (it had been
`ptrToAssignable(Ty,Ty)` — types alone cannot express "the literal zero").

**`ptr<S>` comes along for free.** A pointer-to-struct's struct id is compared
when one address is stored into another; null has no struct id to mismatch, so
`let ps: ptr<S> = 0;` is admitted by the same predicate.

## 3. The comparison: no new instruction, and that was verified first

Before any type rule was changed, a probe removed the three refusals and asked
what the emitter would do. The answer was already correct — and the
disassembly says why:

```
$ aarch64-linux-gnu-objdump -d tmp-p3.o | grep cmp
  34:	eb01001f 	cmp	x0, x1        # ptr == ptr, at full width
  74:	7100001f 	cmp	w0, #0x0      # a bool value against zero
```

`tyIs64(Ty)` already returned true for `Ty::Ptr`, so the comparison path's
existing width rule — `wide = tyIs64(ta)||tyIs64(tb)` — was already choosing
`CMP Xn, Xm` and generating each operand at 64 bits. **The round therefore
contains no new encoding, no new instruction and no new register discipline**;
it is entirely a matter of which programs the type rules let through. That is
also why the byte baseline holds by construction: no pre-existing example can
contain a pointer comparison or a null literal in a ptr slot (both used to be
compile errors), so not one old byte can move.

**Two boundaries are deliberate.** Ordering two addresses (`< <= > >=`) stays
rejected — which of two unrelated objects "came first" is not a question Aster
answers — and a ptr compared with an integer that is not the literal `0` stays
rejected, so `p == 1`, `p == -1` and `p == x` are errors. `if (p)` stays
rejected too: write `if (p != 0)`.

## 4. `tests/null-ptr-checks.sh` — nine layers, all run

Registered in `tests/ci.sh` after `condition-checks.sh`.

**[1/9] Strict build.** `-Werror` (and `-pedantic`, as `ci.sh` builds), zero
warnings.

**[2/9] Source guards.** The predicate's exact form; `tyAssignable`'s ptr
branch; `ptrToAssignable`'s new signature and all 4 of its sites (1 definition
+ 3 calls); the eight gates that admit the constant; both new messages (the
ordering one counted at exactly 3 — sema plus both codegen twins); and an
assertion that the old blanket refusal is **gone from the source**, so a
reintroduction cannot hide behind a stale message.

**[3/9] Behavioural battery — 19 cases under qemu.** The constant in every
position it may appear (local, argument, return, assignment, global); both
equality directions including `0 == p`; two pointers for the same object and
for different ones; a comparison stored as a bool and composed with `&&` and
`!`; the search shape (hit and miss); a pointer read out of memory with
`load_ptr`; `ptr<S>` null and non-null; a loop driven by `p != 0`; and an array
name's address against null.

**[4/9] Differential battery — 5 cases, gcc-differential.** The search shape
end to end, two names for one object, null through a parameter and back out of
a return, a null test stored as a value and reused, and the shipped example
against `tests/null-ptr-example-twin.c`. Every case is compiled by
`aarch64-linux-gnu-gcc -O2` and both exit statuses are compared — no
hand-computed expectation anywhere.

**[5/9] Rejection matrix — 26 cases.** `if (p)` and `while (p)`; ordered
comparisons at all four operators, against both a ptr and `0`; `p == 1`,
`p == -1`, `p != 7`, `p == x` (an i32 variable); `false` and `true` in all four
ptr positions; non-zero integer literals in the same four; a ptr into an `i32`
slot and into an `i32` argument; and a struct against `0`.

**[6/9] Coverage map.** 22 named rows — every accepted shape and every refused
one — must stay resident.

**[7/9] Mutation layer — 8 mutants.** Drop the predicate (m1); withdraw ptr
equality from `emitCondition` (m2), from `genBool` (m2c) and from sema (m2b);
let `false` be an address (m3); allow ordering (m4); allow `p == 1` (m5); let
any integer literal be null (m6); withdraw the null return (m7).

**[8/9] Byte-identity baseline.** 288/288 rows reproduce, 3 of them the new
`null_ptr.*` rows, the other 285 byte-identical.

**[9/9] The shipped example, end to end.** `examples/null_ptr.ast` exits 33,
equal to its C twin.

## 5. What this deliberately does not do

- **No `null` keyword.** The literal `0` is the spelling, as in C; a second way
  to say the same thing would be a second thing to keep consistent.
- **No pointer truthiness.** `if (p)` is still refused — an address is not a
  truth value, and v0.23.25-dev's boundary holds.
- **No ordering, and no new arithmetic.** `p < q` stays an error, and a ptr's
  only arithmetic relationship to an integer remains the byte offset it already
  had (`p + i`).
- **No crossing back.** A `ptr` is still not an integer in any position:
  `let x: i32 = p;` is unchanged.

## 6. Byte identity: 285 of 285

`tests/struct-checks.sh` [4/8] re-hashes every example in three modes
(`build-so`, `build-elf`, `build-obj --pic`) against
`tests/baseline/v0.23.5-dev/example-hashes.txt` and **passed with the round's
compiler**: the 285 pre-existing rows byte-identical, plus 3 new rows recording
`examples/null_ptr.ast`. This holds by construction — the round adds no codegen
path and admits only programs that used not to compile — and the re-recording
was verified by `tests/rebuild-baseline-v0.23.26.sh`, which refuses to write the
file unless every old row reproduces.

## 7. Verification log

| Step | Result |
|---|---|
| Strict `-Werror` (+ `-pedantic`) build of the modified compiler | clean |
| Feasibility probe (three refusals removed, before any design) | `p == 0` and `let p: ptr = 0` behaved correctly; `cmp x0, x1` confirmed in the disassembly |
| `examples/null_ptr.ast` vs its C twin | both exit 33 |
| `null-ptr-checks.sh` [3/9] battery | **19/19** behavioural cases |
| `null-ptr-checks.sh` [4/9] differential battery | **5/5 match the C oracle** |
| `null-ptr-checks.sh` [5/9] rejections | **26/26** rejected with the naming diagnostic |
| `null-ptr-checks.sh` [6/9] coverage map | 22 named cases resident |
| `null-ptr-checks.sh` [7/9] mutations | **8/8** correctly turn the battery red |
| `null-ptr-checks.sh` [8/9] baseline | **288 recorded outputs reproduced byte for byte** (285 old + 3 new) |
| `null-ptr-checks.sh` [9/9] shipped example | exits 33, equal to its twin |
| Test case `0 == p`, first written as a rejection | wrong — it is the same test as `p == 0`; moved to the behavioural battery |
| Test case `0 + p`, first written as a rejection | wrong — pointer arithmetic has always been legal; replaced by a struct-against-0 case |
| Mutant m2, first aimed at `genBool` | `if (p == 0)` still compiled: a condition runs through `emitCondition` (operand `c`). Split into m2 + m2c, proving both twins live |
| Mutant m4 (allow `p < q`) | unreachable from one pass alone — the other still refuses; the mutant withdraws both halves, which is the point of having two |
| Mutant m5's first form (`if(true)`) | inverted: the guard reads `if (!null) throw`, so dropping it needs `if(false)` |
| `sema-checks.sh` pinning `pointer comparison is not supported yet` | the message no longer exists (it narrowed into two); the case asserts the ordering message and a second case asserts the integer one |
| Full CI | see §8 |

## 8. Full CI

```
========================================
CI SUMMARY: 83 passed, 0 skipped, 0 failed (of 83 checks)
========================================
```

| CI | v0.23.25-dev | v0.23.26-dev |
|---|---|---|
| Result | 82 passed / 0 skipped / 0 failed | **83 passed / 0 skipped / 0 failed** |
| Checks | 82 | 83 (+1: `null-ptr-checks.sh`) |
| Baseline rows | 285 (282 unchanged + 3 new) | 288 (285 unchanged + 3 new) |
| New resident suite | `condition-checks.sh` | `null-ptr-checks.sh` |

## 9. What this unblocks

- **"Found nothing" is now expressible.** A search function answers an address
  or null, the caller tests it with `== 0`, and the pattern needs no sentinel
  index, no out-parameter and no separate "found" flag.
- **Pointers can be cleared.** `p = 0;` turns a live address into nothing, so a
  pointer can be reset and re-tested — the shape a hand-written free-list or a
  cache slot needs.
- **Two addresses can be compared for identity.** `p == q` answers "same
  object" without converting anything to an integer, at 64 bits, with no cast.
- **The remaining pointer boundary is now written down, not assumed.** Ordering,
  truthiness and every integer but `0` are refused by name in the matrix and
  pinned by mutants, so the next round that wants them has to say so.
- **Still open, in the order the difficulty audit argued:** the
  debug-information slice (`.debug_info` on top of the v0.23.12-dev line
  table), then the audit-ranked backlog.
