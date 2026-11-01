# Aster v0.23.62-dev — Validation Report

**Version:** `0.23.62-dev`
**Theme:** evaluation order and operand width in codegen (the four P0 defects from
the full source audit)
**Full gate:** see Part III

---

## Part 0. What this round is

`AUDIT-v0.23.61-dev.md` audited the whole tree and confirmed ten defects by
execution. This round fixes the four rated P0 and adds the regression suite that
keeps them fixed. Nothing in the language changes; there is no new surface, no
new example, and no new syntax.

The four defects share one mechanism, and the suite is built around that
mechanism rather than around the four shapes:

> `X16` holds the address a store is about to write through. Evaluating an
> operand is **not** inert with respect to `X16` — materializing a *global*'s
> address writes it too. So a store that evaluates its right-hand side after
> computing its address retargets itself at whatever global the right-hand side
> mentioned.

Two of the four are that. The other two are the same story about width: an
operand generated at the default width rather than its own.

The audit's meta-finding is the reason the suite is shaped the way it is: all
four had survived a 115-suite green gate, because the existing tests were
written in the one column of the matrix that dodges them — a constant
subscript, a constant right-hand side, a 32-bit operand.

---

## Part I. The fixes

| # | Site | Wrong | Right |
| --- | --- | --- | --- |
| P0-1 | `Stmt::IndexAssign`, multi-dimensional scalar branch | address first, value second | value first, address second |
| P0-2 | `emitElemAddrField` | field base first, subscript second | subscript first, field base second |
| P0-3 | `Stmt::DerefAssign` | `gen(*s.expr)` at the default `i32` | `gen(*s.expr, elem)` |
| P0-4 | `gen(Cast)` → `bool` | always `cmpZero` (32-bit) | `tyIs64(from) ? cmpZeroX : cmpZero` |

P0-1's struct branch deliberately keeps addressing first, and the source now
says why: `emitStructStore` parks its destination in the frame and reloads `X16`
per field, so it never holds an address across the value's evaluation. Splitting
that branch out is why the fix is a two-line reordering rather than a rewrite.

---

## Part II. Evidence

### II.1 Before/after, on the same programs

Each defect is one program, run on `qemu-aarch64`, compiled by the pre-fix
compiler (`HEAD`, v0.23.61-dev) and by this one. Each is paired with a control
that differs only in the operand kind — the control was already correct before
the fix and must still be correct after it, which is what shows the fix is a fix
and not a different behavior wearing the same name.

| Program | Pre-fix | This version | Correct | Note |
| --- | --- | --- | --- | --- |
| `a[1][2] = g;` → read back (`g` a global) | **0** | **42** | 42 | P0-1: the store landed on `g`'s address |
| `a[1][2] = v;` → read back (`v` a local) | 42 | 42 | 42 | control — unchanged |
| `s.xs[gi]` (`gi` a global) | **0** | **3** | 3 | P0-2: the base was already clobbered |
| `s.xs[2]` (constant subscript) | 3 | 3 | 3 | control — unchanged |
| `*p = -5` on a `ptr<i64>`, then `q > 0` | **1** (read `4294967291`) | **0** | 0 | P0-3 |
| `bool(4294967296)` | **0** | **1** | 1 | P0-4 — C agrees (see the twin) |

The strict build is clean throughout: `g++ -std=c++17 -O2 -Wall -Wextra
-pedantic -Werror src/aster.cpp`.

### II.2 `tests/eval-order-checks.sh`

Nine layers, registered in `tests/ci.sh` in both `DEFAULT_SUITES` and
`CRITICAL`.

| Layer | What it does | Result |
| --- | --- | --- |
| [1/9] | strict `-Werror` build of `src/aster.cpp` | PASS |
| [2/9] | 5 source guards: the version constant and one anchor per fix | PASS |
| [3/9] | 19 qemu witnesses, each a distinct exit code, over the operand-kind matrix (constant / local / global / call) | PASS |
| [4/9] | 9 gcc differential cases against `tests/eval-order-twin.c` | PASS |
| [5/9] | 4 rejections: the array bounds checks still fire after the reordering | PASS |
| [6/9] | coverage counting — ≥19 witnesses, ≥4 refusals | PASS |
| [7/9] | 4 mutants, each restoring exactly one defect, `cmp -s` proving the source really changed | 4/4 caught |
| [8/9] | byte baseline over the 288 pre-existing rows | PASS |
| [9/9] | the four fixed shapes through `build-elf` / `build-so` / `build-obj --pic` | PASS |

Layer [5/9] exists because a reordering is the kind of fix that can move
something else: a bounds check that ended up *after* the store it guards would
be a new bug wearing this round's name. Layer [7/9]'s `cmp -s` is there because
a mutation that does not change the source reports "caught" while testing
nothing.

### II.3 Byte baseline

`tests/baseline/v0.23.62-dev/example-hashes.txt` — 360 rows, frozen for this
version. Three examples changed bytes in all three baseline modes:

| Example | build-so | build-elf | build-obj --pic |
| --- | --- | --- | --- |
| `array_address` | changed | changed | changed |
| `multi_dim_array` | changed | changed | changed |
| `struct_array_field` | changed | changed | changed |

9 of 360 rows, every one hash→hash, none hash→`FAILED`. That the three changed
names are exactly the three examples that exercise a struct field's array, a
multi-dimensional store and an array address is the expected footprint. The
eight suites carrying `FILTER` lists already exclude all three names, so no
suite sees a row count it does not expect; the three whole-baseline suites take
the new rows directly.

### II.4 The gate's own floors, re-measured after the round

| Gate | Measurement |
| --- | --- |
| `coverage-checks.sh` | (see Part III) |
| `mutation-score-checks.sh` | 25 suites declare 159 mutant builds (floors: 24 suites, 150 mutants, 2 per suite) — this round's suite adds 1 suite / 4 mutants |
| `ci-protocol-checks.sh` | 116 suites, 121 examples, 360 baseline rows, 34 mutation-bearing suites, no orphans |
| `version-checks.sh` | the banner, the single version literal, README, VERSION_HISTORY and this report all name `0.23.62-dev` |

---

## Part III. Full gate

`LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc bash tests/ci.sh`

```
CI SUMMARY: 116 passed, 0 skipped, 0 failed (of 116 suites)
APK GATES : 3 passed, 0 skipped, 0 failed
```

116 suites, up from 115 — this round's `eval-order-checks.sh` is the 116th — and
no skips, so nothing was skipped in order to be green. Measured on the same
tree:

| Gate | Measurement after the round |
| --- | --- |
| `coverage-checks.sh` | **84.71%** of **7526** executable lines (floor 80%) |
| `mutation-score-checks.sh` | **25 suites / 159 mutants** (floors 24 / 150 / 2 per suite) → 159/159 caught |
| `ci-protocol-checks.sh` | 116 suites, 121 examples, 360 baseline rows, 34 mutation-bearing suites, no orphans |

### What the round did not change

- No language change, no new example, no new reserved word; the lexer tables and
  `bootstrap/aster.ast` are untouched (the bootstrap loop still closes).
- Coverage and the mutation census are flat-to-up: the compiler's executable-line
  count is unchanged at 7526 and coverage holds at 84.71%, while the census gains
  one suite and four mutants.
- The gate's own floors were re-run, not merely re-read: a version bump that
  forgets a baseline snapshot is still a hard failure, and `version-checks.sh`
  still pins the banner, the single version literal, README, VERSION_HISTORY and
  this report.

### What is still open

The audit's five P1 defects and its P2/code-review findings are **not** in this
round; `AUDIT-v0.23.61-dev.md` carries the list and the suggested batching. The
next candidate batch is the P1 half: `typeOf`/`exprType` unification with its
TypedIR exemption list, the three enum-strictness gaps, and `checkValue` routed
through `tyAssignable` — all of which are "silently accepts an ill-typed
program" rather than "silently computes the wrong answer", which is why they
rank below the four fixed here.
