# M3b Parser Specification (frozen)

**Status: frozen for v0.23.44-dev.** This document is the contract for the two
implementations of the bootstrap compiler's second stage:

- `bootstrap/aster.ast` — the bootstrap compiler itself, now extended past its
  lexer into a parser. It reads one Aster source text from **stdin** and writes
  the parsed AST to **stdout** as an indented node dump (§9).
- `tests/parser-twin.c` — an independent C implementation of the same contract,
  the differential oracle. Where the bootstrap parses expressions with an
  explicit work stack (§7), the twin parses them by recursive descent; where the
  bootstrap stores the AST in parallel arrays (§3), the twin stores it in a
  struct array. Two shapes, one contract.

Both are checked byte-for-byte by `tests/parser-checks.sh`. Where this document
and an implementation disagree, this document wins and the implementation is
wrong. Where this document and `src/aster.cpp` (the host compiler's parser,
`class Parser`) disagree, **`src/aster.cpp` wins for parsing behaviour and this
document records the divergence explicitly** — the bootstrap compiler is a
re-implementation, not a port, and every intentional difference is listed in
§12.

M3b **extends** the M3a program rather than replacing it: `read_source` and the
scanner are unchanged (`bootstrap/LEXER-SPEC.md` remains their contract), the
token arrays are now the parser's input, and the program's stdout changes from
the token stream to the AST dump. The token-dump emitters are gone; §12 records
what that costs and what covers it.

---

## 1. Role and invocation

M3b is the parser stage. It reads one Aster source text from **stdin**, parses
it into an AST held in fixed global arrays, and writes the AST to **stdout**,
one node per line (§9). It performs no name resolution, no type checking and no
code generation; it is the second stage of what becomes a self-hosting compiler.

```
aster.bin < source.ast > ast.txt
```

- stdin: the complete source text, read as raw bytes (LEXER-SPEC.md §3).
- stdout: the AST dump (§9). **Nothing is written to stdout unless the whole
  input parses cleanly** — parsing completes before the first dump byte is
  emitted (two-phase, §10), so a failed run leaves stdout empty.
- stderr: diagnostics (§11), one line each, format `aster: error: <message>`.
- exit status: **0** on success, **1** on any error. `main` returns the status
  (the compiler lowers `main`'s return to `exit`).

The subset parsed here is the one the bootstrap compiler's own sources need —
`bootstrap/aster.ast` and `stdlib/aster_std.ast` — widened with the complete
binary-operator table and unary `-` / `!` (§4–§6). Everything outside it is
refused with a frozen "not in the bootstrap subset" diagnostic (§6.3, §11).

## 2. Node kinds

Three tag spaces share one `i32` field, so a node's kind tells the emitter
which space it is in: **0–63 expression kinds**, **64–127 statement kinds**,
**128–135 structural kinds**. The numbers are part of the contract only inside
the implementations — the dump prints names, never numbers.

### 2.1 Expression kinds (25)

The subset of `enum Kind` inside `struct Expr` in `src/aster.cpp`, keeping the
host's numbers. The ten excluded host kinds are listed in §12.2.

| # | Kind | # | Kind | # | Kind | # | Kind |
|---|---|---|---|---|---|---|---|
| 0 | Num | 10 | Neg | 20 | ~~Field~~ | 28 | BitOr |
| 1 | Var | 11 | Eq | 21 | ~~AddrOf~~ | 29 | BitXor |
| 2 | String | 12 | Ne | 22 | ~~StructLit~~ | 30 | ~~BitNot~~ |
| 3 | Call | 13 | Lt | 23 | ~~Embed~~ | 31 | ~~Cond~~ |
| 4 | Index | 14 | Le | 24 | Mod | 32 | ~~SizeOf~~ |
| 5 | ~~Deref~~ | 15 | Gt | 25 | Shl | 33 | ~~Len~~ |
| 6 | Add | 16 | Ge | 26 | Shr | 34 | ~~FieldCall~~ |
| 7 | Sub | 17 | And | 27 | BitAnd | | |
| 8 | Mul | 18 | Or | | | | |
| 9 | Div | 19 | Not | | | | |

The ten struck-through kinds are the host kinds this subset excludes; their
numbers are skipped so the surviving 25 keep the host's numbering. The name
table still carries all 35 records (§13), and §12.2 records what replaces each
excluded construct.

### 2.2 Statement kinds (9)

The subset of `enum Kind` inside `struct Stmt`, host numbers **+ 64**.

| # | Kind | # | Kind |
|---|---|---|---|
| 64 | Let | 69 | Return | 73 | Break |
| 65 | Assign | 70 | If | 74 | Continue |
| 67 | IndexAssign | 71 | While | 75 | Expr |

64 is Let; 65 Assign; 67 IndexAssign; 69 Return; 70 If; 71 While; 73 Break; 74 Continue; 75 Expr; 66 (FieldAssign), 68 (DerefAssign), 72 (For) excluded.

### 2.3 Structural kinds (5)

No counterpart in `src/aster.cpp`: the host carries functions, globals,
parameters and block bodies as vectors beside the AST, not as nodes. The dump
makes them nodes so every line has one shape.

| # | Kind | Children |
|---|---|---|
| 128 | Program | the top-level items, in source order |
| 129 | Function | the parameters, then the body Block |
| 130 | Global | the initializer expression, if any |
| 131 | Param | none |
| 132 | Block | the statements |

### 2.4 Type tags (7)

A declaration's type, one tag. `ptr` with an element type is a distinct tag from
bare `ptr`, because the two index and lay out differently downstream.

| # | Tag | printed as | # | Tag | printed as |
|---|---|---|---|---|---|
| 1 | TY_I32 | `i32` | 5 | TY_PTR_U8 | `ptr<u8>` |
| 2 | TY_I64 | `i64` | 6 | TY_PTR_I32 | `ptr<i32>` |
| 3 | TY_U8 | `u8` | 7 | TY_PTR_I64 | `ptr<i64>` |
| 4 | TY_PTR | `ptr` | | | |

## 3. The AST representation

Aster has no structs, no unions and no allocator at this stage, so the AST lives
in **seven parallel `i32` arrays of 65536 entries**, indexed by **handle**
(handle = array index + 1; **0 means "no node"**):

| array | meaning |
|---|---|
| `nkind` | the node's kind (§2) |
| `ntok` | the **introducing token's** index in the token arrays — the source of the node's position, its name, its number text or its string value (§8) |
| `nfirst` | first child of the node's child chain (0 = none) |
| `nlast` | last child of that chain, so an append is O(1) |
| `nnext` | next sibling in the chain |
| `nty` | the type tag (§2.4) — Param, Global, Function (return), Let |
| `ncount` | a Global's array element count (1 for a scalar) |

Every child of every node — a binary operator's two operands, an `If`'s
condition and branches, a `Block`'s statements, a `Call`'s arguments, a
`Function`'s parameters — lives in the **sibling chain** headed by `nfirst` and
linked by `nnext`. There are no `a`/`b` fields: the emitter walks one chain, and
one append helper serves every list in the language.

Nothing else is stored per node. A `Num`'s value is converted from its token's
text at emit time (the same conversion the parser made, §6.2); a `Var`'s name is
the token's bytes; a `String`'s value is the token's decoded bytes in the string
pool, re-escaped (§9). The 65536-node pool is capped with C3 (§10).

The work-stack expression parser (§7) keeps its stacks in fixed arrays too:
`vstack` (value handles, 256), `ostacl` (operator token kinds, 256), `oprec`
(operator precedences, 256), and a marker stack of 128 entries (`mkind`,
`mvdepth`, `modepth`, `maux`). §10 proves the caps bound every one of them.

## 4. The subset: declarations and types

### 4.1 Program shape

```
program  := item*  EOF
item     := global | function
global   := 'let' name ':' type dims? '=' expr ';'
          | 'extern' 'let' name ':' type dims? ';'
function := 'extern'? 'fn' name '(' params? ')' '->' type body
params   := param (',' param)*
param    := name ':' type
body     := '{' statement* '}'
dims     := '[' number ']'          // globals only, 1..1048576, one dimension
```

- A function's body must be non-empty (P16). `main`, when present, must return
  `i32` (P12); its presence and its parameter list are **not** policed — M3b
  behaves like the host's `build-obj` mode (§12.3).
- Duplicate function (P17), duplicate global (P21) and global/function name
  collisions (P18) are refused.
- `struct`, `include`, `@align` on a global, `fn(…)` types and every type outside
  §4.2 are refused where the host's grammar would enter them (§11).

### 4.2 Types

```
type := 'i32' | 'i64' | 'u8' | ptr
ptr  := 'ptr' | 'ptr' '<' elem '>'
elem := 'i32' | 'i64' | 'u8'
```

Seven tags (§2.4). Anything else in a type position is either a boundary
diagnostic (bool/u16/u32/ptr-of-ptr/fn, B15–B17/B21/B22), the host's
"unknown struct type in ptr<…>" for an identifier inside `ptr<…>` (P59), the
host's "expected a struct name after 'ptr<'" for anything else there (P58), or
the shared type-expected message (P10) everywhere else — the same words the host
uses for the same input. A missing `>` after an element type is P60; after an
identifier it is P62, the host's struct-name variant — the two paths are the
host's, because it parses a known element type and a struct name through
different branches.

## 5. The subset: statements

```
statement := 'let' name ':' type '=' expr ';'                      // Let
           | name '[' expr ']' '=' expr ';'                        // IndexAssign
           | name '=' expr ';'                                     // Assign
           | 'return' expr ';'                                     // Return
           | 'if' '(' expr ')' block else?                         // If
           | 'while' '(' expr ')' block                            // While
           | 'break' ';' | 'continue' ';'
           | name '(' … ')' expr-tail ';'                          // Expr (call)
else      := 'else' 'if' …            // desugars to a nested If, not a Block
           | 'else' block
```

- A **discarded call statement** is what the host's `isCallStatement` recognises:
  an **identifier** (never the `main` keyword — P57 fires for `main();`, a host
  quirk this subset keeps) followed by `(`, then a full expression, then `;`.
  `f(1) + 1;` is therefore an `Expr` statement whose child is an `Add`, exactly
  as in the host.
- There is no general expression statement: `x + 1;` is the fallback error P57.
- `return` requires its expression (P41); `let` requires `= expr` (P35).
- The statement dispatch order is the host's, with the excluded forms replaced by
  boundary diagnostics: `*` (B7), `++`/`--` (B9), `for` (B1), `ident .` (B4),
  compound assignment (B10), and the fallback P57 — whose words name `for` even
  though the subset excludes it (the host's sentence, kept byte for byte).

## 6. The subset: expressions

### 6.1 Grammar and precedence

```
expr      := logical
logical   := logicalAnd ('||' logicalAnd)*
logicalAnd:= bitor ('&&' bitor)*
bitor     := bitxor ('|' bitxor)*
bitxor    := bitand ('^' bitand)*
bitand    := equality ('&' equality)*
equality  := relational (('=='|'!=') relational)?     // at most one, not chained
relational:= shift (('<'|'<='|'>'|'>=') shift)?       // at most one, not chained
shift     := sum (('<<'|'>>') sum)*
sum       := product (('+'|'-') product)*
product   := unary (('*'|'/'|'%') unary)*
unary     := '-' unary | '!' unary | primary
primary   := number | string | name call? | name '[' expr ']' | '(' expr ')'
call      := '(' (expr (',' expr)*)? ')'
name      := identifier | 'main'
```

The chain is the host's, tight to loose, and matches C: **the bitwise operators
bind tighter than equality** (`1 | 2 == 2` is `1 | (2 == 2)`), relational binds
tighter than equality (`a < b == c` is `(a < b) == c`), and `&&` binds tighter
than `||`. Two operators **from the same non-associative level** in a row are
refused (P54): `a < b < c` and `a == b == c` are errors at the second operator,
while `a < b == c` and `a == b < c` are legal crossings.

Precedence numbers used by the work stack (higher binds tighter):

| level | operators | # | chaining |
|---|---|---|---|
| logical | `||` | 1 | left-associative |
| logicalAnd | `&&` | 2 | left-associative |
| bitor | `|` | 3 | left-associative |
| bitxor | `^` | 4 | left-associative |
| bitand | `&` | 5 | left-associative |
| equality | `==` `!=` | 6 | **one per level** |
| relational | `<` `<=` `>` `>=` | 7 | **one per level** |
| shift | `<<` `>>` | 8 | left-associative |
| sum | `+` `-` | 9 | left-associative |
| product | `*` `/` `%` | 10 | left-associative |
| unary | `-` `!` (prefix) | 11 | prefix |

### 6.2 Numbers

A `Number` token is converted to an `i64` by the parser — decimal, or
hexadecimal when the text is `0`/`0X` followed by hex digits. The conversion is
the subset's own (there is no `strtoull` to call) and reproduces the host's
`unsignedLiteral` exactly:

1. Strip leading zeros from the digit run (keeping at least one digit); an
   all-zero text is the value 0.
2. **Too large** (P52 for a literal, P53 for an array length): a decimal text of
   more than 20 significant digits, a 20-digit decimal greater than
   `18446744073709551615`, a hex text of more than 16 digits, or a 16-digit hex
   greater than `ffffffffffffffff`. Equal-length digit texts compare
   byte-wise, which for digits is numeric order.
3. Otherwise the value fits `u64`. If it exceeds `i64` max — a 20-digit decimal,
   a 16-digit hex greater than `7fffffffffffffff`, or a decimal accumulation
   that would pass `i64` max — the value is **saturated** to `i64` max and
   flagged. The flag turns into P51 at a literal, and at an array length the
   saturated value simply fails the range check (P25), which is what the host's
   full-width value does there.
4. Accumulation is `acc = acc * base + digit` with the guard
   `acc > (i64max - digit) / base`; on a guard hit the value is saturated and
   flagged and accumulation stops.

The dump prints the **converted value** in decimal, so `0x1F` dumps as `Num 31`
— the conversion is observable, and the twin's `strtoull` must agree with it.

### 6.3 The excluded expression forms

Each is refused at the token where the host's grammar would enter it, with the
frozen message from §11: `~` (B6), prefix `*` (B7), prefix `&` (B8), `@embed`
(B19), `sizeof`/`len` as a callee name (B18), `true`/`false` (B14), `?:` (B5,
in value position), `.` (B4, in value position and in statement dispatch), a
second `[` after an `Index` (B13), and `ptr<ptr<…>>` / `fn(…)` types (B21/B22).
A `(` after a complete `Call` or `Index` is the host's P55; a `[` after anything
else is the host's P56.

## 7. The expression parser: the explicit work stack

The bootstrap has no allocator and one fixed 8 KiB frame per Aster call
(`docs/language-spec.md`: "Each function reserves an 8 KiB stack frame"), so a
recursive-descent expression parser would spend 8 KiB per precedence level and
overflow qemu's 8 MiB stack on deeply nested input. Expressions are therefore
parsed by an **iterative machine with explicit stacks**; the twin parses the same
grammar by recursion. The machine has two states.

### 7.1 State: expect-operand

The machine wants a value.

1. `-` or `!` — push a **prefix operator** (token kind on `ostacl`, precedence
   marker on `oprec`), depth +1 (C1), stay in expect-operand.
2. `~`, `*`, `&`, `@` — the boundary errors B6/B7/B8/B19.
3. `true`, `false` — B14. An identifier whose text is `sizeof` or `len` — B18.
4. `bool`, `u16`, `u32` — B15/B16/B17 (they can only appear here inside a
   `ptr<…>`; §4.2 owns the rest).
5. An identifier or `main`:
   - followed by `(` — consume both, **create the `Call` node now**, push a
     **call marker** carrying its handle, stay in expect-operand;
   - followed by `[` — consume both, push an **index marker** carrying the name
     token, stay in expect-operand;
   - otherwise — consume it, push a `Var` node, go to have-value.
6. A number — convert (§6.2), push a `Num` node, go to have-value.
7. A string — push a `String` node, go to have-value.
8. `(` — consume it, push a **group marker**, stay in expect-operand.
9. Anything else — P41 at the current token.

### 7.2 State: have-value

A complete value is on top of `vstack`. **After every value push and every
marker close, the prefix reducer runs**: while the top of `ostacl` is a prefix
operator, pop it, pop its operand, build `Neg`/`Not`, push the result. (A prefix
is pushed in expect-operand and its operand completes before any binary operator
can arrive, so a binary operator is never sitting on an unreduced prefix.)

1. A **binary operator** of precedence `p`:
   - while the top of `ostacl` is a binary operator of precedence `q`:
     - `q < p` — stop reducing;
     - `q == p` and `p` is 6 or 7 — **P54** at the current token (the chained
       comparison rule);
     - otherwise — reduce: pop the operator, pop `b`, pop `a`, build the node
       (the token decides the kind, §6.1), push it.
   - push the operator (token and `p`), go to expect-operand.
2. `(` — if the top value is a `Call` or an `Index`, P55; otherwise the
   expression **stops** here.
3. `[` — if the top value is an `Index`, B13; otherwise P56.
4. `.` — B4. `?` — B5.
5. Anything else — the expression **stops**.

### 7.3 Markers and stops

A marker records the `vstack` and `ostacl` depths at its entry (`mvdepth`,
`modepth`) plus one auxiliary word `maux`: the `Call` node's handle for a call
marker, the name token for an index marker, unused for a group marker. Pushing
any marker or prefix operator increments the depth counter (C1 at 97).

**Stopping** means: the current token cannot continue the expression. The
machine then looks at the innermost open marker:

- a **call** marker and the token is `,` — reduce everything above `modepth`,
  pop the top value, append it to the call node's child chain, go to
  expect-operand;
- a **call** marker and the token is `)` — reduce above `modepth`, append every
  value above `mvdepth` to the call node's chain (in stack order; zero values is
  a legal empty argument list), push the call node, pop the marker, run the
  prefix reducer, stay in have-value;
- a **call** marker and the token is anything else — P49;
- a **group** marker and the token is `)` — reduce above `modepth`; exactly one
  value must sit above `mvdepth` (zero is P41 at the `)`); the group adds **no
  node** — the host's `(expr)` returns the inner expression unchanged; pop the
  marker, run the prefix reducer, stay in have-value;
- a **group** marker and the token is anything else — P48 (the host's message,
  trailing space and all);
- an **index** marker and the token is `]` — reduce above `modepth`; exactly one
  value above `mvdepth` (zero is P41); build the `Index` node (name token from
  `maux`, child = the value), push it, pop the marker, run the prefix reducer;
- an **index** marker and the token is anything else — P39;
- **no marker open** — reduce every remaining operator and return the top value
  to the statement-level caller, which inspects the token itself.

Two invariants keep the stacks bounded and are relied on above: a marker close
never finds more than one value above its `mvdepth` (a non-continuing token with
a marker open errors first), and the prefix reducer runs at every point a value
could be waiting on one.

## 8. Position conventions

Every node records its **introducing token**, and its position is that token's
`line:col` (LEXER-SPEC.md §5: 1-based, bytes not columns). The conventions are
the host's, node kind by node kind:

| node | introducing token |
|---|---|
| Num, Var, String | the literal's / the name's token |
| Call | the callee token |
| Index | the array name token |
| every binary operator | **the left operand's** token (inherited) |
| Neg, Not | **the operand's** token (inherited) |
| Let, Assign, IndexAssign | the target name token |
| Return | **its expression's** token (inherited) |
| If, While | **the condition expression's** token (inherited) |
| Break, Continue | the keyword token |
| Expr (call statement) | the leading (callee) token |
| Function | the `fn` token — also when `extern` precedes it |
| Global | the name token |
| Param | the name token |
| Block | the `{` token |
| Program | the first token's; for an empty token stream, the End token's |

The dump prints every node's position, so these conventions — including the
host's oddity that a binary node carries its *left* operand's position — are
pinned by the differential suite rather than left to trust.

## 9. The dump format

One node per line:

```
<indent><KindName> <line>:<col>[ <fields>]
```

- `<indent>` is two spaces per depth. `Program` is depth 0; a node's children
  are the lines beneath it at one more space of indent, in child order (§3).
- `<KindName>` is the kind's name from §2, from the same generated table in both
  implementations.
- `<line>:<col>` is the node's position (§8), decimal, no padding.
- `<fields>` is kind-specific:

| kind | fields |
|---|---|
| Program, Block, Return, If, While, Break, Continue, Expr | none |
| Function | `name rettype` + ` extern` when external |
| Global | `name type count` + ` extern` when external |
| Param | `name type` |
| Let | `name type` |
| Assign, IndexAssign | `name` |
| Num | the decimal value (§6.2) |
| Var, Call, Index | `name` |
| String | the value, re-escaped with exactly `\"` `\\` `\n` `\r` `\t` `\0` |
| the 18 binary kinds, Neg, Not | none |

An `If`'s children are, in order: the condition, the then-block, and — when an
`else` is present — the else-part, which is a `Block` for `else { … }` and an
`If` for `else if (…) …` (the host desugars the latter to a nested If, not a
block, and the dump shows the difference). A `Function`'s children are its
parameters followed by its body `Block`; an external function has no `Block`.
Every line ends with 0x0A; fields are separated by one space.

### 9.1 Frozen example — precedence and positions

Source (`ex1.ast`):

```
fn main() -> i32 { let x: i32 = 1 + 2 * 3; return x; }
```

Dump:

```
Program 1:1
  Function 1:1 main i32
    Block 1:18
      Let 1:24 x i32
        Add 1:33
          Num 1:33 1
          Mul 1:37
            Num 1:37 2
            Num 1:41 3
      Return 1:51
        Var 1:51 x
```

`Add` sits at the `1` because a binary node inherits its left operand's
position; `Mul` at the `2`; `Return` at the `x` it returns.

### 9.2 Frozen example — globals, calls, if/else

Source:

```
let g: i32 = 0;
fn add(a: i32, b: i32) -> i32 { return a + b; }
fn main() -> i32 { if (g == 0) { return add(1, 2); } else { return 0; } }
```

Dump:

```
Program 1:1
  Global 1:5 g i32 1
    Num 1:14 0
  Function 2:1 add i32
    Param 2:8 a i32
    Param 2:16 b i32
    Block 2:31
      Return 2:40
        Add 2:40
          Var 2:40 a
          Var 2:44 b
  Function 3:1 main i32
    Block 3:18
      If 3:24
        Eq 3:24
          Var 3:24 g
          Num 3:29 0
        Block 3:32
          Return 3:41
            Call 3:41 add
              Num 3:45 1
              Num 3:48 2
        Block 3:59
          Return 3:68
            Num 3:68 0
```

The scalar global prints its count (`1`); an array global would print its
element count there.

### 9.3 Frozen example — the wider subset

Source:

```
extern fn write(fd: i32, buf: ptr<u8>, n: i32) -> i32;
let tab: i32[4] = 0;
fn main() -> i32 {
    let i: i32 = 0;
    let s: ptr = "a\tb";
    while (i < 4) {
        if ((i & 1) == 0) { tab[i] = i * 2; }
        else { tab[i] = -i; }
        i = i + 1;
        if (i == 4) { break; }
    }
    return write(1, s, 4);
}
```

Dump:

```
Program 1:1
  Function 1:8 write i32 extern
    Param 1:17 fd i32
    Param 1:26 buf ptr<u8>
    Param 1:40 n i32
  Global 2:5 tab i32 4
    Num 2:19 0
  Function 3:1 main i32
    Block 3:18
      Let 4:9 i i32
        Num 4:18 0
      Let 5:9 s ptr
        String 5:18 a\tb
      While 6:12
        Lt 6:12
          Var 6:12 i
          Num 6:16 4
        Block 6:19
          If 7:14
            Eq 7:14
              BitAnd 7:14
                Var 7:14 i
                Num 7:18 1
              Num 7:24 0
            Block 7:27
              IndexAssign 7:29 tab
                Index 7:29 tab
                  Var 7:33 i
                Mul 7:38
                  Var 7:38 i
                  Num 7:42 2
            Block 8:14
              IndexAssign 8:16 tab
                Index 8:16 tab
                  Var 8:20 i
                Neg 8:26
                  Var 8:26 i
          Assign 9:9 i
            Add 9:13
              Var 9:13 i
              Num 9:17 1
          If 10:13
            Eq 10:13
              Var 10:13 i
              Num 10:18 4
            Block 10:21
              Break 10:23
      Return 12:12
        Call 12:12 write
          Num 12:18 1
          Var 12:21 s
          Num 12:24 4
```

### 9.4 Frozen example — hex conversion and else-if

Source:

```
fn main() -> i32 {
    let x: i32 = 0x1F;
    if (x == 31) { return 1; }
    else if (x == 32) { return 2; }
    return 0;
}
```

Dump:

```
Program 1:1
  Function 1:1 main i32
    Block 1:18
      Let 2:9 x i32
        Num 2:18 31
      If 3:9
        Eq 3:9
          Var 3:9 x
          Num 3:14 31
        Block 3:18
          Return 3:27
            Num 3:27 1
        If 4:14
          Eq 4:14
            Var 4:14 x
            Num 4:19 32
          Block 4:23
            Return 4:32
              Num 4:32 2
      Return 5:12
        Num 5:12 0
```

The else-if is the first `If`'s third child — an `If`, not a `Block`. The hex
literal dumps as its converted value, `31`. A `Return` sits at the expression
it returns, the host's own rule (`s.line=s.expr->line`), the same convention
§9.1's dump shows.

### 9.5 Frozen example — empty input

An empty stdin lexes to just the End token at 1:1, parses to a `Program` with no
children, and dumps one line:

```
Program 1:1
```

## 10. Two phases, and the limits

Phase 1 reads stdin and lexes it (LEXER-SPEC.md §8). Phase 2 parses into the
pool. Phase 3 emits the dump. The phases exist so that an error anywhere leaves
stdout byte-empty — the contract §1 makes checkable. Emission goes through the
M3a output buffer (64 KiB, flushed when full and once at the end).

| limit | value | diagnostic |
|---|---|---|
| source size | 1048576 bytes | E8 (LEXER-SPEC.md §10) |
| tokens | 65536 (End excluded) | E9 (LEXER-SPEC.md §10) |
| AST nodes | 65536 | C3 |
| expression nesting (markers + prefixes open at once) | 96 | C1 |
| statement nesting (blocks entered + else-if links taken, one counter) | 96 | C2 |

The caps are bootstrap-specific — the host has none — and they are what keeps
this stage inside the language's own frame discipline. One Aster call costs a
fixed 8 KiB frame, and qemu's default stack is 8 MiB:

- **C2 (96).** A nesting level costs three live frames — `block`, `statement`,
  `if` — so 96 levels is about 2.3 MiB, and an else-if chain costs one frame per
  link, under 768 KiB. The single counter covers both shapes, so it is
  conservative where they mix; no shipped source comes close.
- **C1 (96).** The expression parser is iterative, so the cap is not about its
  own stack — it bounds the work arrays (below) and the **emitter**, which
  recurses once per AST level: a 96-deep expression chain is 96 frames, and the
  worst AST the caps allow — 96 nested blocks whose innermost statement holds a
  96-deep expression — is a few hundred frames, still about 2.3 MiB.
- **The work arrays.** With at most 96 markers+prefixes open, the marker stack
  needs 96 entries (128 provided); the operator stack holds the open prefixes
  plus at most two binaries per marker level, bounded by 98 + 96 = 194 (256
  provided); the value stack holds at most the left spine, bounded by markers +
  2 (256 provided). The caps fire before any array can overrun.

## 11. Errors

One line on stderr, `aster: error: <message>`, exit status 1, stdout empty.
Messages whose site carries a position end in ` at L:C`; the rest are bare. The
lexer's nine (E1–E9) are LEXER-SPEC.md §10 unchanged and still fire first.

### 11.1 The host's own parser messages

Same words, same positions — verified against `src/aster.cpp` (v0.23.43-dev) and
its binary. `<X>` is a name, type spelling or folded value filled in.

| id | message | position |
|---|---|---|
| P1 | `expected fn` | current token |
| P2 | `expected function name` | current token |
| P3 | `expected '(' after function name` | current token |
| P4 | `expected parameter name` | current token |
| P5 | `expected ':' after parameter name` | current token |
| P6 | `duplicate parameter name in function <F>: <p>` | — |
| P7 | `functions support at most 32 parameters: <F>` | — |
| P8 | `expected ')' after parameters` | current token |
| P9 | `expected ->` | current token |
| P10 | `expected i32, i64, u8, u16, u32, ptr, ptr<S>, bool, or a struct name` | current token |
| P11 | `a function cannot return an array: return ptr<T>, or take the array as a parameter and let the caller's storage be written through` | the `[` |
| P12 | `main must return i32` | — |
| P13 | `expected ';' after extern function declaration` | current token |
| P14 | `expected '{'` | current token |
| P15 | `expected '}'` | current token |
| P16 | `function body cannot be empty: <F>` | — |
| P17 | `duplicate function declaration: <F>` | — |
| P18 | `global variable conflicts with function: <G>` | — |
| P19 | `expected global variable name` | current token |
| P20 | `expected ':'` | current token |
| P21 | `duplicate global variable: <G>` | — |
| P22 | `expected '=' in global variable declaration` | current token |
| P23 | `expected ';' after extern global declaration` | current token |
| P24 | `expected array length` | current token |
| P25 | `array length must be between 1 and 1048576: <G>` | the number token |
| P26 | `expected ']' after array length` | current token |
| P27 | `array initializer must be a constant expression: <G>` | — |
| P28 | `array initializer does not fit in <T>: <G> (<V>)` | — |
| P29 | `global initializer does not fit in <T>: <G> (<V>)` | — |
| P30 | `division by zero in global variable initializer` | the operator node's (left operand's) |
| P31 | `shift count <N> is out of range (0..63) in global variable initializer` | the operator node's |
| P32 | `left shift overflows i64 in global variable initializer` | the operator node's |
| P33 | `expected variable name` | current token |
| P34 | `expected ':'` | current token |
| P35 | `expected '='` | current token |
| P36 | `expected ';'` | current token |
| P37 | `expected '=' in array element assignment` | the array name token |
| P38 | `expected '['` | current token |
| P39 | `expected ']' after array index` | current token |
| P40 | `expected '=' after variable name` | the variable name token |
| P41 | `expected expression` | current token |
| P42 | `expected ';' after call statement` | current token |
| P43 | `expected '(' after if` | current token |
| P44 | `expected ')' after condition` | current token |
| P45 | `expected '(' after while` | current token |
| P46 | `expected ';' after break` | current token |
| P47 | `expected ';' after continue` | current token |
| P48 | `expected ')' ` (with the host's trailing space) | current token |
| P49 | `expected ')' after function arguments` | current token |
| P50 | `function calls support at most 32 arguments` | the callee token |
| P51 | `integer literal exceeds i64 range` | the literal token |
| P52 | `integer literal is too large` | the literal token |
| P53 | `array length is too large` | the number token |
| P54 | `chained comparisons are not supported` | the second operator token |
| P55 | `cannot call the result of this expression: assign it to a fn(...) variable or a fn(...) field first` | the `(` |
| P56 | `cannot index this expression` | the `[` |
| P57 | `expected let, assignment, return, if, while, for, break, or continue` | the statement's first token |
| P58 | `expected a struct name after 'ptr<'` | current token |
| P59 | `unknown struct type in ptr<X>` | the `X` token |
| P60 | `expected '>' after the type in a ptr<...> type` | current token |
| P61 | `local alignment is not supported: <name>` | the name token |
| P62 | `expected '>' after the struct name in a ptr<...> type` | current token |

P48 is the host's message with its trailing space reproduced byte for byte, so a
group closed by the wrong token prints `expected ')'  at L:C` — two spaces —
exactly as `src/aster.cpp` does.

### 11.2 Subset boundaries

No host counterpart: the host accepts these inputs and the subset refuses them.
All carry a position.

| id | message | position |
|---|---|---|
| B1 | `the 'for' statement is not in the bootstrap subset` | the `for` |
| B2 | `struct declarations are not in the bootstrap subset` | the `struct` |
| B3 | `include is not in the bootstrap subset` | the `include` |
| B4 | `'.' field access is not in the bootstrap subset` | the `.` |
| B5 | `the '?:' operator is not in the bootstrap subset` | the `?` |
| B6 | `'~' is not in the bootstrap subset` | the `~` |
| B7 | `'*' dereference is not in the bootstrap subset` | the `*` |
| B8 | `'&' address-of is not in the bootstrap subset` | the `&` |
| B9 | `'++' and '--' are not in the bootstrap subset` | the token |
| B10 | `compound assignment is not in the bootstrap subset` | the compound token |
| B11 | `local arrays are not in the bootstrap subset` | the `[` |
| B12 | `array parameters are not in the bootstrap subset` | the `[` |
| B13 | `multi-dimensional indexing is not in the bootstrap subset` | the second `[` |
| B14 | `true/false are not in the bootstrap subset` | the token |
| B15 | `type bool is not in the bootstrap subset` | the `bool` |
| B16 | `type u16 is not in the bootstrap subset` | the `u16` |
| B17 | `type u32 is not in the bootstrap subset` | the `u32` |
| B18 | `sizeof/len are not in the bootstrap subset` | the name token |
| B19 | `@embed is not in the bootstrap subset` | the `@` |
| B20 | `global alignment is not in the bootstrap subset` | the `@` |
| B21 | `ptr<ptr<...>> is not in the bootstrap subset` | the inner `ptr` |
| B22 | `fn(...) types are not in the bootstrap subset` | the `fn` |

### 11.3 Caps

| id | message |
|---|---|
| C1 | `expression nests too deeply (limit 96)` |
| C2 | `statements nest too deeply (limit 96)` |
| C3 | `too many AST nodes (limit 65536)` |

The first error found wins: parsing stops at the first one, and because of the
phases nothing has been written to stdout.

## 12. Deliberate divergences from `src/aster.cpp`

Recorded so a future reader does not "fix" them into bugs.

1. **The token dump is retired.** M3a's stdout was the token stream; M3b's is
   the AST. The scanner is unchanged, but its token-dump emitters and the
   `ktab` name table they used are gone — `bootstrap/gen_lexer_names.py` no
   longer emits `ktab`, and `tests/lexer-checks.sh` / `tests/lexer-twin.c` are
   retired. What covers the loss: `tests/parser-checks.sh` pins every lexer
   diagnostic (E1–E9, same words and positions), and the AST dump observes the
   tokenization itself — identifier text through names, number conversion
   through `Num` values (§9.4), string decoding through `String` values, token
   boundaries through positions, and operator spelling through the diagnostics
   (`x <<= 1` is B10 precisely because `<<=` is one token).
2. **The subset boundaries (§11.2).** Ten expression kinds, three statement
   kinds and five type spellings the host parses are refused here. Each has its
   own frozen message rather than a generic one, so a program that outgrows the
   subset says which construct to wait for.
3. **`main` is not required and its parameters are not policed.** The host's
   `requireMain` is a driver flag: `build-obj` passes false (that is how
   `stdlib/aster_std.ast`, which has no `main`, compiles). M3b has no driver
   modes, so it takes the library reading — `main must return i32` (P12) is
   still enforced, `main must not have parameters` is not. The check returns
   when a stage owns the driver.
4. **The caps (§10).** The host's `std::vector`s are unbounded and its recursion
   is bounded only by the machine's stack; the bootstrap's fixed arrays and
   8 KiB frames force explicit limits, which it states instead of crashing.
5. **`sizeof` / `len` cannot be function names here.** The host dispatches a
   call to the intrinsic unless the program defines a same-named function, so
   `fn len(…)` is legal there. The subset refuses the names outright (B18): its
   `primary` has no intrinsic to fall back on, and a silent `Call` node named
   `len` would dump a tree no later stage could type.
6. **The statement fallback still names `for`** (P57) although the subset
   refuses `for` with B1 first. The words are the host's, kept byte for byte.
7. **Unreachable host messages are not carried.** `invalid integer literal` /
   `invalid array length` (the host's `strtoull` partial-parse failure) cannot
   happen: the lexer's `Number` grammar guarantees a full parse, and §6.2's
   conversion replaces `strtoull` wholesale. The `for`-clause messages, the
   `@align` messages after B20 fires, and the `cannot read field`-family sema
   messages are likewise absent — the first two because their constructs are
   excluded before the host would reach them, the last because sema is a later
   stage.
8. **The `1 << 63` fold edge is reproduced, not smoothed over.** The host's
   `foldConst` computes `1 << 63` in C++ (where it is `INT64_MIN`) and accepts
   it; the subset's own fold accepts exactly `a` ∈ {0, 1} at a shift count of 63
   and refuses the rest, which is the same set the host's overflow check passes.
9. **The structural nodes (§2.3) and the dump's positions have no host
   counterpart.** The host's AST carries `line`/`col` (P4.1) but has no textual
   form; the subset's dump is the first observable one, and it is what makes §8
   testable.

## 13. The generation contract

`bootstrap/gen_parser_names.py` is the single source of truth for the node kind
numbers and names (§2), the type tags (§2.4) and the packed name tables. It is
deterministic and idempotent, and it emits:

- the **generated region** of `bootstrap/aster.ast`, between the
  `BEGIN GENERATED: parser names` / `END GENERATED` markers: the 25 `E_*`
  constants, the 9 `S_*` constants, the 5 `N_*` constants, the 7 `TY_*`
  constants, and four packed name tables — `entab` (35 records × 16 bytes, the
  host's full `Expr::Kind` list so a kind's record sits at its own number),
  `sntab` (13 records, `Stmt::Kind`), `nntab` (5 records, the structural
  kinds), `tytab` (7 records, the type spellings). A record is the name's bytes,
  NUL-padded to 16; the longest name, `IndexAssign`, is 12 bytes.
- `tests/parser_names.h`: the C twin's `enum`s of the same codes, the same four
  name arrays, and the type enum.

The region is regenerated in place — the generator never touches hand-written
code. `tests/parser-checks.sh` re-runs the generator and asserts the files on
disk are what it produces, so a stale table fails CI rather than the
differential. Before emitting, the generator cross-checks its lists against
`src/aster.cpp` itself — the `enum Kind` inside `struct Expr` and inside
`struct Stmt` — and fails if the subset is not a subsequence of the host's, in
the host's order. Any change to the node set lands in the Python first, then in
`src/aster.cpp` — never the other way round.

### 13.1 Names the bootstrap source must not use

`bootstrap/aster.ast` is compiled by the host compiler, so its identifiers must
avoid the names the host compiler already claims. Besides the 22 keywords, these
are built-ins — a call to any of them is dispatched to the intrinsic unless the
program defines a same-named function, and `sizeof` / `len` are operators
wherever they appear as a callee name:

```
read write openat close fstat mmap brk
load_u8 store_u8 load_u16 store_u16 load_i64 store_i64 load_ptr
sizeof len
```

M3b adds: **`sizeof` and `len` may not be defined or called at all** (§12.5), so
the parser stage keeps them out of its own function names as well. The generated
region owns the `E_`, `S_`, `N_` and `TY_` prefixes; hand-written code must not
define them. The C twin has no such constraint (it is C), but it keeps the same
names for its state where it can, so the two read alike.
