# Validation Report — v0.23.27-dev

**Feature: four places where Aster read an expression differently from C, closed.**
The previous round was a document — `docs/language-reference.md`, written out of
the compiler source and then checked line by line against the binary. Its §9
recorded four divergences from C, found by *testing* rather than by reading, and
two of them were named as candidate rounds rather than design. The user's answer
to the list was one line — *"好的，全部开始修"* — so all four closed here:

1. **`&&` and `||` shared one precedence level.** `a || b && c` was read
   `(a || b) && c` — a different answer, silently.
2. **`-` `!` `~` `*` took a `primary()` operand.** `-s.v` parsed as `(-s).v` and
   `*s.p` as `(*s).p`, which in practice made all four *rejected* whenever the
   operand was a struct.
3. **`a < b == c` was rejected** by the anti-chaining check, although the comment
   directly above `relational()` had always promised `(a < b) == c`.
4. **A local `let` skipped the range check a global `let` applies.**
   `let b: u8 = 300;` stored 44 inside a function while the same line at file
   scope was an error.

```
$ ./aster build-elf examples/precedence.ast -o precedence && ./precedence
$ echo $?
127                                    # matches the gcc twin of the same program — §4 [4/9]
```

Three of the four were silent — a different answer, or a truncated value — which
is exactly why they survived; nothing ever complained.

## 1. Why this round exists: a document found them, not a bug report

The divergences were not reported by a user and not caught by any suite. They
surfaced because writing a *descriptive* reference means writing down what the
compiler does, not what it ought to do, and then running every row. §9 was the
residue of that process: four rows that started "Aster reads … C reads …".

Two of the four were recorded as **candidate rounds rather than design** — (3),
because it is a comment/implementation mismatch, and (4), because it needs a
decision about whether narrowing a local is a warning, an error, or allowed.
Both decisions are made below and both are narrow. The other two were recorded
as defects without being scheduled, and this round took them as well rather than
fixing half a list.

## 2. The four fixes

### 2.1 Two logical levels instead of one

```
E logicalAnd(){                      // new level: collects &&
    E x=bitor_();
    while(cur().k==TK::And){ … }
    return x;
}
E logical(){                         // was: collected both, in one loop
    E x=logicalAnd();
    while(cur().k==TK::Or){ … }
    return x;
}
```

`logicalAnd()` sits over `equality()` and `logical()` over that, so `&&` is the
tighter of the two: `a || b && c` is now `a || (b && c)`. This is C's reading
*and* the one `docs/language-spec.md` had been printing for releases — the spec
and the compiler disagreed, and only one of them was executable. Both operators
still short-circuit (two battery cases pin that), and neither accepts a
non-bool operand.

### 2.2 A `unary()` level between `postfix()` and the multiplicative level

```cpp
E unary(){
    if(eat(TK::Star)){E x=unary(); … }     // Deref
    if(eat(TK::Amp)){E x=unary(); … }      // AddrOf
    if(eat(TK::Minus)){E x=unary(); … }    // Neg
    if(eat(TK::Not)){E x=unary(); … }      // Not
    if(eat(TK::Tilde)){E x=unary(); … }    // BitNot
    return postfix();
}
```

The five branches moved out of `primary()` as a group. `&` had been the odd one
out — it was already taking a `postfix()` operand inside `primary()`, so it
behaved correctly and simply moved. The prefix operators are right-recursive
(`- -x` is legal), and `product()` now starts at `unary()` instead of
`postfix()`.

**Both dereference-assignment targets moved with them** — `*p = v` and `*p += v`
parse their target at `unary()` depth now — so `*p.f = v` means what C means
rather than being a parse error or a mis-targeted store.

### 2.3 One predicate, split in two

```cpp
bool isRelationalOp(TK op)const{return op==TK::Lt||op==TK::Le||op==TK::Gt||op==TK::Ge;}
bool isEqualityOp(TK op)const{return op==TK::EqEq||op==TK::Ne;}
```

`isComparisonOp` (any comparison operator) becomes two predicates, and each
level refuses a chain **within itself**:

| Source | Before v0.23.27-dev | Now |
|---|---|---|
| `a < b < c` | rejected | rejected |
| `a == b == c` | rejected | rejected |
| `a < b == c` | rejected | **accepted** — `(a < b) == c` |
| `a == b < c` | rejected | **accepted** — `a == (b < c)` |

Both levels are non-associating, so a chain inside one of them can only be a
mistake: `(a < b) < c` would compare a `bool` against an integer. That is the
rule the comment described; the old check was merely asked the wrong question.

### 2.4 A local `let` runs `initializerFits`, in both passes

| Where | Before | Now |
|---|---|---|
| `let b: u8 = 300;` at file scope | `global initializer does not fit in u8: b (300)` | unchanged |
| `let b: u8 = 300;` in a function | **accepted, stored 44** | `local initializer does not fit in u8: b (300)` |
| `let a: u8[4] = 300;` in a function | **accepted, filled with 44** | `local array initializer does not fit in u8: a (300)` |

The check is the same `initializerFits` a global has always used, and it is
installed four times — sema and codegen for a scalar, sema and codegen for an
array's element initializer — because sema is the rule and codegen is its
defensive twin. Both copies emit the same message, so whichever fires the user
reads the same diagnostic.

**The decision is narrow on purpose: only a *constant* that does not fit is
refused.** Narrowing a *value* — `let b: i32 = <an i64>;`,
`let b: u8 = <an i32>;` — is still accepted, as it has always been, because that
is a conversion the language offers rather than a constant that cannot be
represented. Three battery cases pin the distinction (`i32 from an i64 value`,
`u8 from an i32 value`, `i32 from a wide literal`), and the rejection matrix
refuses seven constant shapes.

## 3. Why no existing program changed, argued and then measured

The argument, made **before** any edit:

- no shipped example mixes `&&` with `||` (`grep '||' | grep '&&'` over
  `examples/` and `tests/` finds nothing);
- none writes `*x.y` or `-x.y` (no code hits
  `\*[A-Za-z_]\w*\.` or `[-!~][A-Za-z_]\w*\.`);
- `a < b == c` did not compile at all, so no program could contain one;
- none of the 411 `let` declarations in `examples/` and `tests/` initializes a
  narrow local with an out-of-range constant.

The measurement: **288 of 288 pre-existing baseline rows reproduce byte for
byte**, and the only new rows are `examples/precedence.ast`'s three output modes
(291 total). Every one of the four fixes is a parser or type rule — the round
carries no codegen at all — so the byte identity is a consequence, not a
coincidence.

## 4. `tests/precedence-checks.sh` — nine layers, all run

Registered in `tests/ci.sh` after `pointer-index-checks.sh`.

**[1/9] Strict build.** `-Werror` (and `-pedantic`, as `ci.sh` builds), zero
warnings.

**[2/9] Source guards.** `logicalAnd()` exists and loops `&&`; `logical()` loops
`||` over it; the old single-operator loop is asserted **absent** from the
source; `unary()` exists and all five prefixes take a `unary()` operand;
`product()` starts there; both dereference-assignment targets parse there
(counted at 2); `isRelationalOp`/`isEqualityOp` exist and `isComparisonOp` does
not; and all four range checks are present with both of their messages counted
at exactly 2 (sema + codegen).

**[3/9] Behavioural battery — 33 cases under qemu.** The five rows of the
`&&`/`||` truth table where the two readings disagree, one-operator chains, and
both short-circuit directions; `-(s.v)`, `!(s.ok)`, `~(s.v)`, `*(s.p)` through a
struct; `-x`, `*p`, `-a[i]`, `- -x`, `-(x + y)` and `&s` (the operators the new
level must not disturb); six comparison shapes including both level crossings, a
crossing stored as a bool, and `a <= b == b >= a`; the top of each narrow range
(`u8` 255, `u16` 65535, `u32` 4000000000, `u8[4]` 200, `u16[2]` 65535); and the
three value-narrowing shapes that must still be allowed.

**[4/9] Differential battery — 5 cases, gcc-differential.** The four rows where
the two `&&`/`||` readings disagree; the four prefix operators against `.`;
`a < b == c`; a narrow local at the top of its range; and
`examples/precedence.ast` against `tests/precedence-example-twin.c`. Every case
is compiled by `aarch64-linux-gnu-gcc -O2` and both exit statuses are compared —
no hand-computed expectation anywhere. **Aster is the one that moved; C is the
oracle.**

**[5/9] Rejection matrix — 16 cases.** Six comparison chains (four operators at
the relational level, two at the equality level); seven out-of-range locals
(`u8` 300 and 256, `u16` 65536, `u32` `0 - 1`, `u8[4]` 300, `u16[2]` 65536, and
`u8 = 200 + 100` to prove the check folds); and three type rules the new
`unary()` depth does **not** loosen — `-b` on a bool, `!` on an i32, `&` on an
i32.

**[6/9] Coverage map.** 33 named rows, one per battery case, each naming the
rule the case is there for. The map is the answer to "why is this case here".

**[7/9] Mutation layer — 12 mutants.** `&&`/`||` back to one level (m1); the two
levels swapped (m2); `-`, `*`, `!` back to a `primary()` operand (m3, m4, m5);
`relational()` refusing a crossing again (m6); `equality()` dropping its own
chain check (m7); the scalar range check withdrawn from sema (m8), from both
passes (m9); the array range check withdrawn from sema (m10), from both passes
(m11); and `initializerFits` always true (m12).

**[8/9] Byte-identity baseline.** 291 rows, of which the 288 pre-existing ones
must reproduce byte for byte; the three new rows are the new example's output
modes. (The baseline file has always carried `FAILED` rows for examples whose
`build-elf` link depends on an external symbol — that is a recorded property of
those examples, not a regression, and the suite does not treat it as one.)

**[9/9] The shipped example, end to end.** `examples/precedence.ast` exits 127,
equal to its C twin.

### Three mutants that earned their shape the hard way

| Mutant | What went wrong first | What it taught |
|---|---|---|
| m2 (two levels swapped) | pinned to `F && T || T`, which the mutant still answered correctly | the row has to disagree on the swapped *nodes*, not only on the grouping: `T && F || F` is false under `(T && F) \|\| F` and true under `T && (F \|\| F)` |
| m7 (`equality()` allows a chain) | written as "the program must now compile" | the program still does **not** compile — it dies one token later on `expected ')'`. The rule is a *diagnostic*, not a gate, so what the mutant loses is the specific message |
| m8 / m10 (one pass only) | — | withdrawing one half must still be **refused**, by the other. That is what proves the codegen twin is a live gate and not dead code copied from sema; m9/m11 then show the pair is the whole gate |

## 5. What this deliberately does not do

- **No chain within one level.** `a < b < c` and `a == b == c` are still errors;
  write `a < b && b < c`. The two levels are non-associating for a reason.
- **No error on value narrowing.** `let b: i32 = <an i64>;` stays legal. Only an
  out-of-range *constant* is refused.
- **No new codegen.** The round is four parser/type rules; the comparison fast
  path, the condition machinery and every encoding are untouched.
- **No re-recorded baseline.** `tests/rebuild-baseline-v0.23.27.sh` asserts the
  288 pre-existing rows before it writes 291, so a silent re-recording is
  impossible.

## 6. Byte identity: 288 of 288

`tests/struct-checks.sh` [4/8] re-hashes every example in three modes
(`build-so`, `build-elf`, `build-obj --pic`) against
`tests/baseline/v0.23.5-dev/example-hashes.txt` and **passes with the round's
compiler**: the 288 pre-existing rows byte-identical, plus 3 new rows recording
`examples/precedence.ast`. `tests/rebuild-baseline-v0.23.27.sh` refuses to write
the baseline unless every old row reproduces, and the suite's own [8/9] asserts
the split (288 unchanged / 291 total) so the two numbers cannot drift apart.

## 7. Verification log

`tests/precedence-checks.sh`, run on this tree (`HOSTCC=aarch64-linux-gnu-gcc`):

```
[1/9] Strictly build Aster compiler
[2/9] Source guards: the four rules, where they live
  all four rules present, in both passes
[3/9] qemu: each of the four rules, one at a time
  T || T && F  (T || (T&&F))         1
  T || F && T  (T || (F&&T))         1
  F && T || T  ((F&&T) || T)         1
  F || F && T  (F || (F&&T))         0
  T && F || F  ((T&&F) || F)         0
  T && T && T                        1
  F || F || T                        1
  || short-circuits                  2
  && short-circuits                  0
  -(s.v)                             5
  !(s.ok)                            2
  ~(s.v)                             1
  *(s.p)                             9
  -x (no field)                      1
  *p (no field)                      7
  -a[i]                              1
  - -x                               6
  -(x + y)                           1
  &s (struct lvalue)                 1
  a < b == c                         1
  a < b == c (false)                 0
  a < b != c                         0
  a == b < c  (a == (b<c))           1
  a <= b == b >= a                   1
  (a<b)==c stored as bool            3
  u8 at 255                          1
  u16 at 65535                       1
  u32 at 4000000000                  1
  u8[4] at 200                       1
  u16[2] at 65535                    1
  i32 from an i64 value              5
  u8 from an i32 value               1
  i32 from a wide literal            1
[4/9] Differential: Aster vs the target C compiler
  || and &&: four rows               5
  prefix operators vs .              7
  a < b == c                         9
  narrow local at its top            3
  examples/precedence.ast            127
[5/9] Rejection matrix
  a < b < c (chain)                  refused
  a <= b <= c (chain)                refused
  a > b > c (chain)                  refused
  a >= b >= c (chain)                refused
  a == b == c (chain)                refused
  a != b != c (chain)                refused
  local u8 = 300                     refused
  local u8 = 256                     refused
  local u16 = 65536                  refused
  local u32 = 0 - 1                  refused
  local u8[4] = 300                  refused
  local u16[2] = 65536               refused
  local u8 = 200 + 100               refused
  -b (a bool)                        refused
  !(an i32)                          refused
  & of an i32                        refused
[6/9] Coverage map: which case exercises which rule
  rules covered                      33
[7/9] Mutation layer: each rule, withdrawn, is caught
  m1: && and || back to one level    caught
  m2: the two levels swapped         caught
  m3: - takes a primary operand      caught
  m4: * takes a primary operand      caught
  m5: ! takes a primary operand      caught
  m6: relational refuses == too      caught
  m7: equality allows a chain        caught
  m8: sema drops the scalar check    caught
  m9: both passes drop the scalar check caught
  m10: sema drops the array check    caught
  m11: both drop the array check     caught
  m12: initializerFits always true   caught
PASS: twelve mutated compilers each lose exactly one rule, and the checks notice
[8/9] Byte-identity baseline
  pre-existing rows byte-identical   288
  rows total                         291
PASS: byte-identity baseline holds
[9/9] The example, end to end
  precedence.ast                     127
PASS: the example runs and returns the value its C twin returns
=== precedence checks: ALL PASSED ===
```

And the round's own baseline rebuild, which refuses to write the file unless
every pre-existing row reproduces:

```
$ sh tests/rebuild-baseline-v0.23.27.sh
OK: 288 pre-existing lines byte-identical; 291 lines total (3 new)
```

One resident suite had to be updated on the record rather than quietly:
`tests/fuzz-checks.sh` [6/7] re-injects the v0.23.10-dev move-then-deref bug at
the exact source line where `-` parses its operand, which is `unary()` now
instead of `primary()`. The step now names that level **and greps for the
injection site before sed sees it**, so a future move makes the step fail loudly
instead of vacuously passing — the re-injected compiler still crashes on 57 of
the 2000 inputs, which is what makes step 4's zero mean anything.


### What went wrong on the way

| Item | What was wrong | Resolution |
|---|---|---|
| Mutant m2 (two levels swapped) | pinned to `F && T \|\| T`, which the mutant still answered correctly — `&&`/`\|\|` agree on that row under both groupings | moved to `T && F \|\| F`: false under `(T && F) \|\| F`, true under the mutant's `T && (F \|\| F)` |
| Mutant m7 (`equality()` allows a chain) | written as "must now compile" — it still does not | the rule is a diagnostic, not a gate: the mutant loses the *message*, not acceptance. New `must_not_say` expectation |
| Mutants m8/m10 (one pass withdrawn) | indistinguishable from m9/m11 if the expectation is "must compile" | they must still be **refused**, by the surviving twin — new `must_still_say` expectation. That is what proves the codegen half is live |
| Seven battery expectations | written as ~250, -6 and other values above 127, which `check()` folds to negative | rewritten to return a small value (`if (~s.v == 0 - 6) { return 1; }`) |
| Two rejection cases | `-b` and `- -x` were written so they never touched the operator under test | rewritten to `let n: i32 = 0 - b;` and `return - -x;` |
| Two mutants that would not build | m7 left a dangling `if`, m11 split a function signature across a line | m7 substitutes an empty block; m11 prepends `return true;` to the existing signature |
| `tests/fuzz-checks.sh` [6/7] | injected the v0.23.10-dev bug at `primary()` depth, which `-` no longer parses at | retargeted to `unary()`, with a grep for the injection site *before* the sed so a future move fails loudly |
| The byte-baseline "FAILED" rows | a first draft treated the baseline's 48 `FAILED` lines as a regression | they are recorded properties of examples whose `build-elf` link needs an external symbol; both places now say so |

## 8. Full CI

```
$ CI_OUT=tmp-ci HOSTCC=aarch64-linux-gnu-gcc sh tests/ci.sh
=== Aster CI — environment ===
CXX       : g++ (g++ (Ubuntu 13.3.0-6ubuntu2~24.04) 13.3.0)
HOSTCC    : aarch64-linux-gnu-gcc
RUNNER    : tests/run-aarch64.sh
qemu      : /usr/bin/qemu-aarch64
readelf   : /usr/bin/readelf
openssl   : /usr/bin/openssl
androguard/PIL: present

=== Building aster (strict: -Wall -Wextra -pedantic -Werror) ===
BUILD OK: ./aster — Aster bootstrap compiler v0.23.27-dev

=== Running 81 test suites ===
… (precedence-checks.sh PASS, all others PASS) …

=== APK verification gate ===
apk: native_render                         PASS
apk: icon_text_demo                        PASS
apk: native_touch                          PASS

========================================
CI SUMMARY: 84 passed, 0 skipped, 0 failed (of 84 checks)
========================================
```


| CI | v0.23.26-dev | v0.23.27-dev |
|---|---|---|
| Result | 83 passed / 0 skipped / 0 failed | **84 passed / 0 skipped / 0 failed** |
| Checks | 83 | 84 (+1: `precedence-checks.sh`) |
| Baseline rows | 288 (285 unchanged + 3 new) | 291 (288 unchanged + 3 new) |
| New resident suite | `null-ptr-checks.sh` | `precedence-checks.sh` |

## 9. What this unblocks

- **Expressions now mean what the documentation says.** Two files claimed a
  grammar the compiler did not implement; both are true now, which is the
  precondition for anyone trusting either of them.
- **Struct fields can be used directly.** `-s.v`, `!s.ok`, `*s.p` no longer need
  parentheses around a field access, so ported C-shaped code reads the same in
  Aster.
- **A comparison's result can be compared.** `a < b == c` (and `a == b < c`)
  removes the last place where the language refused a perfectly ordinary bool
  expression.
- **A narrow type is narrow everywhere.** A `u8` cannot hold 300 in a global or
  in a local, so the type's range is a property of the type and not of where the
  declaration happens to stand.
- **The remaining divergences from C are now deliberate ones** — ptr truthiness,
  ptr ordering, no `null` keyword — each written down with its reason rather than
  discovered.
