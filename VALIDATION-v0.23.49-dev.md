# Validation Report — v0.23.49-dev

**Feature: language completion, Round B — `switch`, and labeled `break`/`continue`.**
This is the second of the three host-language rounds frozen after the
self-hosting arc closed (Round A was `u64` + the `T(x)` cast; Round C — character
literals and numeric sugar — is still ahead). The language had one control-flow
shape missing: a multi-way branch whose arms are compile-time integer constants.
Every other selection was a boolean `if`; a dispatch on, say, an opcode or a
tag meant a ladder of `if (x == 1) … else if (x == 2) …` that the compiler
lowered to a comparison chain anyway. This round adds that shape with **Pascal
semantics** — each matching case body self-ends, there is no fallthrough, and
therefore no per-case `break` is needed or permitted — and, while it was in the
neighbourhood, the long-promised labeled `break`/`continue` that let a nested
loop jump straight to a named outer loop. Both ship in the host compiler only:
`bootstrap/aster.ast`'s subset deliberately did **not** grow (the new forms are
rejected there, §6), and its C twin was synchronized with **comments**, not code.

```
// the shipped example, under qemu-aarch64 (host = the target C compiler):
//   aster build-elf examples/switch.ast -o sw && ./sw ; echo $?
//   212
//   aarch64-linux-gnu-gcc -std=c11 -O2 tests/switch-twin.c -o swt
//   qemu-aarch64 ./swt ; echo $?
//   212
```

## 1. Why this round exists

A multi-way branch is the one control-flow primitive the language lacked. Without
it, a dispatch on a small integer reads as a staircase of equality `if`s, and a
programmer who wants "do this for 1, that for 2, otherwise the default" has no
single construct to say so. The plan's three language rounds close the remaining
shape gaps; Round B is the multi-way branch plus the loop labels that a real
`switch` makes urgent (break out of, or continue, an outer loop from inside a
nested one).

The semantics were a deliberate choice. C `switch` fallthrough is the single most
error-prone construct in that language — forgotten `break`es silently run the
next arm. Aster takes the Pascal reading: a case body that matches runs to its
end and leaves the `switch`; there is no fallthrough and no `break` keyword
inside a `switch`. `break` and `continue` keep their existing meaning — they
still name the innermost loop — and `switch` does **not** push a loop context,
so a `break` inside a `switch` that is inside a `while` breaks the `while`, not
the `switch`. The labeled forms (`break outer;` / `continue outer;`) are the
only way to cross loop nesting, and they resolve the name innermost-first.

## 2. What shipped

### 2.1 `switch (e) { case C: … default: … }`, Pascal semantics

`enum TK` gains `Switch, Case, Default` grouped with the loop-control words, and
`enum Stmt::Kind` gains `Switch` between `Continue` and `Expr`. `Stmt` carries
the new fields `caseExprs`, `caseBodies`, `hasDefault` and a reused `label`
string (the same field that names a `while`/`for` also names the target of a
labeled `break`/`continue`). The parser recognises an optional `Ident :` prefix
on a `while` or `for` only, collects each case body with a brace-less
`caseBody()` that runs until it meets `Case`, `Default`, `}` or `End`, and reads
a `:` after every case value.

Codegen lowers the `switch` to the **comparison chain it would have been**: the
subject is spilled to a frame slot, then each case is `load subject; load case
value; CMP; B.NE → skip-body; body; B → end`, with a final `default` body and a
single `end` that every arm branches to. `patchCond(skip, 1, bodyEnd)` emits a
**not-equal** branch (cond `1` = `B.NE`), so a mismatch skips the body instead
of falling into it. The round added **zero new instructions** and **zero new
label concepts** — it is a rearrangement of existing materialisation and
branching, which is exactly why the byte baseline of every pre-existing example
is untouched (§7).

### 2.2 The subject must be an integer; case values must be constants that fit and are unique

Sema pins the subject to `tyIsInteger` ("switch subject must be an integer, not
X"), each case value to `constantInteger` ("case value must be a compile-time
constant"), and each value to `caseValueFits` — the same width logic
`initializerFits` uses for a slot, so a `u8` subject rejects a case of `300` and
an `i32` subject rejects `2147483648`. A repeated value is refused
("duplicate case value N"), and `default` may appear at most once, in any
position. The `caseValueFits` helper lives beside `initializerFits` so the two
width rules cannot drift.

### 2.3 Labeled `break`/`continue` across loop nesting

A `while` or `for` may carry `name:`; `break name;` / `continue name;` read the
following identifier as the target. Sema keeps a `loopNames` stack parallel to
`loopDepth` and resolves the label innermost-first
(`std::find(loopNames.rbegin(), loopNames.rend(), s.label)`); a name that
matches no enclosing loop is "no such loop label: X", and a label on anything
but a loop is "only a while or for loop may be labeled". Codegen resolves the
same way through `loopIndexFor(const Stmt&)`, which returns the innermost
matching loop index (or the top of the stack for an unlabeled jump). A
labeled jump that names a real loop but is not inside it, or names a missing
loop, is rejected at compile time — the labels are a compile-time name
resolution, not a runtime goto.

### 2.4 `definitelyReturns` learns `switch`

A `switch` "definitely returns" exactly when it has a `default` and **every**
case body and the `default` body definitely return — so a function whose only
return path is a `switch` with a covering `default` is still well-formed, which
is the natural reading and the one the suite pins (§4).

## 3. The defects the round found in itself

The round's own code went through several wrong compilations before the chain
was right, and the suite was written to keep each one from coming back:

- **Case bodies fell through on a mismatch.** The first codegen emitted
  `B.EQ → body` and let a non-matching subject drop into the next arm; the
  "no case matches, default 99" witness returned `10` instead of `99`. The
  branch is now `B.NE → skip` (cond `1`). The mutation layer re-inverts it
  (`patchCond(skip,1,…)` → `patchCond(skip,0,…)`) and asserts the witness
  changes, so the inversion can never return silently.
- **A `case` value needed its trailing `:`**. Forgetting `need(TK::Colon)` after
  the case value made the parser report "expected let … or switch" against the
  body's first token; the grammar now reads the `:` explicitly and a case with a
  missing `:` is a parse error, not a mislabeled statement.
- **A labeled jump resolved to the wrong loop.** The first `loopIndexFor`
  returned the top of the stack for any labeled jump, so `continue outer`
  behaved like the innermost loop; the double-label witness would have returned
  `6` instead of `3`. The mutation replaces the name lookup with
  `return loops.size()-1` and asserts the witness changes.
- **The `default` body could be dropped.** A mutant that deletes
  `if(s.hasDefault)block(s.elseBody,true);` makes a subject that matches no case
  return the uninitialised accumulator; the same `99` witness catches it.

These are the system working as designed: the witnesses are pinned against the
hand-derived exit code, so a regression in the chain shows up as a wrong exit,
not as a compile error.

## 4. What the suite proves (`tests/switch-checks.sh`, [9/9])

The resident suite is nine layers, each guarding a different angle of the same
feature:

1. **Strict build** of the compiler (`-Wall -Wextra -pedantic -Werror`).
2. **Source guards** — every change pinned where it was made (the `TK` trio, the
   lexer chain, `Stmt::Kind`, the `caseBodies`/`label` fields, `caseValueFits`,
   `switchStatement`/`caseBody`, the label dispatch, the `break`/`continue`
   label read, the subject/duplicate/fit refusals, `loopNames`, `loopIndexFor`,
   and the `patchCond(skip,1,…)` comparison chain).
3. **qemu behavioural matrix** — 20 cases, each returning the value it is named
   for: basic match, default before/after the cases, an expression case value,
   empty/chained case bodies, a nested `switch`, a `switch` inside a loop, the
   single- and double-label `break`/`continue`, `u8`/`i64`/`u64` subjects, the
   `definitelyReturns` case, and a label on a `for`.
4. **Differential** — Aster against the target C compiler (the shipped example
   plus a labeled-`continue`-crossing-a-loop case and a no-fallthrough select),
   where C needs an explicit `goto` and Aster names the outer loop directly.
5. **Rejection matrix** — 13 refusals: non-integer subjects (`bool`, `ptr`),
   a non-constant case value, a duplicate, a case value too wide for `i32`/`u8`,
   a second `default`, `break`/`continue` outside a loop, a label on a non-loop,
   and a `break`/`continue` to a missing label.
6. **Coverage** — the behavioural layer is the coverage; it asserts at least 20
   cases, so a hole in a guard is a hole here.
7. **Mutation** — three mutants, each removing exactly one rule (the mismatch
   branch inverted, the labeled jump always innermost, the `default` body
   dropped); a witness must notice each.
8. **Byte-identity baseline** — the shared `example-hashes.txt` reproduces
   byte for byte; this round's `switch.ast` joins the filter (§7).
9. **End-to-end** — `examples/switch.ast` runs under qemu and returns `212`,
   the value its C twin `tests/switch-twin.c` returns.

## 5. Lessons the round recorded

- **Pascal semantics are cheaper than they look.** Because there is no
  fallthrough, codegen is just the comparison chain it would have been, and the
  no-new-instruction property is what keeps the byte baseline at 288 pre-existing
  rows unchanged. A C-style `switch` would have needed jump tables or explicit
  fallthrough edges; Pascal needs neither.
- **Labels are a compile-time name resolution, not a runtime goto.** Keeping
  `loopNames` parallel to `loopDepth` and resolving innermost-first means a bad
  label is a hard error at Sema time, and `loopIndexFor` is the single point
  codegen asks. The mutation that drops the name lookup is caught because the
  double-label witness changes shape.
- **The exit-code mask is a trap.** qemu-aarch64 returns the guest's
  `_exit(status & 0xff)` verbatim, so every value in `0..255` is observable
  directly — but a harness that folds `>127` to `value-256` corrupts a genuine
  return such as `200` or `255`. The suite compares raw exit codes (cf. the
  example's `212`), and the differential layer compares Aster's exit against
  C's, both raw.

## 6. The twin: synchronized by comment

`bootstrap/aster.ast` (the C that bootstraps the compiler) and
`tests/codegen-twin.c` (the C that mirrors Aster's codegen) both reject the new
forms in the bootstrap subset, with the same diagnostics:

- `switch` → "switch is not in the bootstrap subset"
- a labeled loop (`Ident :` before a `while`/`for`) → "labeled loops are not in
  the bootstrap subset"
- a labeled `break`/`continue` (`K_Ident` after `break`/`continue`) → "labeled
  break/continue is not in the bootstrap subset"

Nothing in the bootstrap path learned to emit or consume a `switch` or a loop
label; the subset stayed exactly as Round A left it, and the C twin carries the
same three rejections so the two stay in lock-step by comment, not by shared
code.

## 7. Baseline

The round adds `examples/switch.ast` (three rows, one per build mode: `build-so`,
`build-elf`, `build-obj --pic`). `tests/rebuild-baseline-v0.23.49.sh` re-records
`tests/baseline/v0.23.5-dev/example-hashes.txt` from **333 to 336 rows**: the 288
core rows the v0.23.30 discipline fixed, plus the fifteen earlier rounds' three-row
families and this round's three. The example imports nothing, so all three of its
rows are real hashes (a `FAILED` row would itself be a regression).

**Sixteen filtering suites** now exclude `^switch\.` alongside the fifteen
earlier rounds' families, so the pre-existing count stays 288 on both sides:

- `switch-checks.sh` (this round)
- `sizeof-len-checks.sh`, `array-address-checks.sh`, `integer-cast-checks.sh`,
  `multi-dim-array-checks.sh`, `array-elem-types-checks.sh`, `precedence-checks.sh`,
  `struct-array-field-checks.sh` — each gains the `^switch\.` exclusion.
- `condition-checks.sh`, `null-ptr-checks.sh`, `struct-checks.sh` do a full
  `diff` of the baseline and therefore need no exclusion; they pass once the
  baseline includes `switch.ast`.

The `integer-cast-checks.sh` version guard was bumped to `0.23.49-dev` alongside
the version constant, so a stale compiler (or a forgotten bump) still fails
loudly.

## 8. Reproduction

```sh
# 0) the resident suite (builds everything from source, ~2 min)
./tests/switch-checks.sh

# 1) the shipped example against its C twin
aster build-elf examples/switch.ast -o sw && qemu-aarch64 ./sw; echo $?   # 212
aarch64-linux-gnu-gcc -std=c11 -O2 tests/switch-twin.c -o swt
qemu-aarch64 ./swt; echo $?                                              # 212

# 2) the byte-identity baseline re-record (one-shot; asserts before it writes)
./tests/rebuild-baseline-v0.23.49.sh

# 3) the full CI (switch-checks.sh is now registered in the suite list)
sh tests/ci.sh
```

## 9. Files

- `src/aster.cpp` — `TK::Switch/Case/Default`, `Stmt::Switch` + `caseExprs`/
  `caseBodies`/`hasDefault`/`label`, `caseValueFits`, `switchStatement`/
  `caseBody`, the label dispatch, `loopNames`, `loopIndexFor`, the comparison
  chain; version `0.23.49-dev`.
- `bootstrap/gen_lexer_names.py` — `TOKENS` 73→76, `KEYWORDS` 23→26 (self-check
  updated).
- `bootstrap/gen_parser_names.py` — `STMT_KINDS` 12→13 (`Switch`; subset stays
  9), self-check updated.
- `bootstrap/aster.ast`, `tests/codegen-twin.c` — three bootstrap-subset
  rejections each, comments synchronized.
- `tests/discard-call-checks.sh` — the "expected … or switch" message cascade.
- `examples/switch.ast`, `tests/switch-twin.c`, `tests/switch-checks.sh` — the
  example, its twin, and the nine-layer suite.
- `tests/rebuild-baseline-v0.23.49.sh` — baseline re-record (333→336).
- `tests/ci.sh` — `switch-checks.sh` registered.
