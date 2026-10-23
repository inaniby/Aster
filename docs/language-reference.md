# Aster Language Reference

**Applies to: v0.23.32-dev** (single-file compiler, `src/aster.cpp`)

This is a *descriptive* reference: every rule below was read out of the compiler
source and then **checked against the v0.23.32-dev binary**. Where a rule says a
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

## 2. Reserved words — 23

All 23 are rejected as identifiers (verified one by one: `let <kw>: i32 = 1;`
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
| `include` | `include "file.ast";` declaration sharing | v0.23.13-dev |
| `true` | Bool literal, value 1 | v0.23.25-dev |
| `false` | Bool literal, value 0 | v0.23.25-dev |

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

### Identifiers

```
ident ::= [A-Za-z_] [A-Za-z0-9_]*
```

## 3. Literals

| Kind | Syntax | Notes |
| --- | --- | --- |
| Decimal integer | `[0-9]+` | e.g. `0`, `42`, `3000000000` |
| Hex integer | `0x` / `0X` + ≥1 hex digit | `0x1F`. Bare `0x` → `hexadecimal literal has no digits at L:C` |
| Integer range | ≤ `0xFFFFFFFFFFFFFFFF` | larger → `integer literal exceeds u64 range at L:C` (v0.23.48-dev; the slot's own range is checked at the declaration — §9.4) |
| Bool | `true`, `false` | reserved words, not integers |
| String | `"…"` | value is a `ptr` to NUL-terminated rodata |

**String escapes** — exactly six: `\n` `\r` `\t` `\0` `\\` `\"`.
Anything else → `unsupported string escape at L:C`.
A raw newline inside → `newline in string literal at L:C`.
Unterminated → `unterminated string literal at L:C`.

There are **no** floating-point literals, character literals, suffixes
(`1u`, `2L`), digit separators, or raw strings.

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
| `u16` | 2 | 2 | same |
| `bool` | 4 | 4 | holds 0 or 1 |
| `S` (a struct) | layout | layout | passed and returned by address |

Struct layout is AAPCS64 / C: each field starts at the next offset that is a
multiple of its own alignment, the struct's alignment is the largest of its
fields', and its size is the final offset rounded up to that alignment.

There is **no** `void`, `float`/`double`, `char`, `enum`, `union`, `const`, or
`typedef`/type alias. An explicit conversion between the integer types is the
**cast** `T(x)` (v0.23.48-dev — see §5.1); no other conversion is expressible.
(`sizeof` and `len` are operators since v0.23.35-dev — see §6.)

### 5.1 The cast: `T(x)`

```
cast  ::= ( "i32" | "i64" | "u8" | "u16" | "u32" | "u64" ) "(" expr ")"
```

- Function-shaped and **primary** (precedence 1), the spelling `sizeof` and
  `len` already use. The type keywords are reserved words, so an integer
  keyword followed by `(` can be nothing else — zero lookahead.
- The operand must be an **integer**: `u8(p)`, `u8(true)`, `u8(s)` are
  `cannot cast ptr to u8` / `cannot cast bool to u8` /
  `cannot cast Point to u8`. `ptr` and `bool` are not cast *spellings*
  either — `ptr(x)` is `expected expression`, exactly as before.
- A **narrowing** cast answers with the target width's low bits:
  `u8(300)` is `44`, `u16(70000)` is `4464`, `u32(0 - 1)` is `4294967295`.
- A **widening** cast extends by the *source* type's signedness:
  `u64(u8(200))` is `200`, `u64(u32(4294967295))` is `4294967295`,
  `i64(i32(0 - 1))` is `-1` (sign-extended, not `4294967295`).
- This is the only way to ask for a truncation; implicit narrowing of a value
  remains a compile error where it is checked at all.

### Implicit conversions

- A folded constant takes on the target type, range-checked by
  `initializerFits` (§9.4 for the one place this does **not** happen).
- `i32` ↔ `u32` interconvert (one 32-bit representation).
- A narrower integer widens losslessly to a wider one.
- Everything else is an error. **A narrowing must be asked for** with a cast
  (§5.1): silently dropping bits would be a bug in the program.

Usual arithmetic conversion for two integer operands: equal types keep their
own width (`u8 + u8` wraps at 256); a 64-bit operand wins — and since
v0.23.48-dev `u64` outranks `i64`, so a mixed pair with a `u64` side is
compared unsigned (`u64 + i64` answers `u64`, not `i64`); a mixed pair widens
to 32 bits, taking the unsigned reading when either side is unsigned.

## 6. Expressions — precedence, highest first

| # | Level | Operators | Associativity |
| --- | --- | --- | --- |
| 1 | Primary | literal, identifier, `f(…)`, `a[i]`, `S { … }`, `( e )`, `@embed(…)`, `@embed_len(…)`, `sizeof(…)`, `len(…)`, `T(x)` cast (v0.23.48-dev) | — |
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
            | while-stmt
            | for-stmt
            | 'break' ';'
            | 'continue' ';'
            | discard-call          ( Call-expr | FieldCall-expr ) ';'   (v0.23.39-dev)
```

**There are no expression statements — except a call.** A bare `;` and a bare
variable (`x;`) or an arithmetic value (`a + b;`) are still refused
(`expected let, assignment, return, if, while, for, break, or continue at L:C`),
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

Braces mandatory.

### `for`

```
for-stmt ::= 'for' '(' [ init ] ';' expr ';' [ step ] ')' block
init     ::= let-decl | assign | inc-dec
step     ::= assign | inc-dec          (no let)
```

Semantics: `{ init; while (cond) { body; step; } }`, with `continue` landing on
the **step**, not the condition. The condition may not be empty
(`for condition cannot be empty`). The initializer and step may be empty.

### Scope

A block introduces a scope; a nested `let` may shadow
(`let x: i32 = 1; if (…) { let x: i32 = 2; }` returns 2). Two `let`s of the
same name in one scope → `duplicate variable in scope: x`.

## 8. Top-level declarations

```
program   ::= decl*
decl      ::= 'include' string ';'
            | struct-decl
            | 'let' ident ':' type [ '[' length ']' ] [ '@align' '(' n ')' ] '=' expr ';'
            | 'extern' 'let' ident ':' type [ '[' length ']' ] ';'
            | [ 'extern' ] 'fn' name '(' params ')' '->' type ( block | ';' )
struct-decl ::= 'struct' ident '{' field (',' field)* '}'
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

### Functions

- The `-> type` is **mandatory** (`fn g() { }` → `expected ->`).
- At most **32 parameters** and at most **32 call arguments**.
- No nested functions. No default or variadic parameters.
- Body may not be empty.
- `main` must return `i32` and take **no** parameters
  (`main must return i32`, `main must not have parameters`).
- A function may call itself. A call to an undeclared name →
  `call to undeclared function: nope`.
- Every path must return; falling off the end is an error.
- `extern fn` declares an imported symbol — this is how libc is reached:
  `extern fn strlen(s: ptr) -> i32;`.

### `struct`

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
| `@embed_len("path")` | the byte count, folded to a literal |
| `@align(N)` | on a global declaration only |

`@embed` paths resolve like `include`. Limits: the file must exist, be
non-empty, not a directory, and ≤ 16 MiB. The same file embedded twice is one
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
*constant* initializer is checked: narrowing a value (`let b: i32 = <an i64>`,
`let b: u8 = <an i32>`) is still allowed, as it always was — the slot's range
is only enforced against constants, and a non-constant narrowing at a `let`
or assignment site is silently accepted (the strict check guards the two
argument paths). Since v0.23.48-dev the explicit spelling is a cast
(§5.1): `let b: u8 = u8(a);` says the truncation was meant.

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
| Integer literal | ≤ `0xFFFF_FFFF_FFFF_FFFF` | `integer literal exceeds u64 range` (the slot's own range is checked at the declaration: `local initializer does not fit in i64: x (…)`) |
| Shift count (constant) | 0 … 63 | `shift count N is out of range (0..63)` |
| Embedded file | ≤ 16 MiB | `embedded file is too large` |
| Struct nesting | a struct may not contain itself, directly or by value | `struct S cannot contain itself` |
| Expression nesting | no declared limit; the parser recurses once per level | — |

Constant folding covers `+ - * / % << >> & | ^ ~` and unary `-`, so
`buf[(1 << 3) | 1]` is bounds-checked like `buf[9]`. Overflow, division by
zero, and an out-of-range shift count simply do not fold, leaving the index
unchecked at run time.

## 11. Compiler command line

```
aster build-elf|build-pie [-g] <source.ast> -o <output>
aster build-obj [--pic] [-g] <source.ast> -o <output.o>
aster build-so  [--soname NAME] [--needed LIB] <source.ast> -o <output.so>
aster link-obj|link-pie <input.o> … -o <output>
aster link-so   [--soname NAME] [--needed LIB] <input.o> … -o <output.so>
aster build-apk <input.so|input.ast> -o <app.apk> --package PKG [options]
aster keygen [--dir DIR] [--bits 2048] [--force]
aster verify-apk <app.apk>
```

| Flag | Effect |
| --- | --- |
| `-o PATH` | output file |
| `--pic` | position-independent object (only with `build-obj`, for `link-so`) |
| `--bounds-check` | lower every dynamic array index — into a global, a local, or an array parameter — into `CMP` + `B.LO` over `BRK #1`, so an out-of-range access raises SIGTRAP. **Off by default**; constant indexes are proved at compile time either way |
| `-g`, `--debug-line` | emit `.debug_line` (v0.23.12-dev), `.debug_info` (v0.23.32-dev) **and `.eh_frame`** (v0.23.33-dev) — the line program and a compilation unit per object (a `DW_TAG_subprogram` per function, a `DW_TAG_variable` per global, local and parameter), plus a call-frame table: a CIE identical to `aarch64-linux-gnu-gcc`'s and one FDE per function (`CFA = SP + 8192` one instruction in; `r30` at `CFA − 8` for every returning body, not the entry), carried by `R_AARCH64_PREL32` in an object and raised through `link-obj`/`link-so`. **Off by default**; no section moves a byte of `.text` |
| `--soname NAME` | `DT_SONAME` for `build-so` / `link-so` |
| `--needed LIB` | add a `DT_NEEDED` entry |
| `--embed-dir DIR` | where `@embed("…")` resolves relative paths |
| `--include-dir DIR` | where `include "…"` resolves relative paths |

Output is always AArch64 ELF64: `build-elf` an `ET_EXEC` at 0x400000,
`build-pie` a static `ET_DYN` PIE with no interpreter, `build-obj` an
`ET_REL` object, `build-so` an `ET_DYN` shared object with SysV `DT_HASH` and
GNU `DT_GNU_HASH`.

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
semantics: `docs/language-spec.md`'s *The bootstrap lexer stage*.

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
