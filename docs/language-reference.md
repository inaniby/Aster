# Aster Language Reference

**Applies to: v0.23.76-dev** (single-file compiler, `src/aster.cpp`)

This is a *descriptive* reference: every rule below was read out of the compiler
source and then **checked against the v0.23.51-dev binary**. Where a rule says a
construct is rejected, the message quoted is the compiler's own. Where Aster
differs from C, it is called out explicitly — §9 records four such places, all
of them closed in v0.23.27-dev and kept there because each row is still the
clearest statement of what the rule is.

Related: `docs/language-spec.md` walks the same ground feature by feature and
explains *why* each rule exists. This file is the lookup table.

---

## 1. Source files

| Property | Rule |
| --- | --- |
| Extension | `.ast` (convention; the compiler does not check) |
| Character set | **ASCII only.** A byte > 127 outside a comment is `non-ASCII character at L:C (Aster source must be ASCII)` |
| Comments | `//` to end of line; `/* … */` block |
| Block comments | **do not nest** — the first `*/` closes. Unterminated → `unterminated block comment at L:C` |
| Whitespace | spaces, tabs, newlines (`isspace`) |
| Encoding note | UTF-8 inside a comment is fine: comments are consumed before the ASCII check runs |

## 2. Reserved words — 32

All 32 are rejected as identifiers (verified one by one: `let <kw>: i32 = 1;`
fails for every one of them).

| Word | Role | Since |
| --- | --- | --- |
| `fn` | function definition / declaration | — |
| `extern` | external function or global (`extern fn`, `extern let`) | — |
| `main` | the entry point's name; legal only as a function name | — |
| `let` | variable declaration (global, local, or `for` initializer) | — |
| `return` | return statement | — |
| `if` | conditional statement | — |
| `else` | `else { }` or `else if (…) { }` | — |
| `while` | loop | — |
| `for` | counted loop | v0.22.50-dev |
| `break` | exit a loop | — |
| `continue` | jump to the loop step / condition | — |
| `i32` | 32-bit signed integer type | — |
| `i64` | 64-bit signed integer type | v0.23.2-dev |
| `u8` | 8-bit unsigned integer type | v0.23.2-dev |
| `u16` | 16-bit unsigned integer type | v0.23.2-dev |
| `u32` | 32-bit unsigned integer type | v0.23.2-dev |
| `u64` | 64-bit unsigned integer type | v0.23.48-dev |
| `ptr` | untyped / typed address (`ptr`, `ptr<S>`) | — |
| `bool` | boolean type | v0.22.51-dev |
| `struct` | struct declaration | v0.23.5-dev |
| `enum` | enumeration declaration (named `i32` constants) | v0.23.61-dev |
| `type` | type-alias declaration (`type Name = T ;`) | v0.23.67-dev |
| `const` | read-only binding (`const x : T = e ;`) | v0.23.67-dev |
| `void` | return type only — names the absence of a result on a function (`fn f() -> void`) | v0.23.68-dev |
| `char` | unsigned 8-bit integer type (**distinct** from the `'a'` character literal, which still folds to `i32`) | v0.23.69-dev |
| `union` | union declaration (`union U { … }`) | v0.23.70-dev |
| `include` | `include "file.ast";` declaration sharing | v0.23.13-dev |
| `true` | Bool literal, value 1 | v0.23.25-dev |
| `false` | Bool literal, value 0 | v0.23.25-dev |
| `switch` | multi-way branch over a compile-time integer (Pascal semantics) | v0.23.49-dev |
| `case` | a `switch` arm value (followed by `:`) | v0.23.49-dev |
| `default` | the `switch` arm taken when no `case` matches | v0.23.49-dev |
| `do` | `do { … } while (cond);` — body first, then the test | v0.23.77-dev |

**Not reserved** (ordinary identifiers, checked by name after `@`): `embed`,
`embed_len`, `align`. `let embed: i32 = 1;` and `let align: i32 = 2;` both
compile.

**Contextual, not reserved** (since v0.23.35-dev): `sizeof` and `len`. They are
ordinary identifiers in the lexer and may be **declared** and **assigned**
(`let len: i32 = 5; len = 6;` compiles), but **read** in expression position the
parser treats them as the operator — `return len;` is `expected '(' after len`,
and so is `sizeof(len)` with `len` a variable, because the expression form
re-enters the same rule. In practice: do not name a variable `len` or `sizeof`.
The type names are likewise ordinary identifiers, which is what lets
`sizeof(i32)` parse a type in `primary()` at all.

**Contextual, not reserved** (since v0.23.51-dev): `tls`. It is an ordinary
identifier everywhere except at the **start of a top-level declaration**, where
`tls let name: type …;` declares a thread-local global (§8). `let tls: i32 = 1;`
compiles — a variable named `tls` is fine; only the declaration prefix is
special. The reserved-word count is therefore **33** (the `type` and `const`
keywords joined it in v0.23.67-dev, `void` in v0.23.68-dev, `char` in
v0.23.69-dev, `union` in v0.23.70-dev, and `do` in v0.23.77-dev).

### Identifiers

```
ident ::= [A-Za-z_] [A-Za-z0-9_]*
```

## 3. Literals

| Kind | Syntax | Notes |
| --- | --- | --- |
| Decimal integer | `[0-9]+` | e.g. `0`, `42`, `3000000000` |
| Hex integer | `0x` / `0X` + ≥1 hex digit | `0x1F`. Bare `0x` → `hexadecimal literal has no digits at L:C` |
| Binary integer | `0b` / `0B` + ≥1 binary digit | `0b1010` (= 10). Bare `0b` → `binary literal has no digits at L:C` (v0.23.50-dev) |
| Digit separators | `_` between two digits | `1_000_000`, `0xFF_FF`, `0b1111_1111_1111` all read with the `_` dropped — `1_000_000` *is* `1000000` (v0.23.50-dev); a `_` not flanked by two digits (`1_`, `_1`, `1_0_`) → `digit separator '_' must be between two digits at L:C` |
| Numeric suffix | `u` / `l` / `ul` after an integer literal | pins the literal's type: `1u` → `u32`, `2l` → `i64`, `3ul` → `u64` (v0.23.50-dev); `primary()` answers `U32`/`I64`/`U64` from `LitSuffix`. A value past the suffix's ceiling (`0xFFFFFFFFu` past `u32`, `0x8000000000000000l` past `i64`) or an unsupported suffix (`ll`, `uu`) → `u32 literal out of range at L:C` / `i64 literal out of range at L:C` / `invalid numeric suffix 'll' at L:C` |
| Integer range | ≤ `0xFFFFFFFFFFFFFFFF` | larger → `integer literal is too large at L:C` (v0.23.48-dev; the slot's own range is checked at the declaration — §9.4) |
| Bool | `true`, `false` | reserved words, not integers |
| String | `"…"` | value is a `ptr` to NUL-terminated rodata |
| Character | `'…'` | exactly one code unit; `'a'`, `'\n'`, `'\''`, `'\a'`, `'\x41'` decode through the shared escape table (v0.23.50-dev). Empty `''` → `empty or unterminated char literal at L:C`; more than one unit `'ab'` → `char literal must hold exactly one character at L:C` |

**String and character escapes** — shared by both literal kinds, exactly:
`\n` `\r` `\t` `\0` `\\` `\"` `\'` `\a` `\b` `\f` `\v` and `\xHH` (two hex digits).
The last six were added in v0.23.50-dev; before then the string table refused
`\'` and had no control codes.
Anything else → `unsupported string escape at L:C` (or `unsupported char escape at L:C`).
A raw newline inside → `newline in string literal at L:C`.
Unterminated → `unterminated string literal at L:C` (or `unterminated char literal at L:C`).

There are **no** floating-point literals or raw strings; every other literal
shape in the host language is supported (character literals, `u`/`l`/`ul`
suffixes, digit separators and `0b` binary all landed in v0.23.50-dev).

## 4. Operators and punctuation — complete token set

| Class | Tokens |
| --- | --- |
| Grouping | `( )` `{ }` `[ ]` |
| Separators | `;` `,` `:` |
| Declaration | `->` (return type) `@` (attributes) |
| Assignment | `=` `+=` `-=` `*=` `/=` `%=` `<<=` `>>=` `&=` `\|=` `^=` |
| Arithmetic | `+` `-` `*` `/` `%` |
| Bitwise | `&` `\|` `^` `~` `<<` `>>` |
| Comparison | `==` `!=` `<` `<=` `>` `>=` |
| Logical | `&&` `\|\|` `!` |
| Conditional | `? :` |
| Unary prefix | `-` `!` `~` `*` (deref) `&` (address-of) |
| Postfix | `.` (field) `[ ]` (index) `( )` (call) `++` `--` |
| Increment | `++` `--` (statement form only) |

**Maximal munch.** Every two-character form is decided by one peek and the
three-character compound shifts by a second, so `<<=` can never be cut into
`<<` + `=`, and `&&` can never be cut into two `&`. `->` is matched before `-=`.

Anything else — `#`, `$`, `'`, `` ` ``, `\`, etc. — is
`unexpected character at L:C`.

`&` has three readings: `&&` (logical), `&=` (compound), and bare `&`, which is
address-of where an operand may begin and bitwise-AND where one has already
been parsed. The two cannot be confused, because `primary()` only sees a
leading `&` and the bitwise level only sees one in operator position.

## 5. Types

| Type | Size | Align | Notes |
| --- | --- | --- | --- |
| `i32` | 4 | 4 | signed |
| `u32` | 4 | 4 | unsigned; `LO/LS/HI/HS` condition codes, `UDIV` |
| `i64` | 8 | 8 | signed; X registers |
| `u64` | 8 | 8 | unsigned; X registers, `UDIV`, `LO/LS/HI/HS` (v0.23.48-dev) |
| `ptr` | 8 | 8 | untyped address |
| `ptr<S>` | 8 | 8 | address of an `S`; gives `.field` its offsets |
| `fn(P1,..,Pn) -> R` | 8 | 8 | function pointer carrying a signature (v0.23.37-dev); stored as a `ptr`. Since v0.23.38-dev it is also legal as a **struct field** type and as a function's **return** type |
| `u8` | 1 | 1 | zero-extended on load, truncated on store |
| `char` | 1 | 1 | unsigned 8-bit; **identical width/ABI to `u8`**, so byte-for-byte ABI-compatible with C `unsigned char` (v0.23.69-dev). Distinct from the `'a'` character *literal*, which still folds to `i32` |
| `u16` | 2 | 2 | same |
| `bool` | 4 | 4 | holds 0 or 1 |
| `E` (an enum) | 4 | 4 | named integer constants over `i32` (v0.23.61-dev) |
| `S` (a struct) | layout | layout | passed and returned by address |
| `U` (a union) | widest member | widest member | every member at offset 0; **byte-for-byte C union ABI** (v0.23.70-dev), see §5.4 |
| `void` | — | — | **return type only** (v0.23.68-dev) — names the absence of a result; never a value you can hold |

Struct layout is AAPCS64 / C: each field starts at the next offset that is a
multiple of its own alignment, the struct's alignment is the largest of its
fields', and its size is the final offset rounded up to that alignment. A
**union** uses the same table with every offset set to 0 — see §5.4.

v0.23.77-dev (audit A-18): the rule is C's, but the *sizes* it is fed with are
the ones in the table above — and `bool` is 4 bytes here, not C's 1. A `struct`
that holds a `bool` is therefore laid out by these rules, not by C's: that is
why `struct T { b: bool, c: char, s: u16, i: i32 }` is 12 bytes (b at 0, c at 4,
s at 6, i at 8) while the C twin with `bool` would be 8. A C twin therefore writes `uint32_t`
where Aster has `bool` and the two agree exactly — the rule
tests/e2e-c-struct.sh uses when it compares a struct field by field against the
C compiler. A struct whose fields are `u8`/`u16`/`i32`/`u64`/`char`/`ptr`/
arrays/unions is byte-for-byte C's.

There is **no** `float`/`double`. `typedef` is spelled `type Name = T ;`
(v0.23.67-dev, §8) and `union U { … }` is a real union (v0.23.70-dev, §5.4);
both exist. `void` exists
as a **return type only** (v0.23.68-dev) — it names the absence of a result on a
function (`fn f() -> void`) and can never be a value, a parameter, a local, a
field, an alias or an array element; see §5.0. There is a **character literal**
(`'a'`) that still folds to `i32` (§3.2, v0.23.50-dev), **and** a distinct
`char` *type* (v0.23.69-dev) — `char` is an unsigned 8-bit integer type
(`Ty::Char`), byte-for-byte ABI-identical to C `unsigned char`, and a *separate*
spelling from the `Char` literal token: `let c: char = 'a';` is the typed story,
while `let c: i32 = 'a';` (the literal folded to `i32`) still works; see §5.1.
(Enumerations **do** exist — see §5.3 — but they are a thin, nominal wrapper
over `i32`, not a separate numeric kind.) An explicit
conversion is the **cast** `T(x)` (integers since v0.23.48-dev; `bool`, `ptr`
and `ptr<T>` since v0.23.60-dev — see §5.2); no other conversion is
expressible. (`sizeof` and `len` are operators since v0.23.35-dev — see §6.)

### 5.0 `void` — a return type only (v0.23.68-dev)

`void` is the one type that names the **absence** of a result rather than a
thing to compute. It is a `Ty::Void`, but it can appear **only** in a function's
return slot — a function declaration's `-> void`, or a function type's `-> void`
(`fn() -> void`). `parseType` accepts the `void` keyword solely behind
`needType`'s `allowVoid` gate, which the two return-parsers pass `true` to and
every value position passes `false`.

Anywhere else `void` is refused:

- as a **parameter** type — `fn f(a: void) -> i32` → `void is only a function return type`;
- as a **local** type — `let x: void = …` → the same;
- as a **struct field** — the same;
- as a **type alias** — `type V = void` → `a type alias cannot be void: V`.

A `void` function behaves like any other function except for the return
discipline:

- `return;` (no expression) is legal, and so is reaching the end of the body
  with no `return` — there is no value to be missing;
- `return e;` in a `void` function is refused: `cannot return a value from a void function`;
- the function still gets a prologue and an epilogue, takes its arguments in the
  usual registers, and returns under the same AAPCS64 ABI as a value-returning
  function — it simply returns nothing.

A `void` *result* cannot be used as a value. `let x: i32 = f()`,
`return f()`, and `g(f())` are refused because a `void` value is not assignable
to anything (`got void`); the operand form `f() + 1` is caught first by the
operator check with `a void value cannot be used in an expression`. The whole
point is C-ABI interop: an Aster `void` function takes its argument in `W0` and
returns nothing, exactly as C does, so a C `main` can link one with no shim on
either side.

### 5.1 `char` — an unsigned 8-bit integer type (v0.23.69-dev)

`char` is a real, first-class integer type of its own (`Ty::Char`), **distinct**
from the `'a'` character *literal*. The literal still folds to `i32` (§3.2,
v0.23.50-dev) — `'a'` is an `i32` constant — so `let c: i32 = 'a';` keeps
working; `char` is the type you may now *spell* for it. Its keyword is `char`
(`TK::CharType`), deliberately separate from the `Char` literal token, so the two
never collide.

`char` reuses the entire `u8` width/ABI machinery — 1-byte size, 1-byte
alignment, `LDRB`/`STRB`, `UXTB`, zero-extending loads — so a `char` is
byte-for-byte ABI-identical to C `unsigned char`. Concretely:

- a `char` **parameter** rides in `W0` truncated to a byte (`UXTB W0`);
- a `char` **return** is `UXTB W0`;
- a `char` **struct field** is a one-byte slot in the AAPCS64 layout;
- a `char` **array** strides one byte per element;
- a `char` **global** lives in `.data`/`.bss` as one byte.

`char` is a legal operand and result everywhere `u8` is: a local, a global, an
array element, a struct field, a parameter and a return type. `promoteInt`
answers `char + char == char` (a `==` b returns `a`), and a `char` widens
losslessly to any wider integer — `let m: i32 = c;` (where `c: char`) is
accepted and reads `c` zero-extended to 32 bits.

Narrowing into a `char` follows the same discipline as `u8`: a compile-time
constant that fits 0..255 assigns directly (`let c: char = 'q';` — `'q'` is 113,
in range), but a value that does not fit is refused — `char = 300` and
`char = -1` both fail with `does not fit in char: c (…)`. The spelled-out
truncation is the cast `char(x)` (§5.2): `char(300)` is `44`.

### 5.2 The cast: `T(x)`

```
cast  ::= ( "i32" | "i64" | "u8" | "u16" | "u32" | "u64" | "char"
          | "bool" | "ptr" [ "<" (type | ident) ">" ] ) "(" expr ")"
```

- Function-shaped and **primary** (precedence 1), the spelling `sizeof` and
  `len` already use. The type keywords are reserved words, so a type keyword
  followed by `(` can be nothing else — zero lookahead.
- **Legal conversions** (v0.23.60-dev): integer ↔ integer, bool ↔ integer,
  integer ↔ `ptr`, and `ptr`/`ptr<T>` ↔ `ptr`/`ptr<U>`. A conversion involving
  a **struct** is refused on either side (`cannot cast Point to u8` /
  `cannot cast u8 to struct 'Point'`), and so are the two `bool` ↔ `ptr`
  crossings — an address is neither a number nor a truth value.
- A **narrowing** cast answers with the target width's low bits:
  `u8(300)` is `44`, `u16(70000)` is `4464`, `u32(0 - 1)` is `4294967295`.
  A **widening** cast extends by the *source* type's signedness:
  `u64(u8(200))` is `200`, `u64(u32(4294967295))` is `4294967295`,
  `i64(i32(0 - 1))` is `-1` (sign-extended, not `4294967295`).
- `bool(x)` normalizes any non-zero integer to `1`; an integer cast of a bool
  answers its 0/1 value. A pointer cast reinterprets the 64-bit address (an
  `i32` source sign-extends, a `u32` source zero-extends into it), and a
  `ptr<T>` ↔ `ptr<U>` cast leaves the value unchanged while changing the
  stride/target the pointer carries.
- This is the only way to ask for a truncation. Since v0.23.63-dev an implicit
  narrowing is a compile error in **every** store position, not just where it
  happened to be checked — see the rule below.

### Implicit conversions

- A folded constant takes on the target type, range-checked by
  `initializerFits` (§9.4 for the one place this does **not** happen).
- `i32` ↔ `u32` interconvert (one 32-bit representation).
- A narrower integer widens losslessly to a wider one.
- Everything else is an error. **A narrowing must be asked for** with a cast
  (§5.2): silently dropping bits would be a bug in the program.

#### Where an implicit narrowing is refused (v0.23.63-dev)

The same `tyAssignable` rule an **argument** has always been checked against
now runs at every position that stores a value:

| Position | Example | Result |
| --- | --- | --- |
| A call argument | `f(n)` where `n: i64` and `f` wants `i32` | always was an error |
| A `let` initializer | `let b: u8 = e;` where `e: i32` | refused since v0.23.63-dev |
| A local assignment | `b = x;` with a narrowing mismatch | refused since v0.23.63-dev |
| A global initializer | `let g: u8 = <an i64>;` | refused since v0.23.63-dev |
| A `return` | `fn f() -> u8 { return n; }` with `n: i64` | refused since v0.23.63-dev |
| An array element or a struct field | `a[i] = w;` with `w: i64` and `a` an `i32[N]` | **unchanged** — see below |

The diagnostic names both types and says what to write instead:
`type mismatch initializing 'b': expected u8, got i64 (write an explicit cast
to truncate)`.

Two things are **not** narrowing errors:

- **A constant that fits.** `let b: u8 = 5;` is fine. When a constant does
  *not* fit, the range check runs **first**, so `let b: u8 = 300;` reports
  `local initializer does not fit in u8: x (300)` — the useful message — rather
  than a type mismatch.
- **An arithmetic result.** `let c: u8 = a + 1;` with `a: i32` is accepted.
  This is a documented consequence of the compiler having two type resolvers:
  Sema's `typeOf()` answers `i32` for every arithmetic node (a placeholder),
  while codegen's `exprType()` answers the *promoted operand width*. Trusting
  Sema at a store would refuse programs the compiler has always accepted —
  `examples/narrow_so.ast` among them — so the arithmetic family is exempt, and
  the exemption is a named predicate (`semaTypeIsPlaceholder`) rather than an
  anonymous case list. Unifying the two resolvers is the remaining root fix and
  is deliberately still open; until it lands, `let c: u8 = a + 1;` truncates
  silently and `let b: u8 = u8(a + 1);` is the honest spelling.
- **A store through a subscript or a field.** `a[i] = w;` with `w: i64` and
  `a` an `i32[N]` is still accepted, and keeps the element's width. This one is
  a fact the tree carries rather than a principle: `bootstrap/aster.ast` — the
  program the self-hosting loop recompiles with its own output — stores an
  `i64` instruction word into an `i32[262144]` stream, and the bootstrap
  subset's parser rejects every type keyword in operand position, so there is
  no cast to spell that truncation with. Tightening those two sites would break
  self-hosting with no way to fix the source. The exemption is a named
  parameter (`checkValue`'s `refuseNarrow`), and the honest fix is to give the
  bootstrap subset a cast.

Usual arithmetic conversion for two integer operands: equal types keep their
own width (`u8 + u8` wraps at 256); a 64-bit operand wins — and since
v0.23.48-dev `u64` outranks `i64`, so a mixed pair with a `u64` side is
compared unsigned (`u64 + i64` answers `u64`, not `i64`); a mixed pair widens
to 32 bits, taking the unsigned reading when either side is unsigned.

### 5.3 Enumerations (v0.23.61-dev, hardened v0.23.63-dev)

A `enum` declaration introduces a **nominal integer type** backed by `i32`. It
names a set of `i32` constants so the source can read `Red`/`Green`/`Blue`
instead of bare integers, without weakening the type system the way a C `enum`
does.

```
enum-decl  ::= "enum" ident "{" enumerator ("," enumerator)* ","? "}"
enumerator ::= ident ("=" constant)?
```

- **Auto-increment.** An enumerator with no `=` takes the previous value plus
  one; the first takes `0`. `enum Color { A, B, C }` names `0, 1, 2`.
- **Explicit values.** `enum Dir { North=10, East=20, South=20, West=-1 }` is
  legal; a `=` value is any compile-time integer that `constantInteger` can
  fold, so `= -1` works (the negative is folded before the assignment).
- **Every enumerator value has to fit `i32`** (v0.23.63-dev): an enum is an
  `i32` underneath, so an explicit `= value`, the auto-increment that follows
  one, and a constant landing in an enum slot are all checked by a single
  `enumValueFits` predicate — `-2147483648 .. 2147483647`. `enum E { A =
  2147483648 }` and an auto-increment that walks past `2147483647` are both
  `enumerator value out of i32 range: X` instead of a silent wrap.
- **No trailing comma.** `enum E { A, B, }` is `expected enumerator name at
  L:C`; write `{ A, B }`. (Struct fields and parameter lists are equally
  strict.)
- **At least one enumerator** is required; `enum Empty { }` is `enum has no
  enumerators at L:C`.
- **Name clashes.** An enum name may not shadow a struct, and an enumerator
  name may not repeat within the same enum (`duplicate enumerator 'X' at L:C`)
  or collide with another enum's enumerator (the enumerator namespace is
  global, so two enums may not reuse a name).

**Enumerators are `i32` constants.** The lexer records each name → value pair;
`primary()` rewrites an `Ident` that is an enumerator into a `Num` of that value
(flagged `enumConst`) *before* any other interpretation, so `A + B` is plain
`i32` addition and `Red == Blue` is a plain `i32` comparison.

**The enum type is nominal.** `enum Color` and `enum Dir` are *different*
types even when their values coincide — this is the one point where Aster's
enum is stricter than C's. `tyAssignable` enforces:

| Assignment | Result |
| --- | --- |
| `enum<same>  ←  enum<same>` | allowed (same `sid`) |
| `enum E  ←  i32 constant` | allowed **only** if the constant fits the value's range (`initializerFits`) — `let c: Color = Red;` compiles, `let c: Color = 99;` does too if `99` fits, `let c: Color = someVar;` does **not** (a variable is not a compile-time constant) |
| `i32  ←  enum E` | **free** — an enum value is already `i32` |
| anything else (cross-enum, `enum ← i32 variable`, `enum ← ptr/bool`, `ptr ← enum`) | refused |

**Comparing enums is nominal too** (v0.23.63-dev). `==` `!=` `<` `<=` `>`
`>=` accept an enum only against **the same enum** or against an **`i32`**:

```
let a: Color = Red;
let b: Dir   = North;
if (a == b)   { … }   // error: cannot compare two different enum types: Color and Dir
if (a == 0)   { … }   // ok   — an enum against an i32
if (a == Red) { … }   // ok   — the same enum
let n: i64 = 0;
if (a == n)   { … }   // error: an enum may only be compared with the same enum
                      //        or with an i32 (got i64)
```

Two enums whose values coincide are still different types, which is the one
point where Aster's enum is stricter than C's — C would compare them as
integers without a word.

Concretely, `let a: Color = Green; let b: Dir = a;` is refused
(`cannot assign Dir from Color`), and `let x: i32 = someColorVar;` compiles
because enum→i32 is free.

**Storage and size.** An enum value occupies 4 bytes and aligns to 4 — exactly
`i32`. `sizeof(Color)` is `4`, and codegen treats the type as a signed 32-bit
slot throughout (`tySize`/`tyAlign` land on `default: 4`, and `tyIsInteger`
includes `Ty::Enum` so an enum value is a legal `if`/`while` condition — zero
vs non-zero — and a legal arithmetic operand alongside `i32`).

**Debug info.** Each enum is emitted to DWARF as a `DW_TAG_enumeration_type`
of `DW_AT_byte_size 4`, `DW_AT_type_encoding 0x05` (signed), so a debugger
shows the named constants rather than bare integers.

### 5.4 `union` — overlapping members (v0.23.70-dev)

`union U { f1: T1, f2: T2, … }` declares an aggregate whose **every member
sits at offset 0**. It is the struct layout with one rule changed: the
alignment is the widest member's, and the size is the widest member's size
rounded up to that alignment. `sizeof(U)` reports that rounded size, not the
sum — `union U { w: i32, q: i64, lo: u8, c: char }` is **8 bytes**, aligned to
8. A union shares the **struct tag namespace**, so a union and a struct may
not share a name, exactly as in C.

Everything else is inherited from `struct` unchanged: field access (`u.q`),
`sizeof`, a union as a struct field, as a parameter and as a return value, and
the AAPCS64 aggregate classification (≤ 8 bytes in one register, 9…16 in two,
> 16 copied through memory). Because a union is a `Ty::Struct` with the same
`tySize` / `tyAlign`, a C `main` links an Aster function taking or returning a
union with no shim at all.

**Literal.** A union literal takes **exactly one value**: `U { 5 }`
initializes the **first** member and zeroes every other byte, matching C's
`union U u = {5};`. Zero or more than one value is refused (`union literal for
'U' has 2 values but a union takes exactly 1`). The zero fill happens both in
a constant initializer (a zero-filled `raw` image) and at run time (`STR
XZR/WZR` over the whole object before the single member store). Only the
**first** member matters for the "contains an array field" rule: an array in a
later member does not block a literal, because a literal never writes it.

**Type punning.** Writing one member and reading another is allowed and is
pure byte reinterpretation — there is no active-member tracking, as in C. With
the union above, `U { 0x11223344 }` leaves `u.q == 0x11223344` (the upper four
bytes zeroed) and `u.lo == 0x44`; assigning `u.q = 0x1122334455667788` then
makes `u.w == 0x55667788` and `u.lo == 0x88` on a little-endian AArch64.

**Debug info.** `-g` emits a real `DW_TAG_union_type (0x17)` DIE with one
`DW_TAG_member` child per field, each at `DW_AT_data_member_location = 0`.

**Refusals.** An empty union, a duplicate field, a self-containing union, a
duplicate declaration, a name colliding with a global or a function, a first
member that is an array (a literal cannot initialize it), and a union whose
widest member crosses the 1024-byte limit are all refused with a
`union`-worded diagnostic.

## 6. Expressions — precedence, highest first

| # | Level | Operators | Associativity |
| --- | --- | --- | --- |
| 1 | Primary | literal, identifier, `f(…)`, `a[i]`, `S { … }`, `( e )`, `@embed(…)`, `@embed_len(…)`, `sizeof(…)`, `len(…)`, `T(x)` cast (integers v0.23.48-dev; `bool`/`ptr` v0.23.60-dev) | — |
| 2 | Postfix | `.field` `[i]` `f(args)` | left |
| 3 | Unary prefix | `-` `!` `~` `*` `&` | right |
| 4 | Multiplicative | `*` `/` `%` | left |
| 5 | Additive | `+` `-` | left |
| 6 | Shift | `<<` `>>` | left |
| 7 | Relational | `<` `<=` `>` `>=` | non-associating |
| 8 | Equality | `==` `!=` | non-associating |
| 9 | Bitwise AND | `&` | left |
| 10 | Bitwise XOR | `^` | left |
| 11 | Bitwise OR | `\|` | left |
| 12 | Logical AND | `&&` | left |
| 13 | Logical OR | `\|\|` | left |
| 14 | Conditional | `? :` | right |

Levels 12 and 13 are two levels, not one: **`&&` binds tighter than `||`**, as
in C (`a || b && c` is `a || (b && c)`). They were collected by a single loop
until v0.23.27-dev, which made `a || b && c` read `(a || b) && c` — see §9.1.

Verified on the binary:

```
1 + 2 * 3      = 7        (1 << 3) + 1 = 9
1 << 3 + 1     = 16       (+ binds tighter than <<)
a + b << c     = (a+b)<<c ("a + b << c" with 1,2,2 → 12)
a << b < c     = (a<<b)<c (shift binds tighter than <)
-1 & 0xFF      = 255      (unary - binds tighter than &)
1 < 2 ? 2 : 3 < 4 ? 4 : 5 = 2   (right-nested)
a || b && c    = a || (b && c)  (&& binds tighter than ||, v0.23.27-dev)
-s.v           = -(s.v)         (a prefix operator's operand is a postfix
                                 expression, v0.23.27-dev)
```

**Chained comparisons are rejected — within one level.** Two operators from the
*same* comparison level in a row is a compile error; a level crossing is not:

```
a < b < c    → chained comparisons are not supported at L:C
a == b == c  → chained comparisons are not supported at L:C
a < b == c   → accepted, and reads (a < b) == c
a == b < c   → accepted, and reads a == (b < c)
```

The two levels are non-associating, so a chain inside one of them can only be a
mistake: `(a < b) < c` would compare a Bool against an integer, and `(a == b) ==
c` the same. Write `a < b && b < c`. Until v0.23.27-dev the check asked whether
*any* comparison operator followed, so `a < b == c` was rejected too (§9.3).

### Bool discipline

- `&&` `||` `!` `?:` require **Bool** operands/conditions.
  `n ? 5 : 6` with `n: i32` → `the condition of '?:' must be a bool expression`.
- Arithmetic, bitwise, shift, unary minus and array indexing **reject** bool
  operands. `a & b == c` → `cannot use a bool value in &`.
- `if` / `while` / `for` conditions accept a comparison, any Bool expression,
  or **any integer** (0 false, non-0 true), but not a `ptr`:
  `if (p)` → `condition must be a comparison, a bool expression, or an integer`.
- A comparison is an ordinary Bool expression: storable in a `let b: bool`,
  passable, returnable, holdable in a global.

### Pointers (v0.23.26-dev)

- The literal **`0` is the null pointer constant** — as in C. It may
  initialize, be assigned to, be passed to and be returned from a `ptr`.
- `==` / `!=` are defined for `ptr` vs `ptr`, and for `ptr` vs `0` in either
  operand order. They compare 64-bit addresses.
- An array name decays to its address in a `ptr` context. **`&arr` is that same
  address, spelled** (v0.23.30-dev), and since v0.23.34-dev it answers a
  **strided `ptr<T>` carrying the element width** for **any** element type — a
  local `T[N]`, a file-scope `T[N]` and a struct's array field. `&i64buf` is
  `ptr<i64>`, `&ubuf` is `ptr<u8>`, `&vbuf` of a `V3[..]` is `ptr<V3>`. Because
  the stride travels with the pointer, `(&arr)[i]` scales by `sizeof(T)` and is
  legal; a subscript after a plain `ptr` value still scales by 4. Storing a
  wider or narrower array address into a plain `ptr` (stride 4) is refused:
  `cannot store a pointer to <T> elements in ptr: 'p' would index it at 4 bytes —
  declare it ptr<T>, or take the array as a parameter`.
- `&` on anything else is still struct-only: `&x` on a scalar, a `ptr`, a `bool`
  or a scalar field → `'&' is only defined for a struct lvalue, not i32`, and a
  non-lvalue → `'&' requires a variable, a field, or a dereferenced ptr<S>`.
- **Ordered comparisons are not defined**: `p < g` → `only == and != are
  defined for a ptr`.
- A `ptr` compared with a non-zero integer → `a ptr may only be compared with
  another ptr, or with the literal 0`.
- `false` is a Bool literal whose value is also 0, but it is **not** an address.
- An array name decays to its address in a `ptr` context.
- `p.f` on a `ptr<S>` dereferences automatically.

### Function types (v0.23.37-dev)

A function pointer may be declared **with its signature**:
`let fp: fn(i32) -> i32 = inc;`. The storage type is still `ptr` (8 bytes) —
the signature rides beside it, on the local `let`, the global and the
parameter list — so a bare `ptr` keeps every rule it had (64-bit argument
staging, an `i32` answer, a struct argument refused) and a typed fn-pointer
gains the direct call's contract:

- **Checked like a direct call**: the argument **count**, and each argument's
  type through the same rule a direct call uses (`argument type mismatch
  calling f at argument 1: expected i32`, `expected 2 arguments, got 3`). An
  `i32` argument to an `i64` parameter is the same legal widening it always
  was; a `bool` to an `i32` parameter the same refusal.
- **Staged by the signature**: an `i32` argument in a `W` register, an `i64`
  one in a full `X` register, a struct laid out as a composite (a 12-byte
  `Tri` splits across two registers — a bare `ptr` refuses a struct argument,
  having no signature to lay one out with). The result is read at the
  signature's **return type** (`i64`/`ptr`/`bool`/`u32`, default `i32`), so
  `let r: i64 = fp(x);` type-checks where a bare-`ptr` call answered `i32`.
- **Every scope**: a local (`let fp: fn(i32) -> i32 = inc;`), a global
  (`let gop: fn(i32, i32) -> i32;` — which may be left **uninitialized**,
  zero-filling into `.bss`, and assigned at run time), and a **parameter**
  (`fn apply(op: fn(i32) -> i32, x: i32) -> i32 { return op(x); }` — the
  signature crosses the call with the pointer).
- **A struct field may declare one** (v0.23.38-dev): `struct Handlers {
  onClick: fn(i32) -> i32, tag: i32 }` — still eight bytes in the layout, and
  the call is written where the field is: `h.onClick(41)`. A store into the
  field is checked by signature, and a call through it is checked and staged by
  the field's own signature. An **array** of fn-pointer fields is refused
  (`an array of function pointers is not supported: Handlers.onClick`).
- **A function may return one** (v0.23.38-dev): `fn pick(which: i32) -> fn(i32)
  -> i32 { … return inc; }` — the `return` is checked against the return slot's
  signature, and a call's result answers it, so `apply(pick(1), 20)` is checked
  against `apply`'s parameter. `pick(0)(20)` is refused (`cannot call the
  result of this expression`): assign it first.
- **Precedence unchanged**: a function name in call position is still a direct
  call (the function always wins), and a same-named variable does not capture
  it. A typed call and a bare-`ptr` call are told apart by the *callee's*
  declaration, never by the call site — which is why `h.onClick(x)`, whose
  callee is a *field* and not a name, is its own expression kind: a field named
  like a function in scope must still be the field.

### Multi-dimensional arrays (v0.23.31-dev)

- A declaration writes **one `[N]` per dimension**: `let grid: i32[2][3] = 0;`,
  `let cube: i32[2][2][2] = 0;`, and a struct field `struct Grid { cells: i32[2][3] }`
  — at every site a one-dimensional array already parses (a local, a global in
  all three branches, a struct field). The length bounds check the **total**
  element count: `i32[1000][1000]` → `local array length must be between 1 and
  1000: a`, and `i32[0][3]` is refused where the length is read.
- **No new type carries it.** `grid` is a `ptr`, `grid[i]` is a **row** (a `ptr`
  to `M` elements) and `grid[i][j]` is the element — the same decay a
  one-dimensional array name has always had, one level in.
- The stride of a subscript at dimension *k* is
  `dims[k+1] * … * dims[L-1] * sizeof(elem)`: the element size for the
  innermost subscript (the stride a one-dimensional array has always had), and
  the product of the dimensions below it for an outer one — 12 for a row of a
  2×3 `i32` grid, 24 for an `i64` one, 4 for a `u8` one.
- **Every subscript is checked**, at its own dimension: `a[2][0]` →
  `array index out of bounds for 'a': index 2, length 2`; `a[0][3]` →
  `array index out of bounds: index 3, length 3`; a bool subscript at either
  level → `cannot use a bool value in an array index`.
- A chain may not run past the innermost dimension: `a[0][1]` on an `i32[3]` →
  `too many subscripts for 'a': it has 1 dimension` (the same refusal names a
  global or a field).
- A row is a `ptr` value: it may be bound to a `ptr` variable and passed to a
  `ptr` parameter (`rowSum(a[1], 3)`), exactly as `&buf` travels.
- **A row may not be stored to**: `a[1] = 5` (and `a[1] += 5`, a 3-D chain two
  dimensions short, the field spelling `s.xs[0] = 5`, and a row store in a `for`
  step) → `cannot assign to 'a'[i]: it addresses a row, not an element`. The
  single-subscript spelling is told apart from a chain by the subscript count
  the parser records, not by the expression's shape.
- A row is not an `i32` (`type mismatch initializing 'x': expected i32, got
  ptr`, `argument type mismatch calling f at argument 1: expected i32`) and not
  a condition (`condition must be a comparison, a bool expression, or an
  integer`).
- Two levels on a `ptr` → `pointer indexing is not supported yet`.

### `sizeof` and `len` (v0.23.35-dev)

Both operators take a **type** or an **expression** and fold to an `i32`
constant at compile time — the type spelling in the parser, the expression
spelling in Sema — so every downstream site sees an ordinary integer:

| Operator | Answers | Examples |
| --- | --- | --- |
| `sizeof(T)` / `sizeof(e)` | **bytes** | `sizeof(i32)` = 4, `sizeof(i64)` = 8, `sizeof(ptr)` = 8, `sizeof(u8[10])` = 10, `sizeof(i32[4])` = 16, `sizeof(i64[2][3])` = 48, `sizeof(S)` = the struct's laid-out size, `sizeof(w)`, `sizeof(row.cells)` |
| `len(T)` / `len(e)` | **element count** | `len(i32[4])` = 4, `len(i64[2][3])` = 6 (the product of the dimensions, not the row count), `len(w)`, `len(b.xs)` |

- An **array parameter** carries its dimensions into the body
  (`Function::paramDims`, filled by `Sema::check`), so `sizeof(a)` answers the
  array's bytes and `len(a)` its element count inside `fn f(a: i32[4])`. The
  dimensions answer these two operators and nothing else by default; under
  `--bounds-check` (since v0.23.36-dev) an out-of-range run-time `a[i]` (read or
  write) traps with `BRK #1` like a local/global array, and a multi-dimensional
  `a[i][j]` is checked per dimension — `return a;` stays refused and `a = ...`
  stays a type error.
- **One deliberate divergence from C**: `sizeof` on a decayed parameter in C is
  the pointer's 8; Aster answers the array's 16 — what the caller passed. The
  C twin measures a real array type, and the divergence is documented in
  `docs/language-spec.md`.
- `len` refuses what has no element count: `len() requires an array, not a
  scalar or pointer` (a scalar local, a `ptr`, a `ptr` parameter) and
  `len() requires an array type, e.g. len(i32[4])` (a scalar or struct *type*).
  `sizeof` is total over the type grammar, and the fold runs after the length
  check — `i32[0]` is still `array length out of range`.
- Malformed spellings are ordinary parse errors: `expected '(' after sizeof`,
  `expected ')' after sizeof expression`, `expected ')' after sizeof type`.
- `sizeof` and `len` are **contextual**, not reserved (§2): a variable may be
  *declared* and *assigned* under either name, but reading it in expression
  position is the operator — `return len;` is `expected '(' after len`, and so
  is `sizeof(len)` with `len` a variable, because the expression form
  re-enters the same rule.

### System-call intrinsics (v0.23.40-dev)

Built-in calls (no declaration, contextual like the memory intrinsics) that emit
a raw AArch64 `SVC #0`, no libc. A user function of the same name shadows one.

| Call | Syscall | Signature |
| --- | --- | --- |
| `read` | 63 | `(fd: i32, buf: ptr, len: i32) -> i32` — bytes read, 0 at EOF |
| `openat` | 56 | `(fd: i32, path: ptr, flags: i32, mode: i32) -> i32` — `AT_FDCWD=-100`, `O_RDONLY=0` |
| `close` | 57 | `(fd: i32) -> i32` |
| `fstat` | **80** | `(fd: i32, buf: ptr) -> i32` — `st_size` at offset 48 (79 is `newfstatat`) |
| `mmap` | 222 | `(addr: ptr, length: i64, prot: i32, flags: i32, fd: i32, offset: i64) -> ptr` — page-aligned `offset` (EINVAL otherwise), answers an address |
| `brk` | 214 | `(addr: ptr) -> ptr` — null queries the break, a page-aligned address grows it |

Results are the **raw kernel return**: failure answers `-errno`, not libc's `-1`
(`close` of a bad fd → `-9` → exit 247). Companion to `write` (64); see the
language spec for the full contract.

Two width rules the heap pair adds, both invisible at 32 bits: a `Ty::Ptr`/`Ty::I64`
**result** is read back at full width (`MOV Xd, X0`) — qemu's mappings sit near
`0x4000_0081_2000`, above 4 GiB, where a W read truncates — and an `i64` **argument**
is staged through X like a `ptr` (a 4 GiB `length` through W becomes 0 → EINVAL).
`mmap`/`brk` answer an address, so `let heap: ptr = mmap(z, 65536, 3, 34, -1, 0);`
type-checks and `heap + k` addresses it; the null check on failure is the
program's (`map == z`, since `-22` is not null). See the language spec's
*Heap intrinsics* section.

## 7. Statements

```
statement ::= let-decl
            | assign
            | deref-assign          '*' unary ( '=' | op= ) expr ';'
            | field-assign          postfix ( '=' | op= ) expr ';'
            | index-assign          ident '[' expr ']' ( '=' | op= ) expr ';'
            | indexed-field-assign  ident '[' expr ']' '.' ident ( '=' | op= ) expr ';'   (v0.23.28-dev)
            | array-field-assign    postfix '.' ident '[' expr ']' [ '.' ident ] ( '=' | op= ) expr ';'   (v0.23.29-dev)
            | multi-dim-assign      ident '[' expr ']' { '[' expr ']' } ( '=' | op= ) expr ';'   (v0.23.31-dev)
            | inc-dec               '++' ident ';' | ident '++' ';'
                                    '--' ident ';' | ident '--' ';'
            | 'return' expr ';'
            | if-stmt
            | labeled-loop          ident ':' ( while-stmt | for-stmt )   (v0.23.49-dev)
            | while-stmt
            | for-stmt
            | switch-stmt           (v0.23.49-dev)
            | 'break' [ ident ] ';'
            | 'continue' [ ident ] ';'
            | discard-call          ( Call-expr | FieldCall-expr ) ';'   (v0.23.39-dev)
```

**There are no expression statements — except a call.** A bare `;` and a bare
variable (`x;`) or an arithmetic value (`a + b;`) are still refused
(`expected let, assignment, return, if, while, for, break, continue, or switch at L:C`),
and every assignment form keeps its reading. But a call written for its side
effect alone, with its result dropped, is now a statement: `g();` and
`h.onClick(41);` run the callee and throw the answer away. Only an expression
whose outermost node is a `Call` or a `FieldCall` qualifies — `isCallStatement()`
peeks past the dot chain to the `(` so `h.onClick(41)` is told from `h.field =
v` — and the call is type-checked exactly as a kept one (argument count,
signature, width) before codegen emits it and releases the result register.

### `let`

```
let-decl ::= 'let' ident ':' type { '[' length ']' } '=' expr ';'
           | 'let' ident ':' struct-type ';'                          (v0.23.29-dev)
```

The initializer is **mandatory** (`let x: i32;` → `expected '='`) — **except
for a struct**, which since v0.23.29-dev may be declared with none and is
zero-filled: `let b: Buffers;`. That is also the only way to declare a struct
containing an array field, since such a struct cannot be built by a literal.
Local array lengths must be 1…1000. **Since v0.23.31-dev the `[N]` suffix may
repeat, one per dimension** (`let grid: i32[2][3] = 0;`, `let cube: i32[2][2][2] = 0;`,
and a struct field `struct Grid { cells: i32[2][3] }`) — the bounds check counts
the **total** elements, and the initializer is still broadcast to all of them.

The array's element type is the type written before the `[N]`, and **since
v0.23.28-dev it may be any type**: `bool[N]`, a struct `S[N]`, and a `ptr[N]`
join the integer widths, at file scope and inside a function alike. (Before that
round a local `T[N]` was gated on `T` being an integer — a local `ptr[N]` was
refused outright — and a global `bool[N]` / `S[N]` did not parse at all.)

### `const` (local, v0.23.67-dev)

```
const-decl ::= 'const' ident ':' type '=' expr ';'
```

- A local `const` is a `let` whose value may not change: it must have an
  initializer (`expected '='`), and the initializer is the same expression a
  `let` takes (including a call — `const k: i32 = bump(41);` is fine).
- Every store to it is refused: `k = e`, `k += e`, `k++`, an element store
  `a[i] = e`, a field store `s.f = e`, and its address `&k`. The last is refused
  because an Aster `ptr` carries no read-only bit, so `*p = v` would be the one
  way back in; C instead hands out a `const int *`, so `&const` is the single
  refusal in the language this round records as Aster's alone rather than one a
  C compiler also makes.
- Reading a `const` is reading a `let` — no special codegen, no byte difference
  from a `let` of the same value.

**Since v0.23.29-dev an array may also be a struct field** — `nums: i32[4]`
inside a `struct` — indexed as `s.nums[i]`, walked as `s.pts[1].a`, addressed as
`&s.pts[1]`, and scaled by the same shift-or-`UMADDL` rule a named array uses. A
field's length is 1…1000. A struct containing an array field is refused a
literal initializer at both scopes:

```
struct 'Buffers' contains an array field and cannot be initialized by a literal
```

and indexing a field that is not an array is `cannot index non-array field: x`.

**Since v0.23.30-dev a whole array has an address** — `&buf`, `&gbuf` and
`&s.cells` are each a strided `ptr<T>` (carrying the element width, any element
type since v0.23.34-dev), so an array can be handed to a `ptr<T>` parameter and
written through it instead of having to live at file scope. The address is the
one the array name already decays to (`&buf == buf` as an address), and it
scales by `sizeof(T)`. **Since v0.23.34-dev an array may also be a parameter
`T[N]`** (which decays to `ptr<T>` at the call) and a function may **return**
`ptr<T>` (handing back the array's address with its stride); only passing the
whole array *by value* is still refused. **Since v0.23.35-dev the parameter
carries its dimensions** (`Function::paramDims`), so `sizeof(a)` and `len(a)`
answer from inside the body. **Since v0.23.36-dev `--bounds-check` also guards
the subscript** — an out-of-range run-time `a[i]` (read or write) traps with
`BRK #1` exactly as a local/global array, and a multi-dimensional `a[i][j]` is
checked per dimension — while a default build stays unchecked, `return a;` is
still refused, and `a = ...` is still a type error.

**Since v0.23.31-dev an array may be multi-dimensional** — `grid[i][j]` is the
element, and `grid[i]` is a **row**: a `ptr` to the `M` elements of the second
dimension, which travels to a `ptr` parameter exactly as `&buf` does. See
*Multi-dimensional arrays (v0.23.31-dev)* under §6 for the stride rule, the
per-level bounds check, and the row-store refusal (`a[1] = 5` →
`cannot assign to 'a'[i]: it addresses a row, not an element`).

### Assignment forms

| Target | Plain | Compound |
| --- | --- | --- |
| `x` | `x = e;` | `x += e;` … |
| `a[i]` | `a[i] = e;` | `a[i] *= e;` … |
| `*p` | `*p = e;` | `*p += e;` … |
| `p.f` | `p.f = e;` | `p.f -= e;` … |
| `a[i].f` (v0.23.28-dev) | `a[i].f = e;` | `a[i].f += e;` … |
| `s.f[i]` (v0.23.29-dev) | `s.f[i] = e;` | `s.f[i] *= e;` … |
| `s.f[i].g` (v0.23.29-dev) | `s.f[i].g = e;` | `s.f[i].g += e;` … |
| `a[i][j]` (v0.23.31-dev) | `a[i][j] = e;` | `a[i][j] += e;` … — a *row* target (`a[1] = e`) is refused |

`x OP= e` desugars to `x = x OP e` in the parser. A target whose *address*
comes from an expression is rejected when it contains a call, because the
desugaring would evaluate it twice: `a[f()] += 1` →
`compound assignment would evaluate this target's address twice; write the
assignment out in full instead`.

`++` / `--` are **statements only**, never expressions — that is what keeps an
Aster expression free of side effects. Prefix and postfix are the same store.

### Evaluation order (v0.23.62-dev)

Aster does not specify the order in which the operands of one *expression* are
evaluated, and a program that depends on it is not portable. It does specify
one thing that used to be observable, and wrong: in every assignment form
above, the **value** is generated before the target's address is held, and a
subscript is generated before the base it indexes. So `a[i][j] = g` and
`s.f[i] = g` store into the element named — including when `g` is a *global*,
whose address materializes in the same register the target address lives in.

The value is also generated at the **target's** width rather than a default
one: `*p = -5` on a `ptr<i64>` stores `-5`, not `4294967291`. And an
integer→`bool` cast tests the operand at its own width, so `0x1_0000_0000` is
true.

Since v0.23.63-dev the same "at its own width" rule covers the **shift
family**: `<<`, `>>` and `~` on a 64-bit operand are emitted 64 bits wide, so
`~(i64 + i64)` is `-4` (a process exit status of `252`), where a 32-bit
reading would answer `-1` (`255`). A shift's *count* is still an `i32`
expression, as in C.

### `if`

```
if-stmt ::= 'if' '(' expr ')' block [ 'else' ( block | if-stmt ) ]
```

The braces are **mandatory** (`if (c) return 1;` → `expected '{'`).
`else` is optional (v0.23.22-dev). `else if (c) { }` desugars to
`else { if (c) { } }`.

### `while`

```
while-stmt ::= 'while' '(' expr ')' block
```

Braces mandatory. A `while` may carry a **label** (`name: while (…) { }`,
v0.23.49-dev); the label is only usable as the target of a `break name;` /
`continue name;` from inside a nested loop.

### `for`

```
for-stmt ::= 'for' '(' [ init ] ';' expr ';' [ step ] ')' block
init     ::= let-decl | assign | inc-dec
step     ::= assign | inc-dec          (no let)
```

Semantics: `{ init; while (cond) { body; step; } }`, with `continue` landing on
the **step**, not the condition. The condition may not be empty
(`for condition cannot be empty`). The initializer and step may be empty. A `for`
may also carry a **label** (`name: for (…) { }`, v0.23.49-dev), used the same
way as a `while` label.

### `switch` (v0.23.49-dev)

```
switch-stmt ::= 'switch' '(' expr ')' '{'
                  { 'case' expr ':' statement* }
                  [ 'default' ':' statement* ]
                '}'
```

Pascal semantics: the subject must be an **integer** type (`switch subject must
be an integer, not X` — `bool` and `ptr` are refused); each `case` value must be
a **compile-time integer constant** (`case value must be a compile-time constant`)
that **fits the subject's type** (`case value does not fit the switch subject
type`) and is **unique** (`duplicate case value N`); `default` may appear at most
once, in any position (`a second default case`). A `case` with no statements is
legal and simply falls through to the next arm (chaining empty cases is the one
form of sharing the language allows). **Each matching case body self-ends** — a
match does not run the next arm, so there is **no fallthrough and no `break`
keyword inside a `switch`**. `break` and `continue` keep their ordinary meaning
and still name the innermost loop; a `switch` does **not** push a loop context,
so a `break` inside a `switch` that is inside a `while` breaks the `while`, not
the `switch`. Codegen lowers the `switch` to a comparison chain — the subject
spilled to a slot, then per case `load subject; load case value; CMP; B.NE → skip
body; body; B → end`, with the `default` body last — adding **no new
instruction** and **no new label concept**, which is why the byte baseline of
every pre-existing example is unchanged (see `tests/switch-checks.sh` and
`tests/rebuild-baseline-v0.23.49.sh`).

### Labeled `break` / `continue` (v0.23.49-dev)

```
break  [ ident ] ';'
continue [ ident ] ';'
```

Unlabeled, `break` / `continue` name the innermost loop, as ever. Labeled, they
read the following identifier as a **target loop name** and resolve it
innermost-first among the enclosing labeled loops; a name that matches no
enclosing loop is `no such loop label: X`, and a label on anything but a `while`
or `for` is `only a while or for loop may be labeled`. The labels are a
compile-time name resolution, not a runtime `goto`: `break outer;` from inside a
nested loop jumps straight to the named loop's exit, and `continue outer;`
jumps to its step / condition — exactly what C needs an explicit `goto` for.

### Scope

A block introduces a scope; a nested `let` may shadow
(`let x: i32 = 1; if (…) { let x: i32 = 2; }` returns 2). Two `let`s of the
same name in one scope → `duplicate variable in scope: x`.

## 8. Top-level declarations

```
program   ::= decl*
decl      ::= 'include' string ';'
            | struct-decl
            | union-decl
            | 'type' ident '=' type ';'
            | 'let' ident ':' type [ '[' length ']' ] [ '@align' '(' n ')' ] '=' expr ';'
            | 'const' ident ':' type '=' expr ';'
            | 'tls' [ 'extern' ] 'let' ident ':' type [ '[' length ']' ] '=' expr ';'
            | 'extern' 'let' ident ':' type [ '[' length ']' ] ';'
            | [ 'extern' ] 'fn' name '(' params ')' '->' type ( block | ';' )
struct-decl ::= 'struct' ident '{' field (',' field)* '}'
union-decl  ::= 'union' ident '{' field (',' field)* '}'
field     ::= ident ':' type
params    ::= ε | ident ':' type (',' ident ':' type)*
name      ::= ident | 'main'
```

### Globals

- Length 1…1048576. Initializer must be a constant expression, or it takes the
  run-time-init path (scalars only).
- `@align(N)` is **global only**; `N` must be a power of two ≤ 4096.
- A `bool` global accepts only a constant folding to 0 or 1
  (`bool global initializer must be 0 or 1`).
- A struct global must be initialized by a struct literal, field by field.
  A `ptr` field cannot be given a constant value
  (`global struct field 'S.p' cannot be initialized by a constant`).
- Duplicate names → `duplicate global variable: g`.

### `do` … `while` (v0.23.77-dev)

```
do { body } while (cond);
```

The body runs **once**, then `cond` decides whether it runs again — the shape
the other loops cannot express (`while` tests first). `continue` jumps to the
condition, not to the body, and `break` leaves the loop, exactly as in the
other loops; the trailing `;` after the condition is required. A `do` loop may
be labeled like `while`/`for` (`outer: do { … } while (c);`), and a `break` or
`continue` naming it resolves to that loop.

### Thread-local storage (`tls let`) (v0.23.51-dev; shared objects since v0.23.52-dev)

- `tls` is a **context keyword**: it is only special at the start of a
  top-level declaration, so it stays a usable identifier everywhere else
  (`let tls: i32 = 5;` is an ordinary local). The reserved-word count is
  33 (the `type` and `const` keywords joined it in v0.23.67-dev, `void`
  in v0.23.68-dev, `char` in v0.23.69-dev, `union` in v0.23.70-dev and
  `do` in v0.23.77-dev).
- Same shapes as a plain global — scalars and arrays, the same types, the
  same constant-initializer rules, the same length bounds. `tls extern let
  name: type;` declares one defined elsewhere, exactly like `extern let` —
  except inside a shared object, where it is refused (there is no way to
  name another module's thread-local through `.dynsym`).
- Storage is a per-thread block, split the way GNU ld splits it: `.tdata`
  holds the non-zero initializers and owns file bytes; `.tbss` holds the
  zero-initialized tail, starts at the first 16-byte-aligned offset past
  `.tdata`, and owns none. `PT_TLS` reports `p_filesz` = `.tdata` and
  `p_memsz` = the whole block; the difference is `.tbss`, which a loader
  (or, in a static image, the kernel) zeroes for every block it hands out.
- **In a static image** (build-elf / build-pie / link-obj / link-pie) the
  entry stub points `TPIDR_EL0` at the block's base (`__aster_tls_block`),
  and an access is **local-exec**: `MRS Xt,TPIDR_EL0` then
  `ADD Xt,Xt,#offset`, the offset being a link-time constant filled into
  the MOVZ/MOVK pair.
- **In a shared object** (build-so / link-so / build-apk) the loader
  decides where this module's block sits, so an access is
  **initial-exec**: `MRS X16,TPIDR_EL0` / `ADRP X17,slot` /
  `ADD X17,X17,#:lo12:slot` / `LDR X17,[X17]` / `ADD X16,X16,X17`. The
  slot holds an *offset from TP*, not an address — that is what the final
  `ADD` means — and it is filled at load time by one
  `R_AARCH64_TLS_TPREL64` per variable (symbol `STN_UNDEF`, addend the
  variable's block offset). This is the shape GNU ld emits for a local
  `static __thread` under `-ftls-model=initial-exec`. Every thread that
  dlopens the module gets its own copy.
- There is **no compile-time size cap** on a shared object's TLS block. glibc
  2.35+ allocates a dlopen'd module's block dynamically, so even a megabyte
  dlopens cleanly on this machine; if a block genuinely cannot be placed, the
  loader reports `cannot allocate memory in static TLS block` at load time. A
  fixed surplus constant would only reject modules that load fine, and could
  not see the *host* process's own TLS footprint at compile time, so the
  runtime error is the honest contract.

### `union` (v0.23.70-dev)

- At least one field; no self-containment, no duplicate field names, and the
  same 1024-byte size limit as a struct (checked against the widest member).
- Every field sits at **offset 0**; the size is the widest member's size
  rounded up to the widest member's alignment (§5.4).
- Shares the struct tag namespace: a `union U` and a `struct U` collide.
- Literal: `U { v }` — **one** value, initializing the first member and
  zeroing the rest. An array in a later member does not block it.
- A union is a legal struct field, parameter and return type, with the same
  AAPCS64 aggregate ABI as an equally-sized struct. Type punning is allowed.
- `-g` emits `DW_TAG_union_type (0x17)` with each member at location 0.

### Functions

- The `-> type` is **mandatory** (`fn g() { }` → `expected ->`).
- At most **32 parameters** and at most **32 call arguments**.
- No nested functions. No default or variadic parameters.
- Body may not be empty.
- `main` must return `i32`. It takes **no** parameters, or the entry form
  `fn main(argc: i32, argv: ptr) -> i32` (v0.23.77-dev), or the same with a
  third `envp: ptr`. Those three arrive in `x0`/`x1`/`x2` — the kernel enters a
  static image with `argc` at `[sp]` and `argv` at `[sp+8]`, and the entry
  prologue reads them there before the first statement, so `_start` is still
  the function itself. Anything else is refused with
  `main must take no parameters, or (argc: i32, argv: ptr[, envp: ptr])`.
  `argv` is a plain `ptr`, not a `ptr<ptr<u8>>` (nested `ptr<…>` is not a type),
  so `argv[i]` is not the i-th argument string; read one with
  `ptr(load_i64(argv + i * 8))`, which is the address `argv[i]` holds.
- A function may call itself. A call to an undeclared name →
  `call to undeclared function: nope`.
- Every path must return; falling off the end is an error.
- `extern fn` declares an imported symbol — this is how libc is reached:
  `extern fn strlen(s: ptr) -> i32;`.
- v0.23.77-dev (audit A-19): an `extern fn` may be **called**, but its
  **address** cannot be taken — `let p: ptr = fa;` with `extern fn fa` is
  refused with "cannot take the address of extern function 'fa': its location is
  another object's business". An `extern let`'s address *is* allowed
  (`let p: ptr = &ga;`), because a global's address can be filled in at startup
  when the link knows where the object landed; a function used as a value is
  bound where it is written, so the object that owns it has to be the one
  naming it. Build the table in the defining object, or pass the function
  through an `extern` *variable* that the owning object initializes.
- v0.23.77-dev (audit A-20): every function reserves a **fixed 8 KiB frame**
  (`sub sp, sp, #0x2000`, return address at `sp+0x1ff8`), whatever its locals
  really need, and `.eh_frame` records exactly that (`DW_CFA_def_cfa_offset:
  +8192`). Recursion is therefore bounded by the thread's stack, not by the
  compiler: roughly 1000 nested calls on an 8 MiB main-thread stack. There is no
  tail-call elimination and no per-function frame shrinking.

### `struct`

  `--compact-frames` (same release) sizes a function's frame to its locals —
  plus the call grid (moved down to just above them) and the saved return
  address — keeping the 8 KiB layout only for functions that need the aggregate
  tail.
- At least one field; no self-containment
  (`struct S cannot contain itself`); no duplicate field names.
- **A field may be an array** (since v0.23.29-dev; multi-dimensional since
  v0.23.31-dev): `nums: i32[4]`, `cells: i32[2][3]`, length 1…1000 per
  dimension, and the length bounds check the total.
- Size limit 1024 bytes.
- Name conflicts with a global, a function, or another struct → error.
- Literal: `S { v1, v2 }` — one value per field, in declaration order. A struct
  containing an array field cannot be built by one
  (`struct 'Buffers' contains an array field and cannot be initialized by a literal`),
  so it is declared without an initializer and written element by element.

### `include`

```
include "path.ast";
```

Brings in **declarations only** — a function's body and a global's initializer
stay in the file that owns them, so there is exactly one definition per symbol.
Paths resolve against the *including* file's directory (C's `#include` rule),
overridable with `--include-dir`. Cycles are an error
(`include cycle: …`); a diamond is a no-op.

### Attributes

| Form | Meaning |
| --- | --- |
| `@embed("path")` | `ptr` to the file's bytes, copied into rodata at parse time |
| `@embed("path", N)` | as above, and the blob starts at an `N`-byte boundary (v0.23.71-dev) |
| `@embed_len("path")` | the byte count, folded to a literal |
| `@align(N)` | on a global declaration only |

`@embed` paths resolve like `include`. Limits: the file must exist, be
non-empty, not a directory, and ≤ 16 MiB. The same file embedded twice is one
blob: both names point at the same bytes, so a second `@embed` never copies
the file into `.rodata` again.

**Optional alignment (v0.23.71-dev).** `@embed("path", N)` asks for the
boundary the blob's first byte starts at. `N` must be an integer literal, a
power of two, and at most 4096 — the same rule `@align(N)` uses, 4096 being
Aster's minimum page size. A non-literal (`@embed(p, n)`), a non-power of two
(`3`, `0`, `6`, `0x18`), a value above 4096, a negative literal, an empty
argument or a third argument are all refused, and `@embed_len` takes no
alignment argument. `.rodata` declares `sh_addralign = N` and is placed at an
address and file offset congruent to `N` by all six writers (`build-obj`,
`build-elf`, `build-pie`, `build-so`, `link-obj`, `link-so`); the two linkers
take the **maximum** of the requests in their input objects. If the same path
is embedded twice with different requests, the single blob's alignment is
raised to the maximum rather than lowered or refused. The default is `1`, so
every program written before v0.23.71-dev stays byte-identical.

### Type aliases (v0.23.67-dev)

```
type Name = T ;
```

- `T` is **any type the grammar accepts** — a scalar, a struct, an enum, a
  `ptr<…>`, or a `fn(…) -> …`. The name expands by the same `parseType` every
  declaration site uses, so it is gone before layout, Sema and codegen run.
- There is no "alias type": two names for `i32` are `i32`, and a value of one
  is a value of the other. The one thing a `Ty` cannot carry — a **function
  signature** — travels in the alias record and is handed back at every use, so
  `type Op = fn(i32) -> i64;` is a real signature and a 64-bit result is read
  at full width.
- An alias **cannot** stand for an array (`i32[4]` is a declaration form, not a
  type → `expected ';' after a type alias declaration`), and is **not** a cast
  spelling (`T(x)` is the type keywords alone, so an identifier there stays a
  call).
- A declaration is refused when the right-hand side is not a type
  (`expected a type after '=' in the declaration of type alias N`),
  when the name is already taken (`duplicate type alias: N` / `type alias
  conflicts with a struct: N` / `type alias conflicts with a global variable: N`),
  and when used before it is declared (`expected i32, i64, …` where a type was
  wanted).
- Aliases may chain (`type A = S; type B = A;`) and an alias may name an
  earlier alias in its right-hand side.

### `const` globals (v0.23.67-dev)

```
const name : type = expr ;
```

- A top-level `const` is a read-only global: the same `.data` bytes a `let`
  global occupies, just never written by the program. It must have an
  initializer (`expected '=' in global variable declaration`), and the
  initializer is the same constant-or-run-time expression a `let` global takes.
- Sema refuses `name = e`, `name += e`, `name++`, an element store
  `name[i] = e`, a field store `s.f = e`, and `&name` — the last because an
  Aster `ptr` carries no read-only bit, so `*p = v` would be the one way back
  in. C hands out a `const int *` for the same, so `&const` is the one refusal
  Aster records as its own.
- A `const` local binding has the same rules and is documented in §7.
copy. An unknown attribute → `unknown attribute '@x' at L:C`.

## 9. Four places Aster used to differ from C — closed in v0.23.27-dev

This section was first written as a list of open traps, and v0.23.27-dev closed
all four. The rows stay, because each one is still the clearest statement of what
the rule *is* — and because three of the four were silent: they produced a
different answer, or a truncated value, rather than an error. Each row below
says what the old binary did and what v0.23.27-dev does. **No program that
compiled before v0.23.27-dev changes by a byte**: no shipped example mixed `&&`
with `||`, none wrote `*x.y` or `-x.y`, `a < b == c` did not compile at all, and
no narrow local in the tree was initialized out of range.

### 9.1 `&&` now binds tighter than `||` (was: one level)

```
if (1 == 1 || 1 == 1 && 1 == 2) { return 10; } return 20;
```

v0.23.26-dev returned **20** — it read `(a || b) && c`. v0.23.27-dev returns
**10**, reading `a || (b && c)`, which is C's answer and the answer
`docs/language-spec.md` had been claiming all along. There are two levels now:
`logicalAnd()` collects `&&` over `equality()`, and `logical()` collects `||`
over that. Both still short-circuit.

### 9.2 The prefix operators now take a postfix operand (was: a primary one)

`-` `!` `~` `*` used to parse their operand at `primary()` depth, so a following
`.field` landed **outside** the operator:

| Written | v0.23.26-dev read | v0.23.27-dev and C read |
| --- | --- | --- |
| `-s.v` | `(-s).v` | `-(s.v)` |
| `~s.v` | `(~s).v` | `~(s.v)` |
| `!s.ok` | `(!s).ok` | `!(s.ok)` |
| `*s.p` | `(*s).p` | `*(s.p)` |

In practice the old reading made all four **rejected** whenever the operand was
a struct:

```
-s.v   → cannot use a struct value (S) in -
~s.v   → cannot use a struct value (S) in ~
!s.ok  → '!' requires a bool operand
*s.p   → dereference requires a ptr expression
```

All four now work as written. A new `unary()` level sits between `postfix()` and
the multiplicative level, and `&` moved onto it with the other four, so `&s.v`
is still `&(s.v)` — sema only allows `&` on a struct lvalue:
`'&' is only defined for a struct lvalue, not i32`.

### 9.3 A level crossing is no longer an error (was: `a < b == c` rejected)

`a < b == c` used to be rejected by the anti-chaining check, although the
comment directly above the relational level promised `(a < b) == c`. The check
now asks whether the next operator is from the *same* level, which is what the
comment always described:

- `a < b < c`, `a == b == c` — a chain **within** a level: still refused,
  `chained comparisons are not supported at L:C`.
- `a < b == c`, `a == b < c` — a crossing: accepted, `(a < b) == c` and
  `a == (b < c)`.

### 9.4 A local `let` is range-checked like a global one (was: not checked)

```
let b: u8 = 300;                      // global → global initializer does not fit in u8: b (300)
fn m() { let b: u8 = 300; return b; } // was: accepted, returned 44
                                      // now:  local initializer does not fit in u8: b (300)
```

The check is `initializerFits`, the same one a global has always applied, and it
now runs for a local scalar **and** for a local array's element initializer
(`let a: u8[4] = 300;` → `local array initializer does not fit in u8: a (300)`),
in sema and again in codegen — the two passes carry the same message. Only a
*constant* initializer is checked by `initializerFits`, and a constant that does
not fit is a range error rather than a type mismatch.

*(v0.23.63-dev changed the sentence that used to follow: narrowing a **value**
was "silently accepted" at a `let` or assignment site and no longer is — see
§5.2's "Where an implicit narrowing is refused". The two argument paths were
never the only guarded ones; the guard now covers a `let`, an assignment, a
global assignment and a `return`.)*

## 10. Limits and quotas

| Thing | Limit | Error when exceeded |
| --- | --- | --- |
| Parameters per function | 32 | `functions support at most 32 parameters: f` |
| Arguments per call | 32 | `function calls support at most 32 arguments` |
| Local array length | 1 … 1000 | `local array length must be between 1 and 1000: a` |
| Global array length | 1 … 1048576 | `array length must be between 1 and 1048576: a` |
| Multi-dimensional array | same limits, on the **total** element count — `i32[1000][1000]` is refused exactly as `i32[1000000]` is (v0.23.31-dev) | `local array length must be between 1 and 1000: a` |
| Struct size | 1024 bytes | `struct S is too large: N bytes (limit 1024)` |
| Global alignment | power of two, ≤ 4096 | `alignment must be a power of two` / `must not exceed 4096 bytes` |
| Integer literal | ≤ `0xFFFF_FFFF_FFFF_FFFF` | `integer literal is too large` (the slot's own range is checked at the declaration: `local initializer does not fit in i64: x (…)`) |
| Shift count (constant) | 0 … 63 | `shift count N is out of range (0..63)` |
| Embedded file | ≤ 16 MiB | `embedded file is too large` |
| Struct nesting | a struct may not contain itself, directly or by value | `struct S cannot contain itself` |
| Frame slots (parameters + locals) | 500 eight-byte slots | `too many local declarations (limit 500, counted in eight-byte slots)` / `too many parameters (limit 500, counted in eight-byte slots)` |
| Expression temporaries | 16 simultaneously live | `expression too complex: temporary register limit exceeded` |
| Expression / statement nesting | 256 each | `expression is nested too deeply (max 256)` / `statement is nested too deeply (max 256)` |
| Constant folding / codegen walk | 2048 | `constant expression is nested too deeply (max 2048)` |
| `include` nesting | 64 | `include nesting is too deep (max 64)` |
| Nested call arguments | 14 levels (struct-valued results inside a struct literal: 4) | `nested function-call arguments exceed compiler limit (14 for pointer ABI)` / `struct-returning calls nested more than 4 levels deep` |

Constant folding covers `+ - * / % << >> & | ^ ~` and unary `-`, so
`buf[(1 << 3) | 1]` is bounds-checked like `buf[9]`. Overflow, division by
zero, and an out-of-range shift count simply do not fold, leaving the index
unchecked at run time.

## 11. Compiler command line

```
aster build-elf|build-pie [-g] <source.ast|input.o> [more…] -o <output>
aster build-obj [--pic] [-g] <source.ast> -o <output.o>
aster build-so  [--soname NAME] [--needed LIB] <source.ast|input.o> [more…] -o <output.so>
aster link-obj|link-pie <input.o> … -o <output>
aster link-so   [--soname NAME] [--needed LIB] <input.o> … -o <output.so>
aster build-apk <input.so|input.ast> -o <app.apk> --package PKG [options]
aster keygen [--dir DIR] [--bits 2048] [--force]
aster verify-apk <app.apk>
aster new [--apk] <dir>
aster add <source.ast>
aster build|run [-g] [--bounds-check] [--page-size N] [-o OUT] [--no-cache] [-- args…]
aster test  [-g] [--bounds-check] [--page-size N] [--no-cache] [filter]
aster doctor [--strict]
aster deps [<source.ast> ...] [-o OBJ]
```

| Flag | Effect |
| --- | --- |
| `-o PATH` | output file |
| `--pic` | position-independent object (only with `build-obj`, for `link-so`) |
| `--bounds-check` | lower every dynamic array index — into a global, a local, or an array parameter — into `CMP` + `B.LO` over `BRK #1`, so an out-of-range access raises SIGTRAP. **Off by default**; constant indexes are proved at compile time either way |
| `--compact-frames` | size each function's frame to its own locals instead of the historical 8 KiB (v0.23.77-dev). A function that neither calls nor copies/returns an aggregate allocates `locals + saved return address` rounded to 16 bytes — a leaf accessor drops from 8192 to as little as 16, and recursion through *leaf* calls goes that much deeper. A function with calls shrinks too: its call/syscall argument grid moves from the historical 4160 down to just above its locals (every instruction that embeds a grid offset is adjusted), so a recursive function's frame is its locals plus one 256-byte grid slot plus the saved return address — 32 bytes for a counter. Only a function that needs the aggregate tail (struct arguments, struct returns, struct copies) keeps the 8 KiB layout, because that tail is still addressed absolutely at 8024…8184. The default is off, so every existing product is byte-identical; with the flag `-g`'s FDEs report each function's own frame (`DW_CFA_def_cfa_offset`), and `main(argc, argv)` reads the initial stack through a captured register rather than a constant |
| `-g`, `--debug-line` | emit `.debug_line` (v0.23.12-dev), `.debug_info` (v0.23.32-dev) **and `.eh_frame`** (v0.23.33-dev) — the line program and a compilation unit per object (a `DW_TAG_subprogram` per function, a `DW_TAG_variable` per global, local and parameter), plus a call-frame table: a CIE identical to `aarch64-linux-gnu-gcc`'s and one FDE per function (`CFA = SP + 8192` one instruction in; `r30` at `CFA − 8` for every returning body, not the entry), carried by `R_AARCH64_PREL32` in an object and raised through `link-obj`/`link-so`. **Off by default**; no section moves a byte of `.text`. Since v0.23.51-dev each subprogram's `DW_AT_type` names a `DW_TAG_subroutine_type` — its return type and parameter types, so a debugger reads `p foo` as the whole signature — and each DIE carries a `DW_AT_decl_file` (index 1, the one entry the line table emits) |
| `--soname NAME` | `DT_SONAME` for `build-so` / `link-so` |
| `--needed LIB` | add a `DT_NEEDED` entry |
| `--embed-dir DIR` | where `@embed("…")` resolves relative paths |
| `--include-dir DIR` | where `include "…"` resolves relative paths |
| `--page-size N` | load-segment page size for `build-elf` / `build-pie` / `build-obj` / `build-so` / `link-*` **and** the embedded-`.so` ZIP offset for `build-apk`. It sets every `PT_LOAD` `p_align` (and the segment base/file offsets) to **N**; for `build-apk` it additionally aligns the embedded shared object inside the APK ZIP to **N**. Default **4096**; only `4096` and `16384` are accepted (`aster: --page-size must be 4096 or 16384`). **16384 is required for Android 15+ devices that use a 16 KB page** — the app is rejected at install when `targetSdk >= 35` unless *both* the ELF segments and the in-ZIP `.so` offset are page-aligned. v0.23.54-dev (ELF segments) / v0.23.55-dev (build-apk ZIP offset) |


Since v0.23.77-dev the three link-producing commands (`build-elf`,
`build-pie`, `build-so`) take **one or more inputs**, so a multi-file program no
longer needs a separate `build-obj` step per file:

```sh
aster build-elf main.ast defs.ast -o demo     # compile both, then link
aster build-elf main.ast defs.o -o demo       # …or mix sources with objects
aster build-so  a.ast b.ast --soname libx.so -o libx.so
```

Each non-`.o` argument is compiled to a private temporary object next to the
output (`<output>.aster-tmp<N>.o`) and removed afterwards; `.o` arguments are
linked as they are. The inputs reach the linker **in argument order**, which is
also the order run-time global initializers run in (§8's A-21/A-22 rules), so
list a dependency before the object that reads it. `build-obj` still compiles
exactly one file — it cannot write two outputs without a naming rule.

Output is always AArch64 ELF64: `build-elf` an `ET_EXEC` at 0x400000,
`build-pie` a static `ET_DYN` PIE with no interpreter, `build-obj` an
`ET_REL` object, `build-so` an `ET_DYN` shared object with SysV `DT_HASH` and
GNU `DT_GNU_HASH`.

Both `.so` writers carry **symbol versioning** (v0.23.51-dev): a `DT_VERDEF`
BASE entry (index 1, `VER_FLG_BASE` — the form glibc's loader skips, so an
import's `versym` of 1 means "no version") plus a named `aster` version
(index 2) for the exports, a `DT_VERNEED` against `GLIBC_2.17` (aux index 3)
for libc imports, and the `.gnu.version` / `.gnu.version_d` / `.gnu.version_r`
sections with the five `DT_VER*` tags. Exported symbols answer `name@@aster`
under `readelf --version-info`, exactly as a `gcc -shared` link with a
version script does.


## 11d. `aster doctor` — check the host and the project (v0.23.77-dev)

`aster doctor` answers "will this machine and this directory build what I think
they will" before anything is compiled. It prints one line per check with
`[ok  ]`, `[warn]` or `[fail]`, a summary, and exits 1 when anything failed
(`--strict` also fails on warnings):

* the compiler itself — version, word size, endianness;
* the host — `uname`, and whether that host can **run** AArch64 output itself or
  needs `qemu-aarch64`;
* the kernel/loader page size, and the `--page-size` it implies (4096 default;
  16384 for Android 15+ 16 KB pages);
* on Android: `pm`, so an APK can be installed;
* a writable scratch directory (`TMPDIR` or `/tmp`);
* the optional tools the suites and C interop use — `cc`, `python3`, `openssl`,
  `readelf`, `objdump`, `llvm-dwarfdump` — as warnings, never failures;
* the project, when `aster.proj` is here: `kind`, the sources (each present),
  whether exactly one defines `main` for an exe project, the `test` sources, the
  signing configuration (release keys actually load, or where the debug key is),
  free space for `build/`, and how many files the object cache holds.

It never writes to the project and never needs one: outside a project it simply
says so.

## 11c. Projects: `aster new`, `add`, `build`, `run`, `deps` (v0.23.77-dev)

A project is a directory with an `aster.proj` in it. A program project and an
APK project differ by one line:

```sh
aster new hello          # program: aster.proj, src/main.ast, src/util.ast
cd hello && aster build  # build/hello
aster run                # build, then execute; the program's exit code is ours

aster new --apk myapp    # APK: kind apk, package com.example.myapp, src/main.ast
cd myapp && aster build  # build/myapp.apk (signed, NativeActivity)
```

### `aster.proj`

Line-oriented: settings are `key value`, every other non-comment line is a
source path, in link order.

| Line | Meaning |
| --- | --- |
| `kind exe` | build an executable (the default) |
| `kind apk` | compile the sources into one PIC shared object, then wrap and sign it as a NativeActivity APK |
| `package com.example.app` | the APK package name (required for `kind apk`) |
| `name <name>` | output base name; default is the directory's name |
| `label <text>` | the launcher label (default: `name`) |
| `abi <abi>` | `arm64-v8a` by default (checked against the shared object, A-14) |
| `min-sdk N` / `target-sdk N` | manifest values, defaults 21 / 30 |
| `page-size 4096\|16384` | load-segment page size; 16384 for Android 15+ 16 KB pages |
| `sign-mode debug\|release` | APK signing; `debug` (default) uses the project key in `.aster/` |
| `keystore <path>` | release private key (PEM/DER, PKCS#8 or PKCS#1) |
| `cert <path>` | release certificate (PEM/DER); both are required with `sign-mode release` |
| `key-bits 2048\|3072\|4096` | size of a generated debug key (default 2048) |
| `test <path>` | a test program (v0.23.77-dev): `aster test` builds and runs it |
| *anything else* | a source path, relative to the project root |

A program project is `build/<name>`; an APK project is `build/<name>.apk`,
signed with the project's debug key (`.aster/` in the project root, created on
first build) unless `build-apk` options are used directly.

`aster add <source.ast>` appends a source to `aster.proj` (once: a second add of
the same path is a no-op). `aster run` builds and executes the program, forwards
everything after `--` to it, and returns the program's exit code; on an APK
project it says so and builds nothing.

### Signing

`build-apk`'s signing options can live in the project file instead of on the
command line. `sign-mode release` needs both `keystore` and `cert`; leaving one
out is refused ("sign-mode release needs `keystore <path>` and `cert <path>` in
aster.proj"), and giving either one without `sign-mode release` is refused too
("keystore/cert are release settings — add `sign-mode release` or remove
them"). The default is `debug`, which uses (and creates on first build) the
project's key under `.aster/`, sized by `key-bits`.

### Tests

A program project may list test programs:

```
kind exe
src/main.ast
src/util.ast
test tests/util_test.ast
```

`aster test` links each test source against the project's **non-entry** sources
(the ones that do not define `main`, found by parsing, not by file name), runs
the result, and reports pass/fail by exit code: 0 is a pass, anything else is a
failure carrying that code:

```
PASS tests/util_test.ast
Aster v0.23.77-dev: 1 test, 0 failed (2 compiled, 0 reused)
```

A non-zero exit from a test makes `aster test` exit 1. An optional argument is a
substring filter on the test path; a filter that matches nothing is an error
rather than a green run. Objects come from the same content cache the build
uses, so an unchanged library is compiled once. APK projects are shared objects
and are refused ("list `test` sources in a program project instead").

### The object cache

`aster build` keeps a content-keyed cache in `build/.cache/`: each source gets
one `<key>.o` and one `<key>.meta`, where the key hashes the compiler version,
the flags (including whether the object is PIC, i.e. an APK project), and the
source path. The meta records the source's content hash and one line per input
the compilation actually read — every `include` file and every `@embed` asset,
each with its own content hash. A rebuild reuses an object only when the
version, the flags, the source hash and **every** recorded input hash still
match; otherwise that source alone is recompiled. Deleted or edited assets, a
different `-g`, a different page size or switching project kind all miss the
cache, and `--no-cache` bypasses it.

Content, not mtime: a fresh `git checkout`, a `cp -p`, or an editor that
rewrites identical bytes does not rebuild, and touching a file without changing
it does not either. The link always runs (milliseconds) and the executable is
deterministic, so a build that compiled nothing reproduces the same bytes.

The cache is per project directory and safe to delete: the next build compiles
everything again.

### `aster deps`

For a build tool that drives the compilation itself, `aster deps` prints the
inputs of a translation unit as make rules. Given sources it names them; with no
arguments inside a project it names every source `aster.proj` lists, with the
`build/<stem>.o` targets the project build uses:

```sh
$ aster deps
build/main.o: src/main.ast /home/me/hello/src/util.ast
build/util.o: src/util.ast
```

`-include $(OBJS:.o=.d)` from a Makefile then maintains the rebuild rule §11b
describes. The command parses each file — that is how `include` and `@embed`
are discovered — but emits no object.

## 11b. Building a program from several files (and what is incremental)

Aster has no module system, but since v0.23.77-dev the three link-producing
commands compile several files in one invocation (`build-elf main.ast defs.ast
-o demo`); `build-obj` still compiles exactly **one** file, because one command
cannot write two outputs without a naming rule. The explicit shape — a file that
owns a definition compiles to an object, and the objects are linked — is what the
shortcut does under the hood, and what an incremental build tool should drive:

```sh
aster build-obj defs.ast -o defs.o        # definitions live here
aster build-obj main.ast -o main.o        # includes defs.ast for the declarations
aster link-obj main.o defs.o -o demo      # link-pie for ET_DYN, link-so for a .so
```

There are two ways for `main.ast` to know `defs.ast`'s declarations, and they
differ in what a rebuild can catch:

* `include "defs.ast";` reads the declarations out of the file that holds the
  body (§8), so the consumer's view cannot drift from the definition. Its body
  and any global initializer stay in `defs.o`.
* `extern fn add2(x: i32) -> i32;` declares it by hand. Nothing checks it
  against the definition; the linker matches symbols **by name only** — not by
  signature, not by arity, not by width.

That name-only link is exactly why the incremental rule below is "rebuild a
consumer whenever a file it includes changes", and not "rebuild only what the
change touched". Retargeting `add2` from one `i32` to two, rebuilding only
`defs.o` and relinking, links cleanly and **runs wrong** (the stale call passes
one argument); the same change with the consumer rebuilt fails to compile
(`wrong argument count calling add2: expected 2, got 1`), because the include
re-read the declaration.

### What is and is not incremental

| Mechanism | Status |
| --- | --- |
| separate compilation into `.o`, linked afterwards | **supported** |
| recompiling only the objects whose inputs changed | **your build tool's job** — the compiler has no mtime check, no object cache, no `-M` depfile |
| one command over several sources | **supported** for `build-elf` / `build-pie` / `build-so` since v0.23.77-dev (each source becomes a temporary object, then they link); **not** for `build-obj` |
| static archives (`.a`) | **not supported** — `link-*` takes `.o` files |
| link time signature checking | **not supported** — names only, see above |
| linking in the same command as compiling | **not supported** — always `build-obj` then `link-*` |

An object depends on **the file it compiles, every file that file includes
(transitively), and every file it `@embed`s** — `@embed` copies the bytes at
compile time, so editing an embedded asset needs that object rebuilt. Compiling
is a pure function of those bytes, which is what makes a timestamp-based build
correct without a cache: relinking is cheap (a two-object link is a few
milliseconds), so the usual Make shape works unchanged:

```make
ASTER := aster
OBJS  := main.o defs.o

demo: $(OBJS)
	$(ASTER) link-obj $(OBJS) -o $@

main.o: main.ast defs.ast           # includes defs.ast
	$(ASTER) build-obj main.ast -o $@
defs.o: defs.ast
	$(ASTER) build-obj defs.ast -o $@
```

Two rules of the linker apply to such a build and are worth stating where the
build is described (both were silent before v0.23.77-dev, see A-21/A-22 in
`AUDIT-v0.23.76-dev.md`): run-time global initializers run in **link order**, so
an initializer that reads another object's initialized global needs that object
listed first (the link is refused otherwise), and the initializer chain is
entered from the object holding `_start`, so at least one runtime-initialized
global must live in the object that holds `main` (the link is refused
otherwise too).

A `-g` build is per-object: each `build-obj -g` carries its own unit and line
program, and `link-obj` merges them (§11).

## 12. The standard library (v0.23.42-dev)

`stdlib/aster_std.ast` is the first slice of a library written in Aster
itself — pure Aster over the byte intrinsics, no compiler change. Because
`include` shares declarations only (§8), it is not an include: it builds to
an object and is consumed through `extern fn` —

```sh
aster build-obj stdlib/aster_std.ast -o std.o
aster build-obj app.ast -o app.o
aster link-obj app.o std.o -o app
```

| Family | Signatures |

| Family | Signatures |
| --- | --- |
| mem (v0.23.77-dev) | `memmove(dst: ptr<u8>, src: ptr<u8>, n: i32) -> i32` |
| str (v0.23.77-dev) | `strncmp`, `strchr(s, c) -> i32` (an offset or -1), `strstr(h, n) -> i32`, `strcat` (returns the new length) |
| parse (v0.23.77-dev) | `atoi(s) -> i32`, `is_digit` / `is_space` / `is_alpha` |
| format (v0.23.77-dev) | `fmt_i32(buf, v) -> i32`, `fmt_hex(buf, v, digits) -> i32` — fixed-arity writers returning the byte count, because there is no variadic call |
| sort (v0.23.77-dev) | `sort_i32(a: ptr, n: i32) -> i32` — ascending insertion sort |
| heap (v0.23.77-dev) | `malloc(n: i32) -> ptr` (a 64 KiB `mmap` bump allocator, 8-byte aligned, 0 when exhausted) and `free(p) -> i32` (the documented no-op answering 0) |
| --- | --- |
| mem | `memcpy(dst: ptr<u8>, src: ptr<u8>, n: i32) -> i32` · `memset(dst: ptr<u8>, c: i32, n: i32) -> i32` · `memcmp(a: ptr<u8>, b: ptr<u8>, n: i32) -> i32` |
| str | `strlen(s: ptr<u8>) -> i32` · `strcmp(a: ptr<u8>, b: ptr<u8>) -> i32` · `strncpy(dst: ptr<u8>, src: ptr<u8>, n: i32) -> i32` |
| num | `utoa(v: i64, buf: ptr<u8>) -> i32` · `itoa(v: i64, buf: ptr<u8>) -> i32` · `utohex(v: i64, buf: ptr<u8>) -> i32` |
| hash | `hash_str(s: ptr<u8>) -> i64` · `hash_put(key: ptr<u8>, val: i64) -> i32` · `hash_get(key: ptr<u8>) -> i64` |

Two rules behind the table: a byte-buffer parameter is `ptr<u8>` because
that spelling alone takes both a string literal and `&arr` of a `u8[N]`; and
`hash_get` answers `-1` for an absent key, so stored values are non-negative
by contract. Full semantics, the FNV basis, the 1024-slot open-addressing
rules and the twin/driver/suite: `docs/language-spec.md`'s *Libraries ship
as objects*, `examples/stdlib_demo.ast`, `tests/aster-std-twin.c`,
`tests/stdlib-checks.sh`.

## 13. The bootstrap lexer stage (v0.23.43-dev)

`bootstrap/aster.ast` is the first stage of the self-hosting compiler
(`SELFHOSTING-PLAN.md` M3a), written in Aster and consuming the §12 library.
It reads one Aster source from stdin and writes the token stream to stdout:

```sh
aster build-obj bootstrap/aster.ast -o boot.o
aster build-obj stdlib/aster_std.ast -o std.o
aster link-obj boot.o std.o -o asterlex
echo 'fn main() -> i32 { return 0; }' | ./asterlex
# Fn 1 1
# Main 1 4
# LParen 1 8
# RParen 1 9
# Arrow 1 11
# I32 1 14
# LBrace 1 18
# Return 1 20
# Number 1 27 0
# Semi 1 28
# RBrace 1 30
# End 1 31
```

The frozen contract is `bootstrap/LEXER-SPEC.md` (13 sections): 72 token
kinds numbered as `enum class TK`, the C-locale character classes, 1-based
byte-column positions, the comment/identifier/number/string/operator rules,
the dump format, and nine diagnostics. The kind names and the 22 keywords are
generated data — `bootstrap/gen_lexer_names.py` emits both the Aster side's
tables and the C twin's `tests/lexer_names.h`, cross-checked against
`src/aster.cpp`. The differential oracle is `tests/lexer-twin.c`; its
resident suite `tests/lexer-checks.sh` [11/11] was **retired in v0.23.44-dev**
and folded into `tests/parser-checks.sh`, which reuses the same lexer twin over
the full lex→parse→dump pipeline. Two limits are specific to the bootstrap
(fixed global arrays, no allocator): the source is capped at 1 MiB (E8) and
the token stream at 65536 stored tokens, the `End` token excluded (E9). Full
semantics: `docs/language-spec.md`'s *The bootstrap lexer stage*. (The frozen
document's §2 table is the v0.23.43-dev numbering — 72 kinds, 22 keywords. The
host compiler's `enum class TK` has since grown to **77 kinds and 26
keywords** (`Char`, the `switch` keywords, `u64`); `docs/language-spec.md`
carries the current numbering, and the generator cross-check keeps both
implementations' tables equal to the source.)

## 13b. The bootstrap parser stage (v0.23.44-dev)

`bootstrap/aster.ast` also carries the second stage of the self-hosting
compiler (`SELFHOSTING-PLAN.md` M3b): the M3a lexer plus an explicit
work-stack recursive-descent parser and an AST dumper, the three-phase core
`stdin → AST`. It reads one Aster source from stdin and writes the **AST dump**
to stdout:

```sh
aster build-obj bootstrap/aster.ast -o boot.o
aster build-obj stdlib/aster_std.ast -o std.o
aster link-obj boot.o std.o -o asterparse
echo 'fn main() -> i32 { return 0; }' | ./asterparse
# Program 1:1
# Function 1:1 main i32 0
# Return 1:11
# End 1:12
```

The frozen contract is `bootstrap/PARSER-SPEC.md` (13 sections): the §6.1
precedence chain `logical→logicalAnd→bitor→bitxor→bitand→equality→relational→
shift→sum→product`, the error catalog `E1`–`E9` / `P1`–`P62` / `B1`–`B22`, the
position semantics (Return at its expression, If at its condition, a
call-statement `Expr` at the callee, binary nodes inherit the left operand's
token, groups add no node), and the limit gates `C1=96` expression nesting,
`C2=96` statement nesting, `E8=1 MiB`, `E9=65536` tokens, `C3=65536` nodes
(defensive — unreachable behind E9). The 40 node kinds (`N_*` statements,
`S_*` structural, `E_*` expressions) and the 22 keywords are generated data
— `bootstrap/gen_parser_names.py` emits both the Aster side's tables and
cross-checks `src/aster.cpp`'s `enum class NK`. The differential oracle is
`tests/parser-twin.c`; the resident suite is `tests/parser-checks.sh` [11/11],
**312 checks including 13 mutation probes** — which also absorbed the retired
lexer suite. Two real bootstrap bugs fell to the suite: **P50**'s diagnostic
position (a node id fed to the token lookup) and **P37/P40**'s `expected '='`
message wrongly carrying the assigned name. Full semantics: `docs/language-spec.md`'s
*The bootstrap parser stage*.

## 14. Worked example

```aster
// Every construct in this file is verified by examples/null_ptr.ast
// (exit code 33) against tests/null-ptr-checks.sh.

let buf: i32[8] = 0;

fn find(needle: i32) -> ptr {
    let base: ptr = buf;
    let i: i32 = 0;
    while (i < 8) {
        if (buf[i] == needle) { return base + i * 4; }
        i = i + 1;
    }
    return 0;                       // null: not found
}

fn main() -> i32 {
    buf[2] = 7;
    buf[5] = 42;
    let r: i32 = 0;
    let hit: ptr = find(42);
    let miss: ptr = find(99);       // -> null
    if (hit != 0)    { r = r + 1; }
    if (miss == 0)   { r = r + 10; }
    if (hit != miss) { r = r + 2; }
    let both: ptr = 0;
    if (both == miss) { r = r + 20; }
    return r;                       // 33
}
```
