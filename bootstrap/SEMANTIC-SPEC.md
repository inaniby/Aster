# M3c Semantic Specification (frozen)

**Status: frozen for v0.23.45-dev.** This document is the contract for the
third stage of the bootstrap compiler:

- `bootstrap/aster.ast` — the bootstrap compiler, now extended with a semantic
  (type-check) pass over the AST that M3b emits. It reads one Aster source from
  **stdin** and, on success, writes the **same AST dump M3b produced** to
  **stdout**; on failure it writes a **semantic error** to stderr and nothing to
  stdout.
- `tests/parser-twin.c` — the differential oracle, extended with a semantic pass
  that mirrors the bootstrap's: same type rules, same error messages, same dump.

Both are checked byte-for-byte by `tests/parser-checks.sh` (the M3b suite,
extended in M3c with §13–§16). Where this document and an implementation
disagree, this document wins and the implementation is wrong. Where this document
and `src/aster.cpp` (the host compiler's `Sema`) disagree, **`src/aster.cpp`
wins for typing behaviour and this document records the divergence explicitly**
— the bootstrap is a re-implementation, not a port, and every intentional
difference is listed in §12.

M3c **extends** the M3b program rather than replacing it: the lexer and the
parser are unchanged (`bootstrap/LEXER-SPEC.md` and `bootstrap/PARSER-SPEC.md`
remain their contracts). M3c adds a third walk over the AST the parser already
built. On success it re-emits that AST; on failure it reports. The parser's
AST-node contract (PARSER-SPEC.md §2, §3, §8, §9) is unchanged and is the input
to everything here.

---

## 1. Role and invocation

M3c is the semantic / type-check stage. It reads one Aster source text from
**stdin**, parses it (M3a + M3b), type-checks the resulting tree, and either
re-emits the AST dump or reports a semantic error. It performs no code
generation and writes no ELF; it is a **validation gate** ahead of M3d.

```
aster.bin < source.ast > ast.txt      # success: ast.txt == M3b's dump
aster.bin < bad.ast   > /dev/null     # failure: empty stdout, S-error on stderr
```

- **stdin**: the complete source text (LEXER-SPEC.md §3).
- **stdout on success**: the AST dump, **byte-identical to M3b's** (§5). No new
  node, no new field, no reordering.
- **stdout on failure**: **empty** — the two-phase rule (§10) holds: nothing is
  written until the whole program passes the semantic walk.
- **stderr on failure**: one line, `aster: error: <message> at L:C` (§10).
- **exit status**: **0** on success, **1** on any semantic error. `main`
  returns the status.

The subset checked here is the one the bootstrap compiler's own sources need
(`bootstrap/aster.ast`, `stdlib/aster_std.ast`) — five scalar/pointer types, no
structs, no unions, no user-defined types (PARSER-SPEC.md §2.4, §11). Anything
the parser could not produce is out of scope by construction.

## 2. Type vocabulary

The bootstrap has **no `struct`, no `union`, no allocator`**; types are carried
as a tag plus an optional element tag (two `i32`s — PARSER-SPEC.md §3, M3c-PLAN
§4). M3c recognises exactly five types, measured from `bootstrap/aster.ast`
(M3c-PLAN §2):

| tag name | meaning | element |
|---|---|---|
| `i32`  | signed 32-bit integer | — |
| `i64`  | signed 64-bit integer | — |
| `u8`   | unsigned 8-bit byte (memory width 1) | — |
| `ptr`  | raw pointer (storage type `ptr`) | — |
| `ptr<u8>` | pointer to `u8` (the `str`/byte-buffer type) | `u8` |

The parser also accepts the `ptr<i32>` / `ptr<i64>` tags (PARSER-SPEC.md §2.4)
but Aster's own source does not use them; M3c accepts them structurally (they
are the same `ptr` storage with a different element tag) at no extra cost.
`bool`, `u16`, `u32`, `u64`, `struct` are **rejected by the parser** as out of
subset (PARSER-SPEC.md §11) and therefore never reach M3c.

**"bool" in this document** denotes the *boolean-valued* result of a comparison
(`==`, `!=`, `<`, `<=`, `>`, `>=`) or a logical operator (`&&`, `||`, `!`) — a
property of an expression, not a storable type tag. The five storable types
above are the only ones that appear in a `: type` annotation, a signature, or an
`expected`/`got` type-name argument.

Type-name rendering in error arguments uses exactly the five names above
(`i32`, `i64`, `u8`, `ptr`, `ptr<u8>`); `ptr<T>` prints as `ptr<` + element name
+ `>`.

## 3. Symbol table (data model)

The symbol table mirrors the AST's own representation (PARSER-SPEC.md §3):
**parallel fixed `i32` arrays, handle-indexed (0 = none)**, no struct, no
allocator, frames within 8 KB. A symbol is one index into these arrays:

| array | meaning |
|---|---|
| `sname`  | symbol's name token index (→ name text via the token arrays) |
| `skind`  | `FN` / `GLOBAL` / `PARAM` / `LOCAL` / `EXTERN_FN` / `EXTERN_LET` |
| `stag`   | type tag index (one of the five) |
| `selem`  | element type tag (`-1` for a bare scalar/`ptr`, the element for `ptr<T>`) |
| `sowner` | owning function id (0 for top-level) |
| `snext`  | next symbol in the same scope chain |
| `schild0`| first param/local of a function (scope head) |

Scope resolution walks outward from the current function's chain to top level.
All capacities are frozen constants (§9), proven bounded exactly as PARSER-SPEC
§10/§11 proved `C1`/`C2`/`C3`.

## 4. The semantic walk

A single iterative pass over the AST sibling chains (no deep recursion — the
8 KB-frame discipline of the parser). Order:

1. **Top-level collection.** Every `fn` / `let` / `extern fn` / `extern let`
   enters the global symbol table with its signature (param types + return type)
   or its type + initializer. Duplicate *same-kind* names are already rejected by
   the parser (PARSER-SPEC.md P17/P21/P18); M3c does not re-report them.
2. **Declaration checks** (per function): `main must return i32`, `main must not
   have parameters`, `function body cannot be empty`, `a function cannot return
   an array` (S1–S4).
3. **Per-function scope.** Build the scope of `PARAM` + `LOCAL` symbols; resolve
   every `Var` / `Call` / `Index` name; reject undeclared names (S5); reject use
   of a `let` before its declaration (one pass, source order) (S6); reject
   duplicate local names (parser-gated, not re-reported).
4. **Expression typing.** Compute a type for every `E_*` node and enforce operand
   rules (§7): arithmetic on integer types only, comparisons yield bool, logical
   ops on bool, `Index` requires an array/pointer (and pointer indexing is not
   yet supported), `Call` checks the signature against actual arity *and* types
   (S7–S11), `Num` is `i32`/`i64` by value, `String` is `ptr<u8>`.
5. **Statement typing.** `Assign` / `IndexAssign` type-compatibility (S12–S14);
   `If` / `While` / `For` conditions accept any integer or bool-valued
   expression (S15); `Return` type matches the function return (S16); `Expr` is a
   call.
6. **Constant-expression validation.** Global initializers and array lengths must
   be constant (S17–S18).
7. **Capacity limits** (bootstrap-only, §9).

If every check passes, the AST dump is emitted (§5). The first failing check
aborts the walk and becomes the single stderr line (§10).

## 5. Success output — the AST dump contract

**On success, M3c writes exactly the bytes M3b writes** for the same source:
same `Kind line:col` format, same one-line-per-node shape, same fields
(PARSER-SPEC.md §8, §9). M3c adds no annotation, no type column, no new node.
This is the key M3c decision (M3c-PLAN §1): the round is a pure checker, so the
observable success output is *unchanged*, keeping all 312 existing
`parser-checks.sh` PASS lines green and giving the round zero output-format
blast radius.

Consequence: the only *new* observable behaviour M3c introduces is **rejection**
— programs M3b accepted but that are ill-typed now fail with an `S`-error and
empty stdout. The validation corpus is anchored on those rejections; the
accepts must stay byte-identical.

## 6. Semantic error catalog (S1–Sn)

Format: `aster: error: <base> at L:C` — the base string below is what the
bootstrap stores; `die_at` appends ` at L:C` from the **anchor token** named in
the *position* column. Exit status is **1** and stdout is **empty** for every
entry. Messages are byte-pinned; the twin must emit them identically.

| id | base message | anchor token | notes |
|---|---|---|---|
| **S1** | `main must return i32` | the `main` function's `fn` token | host `src/aster.cpp:2156` |
| **S2** | `main must not have parameters` | the `(` of `main`'s param list | host `:2165` |
| **S3** | `function body cannot be empty: <name>` | the `{` opening the body | host `:2158` |
| **S4** | `a function cannot return an array: return ptr<T>, or take the array as a parameter and let the caller's storage be written through` | the `return` keyword | host `:2153` |
| **S5** | `unknown variable: <name>` | the use site (the name token) | host `:3147/:4050` |
| **S6** | `call to undeclared function: <name>` | the call site (callee token) | host `:3374/:6064` |
| **S7** | `cannot call through '<name>': it is an array` | the call site | host `:6054/:6059` |
| **S8** | `cannot call through '<name>': expected a function pointer (ptr), got <T>` | the call site | host `:6056/:6062` (non-array, non-fn) |
| **S9** | `wrong argument count calling <name>: expected <N>, got <M>` | the call site | host `:3394/:6074/:6088` |
| **S10** | `argument type mismatch calling <name> at argument <K>: expected <T>, got <U>` | the call site | host `:3403/:3406/:3408` |
| **S11** | `type mismatch assigning variable: <name>` | the assignment's `=` | host `:4747/:4749` (ptr/bool/value mismatch) |
| **S12** | `cannot assign to an array as a whole: <name>` | the assignment's `=` | host `:4735/:4756/:6258` |
| **S13** | `cannot index non-array variable: <name>` | the `[` of the index | host `:3831` |
| **S14** | `pointer indexing is not supported yet` | the `[` of the index | host `:2691/:3513/:4802` |
| **S15** | `condition must be a comparison, a bool expression, or an integer` | the `if`/`while`/`for` keyword | host `:4508/:6133` |
| **S16** | `return type mismatch in function <name>: expected <T>, got <U>` | the `return` keyword | host `:4530/:4549/:4551/:4553` |
| **S17** | `array initializer type mismatch: expected <T>, got <U>: <name>` | the `=` of the initializer | host `:4650/:6151/:6155` |
| **S18** | `array initializer must be a constant expression: <name>` | the `=` of the initializer | host `:4646/:6167` |
| **S19** | `global variable initializer must be a constant expression` | the `=` of the initializer | host `:1738` |
| **S20** | `'!' requires a bool operand` | the `!` | host `:4412/:5933` |
| **S21** | `too many local declarations (limit <N>, including parameters)` | the offending `let`/param token | host `:4585/:4700/:4989` |
| **S22** | `cannot return a local array (its frame storage does not outlive the call): <name>` | the `return` keyword | host `:4521/:6359` |

`<name>` is the identifier text, `<N>`/`<M>` decimal arities, `<K>` the 1-based
argument position, `<T>`/`<U>` the five type names of §2. Host line numbers are
the anchor in `src/aster.cpp`; the bootstrap's base string is the contract.

## 7. Expression typing rules

Per `E_*` node, in source order, computing a type:

- **`Num`** → `i32` if the literal fits 32-bit signed, else `i64` (LEXER-SPEC.md
  §9 number ranges). **`String`** → `ptr<u8>`. **`Var`** → the symbol's type
  (S5/S6 if unresolved). **`(expr)`** → the inner type.
- **Unary `-`** → integer type of operand; operand must be `i32`/`i64`/`u8`.
  **Unary `!`** → boolean-valued; operand must be bool-valued (S20).
- **Binary arithmetic** (`+ - * / %` and the shifts `<< >>`) → integer type of
  the operands; **both operands must be integer types** (no `bool`, no pointer
  arithmetic). The result type is the wider of the two (`i64` if either is
  `i64`, else `i32`; `u8` widens to `i32` for arithmetic).
- **Relational / equality** (`< <= > >= == !=`) → boolean-valued; operands
  comparable (both integer, or both `ptr` of the same element).
- **Logical** (`&& ||`) → boolean-valued; both operands boolean-valued.
- **`Index`** (`a[e]`) → the element type of `a`; `a` must be an array or
  pointer; **a bare `ptr`/`ptr<u8>` indexed is S14** (pointer indexing not yet
  supported); a non-array, non-pointer `a` is S13.
- **`Call` / `FieldCall`** → the callee's return type. The callee must resolve to
  a function (S5/S6 if not; S7 if an array; S8 if a non-function value); arity
  must match (S9); each argument's type must match the parameter's (S10).

Type mismatches that reach an `Assign`/`let` initializer surface as S11/S17; a
mismatch that reaches a `Return` surfaces as S16.

## 8. Statement typing rules

- **`Assign`** (`x = e;` / `x[e] = e;`): the assigned type must equal the
  right-hand type. Whole-array assignment (`x = ...` where `x` is an array) is
  S12. Element assignment (`x[e] = ...`) requires `x` to be an array (S13 if
  not). A type mismatch (e.g. `i32` vs `u8`, or any non-assignable pair) is S11.
- **`If` / `While` / `For`**: the condition must be a comparison, a bool-valued
  expression, or an integer (0 = false, non-zero = true) — S15 otherwise.
- **`Return`**: the returned expression's type must equal the enclosing
  function's declared return type (S16); a function returning an array is S4;
  returning a local array is S22.
- **`Expr`** (expression statement): must be a `Call` (`CallStmt`).
- **`Break` / `Continue`**: valid only inside a loop (parser-gated).

## 9. Capacity limits (bootstrap-only)

Fixed global arrays bound every table. Each limit is a frozen constant; a
pathological input fails cleanly with the named error rather than overrunning a
buffer (the same defensive posture as `C3` in M3b).

| gate | value | error |
|---|---|---|
| symbol-table size | 4096 symbols | `too many symbols` (new S23) |
| scope depth | 96 (shares parser `C2`) | `scopes nest too deeply (limit 96)` (new S24) |
| local declarations / function | 500, including parameters | S21 |
| type nesting (ptr depth) | 16 | `type nests too deeply` (new S25) |
| identifier length | lexer name buffer (≤ per-token cap) | lexer `E`-error already |

`S23`/`S24`/`S25` follow the same format as §6; they are listed here once and
added to the catalog. In normal Aster source these are unreachable (the node and
token ceilings `C1`/`C2`/`C3`/`E9` gate them first), but they are pinned so a
fuzzed input fails predictably.

## 10. Two-phase rule, stderr format, exit status

- **Nothing is written to stdout until the semantic walk completes successfully.**
  A semantic error leaves stdout byte-empty, exactly like a parse error.
- **stderr**: a single line `aster: error: <base> at L:C` where `<base>` is the
  §6/§9 text and `L:C` is the anchor token's 1-based line:column (LEXER-SPEC.md
  §4 position semantics — tab counts as one column, a token's position is its
  first byte).
- **exit status**: `0` on success, `1` on any semantic error. `main` returns it.
- Multiple semantic errors in one program: the walk reports the **first** in
  source order and stops; the suite pins each `S`-diagnostic on a *minimal
  complete program* so exactly one error fires.

## 11. Frozen examples

These are the contract's golden cases; `tests/parser-checks.sh` extracts them
from this section at runtime (the spec is the single source of truth, as in
M3b §9). `<dump>` denotes the byte-identical M3b AST dump; `<Sxx>` denotes the
§6 error. For the accept cases the dump must equal the dump M3b already produced
for the same source (verified byte-for-byte). For the reject cases the message
text, exit status 1 and empty stdout are pinned here; the exact `L:C` is the
anchor token's position as the bootstrap's lexer computes it, taken from the
actual run during extraction (the anchor token is named in each case).

### 11.1 Accept — well-typed, dump == M3b

```
fn add(a: i32, b: i32) -> i32 { return a + b; }
fn main() -> i32 { let x: i32 = 1 + 2 * 3; return x; }
```
→ stdout: `<dump>` (byte-identical to `parser-checks.sh` §9.1's frozen dump);
rc=0; stderr empty.

```
extern fn write(fd: i32, buf: ptr<u8>, n: i32) -> i32;
let tab: i32[4] = 0;
fn main() -> i32 {
    let i: i32 = 0;
    let s: ptr = "a\tb";
    tab[i] = i * 2;
    return write(1, s, 3);
}
```
→ stdout: `<dump>`; rc=0; stderr empty.

### 11.2 Reject — ill-typed, empty stdout + S-error

```
fn main() -> i64 { return 0; }
```
→ S1 `main must return i32` at `1:1`; rc=1; stdout empty.

```
fn main(a: i32) -> i32 { return 0; }
```
→ S2 `main must not have parameters` at the `(` of `main`'s params; rc=1.

```
fn f(x: i32) -> i32 { return x + y; }
fn main() -> i32 { return f(1); }
```
→ S5 `unknown variable: y` at the `y` name token (line 1); rc=1.

```
fn f(x: i32) -> i32 { return x; }
fn main() -> i32 { return f(1, 2); }
```
→ S9 `wrong argument count calling f: expected 1, got 2` at the call site (the
callee `f` token); rc=1.

```
fn f(x: ptr) -> i32 { return 0; }
fn main() -> i32 { return f(1); }
```
→ S10 `argument type mismatch calling f at argument 1: expected ptr, got i32` at
the call site; rc=1.

```
fn main() -> i32 { let x: i32[4] = 0; x = 1; return 0; }
```
→ S12 `cannot assign to an array as a whole: x` at the `=`; rc=1.

```
fn main() -> i32 { let x: i32 = 0; if (x) { return 1; } return 0; }
```
→ accepted (condition is an integer); rc=0. Contrast:
```
fn main() -> i32 { let x: i32 = 0; if (x + 1) { return 1; } return 0; }
```
→ accepted (integer-valued condition). A non-comparison, non-integer,
non-bool condition (e.g. `if ("a")`) is S15.

## 12. Divergences from the host (intentional)

Every difference from `src/aster.cpp`'s `Sema` is listed; all are consequences
of the bootstrap being a re-implementation over fixed arrays with a 5-type
subset.

1. **No `struct` / `union` / user types.** The host's struct literal, field
   access, `struct<S>` pointer, and `unknown struct`/`has no field` checks do not
   exist in M3c — the parser refuses those spellings (PARSER-SPEC.md §11).
2. **No `bool` / `u16` / `u32` / `u64` storable types.** The host accepts them;
   the parser refuses them as out of subset. "bool" in M3c messages is the
   boolean-valued *property* of comparisons/logical ops (§2), not a type tag.
3. **Success re-emits the AST dump, not an IR.** The host's `Sema` produces an
   internal typed tree consumed by `gen`; M3c emits the *untyped* dump M3b
   already produced, because M3c is a pure gate this round (M3c-PLAN §1). M3d
   rebuilds type tables from this AST.
4. **Arity ceiling is 32, not 500.** The parser gates parameters/arguments at 32
   (PARSER-SPEC.md P50); M3c's `S21` local-declaration limit is the host's 500
   *concept* but the bootstrap's array size may differ — the message text pins
   the concept, the number is the bootstrap's frozen constant.
5. **No overloads, no generics, no modules.** Single flat global namespace; the
   host's same-kind duplicate detection (PARSER-SPEC P17/P21/P18) is the only
   collision check and runs in the parser, not here.

## 13. Twin and suite obligations

- The twin (`tests/parser-twin.c`) gains a semantic pass using a real C struct
  array + array-indexed symbol table (the independence the differential needs).
  Its outputs are byte-identical to the bootstrap's: same dump on accept, same
  `S`-error bytes on reject.
- `tests/parser-checks.sh` gains §13 (the §6 catalog, exact message + position +
  rc=1 + empty stdout, on minimal complete programs), §14 (an accept/reject
  differential corpus), §15 (self-semantic: run the stage over its own source
  and the library — the dump must be **byte-identical to M3b's**), and §16
  (semantic mutation probes, each asserted to diverge from the twin).
- Frozen examples (§11) are extracted from this document at runtime; the spec
  wins on any disagreement.
- **No compiler change** in this round → the A/B baseline stays **330 lines,
  byte for byte** (`tests/rebuild-baseline-v0.23.45.sh`).

---

*Frozen before any semantic code was written. The discipline that caught two
real bootstrap bugs in M3b (P50 position, P37/P40 name pollution) is repeated
here: the contract is the source of truth, the twin is the oracle, and the
mutation probes must each be able to fail.*
