# Validation Report — v0.23.50-dev

**Feature: language completion, Round C — the literal surface: character
literals, numeric suffixes (`u` / `l` / `ul`), digit separators (`1_000_000`),
`0b` binary literals, and the extended escape table.** This is the third of the
three host-language rounds frozen after the self-hosting arc closed (Round A was
`u64` + the `T(x)` cast; Round B was `switch` + labeled `break`/`continue`). The
language's literal grammar had been frozen too small: integer and string tokens,
the hex prefix, and a six-entry escape table that still refused `\'` (so a string
could not name itself) and had no control codes beyond `n r t 0 \ "`. This round
fills the surface out — every shape in `examples/literals.ast` returns the value
it is named for — and keeps the bytes of every program that compiled before,
because a literal is a token, not an instruction: the byte baseline is untouched
except for this round's own example (`§7`). Both ship in the host compiler only:
`bootstrap/aster.ast`'s subset deliberately did **not** grow (the new `Char`
token is rejected there, `§6`), and its C twin was synchronized with **comments**,
not code.

```
// the shipped example, under qemu-aarch64 (host = the target C compiler):
//   aster build-elf examples/literals.ast -o lit && ./lit ; echo $?
//   255
//   aarch64-linux-gnu-gcc -std=c11 -O2 tests/literals-twin.c -o litt
//   qemu-aarch64 ./litt ; echo $?
//   255
```

## 1. Why this round exists

The literal surface was the one shape gap the language closed last, and it was
small by accident, not by design. An integer literal's *type* was decided by the
slot it landed in: `0xFFFFFFFF` was always an `i64`, so asking for it as a `u32`
meant writing `let x: u32 = 0xFFFFFFFF;` and watching the literal widen into
64 bits before the slot narrowed it back — and a `u32` slot could only ever hold
a value that *happened* to fit, never a value the literal *declared* itself to
be. A character was a string of length one, so `'A'` did not exist and a string
could not name a quote. A binary or digit-grouped constant had to be written out
in full in hex or decimal. The plan's three language rounds close the remaining
shape gaps; Round C is the literal surface — the leaves of every other
expression that the language could already build.

The semantic decisions were each a deliberate choice. The `Char` token is a
**punctuation token**, not a keyword, so the reserved-word count stays 26 and the
generator's `KEYWORDS` is untouched — only `TOKENS` moves, and `check_list()`
pins the new count. A numeric suffix **pins the literal's type** at the lexer/primary
level (`LitSuffix`), so a `u32` is a `u32` before any slot sees it, and the value
is read at the width it was written. Separators and binary are **cosmetic
re-decoration** stripped at lex time — they change how a number looks, never
what it is. The escape table **fills out** through the same shared `unescape` the
strings already used, so the two literal kinds cannot drift.

## 2. What shipped

### 2.1 A `Char` token, decoded through the shared escape table

`enum TK` gains `Char` beside `String` (and `bootstrap/gen_lexer_names.py` —
the single source of truth — gains `"Char"` in `TOKENS`, moving `TOKEN_COUNT`
**76 → 77**; `KEYWORDS` stays 26, and `check_list()` asserts `TOKEN_COUNT != 77`
is a build failure). A character literal is a single-quoted character whose body
decodes through the **same `unescape` function** the strings use, so `'a'`,
`'\n'`, `'\''`, `'\a'` and `'\x41'` all produce one code unit (0..255) carried
as an `i32` in a `Char` token. The lexer rejects the two malformed shapes: an
empty or unterminated literal (`''` or a quote with no closing quote) and a
multi-character literal (`'ab'`), because a `Char` token carries exactly one
code unit — "char literal must hold exactly one character" / "empty or
unterminated char literal".

### 2.2 Numeric suffixes pin a literal's type: `u` / `l` / `ul`

`Expr` gains `enum LitSuffix { LSNone, LSU, LSL, LSUL } suffix=LSNone;` and
`primary()` answers the suffix directly:

| Suffix | Type | `exprType` answer |
| --- | --- | --- |
| (none) | inferred from the slot | `tyIsInteger(want)` – unchanged |
| `u` | `u32` | `case Expr::LSU:  return Ty::U32;` |
| `l` | `i64` | `case Expr::LSL:  return Ty::I64;` |
| `ul` | `u64` | `case Expr::LSUL: return Ty::U64;` |

The suffix has a **ceiling**, enforced at parse time: `0xFFFFFFFFu` is the `u32`
max, `0x8000000000000000l` is the `i64` max, `0xFFFFFFFFFFFFFFFFul` is the `u64`
max. A value past the ceiling throws `"u32 literal out of range at "` /
`"i64 literal out of range at "`. An unsupported suffix (`ll`, `uu`, …) throws
`"invalid numeric suffix 'll'"`. This is what makes the u64/cast round's type
story complete: a literal's width stops being something only the destination
slot decides, and a `u32` value is read at 32 bits rather than widened into 64
and re-narrowed.

### 2.3 Digit separators and binary literals

A `_` between two digits is dropped from the value text at lex time — `1_000_000`,
`0xFF_FF` and `0b1111_1111_1111` are exactly `1000000`, `65535` and `4095`, and
a separator may appear in any base. A separator not flanked by two digits
(`1_`, `_1`, `1_0_`) is `"digit separator '_' must be between two digits in …"`.
A `0b` / `0B` prefix is recognized by the lexer, stripped by `unsignedLiteral`,
and the body is parsed **base 2** (`const bool bin = … (digits[1]=='b'||digits[1]=='B')`);
a bare `0b` with no digits is `"binary literal has no digits"`. Hex and binary
share the separator rule, so `0xDEAD_BEEF` and `0b1111_1111_1111` are both
legal and both unchanged in value.

### 2.4 The escape table fills out

`unescape` now handles `\' \a \b \f \v` plus the existing `\n \r \t \0 \\ \"`
and `\xHH` (two hex digits), so a string can name a quote (`"\'"`) and carry the
control codes the table used to refuse (`"\a\b\f\v"` decodes to `7, 8, 12, 11`).
Because the table is **shared** by the string and character literals, the two
kinds answer the same byte for the same escape — the string table and the char
table can no longer drift apart.

### 2.5 The bootstrap subset deliberately did not grow

A `Char` token is outside the subset `bootstrap/aster.ast` understands, so the
bootstrap lexer's string branch is followed by a hand-written rejection of
`'`: `"character literals are not in the bootstrap subset"`. The C twin
`tests/codegen-twin.c` carries the **same** rejection, so the differential suite
stays in agreement on subset programs — both refuse `'` — while the host
compiler accepts the full surface. The generator's `KEYWORDS` count and the
subset's token line are untouched; only `src/aster.cpp` grows. This is the same
"subset stays, twin synchronized by comment" contract Round A (`u64`) and Round
B (`switch`) held.

## 3. The defects the round found in itself

The round's own code went through several wrong compilations before the decode
was right, and the suite was written to keep each one from coming back:

- **The BEL escape was mis-decoded.** The first `unescape` table ranked `'\a'`
  as `'?'` (63) instead of `'\a'` (7), so the witness that reads it returned the
  wrong bit. The mutation layer re-writes `case 'a': return '\a';` to
  `case 'a': return '?';` and asserts the witness changes — the inversion can
  never return silently.
- **Binary decoding was coupled to the wrong flag.** The lexer computes an
  `isBin` flag beside `isHex`, but the *value* is decoded in `unsignedLiteral`,
  which keys on the prefix — not the flag. An early mutant flipped `isBin=true`
  into `isHex=true` and was a **no-op**: the witness still compiled and still
  returned 42, because nothing in the decode path reads `isBin`. The real rule is
  the `const bool bin = digits[0]=='0' && (digits[1]=='b'||digits[1]=='B')`
  line, and the mutant that sets `const bool bin=false;` makes `0b101010` fall
  through to the base-10 path and be **rejected** — so `must_reject` asserts the
  real compiler accepts it while the mutant refuses it.
- **The u32 suffix ceiling was dropped.** A mutant that deletes
  `if(n>0xffffffffULL)throw Error("u32 literal out of range at …")` from the `u`
  branch silently truncates a value past 2³² into the slot. The real compiler
  refuses `0x1_0000_0001u`; the mutant accepts it. `must_now_compile` asserts
  the mutant now accepts what the real compiler rejects — the ceiling is gone.

These are the system working as designed: the witnesses are pinned against the
hand-derived exit code, so a regression in the decode shows up as a wrong exit,
not as a compile error.

## 4. What the suite proves (`tests/literals-checks.sh`, [9/9])

The resident suite is nine layers, each guarding a different angle of the same
feature:

1. **Strict build** of the compiler (`-Wall -Wextra -pedantic -Werror`, `-O2`).
2. **Source guards** — 16 pins, each at the change it was made: the version
   constant `0.23.50-dev`, the `Char` token in `enum TK`, the `LitSuffix` state
   on `Num`, the `unescape` table and its extended escapes, the `Char`-token
   dispatch, the `isHex`/`isBin` flags, the digit-separator rule, the three
   suffix pins (`if(low=="u")…`, `else if(low=="l")…`, `else {…LSUL}`), the two
   range ceilings, and the three suffix type answers in `exprType`/`typeOf`.
3. **qemu behavioural matrix** — **20 cases**, each returning the value it is
   named for: every character literal and escape (`'A'`=65, `'\n'`=10, `'\''`=39,
   `'\a'`=7, `'\x41'`=65), character arithmetic (`'B'-'A'`=1, `'a'+1`=`'b'`,
   `'z'-'a'`=25), every suffix width (`0xFFFFFFFFu` zero-extends, `5l`=5, `-1l`
   is a negative `i64`, `0xFFFFFFFFFFFFFFFFul` is `u64` max), binary
   (`0b101010`=42, `0b1`=1, `0b1111_1111`=255), separators (`1_000_000`=1000000,
   `0xFF_FF`=65535, `0xDEAD_BEEF`=3735928559, `0b1111_1111_1111`=4095), and the
   extended-escape string (`"\a\b\f\v"` indexes 7,8,12,11).
4. **Differential** — Aster against the target C compiler (the shipped example
   plus `char + suffix + binary + separator` small program), where C needs
   C11's own literal rules and Aster matches them exactly; both exit the same
   code and `diff` byte-for-byte on the ELF.
5. **Rejection matrix** — **9 refusals**: bad suffixes (`ll`, `uu`), a char
   literal too long, an empty char literal, a separator with no digit, binary
   with no digits, hex with no digits, and a `u32`/`i64` suffix out of range.
6. **Coverage** — the behavioural layer is the coverage; it asserts at least 18
   cases (the round ships 20), so a hole in a guard is a hole here.
7. **Mutation** — three mutants, each removing exactly one rule (BEL mis-decoded,
   binary decode removed, u32 ceiling dropped); a witness must notice each.
8. **Byte-identity baseline** — the shared `example-hashes.txt` reproduces byte
   for byte; this round's `literals.ast` joins the filter (`§7`).
9. **End-to-end** — `examples/literals.ast` runs under qemu and returns **255**,
   the value its C twin `tests/literals-twin.c` returns.

## 5. Lessons the round recorded

- **A literal is a token, not an instruction.** None of the new surface moved
  the instruction stream of a program that does not use it — the `Char` token,
  the suffix state and the separator/binary lexer rules are all *parse-time*
  decoration. That is exactly why the byte baseline of every pre-existing example
  is unchanged (288 core rows byte-identical, `§7`).
- **The escape table belongs to one function, not two.** Routing both string and
  character literals through the single `unescape` means the table grew once and
  the two kinds answer the same byte — there is no second table to keep in sync,
  and the suite's BEL mutation guards the one place that matters.
- **Lexer flags lie; decode keys don't.** The `isBin` lexer flag was a tempting
  mutation target and a complete no-op, because the *value* is decided downstream
  by the prefix. The real rule is the `const bool bin = …` line in
  `unsignedLiteral`, and the mutant that flips *that* is the one `must_reject`
  catches. A mutation layer earns its keep only when the mutant actually removes
  the rule the witness tests.
- **The exit-code mask is a trap.** `qemu-aarch64` returns the guest's
  `_exit(status & 0xff)` verbatim, so every value in `0..255` is observable
  directly — but a harness that folds `>127` to `value-256` corrupts a genuine
  return such as `200` or `255`. The suite compares raw exit codes, and the
  differential compares Aster's exit against C's, both raw.

## 6. The twin: synchronized by comment

`bootstrap/aster.ast` (the C that bootstraps the compiler) and
`tests/codegen-twin.c` (the C that mirrors Aster's codegen) both reject
character literals in the bootstrap subset, with the same diagnostic:

- `'` → "character literals are not in the bootstrap subset"

Nothing in the bootstrap path learned to emit or consume a `Char` token, a suffix
state, or a binary/separator decode; the subset stayed exactly as Round B left
it, and the C twin carries the same rejection so the two stay in lock-step by
comment, not by shared code. The generator's `TOKENS` count moved (76→77) and the
host compiler accepts `Char`, but the subset's keyword line and token line are
untouched — the differential suite's "both refuse `'`" agreement holds.

## 7. Baseline

The round adds `examples/literals.ast` (three rows, one per build mode: `build-so`,
`build-elf`, `build-obj --pic`). `tests/rebuild-baseline-v0.23.50.sh` re-records
`tests/baseline/v0.23.5-dev/example-hashes.txt` from **336 to 339 rows**: the 288
core rows the v0.23.30 discipline fixed, plus the sixteen earlier rounds' three-row
families and this round's three. The example imports nothing, so all three of its
rows are real hashes (a `FAILED` row would itself be a regression, and the script
asserts there are zero).

**Seventeen filtering suites** now exclude `^literals\.` alongside the sixteen
earlier rounds' families, so the pre-existing count stays 288 on both sides:

- `literals-checks.sh` (this round)
- `sizeof-len-checks.sh`, `array-address-checks.sh`, `integer-cast-checks.sh`,
  `multi-dim-array-checks.sh`, `array-elem-types-checks.sh`, `precedence-checks.sh`,
  `struct-array-field-checks.sh` — each gains the `^literals\.` exclusion.
- `condition-checks.sh`, `null-ptr-checks.sh`, `struct-checks.sh`, `switch-checks.sh`
  do a full `diff` of the baseline and therefore need no exclusion; they pass once
  the baseline includes `literals.ast`.

The `literals-checks.sh` version guard (`#define ASTER_VERSION_STRING
"0.23.50-dev"`) is the constant itself, so a stale compiler (or a forgotten
bump) fails loudly at layer [2/9].

## 8. Reproduction

```sh
# 0) the resident suite (builds everything from source, ~2 min)
./tests/literals-checks.sh

# 1) the shipped example against its C twin
aster build-elf examples/literals.ast -o lit && qemu-aarch64 ./lit; echo $?   # 255
aarch64-linux-gnu-gcc -std=c11 -O2 tests/literals-twin.c -o litt
qemu-aarch64 ./litt; echo $?                                               # 255

# 2) the byte-identity baseline re-record (one-shot; asserts before it writes)
./tests/rebuild-baseline-v0.23.50.sh

# 3) the full CI (literals-checks.sh is now registered in the suite list)
sh tests/ci.sh
```

## 9. Files

- `src/aster.cpp` — `TK::Char`, `Expr::LitSuffix` + `suffix`, the shared
  `unescape` (extended escapes), the `Char`-token dispatch, the `isHex`/`isBin`
  flags, the digit-separator rule, binary/hex prefix detection in
  `unsignedLiteral`, the three suffix pins and type answers in `primary()` /
  `exprType` / `typeOf`, and the two suffix range ceilings; version `0.23.50-dev`.
- `bootstrap/gen_lexer_names.py` — `TOKENS` 76→77 (`Char` added), `KEYWORDS`
  stays 26, `check_list()` asserts `TOKEN_COUNT == 77`; regenerates
  `bootstrap/aster.ast` and `tests/lexer_names.h`.
- `bootstrap/aster.ast`, `tests/codegen-twin.c` — one bootstrap-subset rejection
  each (`'` → "character literals are not in the bootstrap subset"), comments
  synchronized.
- `examples/literals.ast`, `tests/literals-twin.c`, `tests/literals-checks.sh` —
  the example, its twin, and the nine-layer suite.
- `tests/rebuild-baseline-v0.23.50.sh` — baseline re-record (336→339).
- `tests/ci.sh` — `literals-checks.sh` registered.
