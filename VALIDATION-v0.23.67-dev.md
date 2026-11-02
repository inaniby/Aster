# Validation — v0.23.67-dev (close the language gaps: `type` and `const`)

This round closes the first two items of the audit's third part
(`AUDIT-v0.23.61-dev.md`, item 13, "language gaps"): `typedef`/type alias (1)
and `const` (2). It is a **pure language-feature round** — no defect was
reproduced, because there was nothing broken to find: Aster simply lacked the
two declaration forms. The measurement that matters most is therefore the one
this project always demands of a "no codegen change" round: **every existing
program compiles to the same bytes.**

## 1. The audit's ask

> `docs/language-reference.md:164` lists unsupported items: `void`,
> `float/double`, `char` **type**, `union`, `const`, `typedef`/type alias.
> … (3) Language gaps, in order of cost-effectiveness: **1. `typedef`/type
> alias** — expandable at `Ty`-parse time, changes mostly in the Parser, lowest
> semantic risk. **2. `const`** — a read-only binding. **3. `void`** — only
> touches the function return bit; would directly unblock C-ABI interop.

This round takes 1 and 2 and leaves `void` queued (it is a different kind of
change — the function return slot — and the roadmap's "one coherent theme per
version" rule keeps it separate).

## 2. What `type Name = T ;` is, and is not

A `Ty` is a `(kind, index)` pair with **no room for a spelling**. There is no
`Ty::Alias`: `parseType()` consults `typeAliasOf()` *before* it reads any
keyword or `ptr<…>` and substitutes the underlying `Ty` on the spot. So the
alias name is gone before layout, Sema and codegen ever run. Two names for
`i32` are `i32`; a value of one is a value of the other; the guarantee is about
the compiler, not the image.

The one thing a `Ty` cannot carry — a **function signature** — travels in the
alias record (`TypeAlias{ Ty ty; bool isFunc; FuncSig sig; }`) and is handed
back at every use through `pendingFuncType`/`pendingFuncSig`. That is the whole
point of the feature: `type Op = fn(i32) -> i64;` is a *real* signature at every
declaration that names it.

**Refusals reproduced on the binary (all confirmed by `tests/alias-const-checks.sh` [5/9]):**

| Attempt | Message | gcc twin also refuses? |
| --- | --- | --- |
| `type P = Nope;` | `expected a type after '=' in the declaration of type alias P` | n/a (Aster-only parse error) |
| `type P = i32; type P = u16;` | `duplicate type alias: P` | n/a |
| `struct P {…} type P = i32;` | `type alias conflicts with a struct: P` | n/a |
| `let P: i32 = 1; type P = i32;` | `type alias conflicts with a global variable: P` | n/a |
| `type Row = i32[4];` | `expected ';' after a type alias declaration` | n/a (array is a declaration form, not a type) |
| `let g: P = 1;` (undeclared) | `expected i32, i64, u8, u16, u32, u64, ptr, ptr<S>, bool` | n/a |

## 3. What `const x : T = e ;` refuses

A const is a `let` whose `isConst` bit rides in the `Binding` (locals, via
`letStatement(isConst)`) and in `constGlobals` (globals, flagged through
`globalDeclaration(false, false, isConst)`). One predicate, `isConstName`,
answers for **every** store site, so the five refusals cannot drift apart:

| Store | Path | Message |
| --- | --- | --- |
| `k = 2` / `k += 2` / `k++` | assignment, local **and** global | `cannot assign to a const: k` |
| `a[0] = 6` (const array) | element store | `cannot assign to a const: a` |
| `s.x = 3` (const struct) | field store — the **base** `s` is refused | `cannot assign to a const: s` |
| `&k` | address-of | `cannot take the address of a const: k` |

`const` must be initialized (`expected '='` at a global; `a const must have an
initializer: s` for a struct local written `const s: Pt;`). Reading a const is
reading a `let`.

**The one refusal gcc does not share.** C hands out a `const int *` for
`&const` because its type system can say "pointer to const". Aster's `ptr`
cannot, so refusing `&const` is the one refusal the suite records as Aster's
alone — it says so rather than inventing a gcc twin. Every *other* refusal in
the matrix has a C twin gcc refuses too.

## 4. The independent reader: an alias is a spelling, not a type

[3/9] of the suite is an independent reader that knows nothing about the
compiler: it rewrites every `type N = T ;` out of the source by hand (whole
words, in declaration order, so an alias whose right-hand side names an earlier
alias resolves against the text the earlier one was already replaced with) and
requires **byte-identical** output from `build-elf` and `build-obj --pic`.

Byte equality is the proof the alias is a *spelling* and not a *type*: had the
compiler attached any weight to the name, the two programs could not agree.
Four cases — a struct/`ptr` alias, an `fn` alias, a nested alias (`type J = I;
type P = ptr<J>;`), and the shipped `type_alias.ast` — all pass byte-identical.
The expander must also fail if any alias survives, which is what catches a
source edit that accidentally keeps a name live.

## 5. The gcc differential (ten cases)

`typedef` and `const` are C spellings, so each behavioural case has a C twin in
`tests/type-alias-twin.c` / `tests/const-binding-twin.c` and the two must agree
on the qemu exit status — never a hand-computed expectation. All ten pass:

| Case | Aster exit | C exit |
| --- | --- | --- |
| alias_scalar | 42 | 42 |
| alias_struct_ptr | 7 | 7 |
| alias_array_elem | 89 | 89 |
| alias_field | 12 | 12 |
| alias_param_ret | 42 | 42 |
| alias_fn_type | 42 | 42 |
| alias_sizeof | 8 | 8 |
| alias_fn_i64_ret | 11 | 11 |
| const_local_read | 42 | 42 |
| const_array_struct | 21 | 21 |

`alias_fn_i64_ret` is the signature witness: with the alias, `op` carries the
`-> i64` signature and the program returns 11; a bare function pointer would
read the result at `i32` width and return 22. The mutation layer (§7) proves the
signature is what makes the difference.

## 6. The keyword table is generated, not hand-edited

Two reserved words (`type`, `const`) join the lexer. The count moves 27 → 29,
and `tls` stays a context keyword. Both the token-kind enum and the hand-written
token count in `docs/language-spec.md` are produced by
`bootstrap/gen_lexer_names.py`, which fails the build's check mode if the
enum/keyword/table numbers disagree. The suite asserts 29 reserved words with
`type` and `const` among them and `tls` *not* among them, so the generated
table cannot silently fall out of step.

## 7. Mutations (six) — every piece is load-bearing

| # | Mutant | Detected by |
| --- | --- | --- |
| a | every alias expands to `i32` | `examples/type_alias.ast` stops building |
| b | local-assign refusal disabled | `const k=1; k=2` now builds (mutant accepts) |
| c | `isConstName` returns `false` | `const a[2]=5; a[0]=6` now builds |
| d | alias drops its signature | `alias_fn_i64_ret` returns 22, not 11 (qemu) |
| e | const initializer rule disabled | `const s: Pt;` (no init) now builds |
| f | duplicate-alias refusal disabled | `type P = i32; type P = u16;` now builds |

(a) is "noticed" when the mutant **fails to build** (aliases are broken);
(b)(c)(e)(f) are "noticed" when the mutant **builds** (a previously-refused
program is now accepted); (d) is "noticed" by the changed qemu exit code. This
is the project's standard convention: a mutant is "noticed" precisely when its
behavior differs from the original's.

## 8. Byte impact — none

All 123 examples compile to the **same bytes** as v0.23.66-dev across all three
build modes. The baseline layer ([9/9]) asserts this directly: it regenerates
the 366 filtered rows (123 examples × 3 modes, minus the three
`address_of_abi.*` rows every release filters) and diffs them against
`tests/baseline/v0.23.66-dev/example-hashes.txt`; **360 pre-existing rows are
unchanged**, 0 moved. The only baseline rows that differ from the previous
snapshot's *file* are the three `address_of_abi.*` lines, which the previous
round already filtered out of the recorded file — so the recorded file has 366
rows and the comparison reproduces exactly.

A const global occupies the same `.data` bytes a `let` global does, so no
codegen path moves; a type alias is gone before codegen runs, so nothing it
touches can move either.

## 9. The gate

Suite added: `tests/alias-const-checks.sh` (registered in `tests/ci.sh`
`CRITICAL` and `DEFAULT_SUITES`, beside `elf-metadata-checks.sh`).

- `tests/alias-const-checks.sh`: **PASS** (9/9 layers).
- Full `LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc bash tests/ci.sh`:
  **124 passed, 0 skipped, 0 failed** (of 124 suites); APK gates
  **3 passed, 0 skipped, 0 failed**.

### 9.1 Regression caught and fixed during this round

The first full gate run came back `18 failed / 106 passed`. Every failure was
**test-side**, not feature-code: the feature itself was already proven by the
self-host `codegen-checks` (0 divergences over 128 programs) and by
`alias-const-checks` 9/9. The 18 broke for five reasons, all now fixed:

| # | Suite(s) | Cause | Fix |
| --- | --- | --- | --- |
| 13 | `precedence`, `array-elem-types`, `struct-array-field`, `array-address`, `multi-dim-array`, `sizeof-len`, `integer-cast`, `cast-conversions`, `switch`, `enum`, `eval-order`, `type-strictness`, `literals` | the 2 new `examples/*.ast` leaked 6 rows into the "pre-existing baseline" count (288 → 294) | added `type_alias`/`const_binding` to each suite's exclusion filter |
| 1 | `elf-metadata-checks` | baseline grew to 366 rows (369 − 3 `address_of_abi`) | bumped the count assertion 360 → 366 |
| 1 | `sema-checks` | `Sema sema{…}` constructor gained a `constGlobals` field | updated the pinned constructor text |
| 1 | `function-type-checks` | `Binding` gained `bool isConst=false;` on its own line | split the guard into two `grep -qF` checks (fn-pointer machinery + the const bit) |
| 2 | `ci-protocol-checks`, `mutation-score-checks` | the new suite hardcoded `v0.23.66-dev` and its mutant FAIL messages lacked a `$KILL` phrase | derive the previous baseline version dynamically; `was not noticed` → `went unnoticed` |

After the fixes, a focused re-run of all 18 suites plus a standalone
`function-type-checks` run both return `0 failed`; the full 124-suite gate is
green.

## 10. Still open

- **`void`** (audit item 13, #3) — queued. It changes the function return slot,
  a different kind of edit from `typedef`/`const`, and the roadmap's one-theme
  rule keeps it a separate round.
- `char` and `union` (audit items 4 and 5) — not yet scheduled.
