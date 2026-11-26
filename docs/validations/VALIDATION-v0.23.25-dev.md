# Validation Report — v0.23.25-dev

**Feature: condition expressions — `true`/`false` literals and integer
truthiness in `if`/`while`/`for`.** The user named the round directly
("下一步完善if、while条件表达式bool类型true/false，0和非0"): a condition had to
be a comparison, so `if (x)` with `x: bool` was a compile error, and a `bool`
value could only be manufactured by a comparison operator — because the language
had no `bool` literal at all: `Expr::Num` was born carrying an `i32` and nothing
else. This round adds the literals, teaches the shared condition machine
(`checkCondition` / `emitCondition`) to accept a comparison, a `bool`
expression, or any integer (0 false, non-zero true, tested at the integer's own
width), and fills the four gaps the literal exposed — with `ptr` and struct
conditions still refused, and `?:`/`&&`/`||`/`!` deliberately left strictly
`bool`.

```
$ ./aster build-elf examples/condition.ast -o condition && ./condition
$ echo $?
16                                     # matches the gcc twin of the same program — §7
```

## 1. Why this round exists: there was no way to write a bool, and no way to use one

Two halves of one gap. **The literal gap was structural.** `bool` has been a
first-class type since v0.22.51-dev — it can be stored, passed, returned — but
every `bool` value in every program ever written for Aster was produced by a
comparison operator, because `Expr::Num` carries an integer value and the type
rules answered `i32` for every `Num` there was. There was no `true`, no `false`,
and no way to write one. **The condition gap followed from it.** `if`/`while`/
`for` accepted exactly one form — a comparison — so `if (b)` with `b: bool` was
`condition must be a comparison or a bool expression`, `while (flag)` was a
compile error, and the integer idiom every other C-family language has
(`while (n) { … n = n - 1; }`, zero meaning done) was unreachable. The round
fixes both with one shared machine, and the honest record of the work is that
the second half — the conditions — is where the subtlety lives, and the first
half — the literals — is where the surprises were.

## 2. The literal: one flag, two type twins, and four exposed gaps

**The lexer maps `true`/`false` to new keywords and `primary()` builds a `Num`
carrying a `boolLit` flag** whose stored value stays `0`/`1`. The flag is read
in exactly the places a literal's type is decided: the two `typeOf` twins (the
semantic pass and codegen) answer `Ty::Bool` for it, so the literal is a `bool`
everywhere a type is asked. The flag is also read by the rules that must
*refuse* it — see the four gaps below. No example or suite in the tree used
`true`/`false` as an identifier, so the byte baseline is preserved by
construction (the lexer change cannot alter the token stream of any existing
program).

Promoting a `bool` literal into the language immediately exposed four real
defects, all fixed in the same round, because a round that ships `true` without
fixing them ships a language where `true` behaves differently in five places:

1. **`genBool` had never handled `Field` or `Cond`.** `genBool` — the helper
   that produces a 0/1 register for an expression in a boolean context —
   covered `Var`, `Call`, comparisons, `Not`, `And`, `Or`, and nothing else. So
   `if (s.b)` (a `bool` struct field) and `c ? a : b` died in **codegen** with
   `expected a bool expression`, although the semantic pass had already typed
   them `bool` and accepted them. A pre-existing defect, invisible until this
   round made those spellings natural; both now delegate to
   `gen(e, Ty::Bool)`, which already supported a `bool`-wanting consumer.
2. **Arithmetic silently accepted `bool` operands.** Through the integer
   widening paths, `1 + true`, `~true`, `-true`, `true << 1` and `a[true]` all
   compiled. One `rejectBool` guard now sits at all fifteen operator sites
   (unary minus, the five binary arithmetics, three shifts, four bitwise
   operators, bitwise not) and array indexing answers
   `cannot use a bool value in an array index`.
3. **`constantInteger` folded `true` to `1`.** That let `let x: i32 = true;`
   and `a[true]` reach integer slots. A `bool` literal is no longer a constant
   integer, and global/struct-field initializers gained a type gate for the new
   literal: `let n: i32 = true;` is a positioned
   `global initializer type mismatch: expected i32, got bool`, and a `bool`
   into a non-`bool` struct field names both types.
4. **A drafted guard was withdrawn as unreachable.** The first cut of the
   `constantInteger` work added an `isBoolConstant` branch for `boolLit`. The
   function is consulted only when the expression's actual type is *not*
   `Bool` — and a `boolLit`'s type always is — so the branch was dead code by
   construction. It was removed rather than shipped untestable, which also
   removed the mutant that had been planned against it.

## 3. Truthiness: one shared machine, three accepted forms, one width rule

`if`, `while` and `for` share one condition machine: `checkCondition` (sema)
and `emitCondition` (codegen). Since this round a condition may be any of:

1. **A comparison** — unchanged. The original `CMP` + conditional-branch
   fast path, which is why every pre-existing example still compiles
   byte-identically and why the byte baseline needed no re-recording of old
   rows.
2. **A `bool` expression** — a variable, field, parameter, call, `&&`/`||`/`!`
   result, or one of the new literals. It is materialized to 0/1 and tested
   against zero, exactly as a comparison's answer already was.
3. **Any integer** — `i32`, `u8`, `u16`, `u32` or `i64`. Zero is false; every
   other value is true.

**The width rule is the round's one real codegen subtlety.** An integer
condition must be tested against zero *at its own width*: narrow integers use
the comparison path's existing `CMP Wn, #0`; `i64` needs the new
`CMP Xn, #0` (`cmpZeroX`). A 32-bit compare of an `i64` holding a value past
four billion reads as zero — so `while (4294967297)` would exit immediately on
a 32-bit zero test, and the mutation layer pins exactly this with a case that
must diverge (1 → 0).

**The boundary is deliberate.** Truthiness coercion lives in control-flow
conditions and nowhere else: `?:`, `&&`, `||` and `!` remain strictly `bool`,
so `a && b` still means "both true" rather than "both non-zero", and
`if (a && b)` works because the `&&` answers a `bool` that the condition
accepts — two layers, one clean. `ptr` and struct conditions stay refused: a
`ptr` is an address, not a truth value, and a struct has no truth value at
all. Anything else answers
`condition must be a comparison, a bool expression, or an integer` (the
message was `condition must be a comparison or a bool expression` before this
round — three resident suites pinned the old wording and were updated on the
record, see §7).

## 4. `tests/condition-checks.sh` — nine layers, all run

Registered in `tests/ci.sh` after `comment-checks.sh`.

**[1/9] Strict build.** `-Werror` (and `-pedantic`, as `ci.sh` builds), zero
warnings.

**[2/9] Source guards.** Pins the two new tokens, the lexer mapping, the
`boolLit` flag in `Expr`, both `typeOf` twins answering `Ty::Bool` for it, the
`constantInteger` refusal, both new `genBool` forms (`Field`/`Cond` and the
literal), `cmpZeroX`, the integer condition path, the new diagnostic message
(both copies — sema and codegen), all 16 `rejectBool` sites (1 definition +
15 calls), the global-initializer gate and the struct-field gate. A
reintroduction of any removed rule fails the suite before it can ship.

**[3/9] Behavioural battery — 21 cases under qemu.** Every literal branch
shape (`if (true)`, `if (false) … else`, a literal in a `while` condition,
literals as arguments and return values); truthiness for `i32` (non-zero,
zero, negative), `i64` (including the wide zero test that a 32-bit compare
would fail), and `u8`/`u16`/`u32` (high bit set); `while (0)`; a call as a
condition; a `bool` struct field as a condition; `?:` arms as conditions; and
`&&`/`||`/`!` over `bool` values. Expected exit codes are hand-derived from
the program text and cross-checked against the differential layer.

**[4/9] Differential battery — 4 cases, gcc-differential.** Each case has an
Aster source and a C twin compiled by `aarch64-linux-gnu-gcc -O2 -fwrapv`, both
run under qemu, exit statuses compared — no hand-computed expectation anywhere:
the `i64` wide zero test, a high-bit `u32`, literal-driven branches, and a
loop with a `?:` in the condition.

**[5/9] Rejection matrix — 31 cases.** A `bool` operand at every arithmetic,
bitwise, shift and negation operator; a `bool` as an array index and as a local
array initializer; a `bool` literal into an `i32` slot, an `i32` argument and
an `i32` return; an integer in `?:`, `&&` and `!` (the strict-`bool` boundary);
`ptr` and struct conditions; misassigned literals at globals and struct
fields. Each demands the diagnostic that names the offending thing.

**[6/9] Coverage map.** Seventeen rows — every accepted condition form, every
refused form, and the fixed `genBool` shapes — must stay resident; deleting a
case without updating the map fails the map.

**[7/9] Mutation layer — 7 mutants.** m1 drops the integer-condition rule
(sema refuses it again), m2 narrows the `i64` zero test to 32 bits, m3 makes
`if (true)` take the else branch, m4 folds `true` in `constantInteger`,
m5 removes one operator's `rejectBool`, m6 bypasses the global-initializer
gate, m7 voids the struct field's literal value. A check that passes on a
damaged compiler is not checking anything.

**[8/9] Byte-identity baseline.** `tests/struct-checks.sh` [4/8] re-hashes
every example in three modes (`build-so`, `build-elf`, `build-obj --pic`)
against `tests/baseline/v0.23.5-dev/example-hashes.txt`: **285/285 rows
reproduce**, 3 of them the new `condition.*` rows, the other 282
byte-identical.

**[9/9] The shipped example, end to end.** `examples/condition.ast` — an
integer-driven `while`, literal-driven `if`/`else`, a `for` loop and a
zero-test in one program — exits 16, equal to its C twin
`tests/condition-example-twin.c`.

## 5. What this deliberately does not do

- **`bool` does not become a numeric type.** `let x: i32 = true` is refused;
  no implicit conversion in either direction exists outside conditions.
- **Truthiness does not spread.** `?:`, `&&`, `||` and `!` stay strictly
  `bool`, so `a || b` still requires both sides to be `bool`. The coercion
  exists in control-flow conditions and nowhere else.
- **No new syntax.** No `elif`/`elsif` sugar, no `while … else`, no `truthy`
  intrinsic. The literals are keywords; the conditions are the existing
  grammar.
- **The comparison fast path is untouched.** `emitCondition`'s comparison
  branch is byte-for-byte what it was, which is why the baseline holds by
  construction rather than by luck.

## 6. Byte identity: 282 of 282

`tests/struct-checks.sh` [4/8] re-hashes every example in three modes
(`build-so`, `build-elf`, `build-obj --pic`) against
`tests/baseline/v0.23.5-dev/example-hashes.txt` and **passed with the round's
compiler**: the 282 pre-existing rows byte-identical, plus 3 new rows
recording `examples/condition.ast`. The diff against the previous recording is
three additions and zero changes. This holds by construction: the comparison
condition path is untouched, the lexer change cannot alter the token stream of
any existing program (no pre-existing source uses `true`/`false` as an
identifier), and every other edit either refuses a program that used to
compile or fills a codegen path (`genBool`'s `Field`/`Cond` forms) that no
existing example reaches. The re-recording itself was verified by
`tests/rebuild-baseline-v0.23.25.sh`, which refuses to write the file unless
every old row reproduces.

## 7. Verification log

| Step | Result |
|---|---|
| Strict `-Werror` (+ `-pedantic`) build of the modified compiler | clean |
| `examples/condition.ast` vs its C twin | both exit 16 |
| `condition-checks.sh` [3/9] battery | **21/21** behavioural cases |
| `condition-checks.sh` [4/9] differential battery | **4/4 match the C oracle** |
| `condition-checks.sh` [5/9] rejections | **31/31** rejected with the naming diagnostic |
| `condition-checks.sh` [6/9] coverage map | 17 named cases resident |
| `condition-checks.sh` [7/9] mutations | **7/7** correctly turn the battery red |
| `condition-checks.sh` [8/9] baseline | **285 recorded outputs reproduced byte for byte** (282 old + 3 new) |
| `condition-checks.sh` [9/9] shipped example | exits 16, equal to its twin |
| `isBoolConstant` `boolLit` branch | dead by construction (consulted only for non-`bool` types); withdrawn |
| Mutation m4's first target (`tyAssignable` at an argument) | unreachable — `checkArgument` checks `Bool` directly; re-aimed at local array initialization |
| Mutation m5's first target (a `rejectBool` site) | covered, but the draft's `isBoolConstant` premise was void; final m5 drops the `Add` guard |
| `let true` probe | rejected at the parser (`expected variable name`), not the statement dispatcher — assertion corrected |
| `bool-checks.sh` [2/8] message guard | old `condition must be a comparison or a bool expression` count 0; new message count 1 — updated with the third type on the record |
| `bool-checks.sh` [3/8] `i32-condition.ast` | inverted from a rejection into an acceptance check; a `ptr` condition case keeps the boundary pinned |
| `for-loop-checks.sh` [2/7] message guard + [3/7] `non-compare-cond.ast` | same inversion; the for-header case now uses a `ptr` condition |
| `struct-checks.sh` struct-condition rejection | message updated to the new wording; old byte-hash assertions never weakened |
| `rebuild-baseline-v0.23.25.sh` | refuses to write the baseline unless every old row reproduces |
| Full CI | see §8 |

## 8. Full CI

```
========================================
CI SUMMARY: 82 passed, 0 skipped, 0 failed (of 82 checks)
========================================
```

| CI | v0.23.24-dev | v0.23.25-dev |
|---|---|---|
| Result | 81 passed / 0 skipped / 0 failed | **82 passed / 0 skipped / 0 failed** |
| Checks | 81 | 82 (+1: `condition-checks.sh`) |
| Baseline rows | 282 (279 unchanged + 3 new) | 285 (282 unchanged + 3 new) |
| New resident suite | `indirect-call-checks.sh` | `condition-checks.sh` |

## 9. What this unblocks

- **The integer idiom is now writable.** `while (n) { … n = n - 1; }` — a
  countdown, a cursor walking to a terminator, a state machine draining a
  work queue — compiles and runs, tested at the integer's own width, and the
  `for` header inherits it for free (`for (let i: i32 = n; i; i = i - 1)`).
- **`bool` values can finally be written.** `let on: bool = true;` and
  `if (on) { … } else { … }` replace the `1`/`0` spellings, and with the
  `genBool` fix a `bool` field, a `bool` call result and a `?:` of `bool` arms
  all work in a condition — three shapes that used to die in codegen.
- **The strict-`bool` boundary is now written down, not assumed.** `&&`, `||`,
  `!` and `?:` keep their v0.22.51-dev contract exactly, so existing programs
  cannot change meaning, and the coercion rule is pinned by the rejection
  matrix and the mutation layer rather than left to habit.
- **Still open, in the order the difficulty audit argued:** the
  debug-information slice (`.debug_info` on top of the v0.23.12-dev line
  table), then the audit-ranked backlog.
