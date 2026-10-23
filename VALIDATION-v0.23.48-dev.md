# Validation Report — v0.23.48-dev

**Feature: language completion, Round A — the `u64` type and the `T(x)` cast.**
This is the first of the three host-language rounds the plan froze after the
self-hosting arc closed (Round B `switch` + labeled `break`/`continue`,
Round C character literals and numeric sugar — both still ahead). The language
had exactly two shape gaps left: no 64-bit **unsigned** type, and no explicit
conversion of any kind. Both close here, in the host compiler only —
`bootstrap/aster.ast`'s subset deliberately did not grow, and its C twin was
synchronized with **comments**, not code (§6). The round found one real defect
in its own new code (§3), and the suite found two bugs in its own witnesses
(§5.2, §5.3) — which is the system working as designed, but only because the
witnesses were pinned against an *independent* oracle (the target C compiler,
or arithmetic redone from scratch) rather than against the compiler itself.

```
// the shipped example, under qemu-aarch64 (host = the target C compiler):
//   aster build-elf examples/integer_cast.ast -o ic && ./ic ; echo $?
//   255
//   aarch64-linux-gnu-gcc -std=c11 -O2 tests/integer_cast-twin.c -o ict
//   qemu-aarch64 ./ict ; echo $?
//   255
```

## 1. Why this round exists

Since v0.23.2-dev the lattice carried `i64` beside `u8`/`u16`/`u32`, so every
width had an unsigned reading except the wide one — a program that needed a
value past 2^63−1 (a hash, a byte count, a raw kernel address) had nowhere to
put it, and a literal past 2^63−1 was a **parse error**, before any context
could say what it was for. And there was no way to ask for a truncation at
all: `u8(300)` had to be written as an implicit narrowing that the argument
paths refused, so the only legal spelling was to narrow by hand (`300 & 255`),
which is a different number. The plan's three language rounds close this
surface; Round A is the type and the conversion.

## 2. What shipped

### 2.1 `u64`, the eighth integer type

`enum Kind { I32, U32, U8, U16, I64, U64, Ptr, Bool, Struct }` — `U64` sits
beside `I64`, and everything that keys on width treats it as `i64`'s equal
(`tySize`, `tyIs64`, the X-register staging, the 8-byte AAPCS64 ABI, the
`MOVZ`+`MOVK` literal materialisation, DWARF `DW_ATE_unsigned` size 8). What
changes is the reading: `tyIsUnsigned` learns `U64`, so comparisons take
`LO/LS/HI/HS` and division is `UDIV`. `ptr<u64>` needed **no new code** — the
existing `tyPtrToElem` gives it the 8-byte stride for free, and two of the
suite's 32 behavioural cases exist to keep it that way.

### 2.2 `promoteInt` answers `U64` first

The rule is tested *before* the `tyIs64` branch:

```cpp
if(a==Ty::U64||b==Ty::U64)return Ty::U64;      // v0.23.48-dev: u64 outranks i64
if(tyIs64(a)||tyIs64(b))return Ty::I64;
```

Were the order reversed, `u64 + i64` would answer `I64` and a `u64` comparison
would be emitted with the **signed** condition codes — silently wrong for
every value past 2^63−1, which is exactly the range `u64` exists for. This is
the rule the mutation layer could not see at first (§5.1).

### 2.3 The cast `T(x)`

Function-shaped at the primary level, the spelling `sizeof` and `len` already
use. The type keywords are reserved words, so recognition is **zero
lookahead**: an integer keyword followed by `(` can be nothing else, and
`ptr`/`bool` are deliberately *not* spellings — `ptr(x)` is
`expected expression` exactly as before, not a new error path. Six spellings
(`i32 i64 u8 u16 u32 u64`), integer operands only, sema's refusal naming the
source type (`cannot cast ptr to u8`, `cannot cast bool to i32`). A narrowing
answers the target width's low bits (`u8(300)` = 44, `u16(70000)` = 4464); a
widening extends by the **source** type's signedness.

### 2.4 The literal ceiling moved out of the parser

`primary()`'s guard moves from `0x7fffffffffffffffULL` to
`0xffffffffffffffffULL`, and the range check that used to live there now lives
at the declaration site, in `initializerFits` — the one place that knows which
slot a value was meant for:

```
let x: u64 = 18446744073709551615;   // accepted — 2^64-1
let x: i64 = 9223372036854775808;    // local initializer does not fit in i64: x (…)
let x: u64 = 18446744073709551616;   // integer literal is too large at L:C (past 2^64-1)
```

Two deliberate readings are pinned by the suite and recorded here so they are
decisions, not accidents:

- **The message prints the folded `int64` view.** `let x: i64 =
  0xFFFFFFFFFFFFFFFF;` reports `x (-1)`, because the value the slot *would*
  hold is the folded −1, not the 2^64−1 that was typed. The syntax-relief
  suite's v0.23.48-dev note names this reading explicitly ("the folded (-1)
  view, at the let statement rather than the literal token").
- **A `u64` slot takes a negative literal** (`let x: u64 = 0 - 1;` → 2^64−1):
  the sign-extended view of a value near 2^64 is that value, never a
  truncation, so the slot accepts it as it stands (`case Ty::U64: return
  true;`).

## 3. The defect the round found in itself

The first draft of the `Cast` arm answered at the **source** width, violating
an invariant every other producer in codegen already followed — *a producer
answers at the width the consumer asked for*: a `Var` load `SXTW`s an `i32`
into an `i64` context, a `BinOp` reruns itself at 64 bits (`wideOp`), a
literal materialises at full width. The consequence:

```
i64(i32(0 - 1))        // answered 4294967295, not -1
```

The inner cast produced a 32-bit register whose upper half was **zeroed** —
the correct `u32` reading of those bits, but not the `i32` one — and the
outer cast, wanting 64 bits, read it as unsigned. The fix is one instruction
at the end of the arm:

```cpp
// Answer at the width the consumer asked for, the way every other
// producer does: … a cast that stops at 32 bits leaves the upper half
// zeroed — the correct u32/u16/u8 reading of those bits, but not the
// i32 one, so an i32 cast consumed at 64 bits extends here.
if(tyIs64(want)&&e.ty==Ty::I32&&!(wf>wt))
    emit(0x93407c00u|(uint32_t(a)<<5)|uint32_t(a));   // SXTW Xa, Wa
```

The guard `!(wf>wt)` matters: a genuine narrowing (`i64` → `i32`) must still
answer in a W register, and the normalisation block above the fix already
handled the reverse case. The example's first draft **hid this bug twice**
behind the qemu exit-code mask (§5.3), which is why the shipped example is
exactly 8 bits wide.

## 4. What the suite proves (resident, `tests/integer-cast-checks.sh` [10/10])

| Layer | Result |
| --- | --- |
| 1/10 strict host build (`-Wall -Wextra -pedantic -Werror`) | PASS |
| 2/10 source guards — the u64 grid and the cast, pinned in the source | **25 guards**, PASS |
| 3/10 qemu behavioural matrix | **32/32** (every cast direction × every scope: locals, globals, parameters, arrays, struct fields, `ptr<u64>` index + parameter, unsigned compare/`UDIV`/promotion) |
| 4/10 differential vs the target C compiler | **2/2** — the two u64-only boundary literals (exit 33) and the shipped example vs its twin (exit 255); no hand-computed expectation |
| 5/10 rejection matrix | **13/13** refused (C-style `(u8)x`, missing/unclosed paren, `ptr(`/`bool(`, ptr/bool/struct operands, the narrow-slot and narrow-parameter discipline this round did *not* loosen, a `u64` literal into a `u8`, an i64 slot, a literal past 2^64−1) |
| 6/10 cascade — the migrated i64-slot diagnostics | **3/3** still refuse at the declaration site, and the three suites that own them (`wide-int-checks.sh`, `wide-int-literal-checks.sh`, `syntax-relief-checks.sh`) are grep-pinned so the message cannot drift |
| 7/10 coverage floor | **32 ≥ 28** behavioural cases |
| 8/10 mutation layer | **9/9 caught** (below) |
| 9/10 byte-identity baseline | **288 pre-existing rows byte-identical**, 3 new (`integer_cast`) rows recorded |
| 10/10 the shipped example, end to end | exit **255** under qemu, equal to its C twin |

The nine mutants, each losing exactly one rule, each noticed:

| # | Mutation | Caught by |
| --- | --- | --- |
| m1 | the normalisation block `if(wf>wt){` → `if(false){` | `u16(70000)` = 4464 |
| m2 | the fix's `SXTW` encoding → `UXTW` | `i32` of an `i64` top bit |
| m3 | the fix's guard → `if(false)` (this round's defect re-introduced) | `i64(i32(0-1))` = −1 |
| m4 | `promoteInt`'s `u64` line deleted | the unsigned compare of a `u64` **sum** (§5.1) |
| m5 | `initializerFits`' i64 arm deleted | an i64 slot above 2^63−1 |
| m6 | `(to==Ty::U64&&from==Ty::I64)` deleted | an `i64` into a `u64` parameter |
| m7 | the operand generated at the *source* width again | `u64(i32(0-1))` = 2^64−1 |
| m8 | the `UXTH` arm kept, the rest of the block dropped | `u16(70000)` still truncates |
| m9 | the literal guard back to the `i64` ceiling | a `u64`-only literal — the new `must_reject` helper: the true compiler **accepts**, the mutant must **refuse** |

## 5. Three lessons the round recorded

### 5.1 The `promoteInt` mutant shipped blind

The first `m4` witness was `let x: u64 = 9223372036854775808; if (x >
9223372036854775807) { return 9; }` — and it passed against the **mutant**,
because a comparison's signedness is taken from its **operand** types
(`genBool`'s `tyIsUnsigned(ta)||tyIsUnsigned(tb)`), not from `promoteInt`'s
answer; the mutant still compared `x` unsigned and still returned 9. The
witness had to carry `promoteInt`'s answer *as a value*: the fix re-aims it at
a **sum** — `if (x + 0 > 9223372036854775807)` — whose type *is* `promoteInt`'s
answer (without the rule the sum is `i64`, the comparison is signed, 2^63 is
negative, and the case fails). A mutant layer is only as good as its
witnesses' type provenance: "the rule is missing but the observation still
holds" is the failure mode, and it is invisible until someone asks *which*
expression's type the rule decides.

### 5.2 The `UDIV` witness was the bug, not the compiler

The witness `top / 1000000000000 == 18446744073` failed. Re-deriving in
Python: `(2^64−1) / 10^12` = **18,446,744** — the hand-computed expectation
was wrong by a factor of 1000. The disassembly confirmed `UDIV` was emitted
correctly. The lesson generalises: for a wide division, the expectation is
computed by the *test author*, and the author is the component with no
oracle. Example, twin and matrix were all corrected to the same re-derived
value.

### 5.3 The 12-bit answer, and the exit-code mask

The example's first two drafts answered **4095** (12 bits) — and 4095 & 0xFF
is 255, so every run "passed" while eleven of the twelve bits were invisible:
qemu's exit code is masked to 8 bits, and the suite's `check()` normalises
anything above 127 to negative, so a witness must be **< 128** and an
example's total weight must be **exactly 8 bits** or the high bits are masked
away. The shipped example is eight `if`s with weights 1,2,4,8,16,32,64,128
and `return r;` = 255, and the property was verified by deletion: removing
any one group's bit drops the exit to exactly 255−weight, 8/8. This is also
what let the §3 defect hide — a 12-bit answer loses only its high bits, and
the low ones agreed.

## 6. The twin: synchronized by comment

`bootstrap/aster.ast`'s subset did **not** grow a `u64` slot or a cast — a
bootstrap stage that parses the compiler's own source needs neither, and the
round is a host-language round by the plan's own discipline (one coherent
theme per version). `tests/codegen-twin.c` was synchronized accordingly, with
comments rather than code:

- **`u64` and `T(x)` are refused**, exactly as the bootstrap's `primary`
  path refuses them: both spellings start with a type keyword where an
  expression is expected, so the existing `TK_U64`/`bad_type_spelling`
  refusals cover them — the comment says so, so a future round that grows the
  subset knows this is the seam.
- **`convert_num`'s i64-max saturation stays.** The host's literal ceiling
  moved to 2^64−1; the bootstrap's cannot follow, because the subset has no
  `u64` slot to put a wider value in — its ceiling is `i64` **by
  construction**. The saturation point now carries a v0.23.48-dev comment
  pinning the decision ("The saturation below is that ceiling, not a gap to
  close"), so a future round does not "fix" it by accident. The corpus's
  largest literal is 2^63−1, so host, twin and bootstrap have nothing to
  disagree about.

`tests/codegen-checks.sh` re-ran green after the synchronization: 115
programs, 48 byte-identical on accept, 67 both rejected, 0 divergence, 7/7
probes still diverge.

## 7. Baseline

`tests/rebuild-baseline-v0.23.48.sh` asserts the **288** pre-existing rows
reproduce byte for byte (fifteen families filtered — the fourteen earlier
rounds' examples plus this round's own), asserts `integer_cast.ast` records
three rows **none of them FAILED** (it imports nothing, so a FAILED row would
mean the round broke its own demo), and then writes the new baseline:
**330 → 333 lines**. Unlike `arena`'s and `stdlib_demo`'s rows, which are
FAILED standalone by construction (they need another object linked in),
`integer_cast` stays in the comparison for every future round.

### The six filtering suites

A re-recorded baseline is not the whole cost. Every resident suite that
compares the baseline through a family filter must learn the new family or
its hard-coded pre-existing count drifts: six suites filter
(`array-address`, `array-elem-types`, `multi-dim-array`, `precedence`,
`sizeof-len`, `struct-array-field`), and each gained `-e '^integer_cast\.'`
plus a lineage comment while keeping its 288 assertion. Three suites
(`condition-checks.sh`, `null-ptr-checks.sh`, `struct-checks.sh`) diff the
whole file unfiltered, so the three new rows — identical on both sides —
needed no change. The first full CI run after the re-record failed on
exactly this point (`FAIL: expected 288 pre-existing baseline rows, found
291`), the same drift every round's lineage comment anticipates; the six
suites were fixed and re-run green (9/9 layers each) before the full CI was
repeated.

The same run caught four more downstream pins the round's source edits had
moved. Three suites (`sema-checks.sh`, `struct-checks.sh`,
`wide-int-checks.sh`) each pinned the whole `Ty::Kind` member list, and U64's
insertion broke all three at once; they now pin the head and the tail — the
discipline `callback-table-checks.sh` and `sizeof-len-checks.sh` already use
for the expression kinds. `wide-int-literal-checks.sh` counts the SXTW sites
in the source, and the cast added two (the narrowing block's i32 form and the
consumer-width extension), so the count moved 11 → 13.

## 8. Reproduction

```sh
# 0) the resident suite (builds everything from source, ~2 min)
sh tests/integer-cast-checks.sh         # === integer-cast checks: ALL PASSED ===

# 1) the shipped example against its C twin
g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o aster
./aster build-elf examples/integer_cast.ast -o ic
qemu-aarch64 ./ic; echo $?               # 255
aarch64-linux-gnu-gcc -std=c11 -O2 tests/integer_cast-twin.c -o ict
qemu-aarch64 ./ict; echo $?              # 255

# 2) the defect of §3 — the sign must survive a 64-bit reading of a 32-bit cast
printf 'fn main() -> i32 { if (i64(i32(0 - 1)) == 0 - 1) { return 7; } return 0; }\n' > d.ast
./aster build-elf d.ast -o d && qemu-aarch64 ./d; echo $?   # 7 (the pre-fix build answered 0)
# …and the negative control: a genuine narrowing still answers in W
printf 'fn main() -> i32 { if (u8(300) == 44) { return 9; } return 0; }\n' > d2.ast
./aster build-elf d2.ast -o d2 && qemu-aarch64 ./d2; echo $? # 9

# 3) the baseline re-record (one-shot; asserts before it writes)
sh tests/rebuild-baseline-v0.23.48.sh

# 4) the full CI
sh tests/ci.sh
```

## 9. Files

- `src/aster.cpp` — `Ty::U64` in the lattice (12 sites: `tySize` ×2,
  `tyIs64`, `tyIsInteger`, `tyIsUnsigned`, `tyName`, the DWARF type entry, …),
  the `u64` keyword in the lexer chain and `parseType`, the cast's parse arm
  (`Expr::Cast` at the primary level), the `Cast` arm in `gen` with the §3
  fix, `promoteInt`'s `u64`-first rule, `tyAssignable`'s `i64`→`u64` rule,
  `initializerFits`' `i64`/`u64` arms, sema's `Cast` type rule, and the moved
  literal guard.
- `examples/integer_cast.ast` — the shipped example: eight one-bit groups,
  exit 255.
- `tests/integer_cast-twin.c` — the from-specification C twin.
- `tests/integer-cast-checks.sh` — the resident suite [10/10].
- `tests/rebuild-baseline-v0.23.48.sh` — the one-shot baseline re-record.
- `tests/codegen-twin.c` — the comment-level synchronization (§6).
- `tests/ci.sh` — `integer-cast-checks.sh` registered.
- `tests/array-address-checks.sh`, `tests/array-elem-types-checks.sh`,
  `tests/multi-dim-array-checks.sh`, `tests/precedence-checks.sh`,
  `tests/sizeof-len-checks.sh`, `tests/struct-array-field-checks.sh` — the
  six baseline-filtering suites: `integer_cast` joins the filter and the
  pre-existing count stays 288 (§7).
- `tests/callback-table-checks.sh` — the `Expr::FieldCall } k;` pin became
  `FieldCall,` when `Cast` was appended to the enum's tail; pinned without
  the tail so a future kind cannot move it again.
- `tests/struct-checks.sh` — the expected type list now names `u64`, and the
  `Ty::Kind` pin is head-and-tail (§7).
- `tests/sema-checks.sh`, `tests/wide-int-checks.sh` — the same `Ty::Kind`
  pin, head-and-tail (§7).
- `tests/wide-int-literal-checks.sh` — the SXTW site count, 11 → 13 with the
  cast's two (§7).
- `docs/language-spec.md`, `docs/language-reference.md` — `u64` and the cast
  in the grammar, types, precedence, limits and error tables (plus the
  reserved-word count corrected from 21 to the lexer's actual 23).
- `README.md`, `VERSION_HISTORY.md`, `FEATURE_STATUS.md`, `ROADMAP.md` —
  the round's record, and Round B/C carried in the roadmap as planned.
