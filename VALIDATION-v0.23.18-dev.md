# Validation — v0.23.18-dev

**Wide-integer correctness: three defects, three rules, and a suite that
rebuilds the compiler sixteen different ways to prove it.**

v0.23.17-dev added the operators and proved their encodings — 30 qemu checks,
11 differential comparisons against C, three mutations. Every one of those
tests used `i32` values. The moment the new operators met the `i64` type
v0.23.2-dev had added, three defects surfaced at once, and one of them was a
silent wrong answer in a two-line program:

```aster
fn main() -> i32 { let x: i64 = 4294967297; return x % 7; }
```

The correct answer is **5**. v0.23.17-dev returns **1** — it truncates `x` to
1, and `1 % 7` is 1. A wrong answer that looks plausible is the worst kind,
and this one was reachable the day the `%` operator shipped.

---

## 1. The three defects, in the form a user would hit them

**Defect A — a wide literal was chopped back to 32 bits.**
`exprType(Num)` reported every numeric literal as `i32`. A literal reaching an
`i64` slot was already materialized at full width (`emitMov64`, `MOVZ` +
`MOVK`), but the five arithmetic sites then unconditionally sign-extended the
operand *from i32* before operating on it:

```aster
fn main() -> i32 { return 4294967296 / 1000; }   // returned 0; correct is 4294967
```

The extension was pure damage: the value had all its bits, and the `SXTW`
threw the top half away. `4294967296` became `0`, and `0 / 1000` is 0.

**Defect B — an operation's width was decided by its consumer.**
The old code computed `const bool wide = tyIs64(want)` — the width the
*result* will be consumed at — and never looked at the operands. So an `i64`
value met by an `i32` context was computed in 32 bits:

```aster
fn main() -> i32 { let x: i64 = 4294967297; return x % 7; }   // returned 1; correct is 5
```

Whether a multiplication overflows is a property of the values being
multiplied, not of who wants the answer. The old code had it exactly
backwards, and because the truncated value still produced *a* number, nothing
anywhere complained.

**Defect C — local array element types were never recorded.**
`slotElemTypes` (frame slot → element type of a local array) was declared and
read but never written, so `elementTypeOf` fell back to `i32` for every local
array. A local `i64[2]` stored its elements 8 bytes wide while *addressing*
them at 4-byte stride — read and write disagreed about where element 1 lived,
and with one slot covering the whole array, `c[1]` could spill into the
neighbouring local. Global arrays were typed correctly; only locals lied.

All three have the same root: **width was decided at the wrong place** — at
the consumer instead of the value (B), at the operation instead of the
operand (A), and nowhere at all (C).

## 2. Why v0.23.17-dev's suite stayed green through all of it

`operator-checks.sh` was a good suite. It proved that `%` emits `SDIV` +
`MSUB`, that `>>` is `ASR` and not `LSR`, that `~x` is `ORN`. It did that with
`i32` operands, because that was the vocabulary being added — and an `i32`
operand exercises none of the width rules. Nothing in the suite was wrong;
the suite simply had no way to see a 33rd bit.

The trap is general and it has a name in this project now: **the
consistently-truncated expectation**. If the expected value and the buggy
computation both lose their high bits, the test passes — both suites green,
both wrong. Case 39 is exactly that:

```aster
fn main() -> i32 { return 8589934593 == 8589934593 ? 39 : 0; }
```

Both sides are `1` after truncation, so the comparison holds under the bug.
It stays in the matrix as a **forward guard** (it must keep passing) and is
never used as a discriminator. Every other case either compares a large
*positive* constant at full width, or never compares against a large constant
at all. That rule is what makes the other 53 cases able to fail.

## 3. The three rules

The repair is three rules, not three patches, because the defects were one
mistake in three places.

**Rule 1 — a constant operand beyond `i32` makes the operation 64-bit.**
`constExceedsI32` tests the magnitude after peeling `Neg` (so `-4294967297`
counts), against thresholds `0x7fffffff` / `0x80000000`. A literal that does
not fit 32 bits cannot be represented in the operation, so the operation has
to move to 64 bits — regardless of what the consumer asked for.

**Rule 2 — widening is the operand's own job, not the consumer's.**
Every post-hoc `SXTW` is deleted from the arithmetic sites. In its place,
each leaf form widens itself from its own type: the literal, `Neg`, a local
variable, a global variable, a field, three index forms (local, global,
pointer), a deref, a call, and a conditional arm — eight sites, each pinned
by a source guard that counts them. The now-dead `extendTo64` helper is
removed outright, and a guard asserts it stays gone: a helper whose job is
"widen it because someone downstream wants width" is the bug expressed as a
function.

**Rule 3 — an operation is 64-bit if either operand is `i64` or over-wide.**
`tyIs64(want) || tyIs64(ta) || tyIs64(tb) || constExceedsI32(e.a) ||
constExceedsI32(e.b)`, with the operands generated at that width. The
consumer's wish is still in the disjunction — it is just no longer the only
voice. `Cond` takes its arm type from the expression itself when the consumer
is `i32`, so `c ? 4294967297 : small` keeps both arms wide instead of
truncating the one that happens to be large.

One consequence worth stating: these rules make the *i32* paths byte-
identical. `(4N+7)/8 == (N+1)/2` for every N, so the frame packing of an
`i32` local array is unchanged; and no expression composed entirely of `i32`
values takes any new path. That is why 259 of 261 outputs are byte-identical
(§9).

## 4. `tests/wide-int-literal-checks.sh` — seven layers, all run

Registered in `ci.sh` after `wide-int-checks.sh`; total wall clock 1:30.

**[1] Strict build.** `c++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror`.

**[2] 22 source guards.** Each rule's helper and its thresholds; the three
`wideOp` call sites and the two variants that take no right operand (shifts,
`BitNot`); each of the eight leaf widening sites counted individually;
`Cond`'s arm type; `Neg`'s `want` pass-through (`int a=gen(*e.a,want);` —
without it a negative wide literal under a unary minus is narrowed on the way
in); `slotElemTypes[slot]=elem;` being *written* at array declaration; the
element-width store bases; the `SXTW Xd, Wd` encoding counted at exactly
eight; and the deleted helper's absence. A rule that compiles but is not
pinned here can be refactored away silently.

**[3] Rejection matrix.** An `i64` argument into an `i32` parameter
(`argument type mismatch calling f at argument 1: expected i32, got i64`) and
a literal that overflows `i64` (`integer literal exceeds i64 range`). Both
were already rejected; the suite pins the messages so a widening change
cannot quietly turn them into silent truncations.

**[4] 54 qemu-run cases in eight groups.**

| Group | Cases | What it pins |
| --- | --- | --- |
| A wide literals consumed as `i32`, comparison width | 36 37 38 39 47 60 65 | a full-width literal survives an `i32` consumer; comparisons widen from their operands; 39 is the forward guard |
| B `i64` local, full operator spectrum | 11–21 | every operator (including v0.23.17-dev's new ones) at 64 bits |
| C `i64` operand, `i32` consumer | 31–35 | the headline defect: `4294967297 % 7 == 5` |
| D negative constants and `INT64_MIN` | 41–44 | `-4294967297`, `-9223372036854775808`, the peel in `constExceedsI32` |
| E leaf widening: call / field / index / deref / neg / var | 51–59, 66 | each of the eight sites, one case each |
| F conditional arms generated at the result width | 61–64 | `Cond`'s arm type |
| G local array element types | 81–87 | `i64`/`u32`/`u16`/`u8` local arrays stride and store at their own width |
| H must stay 32-bit | 91–96 | a spurious widening is as much a bug as a missing one: `u32` wrap, `i32` overflow, `u16`/`u8` arrays |

**[5] 14 differential comparisons against cross-compiled C.** See §6.

**[6] A 16-mutation layer.** See §7.

**[7] The blind spots, written into the file.** See §10.

## 5. What the old binary does with the same 54 cases

Run against v0.23.17-dev's compiler, the matrix is **23 PASS / 31 FAIL** —
31 defects reproduced in one run, including the two-line `%` program. The 23
that pass split into two honest categories:

- **Forward guards.** 84, 85 (`u16`/`u8` local arrays with values 1, 2, 3 —
  nothing to truncate) and 56, 59, 66 (`i32` leaves, where the old post-hoc
  `SXTW` happened to be harmless). The old code was not wrong about these;
  it was wrong about the ones that failed.
- **The trap, still live.** 81, 82, 83 and 87 pass under the old compiler for
  the wrong reason: read and write truncated *symmetrically*, so
  `c[0] + c[1] == 3000000000000` compared one truncated pattern against
  another and held. That is the §2 trap in its natural habitat, and it is why
  the mutation layer — not the old-vs-new comparison — is what gives group G
  its teeth: delete `slotElemTypes[slot]=elem;` from the *new* compiler and
  storage goes back to full width while addressing stays wide from `s.ty`,
  the symmetry breaks, and 81/82/83 go red immediately.

## 6. The differential layer

Fourteen expressions compiled by `aarch64-linux-gnu-gcc -O2 -fwrapv` must
return the same exit codes as the Aster programs (the guest host binary is
run through `tests/run-aarch64.sh` exactly like the Aster output; a
`-static` probe comes first and the layer prints a clean `SKIP:` on a host
with no AArch64-emitting compiler). This is the layer that catches an
expectation which is wrong in the same direction as the compiler — the
failure mode §2 is about. Two of the fourteen are worth naming:

```c
int main(){ return 1000000000000 % 7; }                  /* case 36 */
int main(){ long x = 4294967297; return x % 7; }          /* case 31 */
```

Writing this layer found two errors *in the tests themselves*, both fixed
before the suite ever ran green: a case whose expected value had taken the
quotient instead of the remainder (`10^12 % 7` is 1, not `142857142857`), and
a case that had been written in the "success returns 0" convention while
every Aster case in the matrix uses the "return the case number" convention.
An oracle only works if both sides are answering the same question.

## 7. The mutation layer

Sixteen mutants, each a one-edit revert of one rule of this round's own diff,
each compiled and run against the same 54-case matrix. A mutant that compiles
and passes means the suite cannot see that rule. All sixteen are caught:

| # | Mutation | Caught by |
| --- | --- | --- |
| M1 | `wideOp` drops the constant test (`… || false`) | 36, 37 |
| M2a | the materialized comparison (`genBool`) drops it | 47 |
| M2b | the conditional comparison (`emitCondition`) drops it | 38 |
| M3 | the call leaf loses its `SXTW` | 51 |
| M4 | the deref leaf loses its `SXTW` | 55 |
| M5 | the field leaf loses its `SXTW` | 53 |
| M6a | the local-index leaf loses its `SXTW` | 54 |
| M6b | the global-index leaf loses its `SXTW` | 57 |
| M7 | `slotElemTypes[slot]=elem;` deleted | 81, 82, 83 |
| M8 | `Cond`'s arm type falls back to the expression's | 61–64 |
| M9 | the array element width forced to 4 | 82, 86 |
| M10 | the global-variable leaf loses its `SXTW` | 56 |
| M11 | the pointer-index leaf loses its `SXTW` | 58 |
| M12 | `Neg` loses its `want` pass-through | 59 |
| M13 | the positive threshold raised past case 60's constant (`0x7fffffff` → `0x80000000`) | 60 |
| M14 | the `Neg` peel removed from `constExceedsI32` | 65 |
| M15 | the local-variable leaf loses its `SXTW` | 66, 59 |

Three of these found real asymmetries on the way. M2a and M2b looked like one
mutation but there are **two** comparison paths — the one that materializes a
comparison as a value (`!` in case 47) and the one that branches on it (`?:`
in case 38) — and each needed its own mutant and its own case, or one of them
could have been broken invisibly. M6a and M6b are two index sites with
*byte-identical* text, so the mutation script distinguishes them by context
(the `slot*8` marker opens the local one, `emitGlobalAddress` the global
one). And M9 chose case 86 over 81 for a reason worth recording: with the
width forced to 4, an `i64[2]` still packs into one slot, so `c[1]` lands
inside the array and 81 stays self-consistent — but 86 declares a second
local `z`, and `c[1]`'s 8-byte store now runs off the end of the slot and
overwrites it. A neighbour is the only witness.

The layer also cost the suite its first architecture decision: launching
sixteen full compiler rebuilds at once starved the machine (every `cc1plus`
in D state, twenty minutes without output). The suite drains them four at a
time and finishes in 1:30.

## 8. A regression this round introduced, and the CI that caught it

Rewriting the local-array declaration (rule 2's element-width storage)
invalidated a guard in `tests/local-array-checks.sh`: the suite pinned the
slot-packing formula as the literal string `const uint32_t slots=(s.count+1)/2;`,
and the new formula is `ceil(N*sizeof(T)/8)`. The full CI run failed on
exactly that line, which is the guard doing its job — the packing rule had
genuinely changed, and a stale pin would have been worse than a red build.

The fix was to update the guard to the new formula and add three more: the
element width (`esz`), the element-width store base (four widths:
`STRB`/`STRH`/`STR X`/`STR W`), and the `slotElemTypes` write. The suite's
comment now records *why* the formula changed and that it is numerically
identical for `i32` (`(4N+7)/8 == (N+1)/2` for every N — which is why the
`i32` frame layout, and every byte of `i32` output, did not move). All eight
layers pass, including the three qemu self-checks of the real frame layout.

Every other source guard in the tree was then verified mechanically against
the new source — every literal `grep -F` pattern in every `tests/*.sh` that
names `src/aster.cpp`, and every counted guard — with exactly one miss, which
was this suite's own, now fixed. No other suite pins text this round touched.

## 9. Byte identity: 259 of 261, and the two that differ

A direct A/B of the v0.23.17-dev compiler against this one over every example
(`examples/*.ast`, 87 files × three modes = 261 builds) reports
**mismatches=2**:

| Output | Why it moved |
| --- | --- |
| `c_struct_abi.build-so` | the array-layout fix reaches a struct's `i64` field array |
| `c_struct_abi.build-obj --pic` | same, object form |

Both are the correction itself: the stride of an `i64` element array is now
the element width. That the change is behaviour-preserving is not asserted,
it is executed: `tests/e2e-c-struct.sh` links that example against a C host
in both directions with 15 assertions and passes, and `struct-checks.sh`
[8/8] re-derives the whole 261-line byte baseline — the two affected rows
re-recorded, the other 259 reproducing exactly. Nothing else in the tree
moved a byte, which is what "the `i32` paths are untouched" means in
practice.

## 10. What this suite deliberately cannot see

Three blind spots are documented in the suite itself rather than left for a
future reader to discover:

1. **The consistently-truncated expectation.** `8589934593 == 8589934593`
   passes when both sides lose their high bits (case 39, §2). Mitigation:
   every expectation is a large *positive* constant compared for value, or
   compares against a small one. This cannot be proven, only designed
   around — so the design is written down.
2. **`&` cannot see a sign extension.** `x & 7` discards the high half
   whichever way it was extended, so the bitwise cases lean on `%`, `/` and
   the comparisons to detect a missing widening. A suite that tested `&`
   alone would report green over a broken `SXTW`.
3. **A `u32` return must not be widened.** Sign-extending a `u32` result
   changes a correct program into a wrong one, so case 52 sits in group H
   (must stay 32-bit) rather than being a "fix" — and case 95
   (`4294967295u + 1 == 0`) is the differential witness that the unsigned
   wrap still wraps.

## 11. Verification log

| Step | Result |
| --- | --- |
| Strict rebuild (`-Werror`) | clean |
| `tests/wide-int-literal-checks.sh` | [7/7] PASS — 22 guards, 2 rejections, 54 qemu cases, 14 differential, 16 mutations, 3 documented blind spots (1:30) |
| Old compiler (v0.23.17-dev) on the same 54 cases | 23 PASS / 31 FAIL — 31 defects reproduced |
| `tests/local-array-checks.sh` | [8/8] PASS after the guard update (§8) |
| `tests/struct-checks.sh` | [8/8] PASS — 261-line baseline, 2 rows re-recorded |
| `tests/e2e-c-struct.sh` | 15 assertions, both directions, against a C host |
| Direct A/B vs v0.23.17-dev | 261 builds, 2 differing (both `c_struct_abi`, §9) |
| Every source guard in `tests/*.sh` | verified against the new source; 1 stale pin found and fixed (§8) |
| Full `tests/ci.sh` | see §12 |

## 12. Full CI

```
========================================
CI SUMMARY: 74 passed, 0 skipped, 0 failed (of 74 checks)
========================================
```

Up from **73/0/0** in v0.23.17-dev: the one new suite is
`wide-int-literal-checks.sh`, and nothing else moved. That includes
`local-array-checks.sh` (§8 — the one suite this round had to touch),
`struct-checks.sh` with its re-derived baseline, `version-checks.sh` (which
demands the documentation this report is part of), the 22 `e2e-*` suites that
run the guest under qemu, and the three APK gates — `native_render`,
`icon_text_demo`, `native_touch` — each verified twice (`validate_apk.py` and
`aster verify-apk`).

| | v0.23.17-dev | v0.23.18-dev |
| --- | --- | --- |
| CI | 73 passed / 0 skipped / 0 failed | **74 passed / 0 skipped / 0 failed** |
| direct A/B | 214/214 byte-identical | **259/261** (2 = `c_struct_abi`, §9) |
| 261-line baseline | reproduces exactly | 2 rows re-recorded, 259 reproduce |
| wall clock | ~29 min | ~18 min |

## 13. What this unblocks

The wide-integer type is now trustworthy under the operators v0.23.17-dev
gave it, which was the precondition for every remaining item on the gap
list: the narrow-argument ABI work (`u8`/`u16` parameters are still not
delivered — recorded, not fixed, since v0.23.17-dev) can be tested with wide
values in the same program; the string and memory builtins can use `&` and
shifts on wide buffers without wondering whether the high half survives; and
`glyph_bit` in `icon_text_demo.ast` can finally become the single `&` it
always wanted to be — though that changes an existing example's bytes, so it
waits for a round whose subject it is.
