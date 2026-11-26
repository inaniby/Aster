# Validation Report — v0.23.35-dev

**Feature: `sizeof` and `len` — two compile-time answers about storage — and an
array parameter that finally remembers its length. `sizeof(i32)` is 4,
`sizeof(i32[4])` is 16, `sizeof(Row)` is the struct's laid-out size, `sizeof(w)`
and `sizeof(row.cells)` ask the same question of an expression; `len` answers
the element count — the product of the dimensions, so `len(i64[2][3])` is 6, not
2. Both fold to an ordinary `i32` constant (the type spelling while parsing, the
expression spelling during sema), and because `fn f(a: i32[4])` used to throw the
length away at the call boundary, `Function::paramDims` now carries it into the
body — which is what lets `len(a)` and `sizeof(a)` answer from inside `f`.**

```
# tests/sizeof-len-checks.sh [3/9] — each compiled with ./aster, run under qemu-aarch64.

fn main() -> i32 { return sizeof(i32); }                                -> exit 4
fn main() -> i32 { return sizeof(i64[2][3]); }                          -> exit 48
fn main() -> i32 { let w: i32[4] = 0; return len(w); }                  -> exit 4
fn f(a: i32[4]) -> i32 { return sizeof(a); }
fn main() -> i32 { let w: i32[4] = 0; return f(w); }                    -> exit 16
struct B { xs: i32[4] }
fn main() -> i32 { let b: B; return len(b.xs); }                        -> exit 4
```

## 1. Why this round exists

A program has always been able to know how wide an `i32` is — it is 4, written
down in the ABI — and how many elements a `T[4]` holds — it is 4, written in the
declaration. What it could never do is **ask**. The two numbers most often
hard-coded in a program that touches arrays are the two numbers the compiler
already computes for its own layout work: `tySize` for every type, the dimension
product for every array. `docs/language-reference.md` listed `sizeof` under
"There is no …" and meant it; this round deletes that line.

The second half is the one that made the first half answerable inside a
function. Since v0.23.34-dev an array may be a **parameter** — `fn f(a: i32[4])`
decays to a `ptr<i32>` — and the decay threw the length away, so inside `f` there
was nothing for `len(a)` to answer from: the binding is a pointer, and a pointer
has no length. `Function::paramDims` now records the parameter's dimensions and
`Sema::check` fills the binding with them, so `sizeof(a)` and `len(a)` answer
what the caller actually passed. This is the v0.23.34-dev "Deliberately not
included" line (*"a decayed array parameter has no bounds information"*) closed
for the two operators — not for subscripting, which stays unchecked exactly as
before.

## 2. Two operators, two spellings, one folded value

Both operators accept a **type** and an **expression**, because both spellings
are things people write:

```aster
sizeof(i32)            // 4    — a type
sizeof(i32[4])         // 16   — an array type, dimensions and all
len(i64[2][3])         // 6    — the element count, not the row count

let w: i32[4] = 0;
sizeof(w)              // 16   — an expression
len(w)                 // 4
sizeof(row.cells)      // 16   — a struct's array field
len(row.cells)         // 4
```

`sizeof` answers **bytes** — `tySize(T)` for a scalar, `sizeof(S)` (the
laid-out size, alignment included) for a struct, `tySize(T) * dimsProduct` for
an array type. `len` answers the **element count** — the product of the
dimensions, which for a one-dimensional array is the length and for a
multi-dimensional one is the total (`len(i64[2][3])` is 6). On an expression,
`len` asks the same question of whatever the expression names: a local binding
(`b->dims`), a global (`arrayDims`), a struct field (`f->len`, already the total
element count since v0.23.29-dev).

The fold happens **in two places, by design**. The type spelling is folded in
`primary()` while parsing — it needs no context, so it arrives in the AST as an
ordinary `Expr::n` and every downstream site sees a plain integer literal. The
expression spelling is folded in `Sema::typeOf`, which *does* need context (the
binding's dims, the field's length), so it folds there — and codegen's `exprType`
twin answers `Ty::I32` for both, `constantInteger`/`isConstExpr`/`foldConst` read
`e.n`, and `gen` materializes it exactly like a `Num`. The value type is `i32`
for both operators, everywhere.

## 3. An array parameter remembers its length

`Function` gained `paramDims`, filled at parse time from `arrayParamType()`'s
new out-parameter (the same place that already answers the element type). At
`Sema::check`, each parameter binding is filled as
`Binding{pty, plen, elem, pd}` — where `plen` is `dimsProduct(pd)`, the total
element count, the same number `len` answers and the same number a struct field
carries. So `sizeof(a)` is `tySize(elem) * plen` and `len(a)` is `plen`, read
from the binding the parameter already had.

The semantic rule this replaces is deliberate and worth stating plainly: **a
decayed parameter is still a pointer for every purpose except these two
operators.** A parameter subscript stays unchecked (no `--bounds-check`, no
compile-time fold), `return a;` is still refused as a dangling frame pointer,
and `a = ...` is still a type error. The dimensions answer `sizeof`/`len` and
nothing else.

One number is Aster's, not C's: `sizeof` on a decayed parameter in **C** is the
pointer's 8. Aster answers the array's 16 — what the caller actually passed —
and the C twin says so out loud by measuring a real array type
(`sizeof(int32_t[4])`) rather than the decayed parameter, so the differential
layer compares the two languages' *arrays*, not their pointers.

## 4. What `len` refuses, and why the refusals are the feature

`len` on anything that has no element count is a compile error, in both
spellings, and each message names the fix:

* `len(x)` on a scalar local, `len(p)` on a `ptr`, `len(p)` on a `ptr`
  parameter — `len() requires an array, not a scalar or pointer`;
* `len(i32)` and `len(P)` (a scalar or struct **type**) —
  `len() requires an array type, e.g. len(i32[4])`;
* `sizeof` without its parenthesis, or with an unclosed one, is the ordinary
  positioned parse error;
* `i32[0]` is still `array length out of range` — the fold runs *after* the
  length check, not instead of it.

Two more rows pin the **contextual-keyword** property the interception
carries: `sizeof` and `len` are ordinary identifiers in the lexer — a variable
may be *declared* and *assigned* under either name — but **read** in expression
position the parser treats them as the operator. `return len;` with `len` a
local is `expected '(' after len`, and so is `sizeof(len)`, because the
expression form re-enters the same rule one level in. The rule is therefore the
honest one — the names are not reserved, but nothing that *reads* them is
anything but the operator — and the two rows keep it that way.

`sizeof` refuses nothing `tySize` can answer; it is total over the type
grammar, which is the point of an operator whose whole job is to report what the
compiler already knows.

## 5. Coverage: `tests/sizeof-len-checks.sh` [9/9]

1. a strict `-Werror -pedantic` rebuild;
2. **source guards** pinning the five changes where they were made —
   `dimsProduct`/`sizeofTypeValue`, the `SizeOf, Len` enum pair, the `primary()`
   interception with both spellings, `paramDims` on `Function`, and the
   `Sema::check` binding fill (twenty-odd `grep -qF` lines);
3. **25 qemu behavioural cases** — every spelling (type and expression) × every
   scope (local, parameter, global, struct, struct array field) × both
   operators, including `sizeof(u8[10])` is 10, `sizeof(ptr)` is 8,
   `sizeof(local ptr)` is 8, a 2-D local and a 2-D parameter, and composition
   (`len(a) + sizeof(a)`, `len(a) * 2` in a bound);
4. **3 gcc-differential pairs** — Aster against the target C compiler: local
   and parameter arrays, scalar widths and the struct/array-field shapes, and
   the shipped example against its twin `tests/sizeof-len-twin.c`. No
   expectation is hand-computed;
5. an **11-row rejection matrix** — the four `len` refusals, the two malformed
   `sizeof` spellings, the zero-length array type, and the two
   contextual-keyword reads (`return len;` and `sizeof(len)` with `len` a
   local, both `expected '(' after len`);
6. a coverage floor (≥ 20 behavioural cases, so the suite cannot silently
   shrink);
7. a **5-mutant layer** — m1 clears `paramDims` (and the real compiler's
   `len(param)` answer becomes *illegal*, which is the point: the fill is what
   makes it legal, so the witness is `must_not_compile`), m2 drops the local's
   dims from the expression fold, m3 the 2-D product, m4 the scalar-`len`
   refusal, m5 the type-spelling fold;
8. the shared byte baseline;
9. the shipped example end to end under qemu.

## 6. The example: `examples/sizeof_len.ast`

The example is a bitmask accumulator — one `if` per spelling-and-scope family,
`return r` — and exits **255**, equal to its C twin. It covers the type spelling
(scalar, wider scalar, array literal, 2-D array), the expression spelling
(local 1-D and 2-D), the parameter spelling (bytes and count, 1-D and 2-D), a
global 3×4 grid (48 bytes, 12 elements), and a struct's own size beside its
array field's (`sizeof(Row) == 16`, `sizeof(row) == 16`, `sizeof(row.cells) ==
16`, `len(row.cells) == 4`) — nine checks, eight bits.

## 7. Nothing that exists moves

```
$ sh tests/rebuild-baseline-v0.23.35.sh
OK: 306 pre-existing lines byte-identical; 309 lines total (+3 sizeof_len)
```

The rebuild filters the three new `sizeof_len` rows, asserts the 306
pre-existing lines are byte-identical (built under `sh` with `LC_ALL=C` so the
shared `example-hashes.txt` ordering is deterministic), and confirms the total
lands at 309. The reason is structural: the feature is **new syntax only** —
`sizeof`/`len` are new tokens in `primary()`, and no pre-existing example spells
them, so no pre-existing parse tree changes shape. Five resident suites had
their `[8/9]` baseline filter extended with `sizeof_len`
(`array-address`, `multi-dim-array`, `array-elem-types`, `precedence`,
`struct-array-field`) and `ci.sh` registers the new suite; nothing had to back a
feature out.

## 8. Deliberately not included

* **`sizeof`/`len` as a bounds mechanism.** The parameter's dimensions answer
  these two operators and nothing else — a parameter subscript stays
  unchecked, `return a;` stays refused, `a = ...` stays a type error. A
  bounds-checked array reference type is a separate design.
* **`len` on a `ptr`.** A pointer has no length, in Aster as in C; `len(p)` is
  refused rather than answered 0 or a guess.
* **A `size_t`-style wide answer.** Both operators answer `i32`. The largest
  thing they can be asked about is an array of at most 1048576 elements of at
  most 8 bytes — 8388608, which fits.
* **C's decayed-parameter `sizeof`.** On `fn f(a: i32[4])`, C answers 8 (the
  pointer). Aster answers 16 (the array the caller passed). This is a
  deliberate divergence, documented in the spec and pinned by the twin's
  comment; it is the more useful answer and the one `len` already implies.

## 9. Full CI

```
$ HOSTCC=aarch64-linux-gnu-gcc RUNNER="qemu-aarch64 -L /usr/aarch64-linux-gnu" sh tests/ci.sh
========================================
CI SUMMARY: 92 passed, 0 skipped, 0 failed (of 92 checks)
========================================
```

One suite is new (`sizeof-len-checks.sh`, registered in `ci.sh`); every
pre-existing suite passes, including the byte-baseline walk and the five suites
whose `[8/9]` filters were extended for the new example's rows. The first full
run caught the filter/serialization coupling before it could catch anything
else — five `[8/9]` layers diff the whole baseline against a filtered copy, and
an unregistered example is exactly the shape that turns them red.

The last coupling the CI caught was a guard, not the compiler:
`tests/operator-checks.sh` (the v0.23.17 round) pins `Expr::Kind`'s tail as
`…, BitNot, Cond } k;`, and this round appends `SizeOf, Len` after `Cond`. The
guard now pins the kinds without the enum tail; the pair itself is guarded by
`sizeof-len-checks.sh`'s source-guard layer, so the pin never went stale. That
run's only red was `operator-checks.sh` [2/8] — one test file edited, no
compiler source touched, and the re-run is the 92/92 above.

## 10. What this closes, and what it opens

The round closes two lines at once: `docs/language-reference.md`'s "there is no
… `sizeof`" becomes false, and the v0.23.34-dev deliberately-not-included line
about a decayed parameter's missing length closes for the operators. What it
opens is the natural next question the lifecycle work keeps asking — a program
that knows `len(a)` inside a function can finally be told `a[i]` is out of
range, and a bounds-checked array parameter is the round that would close that.
It stays out of scope here, by the same rule that kept it out of the last three.
