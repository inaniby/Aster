# Validation — v0.23.17-dev

**The operators the language was missing: `%`, `<<`, `>>`, `&`, `|`, `^`, `~`,
the compound assignments, `++` / `--`, and `?:`.**

Before this release Aster's arithmetic vocabulary was `+ - * /` and the six
comparisons. A remainder could not be written at all without division, a bit
mask was unreachable, and `glyph_bit` in `examples/icon_text_demo.ast` is
division-and-modulo *because the language had no `&`*. This release adds the
operators, on a real precedence chain, with encodings measured from a C compiler
rather than derived by hand — and proves each one three ways: rejected where it
must be, executed under qemu, and compared against cross-compiled C.

---

## 1. Where the encodings came from

Nothing here was invented. For every operator the equivalent C expression was
compiled with `aarch64-linux-gnu-gcc -O2` and the encoding read off the output:

| Aster | AArch64 | Read from gcc output for |
| --- | --- | --- |
| `a % b` | `SDIV` `Q, a, b` then `MSUB` `a, Q, b, a` | `int f(int a,int b){return a%b;}` |
| `a << b` | `LSL` (register) | `int f(int a,int b){return a<<b;}` |
| `a >> b` | `ASR` for a signed left operand, `LSR` for an unsigned one | same, with `int` and `unsigned` |
| `a & b` / `a \| b` / `a ^ b` | `AND` / `ORR` / `EOR` | same shape, three opcodes |
| `~a` | `ORN a, xzr, a` (which is what `mvn` is) | `int f(int a){return ~a;}` |

The signed/unsigned choice in `>>` is taken from the **left** operand's type,
because whether the sign survives is a property of the value being shifted, not
of the count. `-8 >> 1` is `-4`, not `0x7FFFFFFC`.

## 2. What is a statement and what is an expression

Two decisions are worth stating, because both are restrictions rather than
features:

- **Compound assignment is desugared in the parser.** `x OP= e` becomes
  `x = x OP e`, so codegen never learns about it and every target form (`x`,
  `a[i]`, `s.f`, `*p`) inherits the new operators for free. The desugaring has
  exactly one observable consequence — the target's address expression is
  evaluated twice — so instead of shipping a silent miscompilation,
  `containsCall()` rejects the form that would show it: `a[f()] += 1` is a
  compile error that says to write the assignment out in full. A plain
  `a[f()] = 1` is still accepted, because it evaluates the subscript once.
- **`++` / `--` are statements only.** Both spellings compile to the same store
  (`name = name ± 1`), so `i++` and `++i` are the same instruction — but neither
  is allowed in expression position. That is what keeps an Aster expression free
  of side effects, which is in turn what makes `containsCall()` a sufficient
  guard above and keeps the constant folder honest. `return d++;` is rejected.

## 3. A folding bug found on the way, and fixed

Folding a global initializer masked the shift count with `& 63`, so:

```aster
let g: i32 = 1 << -1;   // became 1 << 63 — a value nobody wrote
```

compiled silently. `constantInteger()` already refused to fold an out-of-range
count everywhere else, so the same expression meant two different things
depending on where it appeared. A count outside `[0,63]`, and a left shift whose
result leaves `i64`, are now compile errors with the offending expression
pointed at:

```
aster: g.ast:1:14: error: shift count -1 is out of range (0..63) in global variable initializer
```

## 4. `tests/operator-checks.sh` — eight layers, all run

| Layer | What it asserts |
| --- | --- |
| [1/8] | strict build: `-std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror` |
| [2/8] | source guards: every new token, AST kind, grammar level and encoding, plus `<<=` being one token |
| [3/8] | **14 rejections** with the diagnostic text asserted, not just "it failed" |
| [4/8] | **12 qemu checks**, one per operator, plus one aggregate program whose value is the sum of nine independent sub-results |
| [5/8] | **18 qemu checks**: precedence, every compound-assignment target form, both `++`/`--` spellings, a `for` step, `?:` nesting and right-associativity |
| [6/8] | **5 qemu checks** of constant folding through a global |
| [7/8] | **11 differential comparisons** against cross-compiled C |
| [8/8] | **3 mutations** proving the checks test the encodings, not the parser |

The rejection matrix covers a pointer in `&` / `~` / `<<`, a struct in `&`,
`++` in expression position (both spellings), a non-bool `?:` condition, `?:`
arms of different types, a compound assignment with a call in the subscript,
`%` by zero, three bad shift counts, and the chained comparison that has to stay
rejected through the new precedence chain.

The aggregate check in [4/8] is the strongest single one:

```aster
fn main() -> i32 {
    let a: i32 = -17; let b: i32 = 5;
    let r1: i32 = a % b;                 // -2
    let r2: i32 = 17 % -5;               //  2
    let r3: i32 = -8 >> 1;               // -4
    let r4: i32 = -8 << 1;               // -16
    let r5: i32 = 1 + 2 * 3 << 2 & 12;   // 12
    let r6: i32 = 1 == 1 ? 7 : 9;        //  7
    let r7: i32 = 1 == 2 ? 7 : 9;        //  9
    let c: i32 = 0;
    c += 5; c -= 2; c *= 3; c /= 2; c %= 4; c <<= 3; c >>= 1; c |= 1; c &= 12; c ^= 3;
    let d: i32 = 10;
    d++; --d;
    return r1 + r2 + r3 + r4 + r5 + r6 + r7 + c + d;   // 21
}
```

Aster's exit status is **21**; the same program written in C and compiled with
`aarch64-linux-gnu-gcc` also exits **21**. Nine sub-results in one value, so one
wrong operator cannot be masked by another operator's accident.

## 5. The differential layer

Hand-written expected values can agree with a mistake. So the same expressions
are compiled twice — once by Aster, once by the target C compiler — and both
binaries are run through the qemu router and their exit statuses compared:

```
[7/8] Differential: Aster vs the target C compiler
  1 | 2 & 3 ^ 4                      7
  1 + 2 << 3 | 1                     25
  8 >> 1 + 1                         2
  2 * 3 % 4                          2
  100 / 7 % 3                        2
  ~17 & 31                           14
  -17 % 5                            254
  -8 >> 1                            252
  (v >> 8) & 255                     190
  ?: nesting                         5
  compound + ++ + ?:                 17
```

(`254` and `252` are `-2` and `-4` as an 8-bit exit status — identical on both
sides, which is the point: the comparison is between two real executions, not
between a value and an expectation.)

## 6. The mutation layer

A behavioural check that passes on a damaged compiler is not checking anything.
Three times, the compiler is rebuilt with one encoding changed and the same
check is required to **fail**:

```
[8/8] Mutation: the checks above must fail on a damaged compiler
  MSUB -> MADD (%)                   mutant gives 32 (correct: 2)
  ASR -> LSR (>>)                    mutant gives 2 (correct: 1)
  ORN -> ORR (~)                     mutant gives 17 (correct: -18)
```

`MSUB`→`MADD` turns `17 % 5` into `17 + 3*5`. `ASR`→`LSR` makes `-8 >> 1`
positive. `ORN`→`ORR` makes `~17` equal `17`. Each mutant still parses and
compiles the program — only the answer changes, which is exactly the class of
regression a source guard cannot see.

## 7. Byte identity: two independent witnesses

The new operators are additive — a program that does not use them must compile
to exactly the bytes it did before.

1. **Direct A/B.** v0.23.16-dev's compiler and v0.23.17-dev's, over every
   `examples/*.ast` in three modes (`build-elf`, `build-obj --pic`, `build-so`):
   **214/214 byte-identical, 0 differing**.
2. **Recorded baseline.** The 261-line `tests/baseline/v0.23.5-dev/example-hashes.txt`
   reproduces exactly, asserted by `struct-checks.sh` [4/8] in the full CI run.

The version string reaches stdout and the APK JAR manifest only — never an
ELF/`.so`/`.o` Aster emits — so the bump cannot move a byte.

## 8. Two defects recorded, not fixed

Both are pre-existing and neither is an operator bug; both are written down here
so they are not discovered twice.

- **A `u8` parameter is not delivered.** `fn g(a: u8) -> u8 { return a; }`
  called as `g(200)` returns **0**, while a `u8` local variable, array element
  and struct field all behave correctly. It reproduces identically under
  v0.23.16-dev, so it is not a regression from this round, and the fix is a
  narrow-argument ABI change — its own theme, not a footnote to an operator
  release. It is the next narrow-type item in the gap analysis.
- **`INT64_MIN / -1` traps inside the compiler.** `let g: i32 = -9223372036854775808 / -1;`
  divides before it checks, so the folder itself faults. `constantInteger()`
  already knows the rule (`a==INT64_MIN && b==-1`); only `foldConst()`'s `Div`
  is missing it.

## 9. Verification log

| Step | Result |
| --- | --- |
| Strict rebuild (`-Werror`) | clean |
| `tests/operator-checks.sh` | [8/8] PASS — 14 rejections, 35 qemu checks, 11 differential, 3 mutations |
| Direct A/B vs v0.23.16-dev | 214/214 identical, 0 differing |
| 261-line recorded baseline | reproduces exactly |
| Full `tests/ci.sh` | see §10 |

## 10. Full CI

```
========================================
CI SUMMARY: 73 passed, 0 skipped, 0 failed (of 73 checks)
========================================
```

Up from **72/0/0** in v0.23.16-dev: the one new suite is `operator-checks.sh`,
and nothing else moved. That includes `struct-checks.sh` (which re-derives the
261-line byte baseline), `version-checks.sh` (which demands the documentation
this report is part of), the 22 `e2e-*` suites that run the guest under qemu,
and the three APK gates — `native_render`, `icon_text_demo`, `native_touch` —
each verified twice (`validate_apk.py` and `aster verify-apk`).

| | v0.23.16-dev | v0.23.17-dev |
| --- | --- | --- |
| CI | 72 passed / 0 skipped / 0 failed | **73 passed / 0 skipped / 0 failed** |
| direct A/B | 212/212 | **214/214** |
| wall clock | ~27 min | ~29 min |

The three demo APKs were rebuilt with this compiler and each verifies
`v1 + v2 signatures verified`; their `.so` payloads are byte-identical to
v0.23.16-dev's (the version string reaches the JAR manifest, not the ELF).

## 11. What this unblocks

Every remaining gap on the list is now expressible without contortion: the
narrow-type ABI item (a `u8` *parameter* is not delivered — §8) can be fixed
and tested directly; the string and memory builtins no longer need `%` spelled
as subtraction; and `glyph_bit` in `icon_text_demo.ast` can become the
single instruction it always wanted to be — though that would change an
existing example's bytes, so it waits for a round whose subject it is.
