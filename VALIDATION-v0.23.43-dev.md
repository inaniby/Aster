# Validation Report — v0.23.43-dev

**Feature: the first stage of the bootstrap compiler itself — the lexer — and,
like M2, a round with no compiler change at all.** `SELFHOSTING-PLAN.md` M3
begins where the plan says it should: with the stage that needs no heap, no
AST and no linker. `bootstrap/aster.ast` is written in Aster, built by the
host compiler and linked against the M2 library: one Aster source in on
**stdin**, the token stream out on **stdout**, one token per line — 72 kinds
numbered exactly as `enum class TK`, the 22 keywords, and nine diagnostics
that are the host compiler's own words and positions. The only edit to
`src/aster.cpp` is the version constant. The round's substance is process as
much as code: the contract was frozen *before* the implementation
(`bootstrap/LEXER-SPEC.md`, 13 sections), the kind names and keywords are
**data generated from one list** rather than transcribed twice, and the
differential oracle — an independent C implementation of the same spec —
matched byte for byte everywhere it was pointed, including the stage reading
**its own source**.

```
// bootstrap/aster.ast — the scanner core (excerpt). The character of the
// code: ASCII literals because the language has no character type, peek()/
// take() because the source buffer has no sentinel byte, and parallel
// arrays because Aster has no structs yet.

fn scan_one() -> i32 {
    let l: i32 = line;
    let c: i32 = col;
    let ch: i32 = peek();
    // --- identifier or keyword ---
    if (is_alpha(ch) == 1 || ch == 95) {
        let start: i32 = pos;
        while (is_alnum(peek()) == 1 || peek() == 95) { take(); }
        let length: i32 = pos - start;
        return push(keyword_kind(srcbuf + start, length), start, length, l, c);
    }
        // --- number (decimal, or 0x/0X hexadecimal) ---
        if (is_digit(ch) == 1) {
            let start: i32 = pos;
            while (is_digit(peek()) == 1) { take(); }
            if (pos - start == 1 && load_u8(srcbuf + start) == 48) {
                if (peek() == 120 || peek() == 88) { take();
                    if (is_xdigit(peek()) == 0) {
                        return die_at("hexadecimal literal has no digits", l, c);
                    }
                    while (is_xdigit(peek()) == 1) { take(); }
                }
            }
            return push(K_Number, start, pos - start, l, c);
        }
        // --- string literal: decode into strpool ---
        if (ch == 34) {
            let vstart: i32 = spool;
            take();
            let closed: i32 = 0;
            while (peek() != 0) {
                let q: i32 = take();
                if (q == 34) { closed = 1; break; }
                if (q == 10 || q == 13) {
                    return die_at("newline in string literal", l, c);
                }
                if (q == 92) {
                    let e: i32 = take();
                    if (e == 0) { break; }
                    if (e == 110) { store_u8(strpool + spool, 10); spool = spool + 1; }
                    else if (e == 114) { store_u8(strpool + spool, 13); spool = spool + 1; }
                    else if (e == 116) { store_u8(strpool + spool, 9);  spool = spool + 1; }
                    else if (e == 48)  { store_u8(strpool + spool, 0);  spool = spool + 1; }
                    else if (e == 92)  { store_u8(strpool + spool, 92); spool = spool + 1; }
                    else if (e == 34)  { store_u8(strpool + spool, 34); spool = spool + 1; }
                    else { return die_at("unsupported string escape", line, col); }
                } else {
                    store_u8(strpool + spool, q);
                    spool = spool + 1;
                }
                if (spool >= 1048576) { return die_at("string pool exhausted", l, c); }
            }
            if (closed == 0) { return die_at("unterminated string literal", l, c); }
            return push(K_String, vstart, spool - vstart, l, c);
        }
        return 0;
}
```

## 1. Why this round exists

M3 is the bootstrap compiler itself, and the plan is explicit that it starts
with the stage that needs nothing new from the toolchain: no allocator, no
node types, no symbol table, no ELF writer. The lexer reads bytes and writes
bytes. But "simple stage" is not the same as "simple contract" — a lexer is
where every later stage's position semantics, every diagnostic's wording and
every token's spelling are decided, and a mistake here is inherited by the
parser and every test written against it. So the round front-loads the
decisions into a frozen document and spends its effort on *proof* rather than
invention: the spec (`bootstrap/LEXER-SPEC.md`) was written and reviewed
before the code, the name tables are generated from a single list that also
cross-checks the host compiler, and an independent C implementation of the
same spec serves as the differential oracle — the discipline that caught two
real bugs in M2, now pointed at the bootstrap compiler itself.

## 2. The contract frozen before the code

`bootstrap/LEXER-SPEC.md` is 13 sections, and every one of them exists
because a decision had to be made:

- **72 token kinds, numbered as `enum class TK`.** The kinds are the host
  compiler's `enum class TK` in declaration order, so the stage's output is
  directly comparable with the host's own token stream — the property that
  makes self-lexing meaningful.
- **The C-locale character classes**, spelled as byte ranges rather than
  `isalpha`-style functions (which take `int` and have locale and EOF
  edge cases a bootstrap has no reason to inherit).
- **Position semantics**: 1-based line and column, a tab advancing one
  column, a token's position taken *before* its first byte, and the `End`
  token's position after all trailing whitespace and comments.
- **The lexing rules**: `//` and non-nesting `/* */` comments (with `/*/`
  deliberately unterminated), identifiers `[A-Za-z_][A-Za-z0-9_]*`, decimal
  and `0x`/`0X` hexadecimal numbers with the prefix kept in the token text,
  strings with exactly six escapes (`\n \r \t \0 \\ \"`) decoded into a
  string pool, and maximal-munch operators including the three-byte-lookahead
  `<<=`, `>>=` and `->`.
- **The dump format**: `<KindName> <line> <col>[ <text>]` per line, with
  `String` tokens printing their *decoded, re-escaped* value — so the dump is
  a readable witness of the decode, not a copy of the source bytes.
- **Nine diagnostics, byte for byte** (spec §10): E1–E7 are the host
  compiler's own messages and positions; E8 (source over 1 MiB) and E9 (over
  65536 tokens) exist only on the bootstrap side.
- **Two phases, one output buffer** (spec §8): tokens are collected in
  memory and the dump is written only after the scan succeeds, so an error
  leaves stdout empty — the property the host has by construction and the
  bootstrap has by discipline.

## 3. The names are data, not code

72 kind names and 22 keywords appear in three places — the Aster stage's
constants, its packed name table and keyword chain, and the C twin's `enum`.
Transcribing them by hand is how the two implementations drift apart
silently. `bootstrap/gen_lexer_names.py` is therefore the single source of
truth: it emits the Aster side's `K_*` constants, an 864-byte packed name
table, the `ident_is` helper and the `keyword_kind` chain; it emits the twin's
`tests/lexer_names.h`; and it **cross-checks itself against
`src/aster.cpp`**, refusing to run if the host's `enum class TK` has drifted.
A `--check` mode verifies the on-disk files are what the generator would
produce, and that check is a CI step — so stale tables fail the freshness
gate, not the differential three sections later.

## 4. Three language limits shaped the design

None of these were discovered late; each is measured, documented in spec §3
and §11, and carried by a test:

- **An array may not exceed 1 MiB.** The source buffer is a fixed global
  array, so it has **no sentinel byte** — `peek()` answers end-of-input by
  comparing the cursor against the length. The consequence is a *feature*:
  an embedded NUL byte ends the scan exactly as the host compiler's `peek()`
  does, and the two implementations agree on it without special-casing.
- **The same 1 MiB cap forced a 65536-token ceiling** with its own
  diagnostic (E9), the `End` token excluded from the count. This is the
  bootstrap-only divergence the spec records in §11 — the host grows arrays
  on the heap, the bootstrap cannot yet. Both edges are pinned by the suite:
  exactly 65536 tokens are accepted (65537 dump lines, both sides byte-
  identical), 65537 is refused with E9 on both sides.
- **`len` is a builtin, not a usable name.** The keyword matcher's parameter
  wanted to be called `len`; the language reserves it (spec §13 lists every
  reserved name the bootstrap source must avoid). The parameter is `n`.

## 5. The oracle is independent by construction

`tests/lexer-twin.c` implements the same spec in C, and the independence is
deliberate and structural — the point of a differential is that a shared
misreading of the spec shows up as *agreement*, so anything that can be made
different is made different:

| Aspect | `bootstrap/aster.ast` | `tests/lexer-twin.c` |
| --- | --- | --- |
| token storage | five parallel `i32` arrays | one `struct tok` array |
| input | `read(2)` intrinsic | stdio `fread`/`fgetc` |
| character classes | byte-range comparisons | `<ctype.h>` |
| dispatch | if-chain | `switch` (30 operator arms) |
| number rendering | library `utoa` | `snprintf("%d")` |
| dump | built in a buffer, one `write` | built in a buffer, one `fwrite` |

The dump buffer is 4 MiB with a **proven** bound, not a guessed one: each
token frame is at most 28 bytes, `Ident`/`Number` text bytes correspond
one-to-one with source bytes, and a `String` escape maps two source bytes to
two output bytes — so the worst case is under 2,818,075 bytes against a
3 MiB budget, and the overflow guard (exit 2) is unreachable. The proof is
in the spec so the bound is reviewable rather than trusted.

## 6. What the differential proved

Every comparison below ran both implementations and compared bytes:

- **The frozen §9 example**, pinned absolutely — expected bytes recorded in
  the suite, Aster side and twin side each required to match them.
- **Nine diagnostics**, each with exact message, position, exit status 1 and
  empty stdout — E1–E7 on seven positioned errors, E8 and E9 at the two
  bootstrap guards.
- **A 32-case boundary corpus**, with the operator table (33 tokens) and the
  keyword table (22 keywords) pinned byte-exact. Among the cases: the empty
  escape `\q` reporting at the column *after* the escape byte (1:4), a lone
  `\` at end of input answering E5, `ab\0cd` lexing as `Ident ab` +
  `End 1 3` (the embedded NUL ending the scan), and `\xc3` refused as a
  non-ASCII byte (E6) rather than silently accepted.
- **The limit edges**: exactly 1 MiB accepted (2 lines, 1,048,601 bytes of
  dump, both sides identical), one byte over refused with E8, 1 MiB of
  newlines putting `End` at 1048577:1, 1 MiB of spaces plus an `x` reporting
  column 1048576.
- **500 randomized inputs** — zero divergence.
- **The whole repository, 203 files**: 117 lex clean, 86 fail with the same
  error bytes on both sides. Among the clean set is **the stage reading its
  own source** — `bootstrap/aster.ast`, 4716 token lines pinned — and the M2
  library's (1176, pinned).

## 7. Coverage: one resident suite, `tests/lexer-checks.sh` [11/11]

Eleven sections, **185 PASS lines (183 checks plus two roll-up lines), zero
FAIL**, registered in `tests/ci.sh`:

1. **Strict build** of the host compiler (`-Wall -Wextra -pedantic -Werror`).
2. **Runner located** — `qemu-aarch64` probed; a missing runner is a clean
   SKIP, as every e2e suite in this project.
3. **Generator freshness** — `gen_lexer_names.py --check` refuses stale
   tables.
4. **The delivery chain**: `build-obj bootstrap/aster.ast` (4038
   instructions, 30 functions, 129 globals) + `build-obj
   stdlib/aster_std.ast` + `link-obj` (main object first — 825 relocations,
   239 `CALL26`, into one `ET_EXEC`), then the twin built strictly
   (`-std=c11 -O2 -Wall -Wextra -Werror -fwrapv -fno-builtin`).
5. **Zero-dependency, measured**: the linked binary carries exactly one UND
   symbol — the ELF null. (`boot.o` itself shows four: the null,
   `__aster_init_next`, `strlen` and `utoa`; the last two are precisely the
   M2 library's, which `std.o` supplies.)
6. **The spec pinned absolutely**: §9's frozen example, E1–E7 with exact
   positions, the End-token/tab/embedded-NUL/comment position semantics.
7. **The boundary corpus, differentially** (32 cases), with the operator and
   keyword tables pinned byte-exact.
8. **Self-lexing**: 114 sources — the stage, the library, the 110 examples,
   the spec and the generator — with the two self-hosting token counts
   pinned.
9. **The two guards** at the edge and one past it (E8, E9, 1 MiB, 65536).
10. **Ten mutation probes**, §8 below.
11. Registered in the full CI gate.

## 8. The first mutation probes against the bootstrap compiler

M2's suite was the project's first to patch *library source*; this round's
ten probes patch **`bootstrap/aster.ast`** — the first time the suite breaks
the bootstrap compiler on purpose. The discipline is unchanged and earned
its keep twice during construction:

- **A probe that cannot fail is decoration.** M2 shipped one blind on the
  first attempt (a hash-mask mutation that left every demo key unshifted);
  the lesson generalises, so every probe here is written against a *measured*
  failure mode, and one of them (`m_e9_off`, doubling the token cap) was
  first *measured* to diverge safely before being admitted — the uncapped
  run writes one token past the parallel arrays' end, which lands inside the
  same object's `.bss` and diverges (rc=0, 65538 dump lines) rather than
  crashing. A probe may be wild; it may not be blind.
- **An anchor that misses is a FAIL, not a skip.** `m_strpool_raw` missed on
  its first attempt because its anchor assumed an `else if` where the source
  has a bare `if` (the first escape branch). The probe suite reported the
  miss instead of quietly passing; the anchor was corrected to the actual
  source text.

The ten: the tab class (`m_tab`), the `true` keyword (`m_kw_true`), the
empty-hex diagnostic (`m_hex_e2`), the escape-error position (`m_esc_pos`),
the token cap (`m_e9_off`), the source cap (`m_e8_off`), the `\n` decode
(`m_strpool_raw`), the End-token column (`m_end_pos`), the unterminated
block comment (`m_e1_off`), and identifier text in the dump
(`m_ident_text`). Each is asserted to apply, to still build and link (a
build failure passes the probe), and to diverge from the twin on stdout or
exit status. All ten diverge.

## 9. Nothing that exists moves

No codegen path is touched: the only source delta is the version constant,
so every pre-existing output is byte-identical by construction — and no new
example was added this round, so the A/B baseline is unchanged at **330
lines, byte for byte** — verified by `tests/rebuild-baseline-v0.23.43.sh`:
330 rows in, 330 out, zero diff, and the CI's baseline-reading suites
(`condition`, `null-ptr`, `precedence`, `sizeof-len`, `struct`,
`struct-array-field`, `array-address`, `array-elem-types`, `multi-dim-array`,
`narrow-value-coverage`) all passed against it. The new files are `bootstrap/aster.ast`, `bootstrap/LEXER-SPEC.md`,
`bootstrap/gen_lexer_names.py`, `tests/lexer_names.h`,
`tests/lexer-twin.c` and `tests/lexer-checks.sh`, plus the suite
registration. No existing test, example or documented behaviour is edited.

## 10. Deliberately not included

- **No parser, no AST, no symbol table** — M3b's work, and the reason this
  round could ship with no compiler change.
- **No allocator.** The stage runs on fixed global arrays sized by the two
  documented caps; the M1 heap and M2's routines are for the stages that
  need to grow.
- **The two caps are bootstrap-only, and documented as such.** The host
  compiler has neither a 1 MiB source limit nor a token ceiling; the spec's
  §11 records them as deliberate divergences with their motivation, not as
  language semantics.
- **No growth of the keyword or kind tables at run time.** They are
  generated data; adding a kind is a generator edit plus a twin rebuild,
  enforced by the freshness check.

## 11. What this closes, and what it opens

**Closes M3a**: the lexer stage exists, its contract is frozen in 13
sections, its names are generated from one cross-checked list, and its
behaviour is pinned by a differential oracle and a resident suite with ten
source-level mutation probes — with the delivery chain and zero-dependency
discipline inherited from M0–M2 and re-measured here.

**Opens M3b**: the parser, which will consume exactly the token stream this
round emits — the same kinds, the same positions, the same diagnostics — and
which is where the M1 heap (node arrays), the M2 hash table (symbol and
label tables) and the M2 text/number routines (identifier interning,
diagnostic formatting) stop being waiting tools and start being load-bearing.
The plan's own shape — each stage needs no compiler change, only the previous
stage's output as input — held for the first time this round, on the stage
everything downstream reads.
