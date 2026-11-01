# Aster v0.23.63-dev — Validation Report

**Version:** `0.23.63-dev`
**Theme:** semantic strictness — the five P1 defects from the full source audit
**Full gate:** see Part III

---

## Part 0. What this round is

`AUDIT-v0.23.61-dev.md` audited the whole tree and confirmed ten defects by
execution. v0.23.62-dev fixed the four rated P0. This round fixes the five
rated P1 and adds the regression suite that keeps them fixed.

The P0 round was *"computes the wrong answer"*. This one is the other kind:
**"answers the wrong thing about a program"** — a legal program refused, an
illegal one accepted. Quieter, and correspondingly harder to notice: nothing
crashes, nothing is miscompiled in the cases anyone had written down, and the
cost is paid later and somewhere else.

Three of the five are enum rules this year's own enum work left open; one is an
exemption list that had grown a member nobody re-read; one is an asymmetry
between "an argument is checked" and "everything else is not".

> The two type resolvers disagree, and that is the thread running through all
> five. Sema's `typeOf()` answers `Ty::I32` for **every** arithmetic node — a
> placeholder — while codegen's `exprType()` answers the promoted operand
> width. The TypedIR contract asserts they agree, and bridges the gap with an
> **exemption list**. P1-1 is a family the list swallowed whole; P1-5 is what
> happens when you try to trust `typeOf()` anyway.

Unifying the two resolvers is a semantic decision and stays open. This round
makes the exemption **named** (`semaTypeIsPlaceholder()`) instead of an
anonymous case list, so the next reader meets the disagreement as a sentence
rather than as eleven cases.

---

## Part I. The fixes

| # | Site | Wrong | Right |
| --- | --- | --- | --- |
| P1-1 | `gen()`'s TypedIR exemption list | `Shl` / `Shr` / `BitNot` exempt, so a 64-bit shift was emitted 32 bits wide | the shift family is emitted at the operand's own width |
| P1-2 | `typeOf()`, the comparison branch | two different enums compare as integers | an enum compares only with the **same** enum or with an `i32` |
| P1-3 | `initializerFits`, the enum branch | any constant is accepted into an enum slot | `enumValueFits` — the value must sit in `i32`'s signed range |
| P1-4 | `enumDeclaration()`, the auto-increment | only the explicit `= value` was ever checked | the auto-increment goes through the same predicate |
| P1-5 | `checkValue` and the four value positions | an *argument* was checked; a `let` / `Assign` / `return` was not | `tyAssignable` runs at a `let`, a local `Assign`, a global `Assign` and a `return`; the two memory stores are left alone (below) |

P1-3 and P1-4 are one predicate because three places ask the same question —
an explicit `= value`, the increment that follows it, and a constant landing in
an enum slot — and each of them used to answer *yes*.

The range check runs **before** the assignability check at all three stores.
That ordering is not cosmetic: `let b: u8 = 300;` reports

```
local initializer does not fit in u8: x (300)
```

and not the technically-true-but-useless `expected u8, got i32`. The one
pre-existing suite that asserted the useful message (`integer-cast-checks.sh`)
was what caught the first draft getting this backwards.

### Two exemptions, both named

`semaTypeIsPlaceholder(e)` returns true for the arithmetic family and nothing
else. Without it, P1-5 refuses

```
fn add_u8(a: u8, b: u8) -> u8 { return a + b; }     // examples/narrow_so.ast
```

because `typeOf(a + b)` answers `i32` while the function returns `u8`. That is
Sema's placeholder leaking into a store rule, not a defect in the program — so
the arithmetic result is exempt and the disagreement is recorded in the source
at the point it is relied on.

The second exemption is `checkValue`'s `refuseNarrow` parameter, `false` at
exactly two of its eight call sites: a store through a subscript and a store
through a field. This one is a fact the tree carries rather than a principle.
`bootstrap/aster.ast` — the program the M4 self-hosting loop recompiles with
its own output — stores an `i64` instruction word into an `i32[262144]` stream
(`textw[textlen] = w;`), and the bootstrap subset's parser rejects every type
keyword in operand position, so there is **no cast** to spell that truncation
with. Tightening those two sites would break self-hosting with no way to fix
the source.

So the narrowing rule covers the four positions where a value is *bound* to a
declared type, and a store through a subscript or a field keeps the container's
width. Both carve-outs are pinned: [2/9] counts the `false` call sites, and
mutants n7/n8 withdraw each one and must be caught.

A ptr or a bool reaching an integer slot is still refused at **every** store,
the two exempt ones included — that refusal is not about width, so
`refuseNarrow` does not reach it. (`local-array-checks.sh`'s `a[0] = true;`
row is what caught the first draft getting this wrong.)

---

## Part II. Evidence

### II.1 Before/after, on the same programs

Each defect is one program, compiled by the pre-fix compiler (v0.23.62-dev) and
by this one. Three of the five are refusals, so "before" is *accepted* and
"after" is *refused with this message*; two are answers, measured on
`qemu-aarch64`.

| Program | Before | After |
| --- | --- | --- |
| `~(i64 + i64)`, exit status | **255** (`-1`, the 32-bit reading) | **252** (`-4`) — gcc agrees |
| `let a: Color = Red; let b: Dir = North; a == b` | accepted | `cannot compare two different enum types: Color and Dir` |
| `let c: Color = Red; c == <an i64>` | accepted | `an enum may only be compared with the same enum or with an i32 (got i64)` |
| `enum E { A = 2147483648 }` | accepted (wraps) | `enumerator value out of i32 range: A` |
| `enum E { A = 2147483647, B }` | accepted (`B` wraps to `-2147483648`) | `enumerator value out of i32 range: B` |
| `let b: u8 = e;` with `e: i32` | accepted | `type mismatch initializing 'b': expected u8, got i32 (write an explicit cast to truncate)` |
| `let b: u8 = a;` with `a: i64` | accepted | `type mismatch initializing 'b': expected u8, got i64 (…)` |
| `fn f() -> u8 { return n; }` with `n: i64` | accepted | `return type mismatch in function f: expected u8, got i64 (…)` |
| `let c: u8 = a + 1;` with `a: i32` | accepted | accepted — the documented exemption |
| `let b: u8 = 5;` | accepted | accepted — a constant that fits |
| `let b: u8 = 300;` | `does not fit in u8: x (300)` | unchanged |

The last four rows are the point of the ordering discipline: a round whose
whole purpose is refusing more programs must prove it did not refuse the ones
that were legal.

The strict build is clean throughout: `g++ -std=c++17 -O2 -Wall -Wextra
-pedantic -Werror src/aster.cpp`.

### II.2 `tests/type-strictness-checks.sh`

Nine layers, registered in `tests/ci.sh` in both `DEFAULT_SUITES` and
`CRITICAL`.

| Layer | What it does | Result |
| --- | --- | --- |
| [1/9] | strict `-Werror` build of `src/aster.cpp` | PASS |
| [2/9] | source guards: the version constant and one anchor per fix | PASS |
| [3/9] | 19 qemu witnesses — the programs that must still compile and still give the same answer, including the two the carve-out admits | PASS |
| [4/9] | 9 gcc differential cases against `tests/type-strictness-twin.c` | PASS |
| [5/9] | 13 refusals — one per rule, each with its exact message | PASS |
| [6/9] | coverage counting on **both** sides: ≥19 witnesses, ≥13 refusals | PASS |
| [7/9] | 8 mutants, in **both** directions | 8/8 caught |
| [8/9] | byte baseline over the 288 pre-existing rows | PASS |
| [9/9] | 4 shapes × `build-elf` / `build-so` / `build-obj --pic` | PASS |

Two things about this suite are unusual and worth stating.

**The mutation layer is two-sided.** A suite whose rules only refuse has a
blind spot: a mutant that makes the compiler refuse *more* still passes every
refusal and every witness that was already legal, so "8/8 caught" would be
measuring nothing. - **n1, n7, n8** withdraw a rule the real compiler *has* (the shift exemption,
  the element carve-out, the field carve-out). Each must be caught by a program
  the real compiler **accepts** (`mutant_refuses`).
- **n2–n6** restore a defect the real compiler *refuses*. Each must be caught by
  a program the real compiler **refuses** (`mutant_accepts`). Both directions are asserted, because
a mutant that agrees with the real compiler has not been tested, whichever way
it agrees.

**The differential twin covers only the accepting half.** `tests/type-strictness-twin.c`
carries the nine cases where Aster and C must agree; the thirteen refusals have
no twin, because C accepts an implicit narrowing with a warning — that
divergence is the whole point of the rule. The file says so in its header, so
nobody "fixes" the gap by deleting the refusals.

The suite compares **raw** exit statuses, not values normalized into `0..255`.
An Aster `return r` *is* the process exit status and is already `r & 0xff`, so
a witness expecting `~(i64+i64)` to be `-4` must compare against `252`
directly; normalizing both sides first made a correct compiler look wrong.

### II.3 The three suites that had to be realigned

A round that refuses more programs always finds out which suites had encoded
the old answer as an expectation. Three did:

| Suite | What moved |
| --- | --- |
| `tests/enum-checks.sh` | a witness named *"distinct enums, same value, compared"* had encoded P1-2 as legal. It became a refusal, and four more joined it (cross-enum `!=`, an enum against an `i64`, an auto-increment past `i32`, a constant past `i32`). The rejection matrix is 10 rows now |
| `tests/precedence-checks.sh` | two witnesses — `let b: i32 = <an i64>;` and `let b: u8 = <an i32>;` — were documented as *"narrowing a value has always been allowed in both scopes, and still is"*. Both became refusals; the cast spelling took their place as a witness. Mutants m8–m12 had to change probe case as well, from `u8 = 300` to `u32 = 0 - 1`: a constant that is *both* out of range and narrowing is now refused twice over, so it no longer isolates the range check under test |
| `tests/array-address-checks.sh` | `return fill(w);` returned an `i64` from a `-> i32` function. Now `return i32(fill(w));` |

`bootstrap/aster.ast` moved too, at exactly two lines:
`data_size = align_up(data_size, w)` and `bss_size = align_up(bss_size, w)`
were `i64` results landing in `i32` slots. A new `align_up32` does the
arithmetic at the slot's width, so nothing truncates anywhere. An instrumented
compiler that reports every narrowing instead of refusing it found **exactly
two** sites in the whole 6 000-line self-host — which is what made the
carve-out for `textw[textlen] = w;` the only one worth keeping rather than a
convenience.

That is the honest cost of the round being the *second* batch of an audit: some
of what it fixes was written down as intended behavior by the round that
introduced it.

### II.4 Byte baseline

`tests/baseline/v0.23.63-dev/example-hashes.txt` — 360 rows, frozen for this
version. **Zero rows changed.**

All 121 examples compile to exactly the bytes v0.23.62-dev produced, verified
as a full 363-row diff (360 frozen rows plus the three rows the version's own
snapshot must register) before the snapshot was taken. That is the expected
footprint for a round that only changes *which programs are admitted*: no
instruction moved, so nothing in the corpus could.

It is also the round's strongest safety claim, and the reason the exemption in
Part I is not a compromise but a measurement — the first draft of P1-5 broke
two shipped examples, and the byte diff is what said so.

### II.5 The gate's own floors, re-measured after the round

See Part III — the gates were run against the finished tree, not read from the
previous report.

---

## Part III. Full gate

`LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc bash tests/ci.sh`

```
CI SUMMARY: 118 passed, 0 skipped, 0 failed (of 118 suites)
APK GATES : 3 passed, 0 skipped, 0 failed
```

117 before this round, 118 after it; no skips, so nothing was skipped in order
to be green.

| Gate | Measurement after the round |
| --- | --- |
| `coverage-checks.sh` | **84.59%** of **7554** executable lines (floor 80%) |
| `mutation-score-checks.sh` | **26 suites / 167 mutants** (floors 24 / 150 / 2 per suite) → 167/167 caught |
| `ci-protocol-checks.sh` | 118 suites, 121 examples, 360 baseline rows, 35 mutation-bearing suites, no orphans |
| `version-checks.sh` | banner, the single version literal, `CMakeLists.txt`, README, `VERSION_HISTORY.md`, `ARCHITECTURE.md` and this report all name `0.23.63-dev` |

The mutation census gains one suite and eight mutants; the compiler's
executable-line count grows by the new predicate, its four call sites and the
comment that explains the carve-out, and coverage holds at 84.59% of 7554.

### What the round did not change

- No language change, no new reserved word, no new example; the lexer tables
  and `bootstrap/aster.ast` are untouched, and the bootstrap loop still closes.
- No instruction. 363/363 baseline rows byte-identical, 0 changed, 0 new.
- The eleven other suites affected by a tightened rule — `enum-checks.sh`,
  `integer-cast-checks.sh`, `literals-checks.sh`, `cast-conversions-checks.sh`,
  `eval-order-checks.sh` among them — were each re-run to `RC=0`, not merely
  re-read.

### What is still open

The audit's root cause behind P1-1: **`typeOf()` and `exprType()` are two
resolvers that disagree**, and the TypedIR contract papers over it with an
exemption list. Unifying them is a semantic decision — it changes what width an
arithmetic node *is*, which is exactly the thing the byte baseline protects —
so it stays out of this round. What landed instead is that the exemption has a
name and a comment, and that `let c: u8 = a + 1;` is documented as exempt in
`docs/language-reference.md` rather than being an accident nobody wrote down.

The audit's P2 batch (`.so` page alignment, struct layout overflow, and the
code-review findings) is untouched and still queued in `AUDIT-v0.23.61-dev.md`.
