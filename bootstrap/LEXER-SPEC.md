# M3a Lexer Specification (frozen)

**Status: frozen for v0.23.43-dev; the lexer stage it contracts was folded
into the parser stage in v0.23.44-dev.** This document remains the contract
for the scanning half of `bootstrap/aster.ast` — §2's token kinds and
numbers, §4's character classes, §5's rules, §9's dump format and §8's nine
diagnostics are unchanged, and where an implementation and this document
disagree this document wins.

The two implementations it was written against were:

- `bootstrap/aster.ast` — the bootstrap compiler itself, written in Aster;
- `tests/lexer-twin.c` — an independent C implementation of the same contract,
  the differential oracle.

Both were checked byte-for-byte by `tests/lexer-checks.sh`. **All three are
retired as of v0.23.44-dev** (`bootstrap/PARSER-SPEC.md` §12.1 records why):
the token dump M3a wrote to stdout is gone, so the twin's reason to exist
went with it. What covers the lexer behaviour now is the parser pair —
`tests/parser-twin.c` carries the same scanner inside its recursive descent,
and `tests/parser-checks.sh` re-pins every lexer diagnostic (E1–E9, same
words and positions) and observes the tokenization through the AST dump
(identifier text through names, number conversion through `Num` values,
string decoding through `String` values, token boundaries through
positions). The generation contract of §12 still holds verbatim: the names
are data emitted by `bootstrap/gen_lexer_names.py`, and `tests/lexer_names.h`
is still that generator's output — now consumed by `tests/parser-twin.c`.

Where this document and `src/aster.cpp` (the host compiler's lexer,
  `class Lexer`, and `reportError`) disagree, **`src/aster.cpp` wins for
lexing behaviour and this document records the divergence explicitly** — the
bootstrap compiler is a re-implementation, not a port, and every intentional
difference is listed in §11.

---

## 1. Role and invocation

M3a is the lexer stage only. It reads one Aster source text from **stdin** and
writes the token stream to **stdout**, one token per line (§9). It performs no
parsing, no name resolution, no output file. It is the first stage of what
becomes a self-hosting compiler; later stages (M3b parser, M3c …) consume the
same source and extend this program rather than replacing it.

```
aster.ast < source.ast > tokens.txt
```

- stdin: the complete source text, read as raw bytes (§3).
- stdout: the token dump (§9). **Nothing is written to stdout unless the whole
  input lexes cleanly** — lexing completes before the first dump byte is
  emitted (two-phase, §8), so a failed run leaves stdout empty.
- stderr: diagnostics (§10), one line each, format `aster: error: <message>`.
- exit status: **0** on success, **1** on any error. `main` returns the status
  (the compiler lowers `main`'s return to `exit`).

## 2. Token kinds

**72 kinds**, numbered in the exact order of `enum class TK` in
`src/aster.cpp` (v0.23.42-dev). The number is part of the contract: the dump
prints the *name*, but both implementations and the generator key off the
number.

| # | Kind | # | Kind | # | Kind | # | Kind |
|---|---|---|---|---|---|---|---|
| 0 | End | 18 | I64 | 36 | Ne | 54 | BitXor |
| 1 | Ident | 19 | U8 | 37 | Lt | 55 | BitOr |
| 2 | Number | 20 | U16 | 38 | Le | 56 | Tilde |
| 3 | String | 21 | U32 | 39 | Gt | 57 | Question |
| 4 | Fn | 22 | True | 40 | Ge | 58 | PlusEq |
| 5 | Extern | 23 | False | 41 | Plus | 59 | MinusEq |
| 6 | Main | 24 | Struct | 42 | Minus | 60 | StarEq |
| 7 | Let | 25 | Include | 43 | Star | 61 | SlashEq |
| 8 | Return | 26 | LParen | 44 | Slash | 62 | PercentEq |
| 9 | If | 27 | RParen | 45 | LBracket | 63 | ShlEq |
| 10 | Else | 28 | LBrace | 46 | RBracket | 64 | ShrEq |
| 11 | While | 29 | RBrace | 47 | At | 65 | AndEq |
| 12 | For | 30 | Colon | 48 | And | 66 | OrEq |
| 13 | Break | 31 | Semi | 49 | Or | 67 | XorEq |
| 14 | Continue | 32 | Comma | 50 | Not | 68 | PlusPlus |
| 15 | I32 | 33 | Arrow | 51 | Percent | 69 | MinusMinus |
| 16 | Ptr | 34 | Eq | 52 | Shl | 70 | Dot |
| 17 | Bool | 35 | EqEq | 53 | Shr | 71 | Amp |

The 22 **keywords** — `fn extern main let return if else while for break
continue i32 ptr bool i64 u8 u16 u32 struct include true false` — each lex to
their own kind (4–25); every other identifier is `Ident`. The keyword set is
data, not code: `bootstrap/gen_lexer_names.py` holds the single list and emits
both implementations' tables, so the two cannot drift.

## 3. Input model and limits

The source is read from stdin in a loop until `read` returns 0 or the buffer is
full; a negative return is treated as end of input, as EOF is.

- **`SRCMAX` = 1048576 bytes (1 MiB).** Reading more than `SRCMAX` bytes is
  error E8 (`source exceeds 1048576 bytes`). The check is on the total bytes
  *read*, before lexing — a source whose first byte is NUL but which is 2 MiB
  long still fails with E8, not with a token stream. Detection: the read loop
  fills the `SRCMAX`-byte source buffer; when it is full, one further
  single-byte read is attempted, and a positive result is E8. (An array
  declaration may not exceed `SRCMAX` elements, so the buffer is exactly
  `SRCMAX` bytes and there is no sentinel byte — `peek()` answers 0 by
  comparing the cursor against `srclen` instead, which is also why an embedded
  NUL needs no special casing.)
- **An embedded NUL byte is end-of-input for the lexer**, exactly as in the
  host compiler (whose `peek()` answers `'\0'` both past the end and on a NUL
  in the text). Bytes after the NUL are read (and counted for E8) but never
  lexed. `"ab\0cd"` yields `Ident "ab"` then the End token at 1:3.
- **`TOKMAX` = 65536 tokens**, the End token **excluded** (it is not stored;
  its position is carried in two variables). Storing a 65537th token is error
  E9 (`too many tokens (limit 65536)`). The End token does not count, so the
  message's limit is exact: 65536 real tokens are accepted.

## 4. Character classes

All classes are the C locale's, i.e. exact byte ranges — this matters because
the source is required to be ASCII and the classes must not drift with locale:

| class | bytes |
|---|---|
| space | 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D |
| digit | 0x30–0x39 |
| xdigit | 0x30–0x39, 0x41–0x46, 0x61–0x66 |
| alpha | 0x41–0x5A, 0x61–0x7A |
| alnum | alpha ∪ digit |

Any byte 0x80–0xFF is error E6 at the position where it is found (§10). 0x7F
(DEL) is ASCII but matches no class and no operator, so it falls through to E7.

## 5. Positions

- `line` and `col` are 1-based. `col` counts **bytes, not display columns**: a
  tab advances `col` by 1.
- Consuming a byte: if it is 0x0A, `line` increments and `col` resets to 1;
  otherwise `col` increments. A NUL is never consumed.
- A token's position is captured **before** its first byte is consumed —
  after leading whitespace and comments have been skipped.
- The End token's position is the position *after* all trailing whitespace and
  comments: `"a\n"` ends with `End 2 1`; `"a"` with `End 1 2`; `""` with
  `End 1 1`.

## 6. Lexing rules

The scanner is a loop. Each iteration first skips whitespace and comments (§6.1),
then captures the position and scans one token (§6.2–6.6). At end-of-input it
produces the End token and stops.

### 6.1 Whitespace and comments (the skip loop)

1. Skip every `space` byte.
2. `//`: skip bytes up to but not including the next 0x0A (or end of input);
   the newline itself is skipped by the next pass of the loop.
3. `/*`: skip until the first `*/`. The pair need not be balanced and comments
   do not nest. If end-of-input is reached first, error **E1** at the position
   of the `/*`. Note `/*/` is *unterminated*: after consuming `/*` the scanner
   is at `/`, which is neither `*` nor end-of-input's `*/` start, so it
   consumes the `/` and then hits end-of-input.
4. Anything else ends the skip loop.

### 6.2 Identifiers and keywords

`alpha` or `_` starts an identifier; it continues with `alnum` or `_`. The
token text is the matched bytes. If the text is one of the 22 keywords the
keyword's kind is used; otherwise `Ident`.

### 6.3 Numbers

Decimal only, plus one hexadecimal form. Scan `digit`s. If the scanned text is
exactly `0` and the next byte is `x` or `X`: consume the prefix byte, then
require at least one `xdigit` — if the next byte is not an `xdigit` (including
end-of-input), error **E2** at the token's start position — then scan the
remaining `xdigit`s. The prefix stays in the token text: `0x1F` is one
`Number` token with text `0x1F`.

There are no floating-point literals, no digit separators and no suffixes; `.`
after digits is the `Dot` operator, so `1.5` is `Number 1`, `Dot`, `Number 5`.
`1x` is `Number 1` then `Ident x` (the hex branch requires the `0` alone).

### 6.4 String literals

`"` starts a string. Bytes are consumed into the decoded value until the
closing `"`:

- `"` ends the token (closed).
- 0x0A or 0x0D: error **E3** at the token's start position.
- `\` consumes one escape byte `e`:
  - `n`→0x0A, `r`→0x0D, `t`→0x09, `0`→0x00, `\`→0x5C, `"`→0x22;
  - anything else — including end-of-input — is error **E4**. For any other
    byte `e` the error position is the position *after* `e` (§5); if `e` is
    0x0A the position is the next line, column 1, because consuming `e` moved
    the cursor there. At end-of-input `\` consumes nothing and the string is
    unterminated: error **E5** at the token's start position.
- Any other byte is appended to the value as-is (bytes 0x00–0x1F other than
  the six escapes, and 0x7F, are legal *inside* a string this way — the host
  compiler accepts them and so does this).

End-of-input before the closing quote is error **E5** at the token's start.

The token's text is the **decoded value** (with the quotes and the backslashes
gone), stored in a separate string pool; the dump re-escapes it (§9). The pool
is 1 MiB, which is sufficient because every decoded byte consumes at least one
source byte and the source is at most 1 MiB.

### 6.5 Operators and punctuation

One-byte forms are their own token. Multi-byte forms are decided by lookahead —
one byte for the two-byte forms, a second for the three-byte compound shifts —
so `<<=` is never cut into `<<` + `=` and `&&` never into two `&`:

| first | second | third | token |
|---|---|---|---|
| `=` | `=` | | `EqEq` else `Eq` |
| `!` | `=` | | `Ne` else `Not` |
| `+` | `+` / `=` | | `PlusPlus` / `PlusEq` else `Plus` |
| `-` | `>` / `-` / `=` | | `Arrow` / `MinusMinus` / `MinusEq` else `Minus` |
| `*` | `=` | | `StarEq` else `Star` |
| `/` | `=` | | `SlashEq` else `Slash` |
| `%` | `=` | | `PercentEq` else `Percent` |
| `^` | `=` | | `XorEq` else `BitXor` |
| `&` | `&` / `=` | | `And` / `AndEq` else `Amp` |
| `|` | `|` / `=` | | `Or` / `OrEq` else `BitOr` |
| `<` | `=` / `<` | `=` | `Le` / `ShlEq` else (`Shl` / `Lt`) |
| `>` | `=` / `>` | `=` | `Ge` / `ShrEq` else (`Shr` / `Gt`) |
| `( ) { } : ; , [ ] @ ~ ? .` | | | `LParen` `RParen` `LBrace` `RBrace` `Colon` `Semi` `Comma` `LBracket` `RBracket` `At` `Tilde` `Question` `Dot` |

For `<` and `>` the table reads: `<=` → `Le`; `<<` then `=` → `ShlEq`, else
`<<` → `Shl`; otherwise `Lt`. Symmetrically for `>`.

`#`, `$`, `` ` ``, 0x7F and any other ASCII byte with no row here is error
**E7** at the token's start position. (`/` reaching this table is always
`Slash` or `SlashEq`: `//` and `/*` were consumed by the skip loop.)

## 7. Token storage

Five parallel `i32` arrays of `TOKMAX` entries — `tkind`, `tstart`, `tlen`,
`tline`, `tcol` — hold the tokens. For every kind except `String`,
`tstart`/`tlen` are the offset and length of the token's text in the source
buffer; for `String` they index the decoded value in the string pool. The End
token is not stored; its position lives in `eline`/`ecol`.

## 8. Two phases, one output buffer

Phase 1 reads stdin and lexes the entire input into the arrays (§7). Phase 2
emits the dump. The phases exist so that an error anywhere in phase 1 leaves
stdout byte-empty — the contract §1 makes checkable.

Emission goes through a 64 KiB buffer flushed with `write(1, …)` when full and
once at the end; a single token may be longer than the buffer (a string value
can be almost 1 MiB), so the emitter copies in buffer-sized chunks.

## 9. Dump format

One line per stored token, then the End line:

```
<KindName> <line> <col>\n                     every kind except the three below
<KindName> <line> <col> <text>\n              Ident, Number, String
End <line> <col>\n                            always last
```

- Fields are separated by one ASCII space (0x20); every line ends with 0x0A.
- `<KindName>` is the kind's name from §2 — the same 72 names, from the same
  generated table, in both implementations.
- `<line>`/`<col>` are decimal, no padding, no sign.
- `<text>` for `Ident`/`Number` is the raw source bytes (which are always
  `[A-Za-z0-9_xX]` — no escaping applies). For `String` it is the **decoded
  value, re-escaped** with exactly six escapes: `\"` `\\` `\n` `\r` `\t` `\0`;
  every other byte is emitted verbatim. (For every escape the lexer accepts,
  re-escaping the decoded value reproduces the source spelling, so the dump
  round-trips through the lexer.)
- The End line has no text field.

Example — source `fn f(x: i32) { return "a\nb"; }`:

```
Fn 1 1
Ident 1 4 f
LParen 1 5
Ident 1 6 x
Colon 1 7
I32 1 9
RParen 1 12
LBrace 1 14
Return 1 16
String 1 23 a\nb
Semi 1 29
RBrace 1 31
End 1 32
```

## 10. Errors

One line on stderr, `aster: error: <message>`, exit status 1. `<message>` is
one of the nine below, byte for byte. `L:C` is the decimal line and column per
§5.

| id | message | position |
|---|---|---|
| E1 | `unterminated block comment at L:C` | of the `/*` |
| E2 | `hexadecimal literal has no digits at L:C` | of the token's first byte |
| E3 | `newline in string literal at L:C` | of the token's first byte (the `"`) |
| E4 | `unsupported string escape at L:C` | of the byte *after* the escape byte |
| E5 | `unterminated string literal at L:C` | of the token's first byte (the `"`) |
| E6 | `non-ASCII character at L:C (Aster source must be ASCII)` | of the offending byte |
| E7 | `unexpected character at L:C` | of the token's first byte |
| E8 | `source exceeds 1048576 bytes` | — |
| E9 | `too many tokens (limit 65536)` | — |

E1–E7 are the host compiler's seven lexer diagnostics, same words, same
positions; E8/E9 are bootstrap-specific guards with no counterpart in
`src/aster.cpp`. The first error found wins — lexing stops at the first one,
and because of the two phases nothing has been written to stdout.

## 11. Deliberate divergences from `src/aster.cpp`

Recorded so a future reader does not "fix" them into bugs:

1. **Token cap (E9).** The host compiler's `std::vector` is unbounded; the
   bootstrap stores tokens in fixed global arrays (no allocator at this
   stage), so it caps at 65536 and says so.
2. **Source cap (E8).** Same reason: the source buffer is a fixed 1 MiB.
3. **`read` errors.** The host compiler reads a named file and reports open
   failures; M3a reads stdin, where the only failure mode worth defining is
   "treated as EOF".
4. Everything else — the seven messages and their positions, the character
   classes, the comment/identifier/number/string/operator rules, the End
   token's position — is intended to be identical, and the differential suite
   that absorbed this one (`tests/parser-checks.sh`) holds it that way.

## 12. The generation contract

`bootstrap/gen_lexer_names.py` is the single source of truth for the kind
names and numbers (§2), the keyword list (§6.2) and the packed name table. It
is deterministic and idempotent, and it emits:

- the **generated region** of `bootstrap/aster.ast`, between the
  `BEGIN GENERATED` / `END GENERATED` markers: 72 `K_*` constants, the packed
  72-record × 12-byte `ktab` literal (name bytes, NUL-padded to 12; kind *k*'s
  name is the NUL-terminated string at `ktab + k*12`), the `ident_is` helper,
  and the `keyword_kind` else-if chain;
- `tests/lexer_names.h`: the parser twin's `enum` of the same 72 codes, the
  same 72 names as a `const char *` array, and the keyword table.

The region is regenerated in place — the generator never touches hand-written
code. `tests/parser-checks.sh` re-runs the generator and asserts the files on
disk are what it produces, so a stale table fails CI rather than the
differential. Any change to the token set lands in the Python first, then in
`src/aster.cpp`'s `enum class TK` — never the other way round.

## 13. Names the bootstrap source must not use

`bootstrap/aster.ast` is compiled by the host compiler, so its identifiers
must avoid the names the host compiler already claims. Besides the 22
keywords, these are built-ins — a call to any of them is dispatched to the
intrinsic unless the program defines a same-named function, and `sizeof` /
`len` are operators wherever they appear as a callee name:

```
read write openat close fstat mmap brk
load_u8 store_u8 load_u16 store_u16 load_i64 store_i64 load_ptr
sizeof len
```

The parser twin has no such constraint (it is C), but it keeps the same names
for its state where it can, so the two read alike.
