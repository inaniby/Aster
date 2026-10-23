# Aster language subset v0.18.1

```aster
let counter: i32 = 0;
let limit: i32 = 100;
let buffer: i32[4] = 0;

fn main() -> i32 {
    counter = counter + 1;
    buffer[0] = counter;
    return add_values(buffer[0], limit - 59);
}

fn add_values(a: i32, b: i32) -> i32 {
    return a + b;
}
```

Function definitions use `fn name(arg: i32, ...) -> i32 { ... }`. The initial pointer ABI slice also accepts `ptr` parameter and return types, and `let name: ptr = expr;` local bindings. Calls use `name(expr, ...)`; calls to functions with any `ptr` parameter or a `ptr` return type are currently rejected from Aster code. `main` is the program entry and must have no parameters; it is emitted as ELF symbol `_start`. Other functions are global function symbols and can be defined in another `.ast` file compiled to `.o`. Cross-file callers should declare external signatures with `extern fn name(arg: i32, ...) -> i32;`.

The first eight arguments are passed in AArch64 registers `w0`–`w7`; `w0` carries the return value. Each function copies incoming parameters to its stack frame. Non-entry functions save and restore `x30`, enabling nested calls and recursion.

## Global variables

A declaration at file scope, `let name: i32 = <expr>;`, defines a global variable that every function in the file (and, with a matching `extern let` declaration, other files) can read and write.

- A **constant** scalar initializer — integer literals, unary minus, and `+ - * /` over constant sub-expressions — is folded at compile time. Any other scalar initializer is a **run-time initializer**: it may read other globals, call functions and use arithmetic, and is compiled into the `__aster_init` routine instead of being rejected (see *Run-time initializers* below).
- Constant folding uses the same 32-bit semantics as the runtime: the folded value is truncated to `i32`.
- **Placement:** if the folded value is `0` the global is emitted into `.bss`; the linker supplies the zero bytes. Otherwise the global is emitted into `.data` with its four-byte little-endian value. Both are decided at compile time, so `let x: i32 = 0;` and `let x: i32 = 1 - 1;` both land in `.bss`.
- An array declaration puts a length after the type: `let buf: T[8] = <const>;`. **Since v0.23.28-dev `T` is any type** — `bool`, a struct, `ptr`, or any integer width; until that round it had to be an integer, so `bool[4]`, `Point[4]` and a local `ptr[4]` did not parse. **Since v0.23.31-dev one `[N]` per dimension may follow it** — `let grid: i32[2][3] = 0;`, `let cube: i32[2][2][2] = 0;` — and the existing length bounds check then applies to the *total* element count (see *A second subscript* below). Its initializer must be a constant expression; `0` places the array in `.bss`, any other constant fills every element in `.data`.
- `@align(N)` after the type (and optional length) sets a global's alignment: `let buf: i32[8] @align(64) = 0;`. `N` must be a power of two and at most 4096.
- A global whose name already exists in the file is a compile error (`duplicate global variable: name`); a global whose name equals a function name in the same file is a compile error (`global variable conflicts with function: name`).
- `extern let name: i32;` declares a global defined in another object file. Using a global that is neither defined nor declared `extern` is a compile error (`unknown variable: name`); leaving an `extern let` unresolved is a link error (`undefined global variable symbol 'name'`).
- A global defined in two linked objects is a link error (`duplicate global symbol 'name' across input objects`).

### Access and shadowing

Each global access materializes the symbol address with a page-relative `ADRP` + `ADD` pair into `x16`, then loads or stores through it:

```
adrp x16, name             ; R_AARCH64_ADR_PREL_PG_HI21
add  x16, x16, :lo12:name  ; R_AARCH64_ADD_ABS_LO12_NC
ldr  w0,  [x16]            ; or  str w0, [x16]
```

`x16` is reserved for this purpose and is never used as an expression temporary (`w0`–`w15`); the address is always materialized immediately before the access, so no live temporary is affected.

**Shadowing rule:** a function parameter or a local `let` may reuse a global's name. Within that scope the local binding wins, and when the scope ends the global is visible again. A global and a global of the same name cannot coexist in one file, and a global cannot share a name with a function.

Statements: local declaration (`let name: i32 = expr;`, `let name: ptr = expr;`, `let name: bool = expr;` since v0.22.51-dev, the wider integer types `i64`/`u8`/`u16`/`u32` since v0.23.2-dev, since v0.22.49-dev `let name: i32[LENGTH] = <const>;`, since v0.23.31-dev `let name: T[N][M] = <const>;` — one `[N]` per dimension — and since v0.23.29-dev `let name: S;` — a struct local with no initializer, zero-filled), assignment, array/pointer element assignment (`buf[index] = expr;`, `p[index] = expr;`), struct array-field element assignment (`s.f[index] = expr;`, `s.f[i].g = expr;` since v0.23.29-dev), multi-dimensional element assignment (`a[i][j] = expr;` since v0.23.31-dev — one subscript on a multi-dimensional array addresses a **row**, and a row may not be stored to), return, if/else, `else if` chains (since v0.22.51-dev), while, for (since v0.22.50-dev), break, and continue. `else` is optional (since v0.23.22-dev; it was mandatory before). `break` exits the innermost loop; `continue` starts its next iteration check — for a `while` that is the condition, for a `for` it is the step (see *Loops*). Both are compile errors outside a loop. Each if/else branch, loop body, and `for` header introduces a lexical scope; declarations can shadow outer bindings, and a variable declared in a `for` initializer is not visible after the loop.

Expressions: decimal integer literals (which include the null pointer constant `0` in a ptr context, v0.23.26-dev), variables, function calls, array element access `buf[index]`, pointer element access `p[index]` (since v0.22.49-dev), multi-dimensional element access `a[i][j]` and a row `a[i]` as a `ptr` value (since v0.23.31-dev; see *A second subscript*), parentheses, unary minus, `+ - * /`, the `bool` literals `true`/`false` (since v0.23.25-dev), and since v0.22.51-dev the logical operators `&&`, `||` and `!`, and since v0.23.30-dev the address of a **whole array** — `&buf`, `&gbuf`, `&s.cells` — which is a strided `ptr<T>` carrying the element width (any element type; see *An array has an address*); since v0.23.34-dev an array parameter `T[N]` decays to that same `ptr<T>`. Precedence, loosest to tightest: `||` < `&&` < comparisons < `+ -` < `* /` < unary `-` `!` `~` `*` `&` < postfix `.` `[]` `()`. That ordering is the implementation's since **v0.23.27-dev** — until that round `&&` and `||` shared one level and the prefix operators bound tighter than `.`, so this file was describing a grammar the compiler did not have. Comparisons `== != < <= > >=` are signed 32-bit and yield a `bool`; they are ordinary expressions (see *Booleans and logical operators*). A chain of comparisons **within one level** (`a < b < c`, `a == b == c`) is still rejected — combine comparisons with `&&` / `||` instead — while a level crossing (`a < b == c`) is legal since v0.23.27-dev. See *Expression precedence and binding*.

Implementation limits: at most 500 parameter-plus-local slots per function, 32 parameters/arguments, 16 simultaneously live expression temporaries, and 124 levels of nested calls within argument expressions. Each function reserves an 8 KiB stack frame for locals, caller-save spill space, and argument scratch slots. Arithmetic is 32-bit wrapping; division by zero and signed overflow are unchecked. Definite-return analysis is conservative; loops are not assumed to execute.

### Compilation order (v0.23.0-dev)

Type checking is a pass of its own (P3.1) and runs **before** code generation:
each emitted function is walked with its own scope stack and every expression is
classified as `i32`, `u32`, `u8`, `u16`, `i64`, `ptr` or `bool` (the unified
`Ty` lattice, v0.23.2-dev); the declaration, assignment, indexing,
dereference, call and return rules — and the constant-folded array bounds check —
are enforced there, with the diagnostics listed above. Code generation still
carries the same checks as a backstop, so a rejected program emits nothing and
no rule is lost by the move. The only visible consequence is ordering: a type
error is reported instead of a later codegen diagnostic (for example
`may fall through without returning i32`), which is what
`tests/sema-checks.sh` [3/6] asserts.

### Fixed-length arrays

`let buf: T[LENGTH] = <const>;` declares a global array of `T`; `LENGTH` is a decimal integer between 1 and 1048576 (`array length must be between 1 and 1048576: name` otherwise).

**The element type is the type written before the `[N]`** (v0.23.28-dev). `T` may be `i32`, `u32`, `i64`, `u8`, `u16`, `bool`, `ptr` or a struct:

| `T` | bytes per element | initializer | notes |
| --- | --- | --- | --- |
| `i32` / `u32` | 4 | a constant integer | the pre-existing case |
| `i64` | 8 | a constant integer | `LDR X`/`STR X` |
| `u8` / `u16` | 1 / 2 | a constant integer, range-checked | `LDRB`/`LDRH` |
| `bool` | 4 | `true`/`false`, or the constant `0`/`1` | a 4-byte 0/1 slot, like a `bool` scalar; an element is a condition (`if (flags[2])`) |
| `ptr` | 8 | the null constant `0`, or an address (`&cell`) | an element answers `==`/`!=` |
| a struct `S` | `sizeof(S)` | a constant aggregate `S { … }` | every element is a copy of the aggregate |

An element is addressed as `base + index * sizeof(T)`. When `sizeof(T)` is a power of two that is one `ADD … UXTW #log2(size)`; **when it is not** — a struct's size is a multiple of its alignment and need not be a power of two, and `{ i32, i32, i32 }` is 12 — the scale is a **multiply** (`UMADDL X16, Wsize, Windex, X16`). (AArch64's extended `ADD` cannot be used to widen the index here: in `ADD Xd, Xn, Wm, UXTW #sh` the field `Rn == 31` is the **stack pointer**, not `XZR`, so `ADD X16, XZR, Widx, UXTW #0` adds `SP`.)

- `buf[index]` reads one element and `buf[index] = value;` writes one. The subscript is an arbitrary `i32` expression, scaled by the 4-byte element width and added to the base, which is still materialized with `ADRP`+`ADD`:

```
adrp x16, buf                ; R_AARCH64_ADR_PREL_PG_HI21
add  x16, x16, :lo12:buf     ; R_AARCH64_ADD_ABS_LO12_NC
add  x16, x16, w_index, uxtw #2   ; base + index*4
ldr  w0,  [x16]              ; or  str w0, [x16]
```

- A subscript that folds to a constant (literals and `+ - * /` over them, including negative results) is **bounds-checked at compile time** since v0.22.48-dev: an index below 0 or at/after `LENGTH` is a compile error (`array index out of bounds for 'buf': index 4, length 4`), on the read and the write path alike.
- A dynamic subscript is unchecked by default — it accesses whatever memory follows the array. `--bounds-check` (since v0.23.1-dev, opt-in) lowers every dynamic subscript into a fixed-size array to a length test that traps instead: see *Run-time bounds checking* below.
- The initializer is a constant expression. `0` places the array in `.bss`; a non-zero constant is broadcast to every element in `.data`. A non-constant array initializer is a compile error (`array initializer must be a constant expression: name`).
- Arrays are `STT_OBJECT` symbols of size `4 * LENGTH`; `extern let buf: i32[LENGTH];` references an array defined in another object.
- Since v0.23.34-dev an array **may be a parameter** — `fn sum(a: i32[4])` decays the argument to a strided `ptr<i32>` and `a[i]` scales by the element width; the parameter carries no length in the addressing tables, so a default build treats a parameter subscript exactly as C does — unchecked. **Since v0.23.36-dev `--bounds-check` extends to parameters**: the same `CMP/` `B.LO`/`BRK #1` trap is emitted for an out-of-range run-time `a[i]` (read or write), and a multi-dimensional `a[i][j]` is checked per dimension, because the parameter's dimensions already feed the existing per-dimension walk. A constant out-of-range subscript (`a[4]`) is still rejected at compile time, flag or not. An array **may be returned indirectly** through a typed pointer: a function whose return type is `ptr<T>` gives back the array's address with its stride intact. An array **still may not be used as a whole by value**: returning the array from an `i32` function or assigning it to an `i32` variable is still a type error (`return type mismatch in function main` / `type mismatch assigning variable: name`), and `buf = ...` is still `cannot assign to an array as a whole: buf`.
- Since v0.22.49-dev the same array type also exists **inside functions**: `let buf: i32[LENGTH] = <const>;` declares a local array in the 8 KiB stack frame (see *Local arrays and pointer indexing* below).

### Run-time initializers

A scalar global whose initializer is not a constant expression gets a **run-time initializer**. The compiler generates one internal routine per unit, `__aster_init`, holding those assignments, and the unit that defines `main` calls it from `_start` before the first user statement. The routine is emitted only when a non-constant initializer exists, so a program without one is byte-for-byte identical to v0.15.0.

Order: within one object, run-time initializers run in **source declaration order**. Across objects, each object's `__aster_init` invokes, through `__aster_init_next`, the next object's routine in **command-line link order** (`link-obj a.o b.o` runs a's initializers, then b's); the final routine returns through a synthesized `RET`. Reading a global whose run-time initializer has not run yet observes its zero initial value — the compiler performs no cross-object dependency inference. Because the call is emitted only by a unit that has its own run-time initializers, cross-object initialization requires the entry object to declare at least one.

For shared objects (`build-so`), which have no `_start`, the generated routine is additionally published through `DT_INIT_ARRAY`/`DT_INIT_ARRAYSZ` (with an `R_AARCH64_RELATIVE` relocation on the array) and runs during `dlopen`.

### Alignment

`@align(N)` requests `N`-byte alignment for a global. `N` must be a power of two and at most 4096; otherwise it is a compile error (`alignment must be a power of two: name`, `alignment must not exceed 4096 bytes: name`). The alignment is honoured in the offset inside `.data`/`.bss`, the symbol's `st_value`, and the section's `sh_addralign`; the linker aligns each input object's contribution to its section alignment so the requested alignment survives linking.

## Local arrays and pointer indexing (v0.22.49-dev)

A function body may declare `let buf: T[LENGTH] = <const>;` (1 to 1000 elements; `@align` is still global-only). **Since v0.23.28-dev `T` is any type** — before that round the `[N]` suffix was opened only after an integer type, and `ptr[LENGTH]` was refused with `local pointer arrays are not supported: name`. The array lives in the function's 8 KiB frame: elements are packed `sizeof(T)` bytes apart inside the 8-byte-per-slot local grid, so `LENGTH` elements of a 4-byte type occupy `ceil(LENGTH / 2)` slots (element `i` sits at byte offset `slot*8 + i*sizeof(T)` from `SP`). A struct element occupies `sizeof(T)` contiguous bytes per element, so a `Triple[3]` (12 bytes each) takes 9 slots. The initializer must be a constant expression and is broadcast to every element with one store per element at the declaration point — a `let` inside a `while` body therefore re-initializes each pass.

```
add  x16, sp, #slot*8           ; frame base of the local array
add  x16, x16, w_index, uxtw #2 ; base + index*4
ldr  w0,  [x16]                 ; or  str w0, [x16]
```

The frame base uses the `sh=0` `ADD (immediate)` encoding so the offset is
exactly `slot*8`. v0.22.50-dev fixed a v0.22.49-dev regression where this
instruction was emitted with the `sh` bit set, scaling the offset by 4096 —
invisible while the array sits in slot 0, writing far outside the 8 KiB frame
at any other slot. `tests/local-array-checks.sh` [8/8] is the regression.

- Constant subscripts are bounds-checked exactly like global arrays (`array index out of bounds for 'buf': index 4, length 4`), and shadowing picks the innermost declaration: a local `let g: i32[2]` inside a scope makes `g[5]` an error even when a global `i32[8]` named `g` exists.
- The array name decays to its frame address (a `ptr` value) wherever an expression is expected, so it can be passed to a `ptr` parameter or bound to a local `ptr`. Returning the array itself is rejected (`cannot return a local array (its frame storage does not outlive the call): buf`) because the frame dies with the function; returning an **element** stays legal.
- Assigning the array as a whole is `cannot assign to an array as a whole: buf`; indexing a non-array local is `cannot index non-array variable: name`.

### An element is a value of its own type (v0.23.28-dev)

`a[i]` is typed as the array's **element type**, not as `i32` — until this round `Sema::typeOf` answered `i32` for every subscript while codegen loaded and stored at the element's real width, so `let q: Point = a[1];` was a type error against itself. From that one sentence follow the rest of the element rules:

- `a[i]` may initialize, be assigned to, and be passed as **anything of the element's type**: `let q: Point = pts[1];`, `let n: i64 = wide[0];`, `take(flags[1])`.
- An element is an **lvalue**, so `&a[i]` is a `ptr<T>` (a struct element only — `&` has always been defined for a struct lvalue alone) and `a[i].f = v` stores through one. Since v0.23.30-dev `&` also takes the address of a **whole array** (`&buf`, `&s.cells`), which is a different thing and a different type — see *An array has an address* below. The dispatch that tells `a[i].f = v` from `a[i] = v` matches the brackets **by depth**, because the subscript is an arbitrary expression and may contain one: `p[i[0]].x = 4`.
- A **whole struct element is not a value**: a struct has no register form, so it is read field by field, copied as a whole (`let c: Point = a[1];`), or reached through `&a[i]`.
- A `bool` element is a **condition** (`if (flags[2])`, `while (seen[i])`), and is stored as the 4-byte 0/1 slot a `bool` scalar has always been. `f[0] = 2` is a type error.
- A `ptr` element takes the null constant `0` or another address, and answers `==`/`!=` like any ptr. `s[0] = 7` is a type error.
- The compile-time bounds check, the run-time one (`--bounds-check`) and the element's scale all come from the same place, `emitElemAddr`, so no path can disagree with another about where an element lives.
- **Since v0.23.29-dev the same rules govern a struct's array *field*** — `s.f[i]` is an element of the field's element type, an lvalue, scaled by the same shift-or-`UMADDL` rule and bounds-checked against the field's own length. See *An array field* under Structs.

`p[i]` on a **ptr-typed local or parameter** is `*(p + i*4)` — one `i32` element stride — on the read and the write path (`p[i] = v`). The base is loaded from its frame slot into `x16` after the index is evaluated, then the same `ADD X16, X16, W(index), UXTW #2` scaling applies:

```
ldr  x16, [sp, #slot*8]         ; the ptr variable's value
add  x16, x16, w_index, uxtw #2 ; base + index*4
ldr  w0,  [x16]                 ; or  str w0, [x16]
```

A ptr subscript or a ptr value stored through `p[i]` is rejected (`pointer indexing is not supported yet` / `pointer indexing/assignment is not supported yet`), matching the pre-existing pointer rules. Dynamic pointer subscripts carry no bounds information and are not checked.

### An array has an address (v0.23.30-dev)

`&` may be applied to a **whole array** — a local `T[N]`, a file-scope `T[N]`, or a
struct's array field — and the result is a **strided `ptr<T>`**: the address of
the array's first element, carrying the element's byte width. It can be stored
in a `ptr<T>`, passed to a `ptr<T>` parameter, and written through; because the
result carries the stride, `(&arr)[i]` scales by `sizeof(T)` and is legal. This
is what lets a function touch an array of **any** element type that is not a
global:

```aster
struct Row { cells: i32[4] }
let gscores: i32[4] = 11;              // a file-scope array

fn sum4(p: ptr<i32>) -> i32 { … return t; } // reads four i32 elements
fn fill(p: ptr<i32>, v: i32) -> i32 { … }   // writes four, and the caller sees it

fn rowSum(pr: ptr<Row>) -> i32 {
    let p: ptr<i32> = &pr.cells;       // an array field, behind a ptr<Row>
    return sum4(p);
}

fn main() -> i32 {
    let buf: i32[4] = 7;
    let row: Row;
    let p: ptr<i32> = &buf;            // the address itself, kept in a variable
    return sum4(&buf) + sum4(&gscores) + rowSum(&row);
}
```

Three properties of this are worth stating, because two of them are
counter-intuitive:

- **The address was already there.** A named array is decayed at declaration —
  a local `T[N]`'s binding type *is* `ptr`, and `gen(Var)` has always materialized
  its frame address (`ADD Xd, SP, #slot*8`), which is what "the array name decays
  to its address in an expression" means. A global's address is materialized by
  `emitGlobalAddress`, and a struct array field's by `emitStructAddr`. So the
  round adds **no instruction and no parser rule**: `&buf == buf` holds as an
  address, and the only thing missing was a rule letting `&` ask.
- **"Is this an array?" is answered by length, not by type.** Because the array
  is decayed, an `i32[4]` and a `ptr` are the same type, so the question cannot
  be asked of the type. `arrayOperandOf()` asks whether the operand *has a
  length* — a local binding's, a file-scope array's, or a `StructField`'s — and
  that is the whole test.
- **The result is a `ptr<T>` carrying the stride, not a plain `ptr`.** Before
  v0.23.34-dev the answer was a plain `ptr` gated to 4-byte elements, which
  silently mis-scaled wider or narrower arrays. The strided `ptr<T>` keeps the
  element width so `p[i]` is `*(p + i*sizeof(T))`. A plain `ptr` (stride 4) is
  still accepted only when `sizeof(T) == 4`; storing a wider or narrower array
  address into a `ptr` is refused with `cannot store a pointer to <T> elements in
  ptr: 'p' would index it at 4 bytes — declare it ptr<T>, or take the array as a
  parameter` (v0.23.34-dev). The struct branch of `&` is untouched and still
  answers `ptr<S>`.

**The decayed address is a live capability.** Because the result is a `ptr<T>`,
`(&buf)[i]` — taking the address and subscripting it in one expression — is
legal and scales by `sizeof(T)`, not hard-coded 4. The postfix parser accepts a
subscript directly after `&`, so `(&w)[0]`, `(&w)[1]`, `(&w)[2]` read `w`'s
first three elements with no intermediate variable. (A subscript after a plain
`ptr` value still scales by 4.)

**An array may now be a parameter or a return.** Since v0.23.34-dev a parameter
written `T[N]` **decays to `ptr<T>`** at the call boundary — `fn sum(a: i32[4])`
receives the argument's decayed address and `a[i]` scales by `sizeof(T)`. There
is no length, so a parameter subscript is unchecked (no `--bounds-check`, no
compile-time fold). The same decayed `ptr<T>` is the type a function **returns**
when its return type is written `ptr<T>`: `fn first(w: i32[3]) -> ptr<i32>` hands
back `&w` with the stride intact, and the caller binds it to `ptr<i32>`. An array
is still **not usable as a whole by value** — `return buf;` from an `i32` function
and `buf = ...` are still rejected exactly as before.

### A second subscript: multi-dimensional arrays (v0.23.31-dev)

Since v0.23.31-dev a declaration may write **one `[N]` per dimension** —
`let grid: i32[2][3] = 0;`, `let cube: i32[2][2][2] = 0;`, `struct Grid { cells: i32[2][3] }` — at every site a one-dimensional array already parses: a local, a file-scope global (all three of `globalDeclaration()`'s branches), and a struct field. The bounds the one-dimensional spelling has always applied now check the **total** element count (`i32[1000][1000]` is refused exactly as `i32[1000000]` is, and `i32[0][3]` is refused where the length is read), and `count` — what the frame reservation, the broadcast initializer, `.data`/`.bss` sizing and `layoutStruct` consume — stays the total element count, so nothing about storage or layout changes shape.

**No new type carries it.** An array name already decays to a `ptr` (v0.23.30-dev made that address reachable by name), so a row address is the same decay one level in:

| Expression | Type | Meaning |
| --- | --- | --- |
| `grid` | `ptr` | the whole 2×3 block |
| `grid[i]` | `ptr` | **a row** — the address of `M` elements |
| `grid[i][j]` | `i32` | the element |

The consequence is the feature's whole content, and it is a question of **stride**:

```
stride(dimension k) = dims[k+1] * … * dims[L-1] * sizeof(elem)
```

For the innermost subscript that is `sizeof(elem)` — the one stride a one-dimensional array has always had, which is why no program that does not write a second subscript changes by a byte — and for an outer one it is the product of the dimensions below it: **12** for a row of a 2×3 `i32` grid, **24** for a row of a 2×3 `i64` one, **4** for a row of a 2×3 `u8` one. A three-dimensional `cube[i][j]` has its middle subscript stride by the innermost length times the element size, and its outermost by everything below.

- **One chain shape** serves assignment and expression alike: the array's name rides on the innermost `Index` node and each subscript above it is another `Index`, so `a[i][j] = v` and `a[i][j]` reach the same address computation, and a single subscript still comes back from the parser as itself — the one-dimensional path is untouched.
- **Every subscript is checked.** Dimension *k*'s bounds come from `dims[k]`, so `a[2][0]` on an `i32[2][3]` reports `array index out of bounds for 'a': index 2, length 2` and `a[0][3]` reports `array index out of bounds: index 3, length 3`. The walk covers *every* level, not just the outermost: an inner `bool` subscript (`a[0][true]`) is as illegal as an outer one, which is the hole the first version of this round had.
- **A chain may not run past the innermost dimension.** `a[0][1]` on an `i32[3]` is `too many subscripts for 'a': it has 1 dimension`, and the same refusal names a global or a field (`too many subscripts for 'g': it has 1 dimension`, `… for field 'xs': …`).
- **A chain may stop short, and what it addresses is a row.** A row is an ordinary `ptr` value: it may be read, bound to a `ptr` variable, and handed to a `ptr` parameter — the exact route `&buf` opened in v0.23.30-dev:

```aster
fn rowSum(p: ptr, n: i32) -> i32 { … }     // sums n i32 elements

fn main() -> i32 {
    let a: i32[2][3] = 0;
    a[1][2] = 6;
    let p: ptr = a[1];                      // the second row, kept in a variable
    return rowSum(a[1], 3) + p[0];
}
```

- **A row may not be stored to, and it is not a truth value.** `a[1] = 5` on an `i32[2][3]` is `cannot assign to 'a'[i]: it addresses a row, not an element` (as is the compound form, a 3-D chain that stops two dimensions short, the field spelling `s.xs[0] = 5`, and a row store in a `for` step); `let x: i32 = a[1];` is a `type mismatch` (a row is a `ptr`), and `if (a[1])` is refused by the condition rule (a ptr is not a truth value). The single-subscript spelling is the subtle one — the parser hands it over as itself, so it is told apart from a chain by the subscript count the parser records, not by the expression's shape.
- **Two levels on a `ptr` have no stride to apply**: `p[0][1]` is `pointer indexing is not supported yet`, exactly as a one-dimensional `p[1]` would be if the element were not `i32`-wide. Codegen computes every subscript first and materializes the base address after, in `emitIndexAddr()`, because evaluating a subscript can materialize a global's address into X16 — which is where the base is about to go.

`tests/multi-dim-array-checks.sh` [9/9] is the resident suite: 12 behavioural cases under qemu, 4 gcc-differential pairs (the shipped `examples/multi_dim_array.ast` against its C twin, both exiting 255), a 22-row rejection matrix, a 36-row coverage map, and an 8-mutant layer.

### `sizeof` and `len` (v0.23.35-dev)

Since v0.23.35-dev a program can **ask** the two numbers it used to have to
hard-code: how many bytes a thing occupies, and how many elements an array
holds. Both operators accept a **type** and an **expression**, because both are
spellings people write:

```aster
sizeof(i32)          // 4    — a type
sizeof(i32[4])       // 16   — an array type, dimensions and all
sizeof(ptr)          // 8
len(i32[4])          // 4    — the element count
len(i64[2][3])       // 6    — the product of the dimensions, not the row count

let w: i32[4] = 0;
sizeof(w)            // 16   — an expression
len(w)               // 4
sizeof(row.cells)    // 16   — a struct's array field
len(row.cells)       // 4
```

**`sizeof` answers bytes** — `tySize(T)` for a scalar, the struct's laid-out
size (alignment included) for `sizeof(S)`, and `tySize(T) * dimsProduct` for an
array type or an array expression. **`len` answers the element count** — the
product of the dimensions, which for a one-dimensional array is the length and
for a multi-dimensional one is the total; on an expression it asks the same
question of whatever the expression names (a local binding's dims, a global's
`arrayDims`, a struct field's length, which has been the total element count
since v0.23.29-dev).

**Both fold to an `i32` constant at compile time**, in two places by design.
The type spelling folds in `primary()` while parsing — it needs no context, so
it arrives in the AST as an ordinary `Expr::n` and every downstream site
(`gen`, `constantInteger`, `isConstExpr`, `foldConst`) sees a plain integer
literal. The expression spelling folds in `Sema::typeOf`, which *does* need
context — the binding's dims, the field's length — and codegen's `exprType`
twin answers `Ty::I32` for both. The value type is `i32` everywhere.

**An array parameter remembers its length.** Since v0.23.34-dev `fn f(a: i32[4])`
decays the argument to a `ptr<i32>` and throws the length away, so inside `f`
there was nothing for `len(a)` to answer from. `Function::paramDims` now records
the parameter's dimensions at parse time (from `arrayParamType()`'s
out-parameter, the same place that already answers the element type) and
`Sema::check` fills the binding as `Binding{pty, plen, elem, pd}` with
`plen = dimsProduct(pd)` — so `sizeof(a)` is `tySize(elem) * plen` and `len(a)`
is `plen`. The dimensions answer these two operators **and nothing else**: a
parameter subscript stays unchecked (no `--bounds-check`, no compile-time
fold), `return a;` is still refused as a dangling frame pointer, and `a = ...`
is still a type error.

**One number is deliberately Aster's, not C's.** `sizeof` on a decayed parameter
in **C** is the pointer's 8; Aster answers the array's 16 — what the caller
actually passed — and the C twin `tests/sizeof-len-twin.c` says so out loud by
measuring a real array type (`sizeof(int32_t[4])`) rather than the decayed
parameter. `len` on a `ptr` is refused rather than answered, in either
language.

**`len` refuses what has no element count**, in both spellings, each message
naming the fix: `len() requires an array, not a scalar or pointer` for a scalar
local, a `ptr` or a `ptr` parameter, and `len() requires an array type, e.g.
len(i32[4])` for a scalar or struct *type*. `sizeof` refuses nothing `tySize`
can answer — it is total over the type grammar, which is the point of an
operator whose whole job is to report what the compiler already knows. The fold
runs *after* the length check, not instead of it: `i32[0]` is still
`array length out of range`. The two names are **contextual**, not reserved: a
variable may be *declared* and *assigned* under either name, but reading it in
expression position is the operator — `return len;` is `expected '(' after len`,
and so is `sizeof(len)` with `len` a variable, because the expression form
re-enters the same rule. In practice: do not name a variable `len` or `sizeof`.

`tests/sizeof-len-checks.sh` [9/9] is the resident suite: 25 behavioural cases
under qemu (every spelling × every scope × both operators), 3 gcc-differential
pairs, an 11-row rejection matrix (the four `len` refusals, the two malformed
`sizeof` spellings, the zero-length array type, and the two contextual-keyword
reads), a 5-mutant layer, and the shipped `examples/sizeof_len.ast` exiting 255,
equal to its C twin.

## Loops (v0.22.50-dev)

`for (init; cond; step) { body }` has the observable semantics of
`{ init; while (cond) { body; step; } }`:

- The **initializer** runs once, before the first condition check, inside the
  loop's own scope: a `let` there is invisible after the loop (`unknown
  variable: i`). It may be a `let` declaration, an assignment (`i = 0;`,
  `buf[i] = 0;`, `*p = 0;`), or empty (`;`).
- The **condition** follows the condition rules of § *Condition expressions and
  bool literals* (a comparison, a bool expression, or any integer since
  v0.23.25-dev — before that round it had to be a comparison, `for condition
  must be a comparison`); it may not be empty (`for condition cannot be
  empty`).
- The **step** is an assignment form (no declarations: `for step cannot
  declare a variable`) or empty; it executes between the body and the
  back-edge, so `continue` inside the body lands on the step and still makes
  progress — unlike `while`, where `continue` re-checks the condition
  directly.

```
; init (once)                 loopStart:
;   ...                           ; cond: cmp + b.cond exit
;   ...                           body:
;   ...                             ; continue -> step
;                               step:
;   ...                             ; step assignment
;   b loopStart                 exit:
```

`break` exits the innermost loop of either kind. Header misuse is rejected at
parse time: `expected '(' after for`, `expected 'let', assignment, or ';' in
for initializer`, `expected ';' after for initializer`, `expected ';' after
for condition`, and `expected ')' after for step`.

## Booleans and logical operators (v0.22.51-dev)

`bool` is a first-class type holding `0` or `1` in a 4-byte slot. Comparisons
(`== != < <= > >=`, signed 32-bit) are ordinary **bool expressions**: they can be
stored in a `let`, passed to a `bool` parameter, returned from a function with
`-> bool`, and held in a `let g: bool = 0;` global. Previously they were legal
only inside an `if`/`while`/`for` condition.

```aster
let enabled: bool = true;                    // bool literals are 0/1 — or true/false since v0.23.25-dev
fn isBig(x: i32) -> bool { return x > 10; }
fn pick(c: bool, t: i32, f: i32) -> i32 { if (c) { return t; } else { return f; } }

fn main() -> i32 {
    let a: i32 = 3;
    let b: i32 = 5;
    let both: bool = a < b && b > a;         // && of two comparisons
    let r: i32 = pick(both && isBig(a), 1, 0);
    if (!both || r == 0) { return 1; }       // ! and || in a condition
    else { return 0; }
}
```

- **Operators.** `&&` and `||` combine bool operands; `!` negates one. Precedence
  is `||` < `&&` < comparisons, so `a < b && b < c` groups as expected.
- **Short-circuit.** `&&` evaluates its right operand only when the left is true,
  `||` only when the left is false. The left operand decides: `MOV Wt, #0` (for
  `&&`) or `MOV Wt, #1` (for `||`) is emitted first, then a `CMP #0` + conditional
  branch skips the right operand when the left already settles the result.
- **Materialization.** A bool value is produced with `CSET Wd, <cond>` — a
  `CSINC` with `Rn = Rm = WZR`, encoding `0x1a9f07e0 | (cond^1) << 12 | Rd`.
- **No implicit conversion.** `bool` is not `i32`: `let x: i32 = a < b;`,
  `let b: bool = 5;`, `f(i32)` into a `bool` parameter,
  `return bool` from an `i32` function, and `fn main() -> bool` are all compile
  errors. The only integer values assignable to a `bool` are the literals `0`
  and `1`; a bool global's initializer must be one of them (or `true`/`false`
  since v0.23.25-dev). `if (x)` where `x: i32` used to be one of these errors
  and is now legal — see § *Condition expressions and bool literals*.
- **Conditions.** `if`/`while`/`for` accept a comparison (which keeps the original
  `CMP` + conditional-branch shape, so pre-existing code compiles
  byte-identically), a bool expression (materialized, then tested with
  `CMP #0`), or — since v0.23.25-dev — any integer, with 0 false and non-zero
  true. Anything else is `condition must be a comparison, a bool expression, or
  an integer` (the message was `condition must be a comparison or a bool
  expression` before v0.23.25-dev).
- **`else if` chains** are sugar: after the optional `else` (optional since v0.23.22-dev — before it every `if` demanded one, and `} else { }` filler blocks were the only way to write a fallback-free `if`), an `if` is parsed as another if statement nested in the else branch, so `else if (c) { }` and `else { if (c) { } }` produce the same code and chains nest to any depth. Because the `else` is optional, `else { if (c) { } }` — the explicit spelling of the sugar — is itself legal without an else on the inner `if`.

Rejected: chained comparisons (`a < b < c`), `&&`/`!` on non-bool operands,
pointer comparisons other than the `==`/`!=` forms of § *Null and pointer
equality* (v0.23.26-dev — before that round *no* pointer comparison was
accepted), and bool/int mismatches in initializers, assignments, arguments and
returns.

## Condition expressions and bool literals (v0.23.25-dev)

### `true` and `false`

`true` and `false` are keywords and the language's first `bool` literals. Before
this round a `bool` value could only be manufactured by a comparison operator,
because `Expr::Num` was born carrying an `i32` and nothing else. The lexer maps
the two words to new tokens; `primary()` builds a `Num` node carrying a
`boolLit` flag whose stored value stays `0`/`1`. Both `typeOf` twins (the
semantic pass and codegen) answer `Ty::Bool` for a flagged `Num`, so the literal
is a `bool` everywhere a type is asked:

```aster
let on: bool = true;
let off: bool = false;
fn flip(b: bool) -> bool { if (b) { return false; } else { return true; } }
```

- A `bool` literal is **not** an integer literal: `constantInteger` refuses to
  fold it, so `let x: i32 = true;` and `a[true]` no longer compile (they did
  before this round, through the constant-integer paths).
- Global and struct-field initializers check the literal against the declared
  type: `let n: i32 = true;` is a positioned `global initializer type mismatch:
  expected i32, got bool`, and a `bool` into a non-`bool` struct field is
  likewise rejected naming both types.
- `while (true) { … }` is a legal infinite loop; it still needs a `return`,
  `break` or a fault to leave.

### Truthiness in conditions

`if`, `while` and `for` share one condition machine (`checkCondition` in sema,
`emitCondition` in codegen). Since this round a condition may be any of:

1. **A comparison** — unchanged: the original `CMP` + conditional-branch shape,
   which is why every pre-existing example still compiles byte-identically.
2. **A `bool` expression** — a variable, field, parameter, call, `&&`/`||`/`!`
   result, or a literal. It is materialized to 0/1 and tested against zero,
   exactly as a comparison's answer already was.
3. **Any integer** — `i32`, `u8`, `u16`, `u32` or `i64`. Zero is false; every
   other value is true.

```aster
fn steps(n: i32) -> i32 {
    let r: i32 = 0;
    while (n) { r = r + n; n = n - 1; }      // integer condition: run to zero
    return r;
}
```

- **The zero test is width-aware.** Narrow integers (`i32`/`u8`/`u16`/`u32`) use
  the comparison path's existing `CMP Wn, #0`; `i64` uses the new
  `CMP Xn, #0` (`cmpZeroX`). A 32-bit compare of an `i64` holding a value past
  four billion reads as zero — the bug this encoding rule exists to prevent.
- **The boundary is deliberate.** Truthiness coercion lives in control-flow
  conditions and nowhere else: `?:`, `&&`, `||` and `!` remain strictly `bool`,
  so `a && b` still means "both true", not "both non-zero", and `if (a && b)`
  works because the `&&` answers a `bool` that the condition accepts — two
  layers, one clean. `if (a || b)` likewise requires both sides to be `bool`.
- **`ptr` and struct conditions stay rejected.** A `ptr` is an address, not a
  truth value, and a struct has no truth value at all
  (`condition must be a comparison, a bool expression, or an integer`).

### `genBool` covers fields and conditional expressions

`genBool` — the helper that produces a 0/1 register for any expression used in a
boolean context — had never handled `Field` or `Cond` before this round, so
`if (s.b)` and `c ? a : b` died in codegen with `expected a bool expression`
although the semantic pass had already typed them `bool`. Both now delegate to
`gen(e, Ty::Bool)`, which already supported a `bool`-wanting consumer.

### Rejections the round added

- A `bool` operand in **any** arithmetic, bitwise, shift or unary-minus
  operation (`1 + true`, `~true`, `-true`, `true << 1`, …): one `rejectBool`
  guard sits at all fifteen operator sites, answering
  `cannot use a bool value in …`.
- A `bool` as an **array index** (`a[true]`): `cannot use a bool value in an
  array index`.
- A `bool` literal into a non-`bool` scalar global or struct field (see above).

Rejected (unchanged from earlier rounds): chained comparisons, `&&`/`!` on
non-bool operands, pointer comparisons that are not `==`/`!=` against another
ptr or the null constant, bool/int mismatches in arguments and returns.

## Null and pointer equality (v0.23.26-dev)

### The null pointer constant

The literal **`0` in a pointer context is null**, exactly as in C — and it is
the *only* integer that crosses the integer/pointer line. It may initialize a
`ptr`, be assigned to one, be passed to a `ptr` parameter and be returned from
a `-> ptr` function:

```aster
let g: ptr = 0;                          // a null global (it lands in .bss)

fn find(needle: i32) -> ptr {
    let base: ptr = buf;
    let i: i32 = 0;
    while (i < 8) {
        if (buf[i] == needle) { return base + i * 4; }
        i = i + 1;
    }
    return 0;                            // "not found" is a ptr answer
}

fn main() -> i32 {
    let p: ptr = 0;                      // a null local
    let r: i32 = find(42);               // an answer, or null
    p = 0;                               // cleared
    return 0;
}
```

- **Only the literal `0`.** `let p: ptr = 1;` is
  `type mismatch initializing 'p': expected ptr`, and so are `p = 1`, `f(1)`
  and `return 1` from a `-> ptr` function. A cast does not help either:
  since v0.23.48-dev the six cast spellings are the integer types only —
  `ptr` is not one of them, so there is no way to ask for an address with a
  value.
- **`false` is not null.** A Bool literal's stored value is also `0`, but a
  bool is not an address: `let p: ptr = false;` is refused. This is the one
  subtlety in the rule, and the reason the compiler's `isNullConstant` reads
  the expression's bool-literal flag rather than just its value.
- **`ptr<S>` takes null too.** A pointer-to-struct's struct id is checked when
  one address is stored into another; null has no struct id to mismatch, so
  `let ps: ptr<S> = 0;` is fine.
- A **`ptr` is still not an integer**: `let x: i32 = p;` remains
  `type mismatch initializing 'x': expected i32, got ptr`.

### Equality on pointers

`==` and `!=` are defined for a `ptr` — against **another `ptr`**, or against
**the null constant**, in either operand order (`p == 0` and `0 == p` are the
same test):

```aster
fn isnull(p: ptr) -> i32 { if (p == 0) { return 1; } return 0; }
fn same(a: ptr, b: ptr) -> i32 { if (a == b) { return 1; } return 0; }
```

- **A pointer comparison is an ordinary `bool` expression.** It can be stored
  (`let b: bool = (p != 0);`), composed with `&&`/`||`/`!`, and reused — it is
  a `bool` value like any other, not a special form.
- **The comparison runs at 64 bits.** An address is a 64-bit value, so the
  emitted test is `CMP Xn, Xm` — the compiler's width rule already counted a
  `ptr` as 64-bit, so no new encoding was needed for this round.
- **Ordering is not defined.** `p < q`, `p <= q`, `p > q`, `p >= q` — and a ptr
  against any integer that is not `0` — are all compile errors
  (`only == and != are defined for a ptr`, and
  `a ptr may only be compared with another ptr, or with the literal 0`). Which
  of two unrelated objects "came first" is not a question the language answers.
- **A `ptr` is not a truth value.** `if (p)` and `while (p)` remain
  `condition must be a comparison, a bool expression, or an integer` — write
  `if (p != 0)`. Truthiness belongs to integers and booleans (v0.23.25-dev),
  not to addresses.
- An array's name is its address, so `if (a != 0)` works on an array too; a
  **struct** compared with anything, null included, is still
  `cannot use a struct value (S) in a comparison`.

## Expression precedence and binding (v0.23.27-dev)

Four places where Aster read an expression differently from C, all four found by
writing `docs/language-reference.md` down and running every claim in it against
the binary. Three of them were silent — a different answer, or a truncated
value — which is why they survived: nothing ever complained.

### `&&` binds tighter than `||`

`&&` and `||` were collected by a single loop, so `a || b && c` was read
`(a || b) && c`:

```aster
if (1 == 1 || 1 == 1 && 1 == 2) { return 10; } return 20;   // was 20, now 10
```

They are two levels now — `logicalAnd()` collects `&&` over `equality()`, and
`logical()` collects `||` over that — so `a || b && c` is `a || (b && c)`, which
is C's reading and the one this file had been claiming for releases. Both still
short-circuit, and neither accepts a non-bool operand.

### The prefix operators take a postfix operand

`-` `!` `~` `*` used to parse their operand at `primary()` depth, so a following
`.field` landed *outside* the operator:

```aster
struct S { p: ptr, v: i32, ok: bool }
-s.v      // was (-s).v  → now -(s.v)
~s.v      // was (~s).v  → now ~(s.v)
!s.ok     // was (!s).ok → now !(s.ok)
*s.p      // was (*s).p  → now *(s.p)
```

In practice the old reading made all four **rejected** whenever the operand was
a struct, because `(-s)` is one (`cannot use a struct value (S) in -`). A new
`unary()` level now sits between `postfix()` and the multiplicative level and
holds all five prefix operators; `&` moved onto it from `postfix()`, where it had
been the exception and already behaved correctly, so `&s.v` is still `&(s.v)`.
Both dereference-assignment targets parse at the new depth, so `*p.f = v` means
what C means.

### A comparison level crossing is legal

The anti-chaining check asked whether *any* comparison operator followed a
comparison, so `a < b == c` was rejected although the comment above the
relational level promised `(a < b) == c`. The check now asks whether the next
operator is from the **same** level:

```aster
a < b < c     // rejected: chained comparisons are not supported
a == b == c   // rejected
a < b == c    // accepted — (a < b) == c
a == b < c    // accepted — a == (b < c)
```

Both levels are non-associating, so a chain within one of them can only be a
mistake: `(a < b) < c` would compare a `bool` against an integer. Write
`a < b && b < c`.

### A local `let` is range-checked like a global one

A global `let` has always run `initializerFits`; a local one did not, so the same
line meant two different things depending on where it stood:

```aster
let b: u8 = 300;                      // global → global initializer does not fit in u8: b (300)
fn m() -> i32 { let b: u8 = 300; return b; }   // was: accepted, returned 44
                                               // now: local initializer does not fit in u8: b (300)
```

The check now runs for a local scalar **and** for a local array's element
initializer (`let a: u8[4] = 300;`), in sema and again in codegen. Only a
**constant** that does not fit is refused: narrowing a *value* —
`let b: i32 = <an i64>;`, `let b: u8 = <an i32>;` — is still allowed, as it has
always been, because that is a conversion the language offers rather than a
constant that cannot be represented.

### Why no existing program changed

Every one of the four is a parser or type rule; the round carries no codegen at
all. The evidence is the A/B baseline: **288 of 288 pre-existing outputs
reproduce byte for byte**, and the three new rows are `examples/precedence.ast`'s
output modes. The zero-impact claim was argued before it was measured too — no
shipped example mixes `&&` with `||`, none writes `*x.y` or `-x.y`, `a < b == c`
did not compile at all, and no narrow local in the tree is initialized with an
out-of-range constant.

## Wider integer types (v0.23.2-dev)

The old scattered `isPtr`/`isBool` booleans are replaced by a single unified
type lattice, `enum class Ty { I32, U32, U8, U16, I64, Ptr, Bool }`. Every
load, store, arithmetic, and comparison picks its width and signedness from the
lattice, so the seven types share one code path and the old `i32`-only behavior
is exactly the default branch.

- **`i64`** is the signed 64-bit type. Literals up to `0x7fffffffffffffff` are
  accepted (a larger literal is a parse error). Literals may be written in
  decimal or, since v0.23.22-dev, hexadecimal: a `0x`/`0X` prefix followed by at
  least one hex digit, in any position a decimal literal is legal (including
  array lengths); a bare `0x` is a lexer error naming its position. i64 values live in 64-bit
  registers and 8-byte frame/argument slots; the compiler materializes a wide
  literal with `MOVZ` + up to three `MOVK` instructions whose shift fields are
  taken from the base encoding (a latent bug that over-shifted the `MOVK` base
  was fixed — i64 constants larger than 32 bits now land in the correct byte
  lane). Arithmetic `+ - * /`, unary minus, and negative literals all work;
  comparisons use the signed `CMP` on the full 64-bit registers.
- **`u8` / `u16` / `u32`** are unsigned narrow/wide types. They use
  zero-extending accesses — `LDRB`/`STRB` for `u8` and `LDRH`/`STRH` for `u16` —
  so a load clears the high bits instead of sign-extending. Comparisons use the
  unsigned condition codes `LO`/`LS`/`HI`/`HS`, and division uses `UDIV` instead
  of `SDIV`. Arithmetic wraps modulo the type width (e.g. `255u8 + 1` is `0`).
- **Type assignment and rejection.** A value flows into a slot of its declared
  type; narrowing (`i32` into `u8`, `i64` into `i32`) and sign mismatch are
  compiler errors in initializers, assignments, arguments and returns. A literal
  must fit the target: `let g: u8 = 250;` is accepted, `let g: u8 = 300;` is
  rejected, and an `i64` literal that exceeds the materializable range is
  rejected too. Wide and narrow globals (`.data`/`.bss`) and array element types
  are supported; narrow globals pad their `.data` slot up to a 4-byte boundary
  so the section stays 4-byte aligned for the linker.

### Wider integer C ABI status (v0.23.2-dev)

`i64` travels the AArch64 **8-byte AAPCS64** ABI: the first eight integer
arguments use `x0`–`x7` (the 64-bit forms), the result uses `x0`, and arguments
beyond the eighth are passed in 8-byte stack slots. A single `i64` value is
call-compatible with a C `long` argument/return on LP64 Android. The unsigned
narrow types (`u8`/`u16`/`u32`) are *not* yet exposed across the C ABI as their
own signatures — they are a language-level feature with the unsigned semantics
described above, and mixing them with C expects the caller to pass a full
register whose low bits hold the value. `ptr` and raw pointer arithmetic remain
as documented in the pointer section; `i64`/`u8`/`u16`/`u32` are distinct from
`ptr` and never implicitly convertible.

## u64 and explicit casts (v0.23.48-dev)

The lattice grows its eighth integer type and the language gains its first
explicit conversion. `enum Kind { I32, U32, U8, U16, I64, U64, Ptr, Bool, Struct }`
— `U64` sits beside `I64`, and `Cast` joins the expression kinds.

### `u64`: the unsigned 64-bit type

- Same storage as `i64`: 8-byte slots, X registers, `MOVZ`+`MOVK` literals.
  Same width of access; what changes is the reading — comparisons take the
  unsigned condition codes `LO`/`LS`/`HI`/`HS` and division is `UDIV`, exactly
  as `u8`/`u16`/`u32` already do at their widths (`tyIsUnsigned` learns `U64`).
- **Literals up to `2^64-1`.** `primary()`'s guard moves from
  `0x7fffffffffffffffULL` to `0xffffffffffffffffULL`; past that there is
  nowhere for the value to go at all and the parse fails with
  `integer literal exceeds u64 range at L:C`. The check against the *slot* —
  which is what knows whether a value above `2^63-1` was meant for `i64` or
  `u64` — moves to the declaration site, `initializerFits`:
  `let x: u64 = 18446744073709551615;` is accepted, and
  `let x: i64 = 9223372036854775808;` is refused naming the slot,
  `local initializer does not fit in i64: x (9223372036854775808)`, where the
  old parser named the token instead. A negative literal in a `u64` slot is
  the sign-extended view of a value near `2^64` (`-1` is `2^64-1`), not a
  truncation, so the slot takes it as it stands.
- **`promoteInt` answers `U64` first.** `u64` outranks `i64` and is tested
  before the `tyIs64` branch: were that branch reached first, `u64 + i64`
  would answer `I64` and a `u64` comparison would be emitted with the signed
  condition codes — silently wrong for every value past `2^63-1`, which is
  exactly the range `u64` exists for. A mixed pair widens to 64 bits and
  takes the unsigned reading when either side is `u64`.
- **`tyAssignable`** keeps its shape: an `i64` flows into a `u64` slot as the
  one same-width asymmetric rule beside `i32`↔`u32` (`to==U64 && from==I64`),
  and every integer still widens into `i64`.
- **C ABI**: `u64` travels exactly the path `i64` does — `x0`–`x7`, 8-byte
  stack slots, `x0` on return — so it is call-compatible with a C
  `unsigned long` argument/return on LP64.

### The cast: `T(x)`

- **Function-shaped, primary level.** `u8(x)`, `i64(x)` — the same spelling
  `sizeof` and `len` use. The type keywords are reserved words, so the
  recognition is zero-lookahead: an integer keyword followed by `(` can be
  nothing else. Six spellings: `i32 i64 u8 u16 u32 u64`.
- **`ptr` and `bool` are deliberately not spellings.** There is no conversion
  to or from an address or a bool, so `ptr(x)` falls through to the
  `expected expression` error exactly as it did before, and a bool operand is
  refused by sema rather than read as `0`/`1`.
- **Sema**: the operand must be an integer — `cannot cast ptr to u8`,
  `cannot cast bool to i32`, `cannot cast Point to i32`. The answer is the
  target type, which is also the type codegen's `exprType` reports, so the
  two passes cannot disagree about the width the value is carried at.
- **Codegen**: a narrowing cast answers with the target width's low bits
  (`u8(300)` is `44`, `u32(-1)` is `0xFFFFFFFF`); a widening cast extends by
  the *source* type's signedness (`u64(u8(200))` zero-extends,
  `i64(i32(-1))` sign-extends). The extension honours the same
  producer-extends rule every other producer follows: the `SXTW` at the end
  of the `Cast` arm answers at 64 bits when a 64-bit consumer asks, because a
  cast that stopped at 32 bits would leave the upper half zeroed — the
  correct `u32` reading of those bits, but not the `i32` one.
- **A cast is how a program asks for a truncation.** There is no implicit
  one: `tyAssignable` refuses a narrowing value at the argument paths, and a
  constant that does not fit its slot is a compile error. `u16(70000)`
  exists so the program can say it meant the low bits.

```aster
let top: u64 = 18446744073709551615;      // 2^64-1, accepted
let b: u8 = u8(300);                      // 44 — the low 8 bits, asked for
let w: u64 = u64(u32(4294967295));        // 4294967295 — zero-extended
let s: i64 = i64(i32(0 - 1));             // -1 — sign-extended, not 4294967295
if (top / 1000000000000 == 18446744) { return 73; }   // UDIV, unsigned compare
```

## Structs (v0.23.5-dev)

A struct is a **nominal composite value**: it has a name, an ordered list of
typed fields, and no register form — it lives in memory, is read and written
field by field, and is moved as a whole.

```aster
struct Point { x: i32, y: i32 }
struct Rect  { a: Point, b: Point }        // a field may be another struct

fn area(r: Rect) -> i32 {                  // passed by value
    let p: Point = r.a;                    // copied as a whole
    return p.x * p.y;
}

fn origin() -> Point { return Point { 0, 0 }; }   // returned by value

fn main() -> i32 {
    let r: Rect = Rect { Point { 2, 3 }, Point { 4, 5 } };
    let q: ptr<Rect> = &r;                 // pointer to a struct
    q.a.x = 10;                            // a field through the pointer
    r = Rect { Point { 1, 1 }, Point { 1, 1 } };
    return area(r) - 1;
}
```

**Declaration and layout.** `struct Name { field: T, … }` declares the type and
lays it out once, under AAPCS64: each field is aligned to its own alignment, the
struct is padded to its widest, and a nested struct contributes its own size and
alignment (computed recursively). The layout is the same one a C compiler
produces for the same declaration — `tests/struct-checks.sh` [5/8] proves it by
comparing the two images byte for byte, padding included. A struct is entered
into the table before its fields are read, so a field of the same struct is
resolved and then rejected: **a struct cannot contain itself**. A field may be
any scalar, `bool`, `ptr`, `ptr<S>`, an earlier-declared struct, or — **since
v0.23.29-dev — a fixed-length array of any of those** (`nums: i32[4]`), which
occupies `sizeof(element) * length` bytes; see *An array field* below.

**Values.** `Name { v1, v2 }` builds one, one value per field in declaration
order; a nested field takes a nested literal. `expr.field` reads a field and is
an lvalue, so `p.x = 5;`, `r.a = Point { 1, 2 };` and `q.a.x = 10;` all write
one. A struct may be a local, a parameter, a return type, a global, and the
target of an assignment: `let q: P = p;` and `p = q;` copy the whole value.
`&v` on a struct lvalue yields `ptr<S>`. Since v0.23.30-dev `&` on a struct's **array field** (`&b.cells`) yields a strided `ptr<T>` instead — the address of the field's first element, carrying the element width (any element type since v0.23.34-dev); see *An array has an address*.

**Types are nominal.** Two structs with identical layouts are different types:
passing a `P` where a `Q` is expected is an error, at an argument, in a `let`,
in a return, and for `ptr<P>` vs `ptr<Q>`. A struct is a value but deliberately
not an integer — `p + 1`, `p == q` and `if (p)` are all rejected with their own
diagnostics, and a struct is never implicitly converted to or from `i32`/`ptr`.

**Globals.** `let g: Point = Point { 3, 4 };` lands in `.data` with the
constant folded field by field (a nested literal is folded the same way); an
all-zero initializer lands in `.bss`. A `ptr` field cannot be given a constant
value and is rejected rather than silently zero-filled.

### An array field (v0.23.29-dev)

A field may be a fixed-length array of any type a field may otherwise have:

```aster
struct Vec3  { a: i32, b: i32, c: i32 }
struct Buffers {
    nums:  i32[4],      // 4 × 4 bytes
    flags: bool[3],     // 3 × 1 byte
    ptrs:  ptr[4],      // 4 × 8 bytes
    pts:   Vec3[2]      // 2 × 12 bytes
}

let gb: Buffers;                     // a global one, zero-filled in .bss

fn main() -> i32 {
    let b: Buffers;                  // a local one, zero-filled
    b.nums[0] = 11;                  // read and write an element
    b.flags[2] = true;               // a bool element is a condition
    b.ptrs[1] = &gb;                 // an address into a ptr element
    b.pts[1].a = 100;                // an element's field, both scopes
    let p: ptr<Vec3> = &b.pts[1];    // &s.f[i] is a ptr<Vec3>
    let c: Vec3 = b.pts[1];          // a whole element copied as a value
    return (*p).a;
}
```

**Layout.** `layoutStruct` reserves `sizeof(element) * length` bytes for the
field and records its offset; the element type's own alignment still applies, so
padding between fields is unchanged. A length must be between **1 and 1000**
(`array field length must be between 1 and 1000`), the same bound a local array
takes.

**Indexing.** `s.f[i]` reads an element and is an lvalue, so `s.f[i] = v`,
`s.f[i].g = v` and `&s.f[i]` all work, and a bracket may be followed by a dot
because `.` and `[` are collected by **one** interleaved postfix loop —
`s.pts[1].a` is a field, then an index, then a field. A constant index is
checked against the field's length at compile time (`array index out of bounds:
index 9, length 4`); a dynamic one is checked at run time under
`--bounds-check`. Scaling is the same rule a named array uses: a shift when
`sizeof(element)` is a power of two, and `UMADDL` when it is not — so a 12-byte
`Vec3` element is scaled by a multiply here for the same reason it is inside a
`Vec3[2]` local.

**A struct that contains an array field cannot be built by a literal.**
`Name { … }` takes one value per field, and an array field needs `length` of
them, so both scopes refuse it rather than guess:

```
struct 'Buffers' contains an array field and cannot be initialized by a literal
```

The check (`structHasArrayField`) is recursive, so a struct *containing* a
struct with an array field is refused too. What works instead is the shape above:
declare the variable — **a struct `let` may now carry no initializer at all**
and is zero-filled — and write the elements. A struct global without an
initializer lands in `.bss`.

**Rejected.** Indexing a field that is not an array (`cannot index non-array
field: x`); an out-of-range length or index; a literal initializer at either
scope; and reading a struct element into an integer (`type mismatch initializing
'n': expected i32, got Vec3` — a struct element is copied as a whole into a
struct variable, or walked field by field, but it is never an `i32`).

### Struct C ABI status (v0.23.5-dev)

A composite crossing a call follows AAPCS64, and both call sides derive the
assignment from **one** function (`layoutArgs`), so they cannot disagree:

| Size | Passed as | Returned in |
| --- | --- | --- |
| ≤ 8 bytes | one general-purpose register | `x0` |
| 9..16 bytes | two consecutive general-purpose registers | `x0` / `x1` |
| > 16 bytes | the **address** of a copy the caller makes (an 8-byte slot, even when the argument itself lands on the stack) | the buffer whose address the caller puts in **X8** |

Two rules are worth stating because they are easy to get wrong from memory.
Composites are **not** padded to an even-numbered register, and this holds even
when the struct is 16-byte aligned: GCC 13.3 at `-O0` puts `s1` in `x1/x2` and
`s2` in `x3/x4` for `f4(int a, struct T s1, struct T s2)` (12 bytes, align 4),
and puts an `__attribute__((aligned(16)))` 16-byte `A16` in `x1/x2` for
`h(char c, struct A16 s)` — straight from the next free register, no rounding,
in both cases. Aster matches, and `tests/struct-checks.sh` runs the `f4`
signature; the `A16` half documents GCC only, because Aster cannot declare a
16-byte-aligned struct. Second, the stack arguments begin at the stack pointer
**as the callee sees it**, with the copies and the >16-byte result buffer
sitting above them.
Aster has no floating-point and no 16-byte alignment, so the HFA/HVA rules do
not arise.

`tests/e2e-c-struct.sh` links `examples/c_struct_abi.ast` into a C host and
checks all three classes in **both** directions — C calls Aster, and Aster calls
C — including a >16-byte C function Aster calls through the X8 pointer.

## Compile-time file embedding (v0.23.7-dev)

Two attribute-like expressions put a file's bytes into the program:

```aster
let blob: ptr = @embed("res/data.bin");         // the address of the bytes
let n: i32    = @embed_len("res/data.bin");     // how many bytes there are
let copy: u8[@embed_len("res/data.bin")] = 0;   // a constant array bound
```

- **`@embed(path)`** is a `ptr` expression. The compiler reads the file while
  compiling and emits its bytes into `.rodata`; the value is that address. There
  is no run-time file I/O and the file need not exist where the program runs.
- **`@embed_len(path)`** is **not** a run-time call — the parser folds it to an
  integer literal, so it is legal anywhere a literal is: array lengths, global
  initializers, case values. Reading bytes with it is `load_u8(blob + i)`.
- **Path base.** A relative path is resolved against **the source file's own
  directory** (C `#include` rules), so a source finds its neighbours no matter
  where the compiler is invoked from. `--embed-dir DIR` overrides the base; an
  absolute path ignores both.
- **Dedup.** Embedding the same path twice emits the bytes **once** and reuses
  the symbol.
- **Diagnostics.** `cannot open embedded file "…" (looked for "…")` names both
  the path you wrote and the path it resolved to; a directory and a zero-byte
  file have their own messages (`embedded file is a directory`, `embedded file
  is empty` — an empty resource is almost always the wrong path); anything over
  16 MiB is refused.
- A pointer-yielding initializer is legal for a **`ptr`-typed global**
  (`let g: ptr = @embed(...)` is initialized by `__aster_init` before `main`);
  for any other target type it is still a type error.
- `ptr` indexing is 8-byte scaled (`p[i]` is `*(p + i*8)`), so embedded bytes are
  walked with `load_u8(p + i)`, not `p[i]`.

## Declaration sharing: `include` (v0.23.13-dev)

```aster
include "include_demo_defs.ast";

fn main() -> i32 {
    return add2(total);
}
```

`include "PATH";` is a **top-level** declaration: it brings another file's
declarations into this one. It is the answer to "who checks that my `extern`
matches the function I actually wrote?" — before it, a multi-file program shared
a signature by retyping it, and because the linker matches by name a retyped
arity or return type linked, ran, and returned garbage without a word.

- **Declarations only.** A body and an initializer stay in the file that owns
  them: an included function arrives as a declaration with its body dropped, and
  an included global as a name and a type with its initializer left behind. The
  declaration is therefore *the definition's own signature*, read out of the file
  that holds it, and cannot drift from it. It also means the two files still
  compile to two objects and still link — nothing about the object format or the
  ABI changes.
- **Path base.** A relative path is resolved against **the file that wrote it**
  (C `#include` rules), not against the working directory, so a file finds its
  neighbours no matter where the compiler is invoked from. `--include-dir DIR`
  overrides; an absolute path ignores both. A file that itself writes `include`
  resolves *its* paths against *its own* directory.
- **A repeat is a no-op.** Including the same file twice, or reaching it through
  two routes (a diamond: two files that both include a third), pulls it in once.
- **A cycle is an error** that names the chain:
  `include cycle: "b.ast" -> "c.ast" -> "a.ast" -> "b.ast"`. A file reached
  through a cycle is part-way through being parsed, which is a different thing
  from one reached twice through a diamond, and the two are told apart by an
  include *stack*, not by a "have I seen this?" set.
- **A definition in this file supersedes the included declaration**, so
  "include the header, then define the functions" is legal. Only an *included*
  declaration gives way: two definitions or two declarations this file wrote
  itself are still an error.
- **An included file's `@embed` bytes do not come across** — those bytes are the
  business of the file that embeds them.
- **Diagnostics.** `cannot open included file "…" (looked for "…")` names both
  the path you wrote and the path it resolved to, and carries the v0.23.9-dev
  source line and `^` caret.
- **`-g` is unaffected.** An included file contributes no code, so it contributes
  no line rows and no DIEs of its own: a link of two `-g` objects has one unit
  per file (v0.23.12-dev for the line rows, v0.23.32-dev for the `.debug_info`
  unit, v0.23.33-dev for the `.eh_frame` table), each naming only its own lines,
  functions, globals and locals.

A file is not required to define `main`, so a "header" file is just a file of
declarations. See `examples/include_demo_defs.ast` and
`examples/include_demo_main.ast`.

## Libraries ship as objects (v0.23.42-dev)

The declaration-only rule above has one consequence worth stating on its own:
**a library is not an include.** An included function arrives with its body
dropped, so a file that *implements* something cannot be included into a
consumer — there would be no body to call. The delivery form is therefore the
one the two-object programs have always used:

```sh
aster build-obj stdlib/aster_std.ast -o std.o     # the library
aster build-obj app.ast -o app.o                  # the consumer
aster link-obj app.o std.o -o app                 # main object first
```

and the consumer names what it uses with `extern fn` / `extern let` — the
same spelling `include` itself reads out of the library's file, so the two
paths cannot drift apart. One definition per symbol: linking a second object
that also defines a routine is refused (`duplicate global symbol 'memcpy'
across input objects`), not silently resolved.

The shipped first slice, `stdlib/aster_std.ast`, is pure Aster over the byte
intrinsics and defines every symbol it uses — its object carries **one UND
entry, the ELF null symbol**, which is what "zero dependencies" looks like
when it is measured rather than promised:

| Family | Routines |
| --- | --- |
| mem | `memcpy(dst: ptr<u8>, src: ptr<u8>, n: i32) -> i32` (bytes copied), `memset(dst: ptr<u8>, c: i32, n: i32) -> i32`, `memcmp(a: ptr<u8>, b: ptr<u8>, n: i32) -> i32` (unsigned first-difference) |
| str | `strlen(s: ptr<u8>) -> i32`, `strcmp(a: ptr<u8>, b: ptr<u8>) -> i32`, `strncpy(dst: ptr<u8>, src: ptr<u8>, n: i32) -> i32` (returns `min(strlen(src), n)`) |
| num | `utoa(v: i64, buf: ptr<u8>) -> i32`, `itoa(v: i64, buf: ptr<u8>) -> i32`, `utohex(v: i64, buf: ptr<u8>) -> i32` — NUL-terminated digits, digit count returned |
| hash | `hash_str(s: ptr<u8>) -> i64` (FNV-1a), `hash_put(key: ptr<u8>, val: i64) -> i32` (slot, or `-1` when the 1024-slot table is full), `hash_get(key: ptr<u8>) -> i64` (value, or `-1` when absent — so values are non-negative by contract) |

Two spellings in that table are decisions, not decoration. **Every
byte-buffer parameter is `ptr<u8>`**: it is the only type that accepts *both*
a string literal (whose type is already a `ptr` to NUL-terminated rodata)
and `&arr` of a `u8[N]` (a strided `ptr<u8>` since v0.23.30-dev) — a bare
`ptr` parameter refuses the array, and a `ptr[N]` global element refuses it
too, so "simplifying" the signature would break half the call sites. And
**every routine answers an `i32` or an `i64`** because there is no `void`: a
negative answer is a documented sentinel (`-1`), never a trap.
`examples/stdlib_demo.ast` is the readable consumer; `tests/stdlib-checks.sh`
is its differential suite, `tests/aster-std-twin.c` the oracle.

## Run-time bounds checking (v0.23.1-dev)

Compile-time bounds checking (v0.22.48-dev) only covers subscripts that fold to
a constant. `--bounds-check` covers the rest: **every dynamic subscript into a
fixed-size array** — a global `let buf: i32[8]`, a local `let a: i32[4]`, or an
array parameter `fn f(a: i32[4])`, on the read path `a[i]` and the write path
`a[i] = v` alike — is lowered to:

```asm
cmp  w_index, #LENGTH   ; SUBS WZR, w_index, #LENGTH — flags only
b.lo skip               ; unsigned < LENGTH: in range
brk  #1                 ; out of range: SIGTRAP
skip:
```

One unsigned comparison covers both halves of the range: a negative index is a
huge unsigned value, so `b.lo` fails for `index < 0` and `index >= LENGTH`
alike. `BRK #1` is delivered as `SIGTRAP`, so a run under qemu (or on a device)
fails loudly and deterministically — exit status `133` — instead of silently
reading or overwriting neighbouring memory.

- **Opt-in.** The flag is off by default. A default build emits no test at all,
  so all 82 existing examples still compile byte-identically.
- **Constant subscripts stay free.** If the index folds to a constant, the
  compile-time check already proved it in range and no run-time test is
  emitted — so a program that only indexes with literals is byte-identical with
  the flag on.
- **Unknown extents are skipped.** `p[i]` on a pointer, or an array whose length
  is not known in this translation unit, has nothing to compare against and is
  left alone.
- **Lengths above 4095** exceed the 12-bit compare immediate and are a compile
  error with the flag on (`array 'name' is too long for --bounds-check`).
- Accepted by `build-elf`, `build-pie`, `build-obj`, `build-so` and `build-apk`
  (where it applies to the library compiled from `.ast` input). The `link-*`
  commands consume objects rather than sources and reject it with the usage
  banner.
- **Array parameters, since v0.23.36-dev.** A parameter `a: T[N]` carries its
  dimensions into the body (v0.23.35-dev), so `--bounds-check` can compare an
  out-of-range `a[i]` (read or write) against `N` exactly as for a local/global
  array — same `CMP`/`B.LO`/`BRK #1`, same exit 133. The length is held in a
  separate `paramArrayLength[slot]` map read *only* by the check sites, so the
  addressing machinery (`gen(Var)` deciding frame-slot vs decayed-pointer by
  `localArrayLength.count(slot)`) is untouched and a default build moves no byte.
  A multi-dimensional parameter `a[i][j]` is checked per dimension through the
  existing `emitIndexAddr` walk, with no second code path; a constant
  out-of-range subscript (`a[4]` on `i32[4]`) is still rejected at compile time,
  flag or not.

## Object and executable layout

`build-obj` emits an `ET_REL` object containing `.text`, an optional `.data` (`PROGBITS`, `WA`, `sh_addralign` = the largest global alignment in the section, at least 4) and/or `.bss` (`NOBITS`, `WA`, same rule), `.rela.text`, `.symtab`, `.strtab`, and `.shstrtab`. Functions are `STT_FUNC` symbols in `.text`; globals are `STT_OBJECT` symbols with `st_size` 4 (or `4 * LENGTH` for an array) and `st_shndx` naming `.data` or `.bss` (or 0 when only declared `extern`). Relocations recorded in `.rela.text` are `R_AARCH64_CALL26` (283) for calls and `R_AARCH64_ADR_PREL_PG_HI21` (275) / `R_AARCH64_ADD_ABS_LO12_NC` (277) for global accesses.

The linker emits a fixed-address AArch64 ELF64 `ET_EXEC` with `.text` at file offset `0x1000` and virtual address `0x401000`; the entry symbol `_start` is at `0x401000` unless `main` is not the first function emitted, in which case the entry offset follows `main`'s position. When the program has data, a second `PT_LOAD` with `R+W` permissions begins on the next page boundary: `p_filesz` is the `.data` size and `p_memsz` is `.data` plus `.bss`, so a program with only zero-initialized globals gets `p_filesz == 0`. Programs without globals keep the single `R+X` `PT_LOAD`, and their loaded image is byte-identical to v0.13.1; v0.17.0 appends the symbol table after it (see *Source-level symbol table*).

## Static PIE and shared objects

`build-pie` (one source) and `link-pie` (one or more `ET_REL` objects) emit a **static PIE**: an
`ET_DYN` image with link base 0, so `p_offset == p_vaddr` for every `PT_LOAD`, the first segment is
page aligned at offset `0x1000`, and `e_entry` is a plain offset (`0x1000`) rather than a virtual
address. There is no `PT_INTERP` and no `PT_DYNAMIC`, so the kernel maps the segments at a
randomised base and jumps to `base + e_entry` with no user-space loader and no self-relocation. The
compiler emits only `ADRP`+`ADD` for global addresses and `BL` for calls, both resolved as
PC-relative deltas, so the image contains no relocation records at all. v0.16.0 wrote no section
header table for these images; v0.17.0 adds one so that `.text`/`.data`/`.bss` and the symbol table
can be described, but it still contains no relocation section.

`build-so` emits a **shared object**: an `ET_DYN` `.so` with an R+X `PT_LOAD` (`.text`, `.dynsym`,
`.dynstr`, `.hash`, `.rela.dyn`), an R+W `PT_LOAD` (`.data`, `.got`, `.dynamic`, `.bss`) and a
`PT_DYNAMIC` segment. Every non-`extern` function is exported as a defined
`STB_GLOBAL`/`STT_FUNC` `DT_SYMTAB` entry with `DT_STRTAB`/`DT_STRSZ` naming it and a `DT_HASH`
table indexing it, so `dlopen`/`dlsym` can resolve it. Every defined global gets an 8-byte
GOT-style address slot in `.got`, initialised to the global's link-time address and covered by an
`R_AARCH64_RELATIVE` relocation (symbol index 0, that address as the addend) published through
`DT_RELA`/`DT_RELASZ`/`DT_RELAENT`/`DT_RELACOUNT`. The object also carries a non-dynamic `.symtab`
alongside `.dynsym`. Shared-object code loads a global address from
its slot instead of computing it with `ADRP`+`ADD`, which makes those relative relocations load
bearing. Shared-object mode has no entry point, so `main` is an ordinary exported function and may
take parameters; since v0.18.0 `extern fn` and `extern let` become dynamic imports through `.plt`/`.got`
(see *v0.18.0: shared objects with dynamic imports* -- `DT_GNU_HASH` remains unimplemented, `link-so`
and `DT_SONAME`/`DT_NEEDED` are implemented). Arrays of `i32`, `@align(N)` and run-time initializers work in shared objects too (a unit with run-time
initializers publishes its `__aster_init` routine through `DT_INIT_ARRAY`/`DT_INIT_ARRAYSZ`). Global
scalars remain 4-byte `i32`; since v0.18.0 `extern let`/`extern fn` resolve through relative GOT slots
or dynamic imports.

## Source-level symbol table

Every final product carries a non-dynamic symbol table: `build-elf`/`link-obj`, `build-pie`/`link-pie`
and `build-so` all emit `.symtab` with a companion `.strtab`, described by a real section header
table. `build-obj` objects already carried one and are unchanged.

| product | symbol | `st_info` | `st_value` | `st_shndx` | `st_size` |
| --- | --- | --- | --- | --- | --- |
| `ET_EXEC` | source function | `STB_GLOBAL`/`STT_FUNC` | final link address | `.text` | bytes of code |
| `ET_EXEC` | source global / array | `STB_GLOBAL`/`STT_OBJECT` | final link address | `.data` or `.bss` | `4`, or `4 * LENGTH` |
| static PIE | source function | `STB_GLOBAL`/`STT_FUNC` | image offset (`e_entry` frame) | `.text` | bytes of code |
| static PIE | source global / array | `STB_GLOBAL`/`STT_OBJECT` | image offset | `.data` or `.bss` | `4`, or `4 * LENGTH` |
| shared object | source function | `STB_GLOBAL`/`STT_FUNC` | link-time virtual address | `.text` | bytes of code |
| shared object | source global / array | `STB_GLOBAL`/`STT_OBJECT` | link-time virtual address | `.data` or `.bss` | `4`, or `4 * LENGTH` |

`.bss` is `NOBITS` in every product, so its symbols carry an address and a size but no file bytes.
Symbols use their source names; the entry function is published as `main` and the conventional ELF
entry name `_start` is published next to it at the same address. Compiler-generated
`__aster_init`, `__aster_init_next` and `__aster_init_end` are not source-level names and are left
out of `.symtab` (they remain in an `ET_REL` object's symbol table, and `__aster_init` remains in a
shared object's `.dynsym` because `DT_INIT_ARRAY` names it). Only file-scope names are published:
function parameters and function-local `let` bindings are not symbols. No `.debug_*` section, no
DWARF and no line-number information is produced — this is a name table, not debug information.

The new sections and the section header table are appended after the last loaded byte. The program
header table, `e_entry`, every segment's `FileSiz`/`MemSiz`/`VirtAddr`/`Flags`/`Align` and every
pre-existing section's bytes are unchanged from v0.16.0; for `ET_EXEC` and the static PIE the whole
v0.16.0 file is therefore a byte-identical prefix once the four section-table header fields
(`e_shoff`, `e_shentsize`, `e_shnum`, `e_shstrndx`, all zero before) are masked out, and a shared
object is byte-identical up to the end of its loaded segments.

Android NativeActivity, APK packaging/signing, runtime APIs, and self-hosting are not implemented.

## v0.18.0: shared objects with dynamic imports

`build-obj --pic` emits a position-independent `ET_REL` object: every global is addressed through a
GOT-style slot (a `__aster_gat_<name>` undefined symbol) and no `_start` alias is emitted, so `main`
stays an ordinary function. `link-so` links one or more such objects into a single shared object.

In a shared object, an `extern fn` / `extern let` that is still undefined after the link is no longer a
compile error: it becomes a dynamic import.

- an imported function is called through a `.plt` stub, with a `R_AARCH64_JUMP_SLOT` relocation in
  `.rela.plt` (described by `DT_JMPREL`, `DT_PLTRELSZ`, `DT_PLTREL`, `DT_PLTGOT`);
- an imported global or array is reached through a `.got` slot with a `R_AARCH64_GLOB_DAT` relocation
  in the `DT_RELA` range;
- the module records `DT_SONAME` (option `--soname NAME`, defaulting to the output file name on the
  dynamic path) and one `DT_NEEDED` per `--needed LIB`, both as strings in `.dynstr`;
- binding is eager (`DT_BIND_NOW`, `DT_FLAGS = DF_BIND_NOW`), so no lazy-resolution trampoline exists.

Without `--soname`, `--needed` and without any `extern` import, `build-so` still writes exactly the
v0.17.0 shared-object layout.

Example:

```sh
./aster build-so examples/so_link_lib.ast    -o libdyn.so        --soname libdyn.so
./aster build-so examples/so_link_import.ast -o libdyn-import.so --needed libdyn.so
readelf -dW libdyn-import.so
readelf -rW libdyn-import.so
```


## Implementation note (Aster v0.19.1)

Generated shared objects carry both SysV `DT_HASH` and GNU `DT_GNU_HASH` dynamic symbol lookup tables. This is an ELF/linker implementation detail and does not change the source language syntax.


### GNU Hash implementation note (v0.19.1)

Shared objects carry both SysV `DT_HASH` and GNU `DT_GNU_HASH`. GNU-hashable defined dynamic symbols are ordered by bucket; undefined imports follow the hashed range. The Bloom filter, bucket starts, chain hashes, and per-bucket end bits are emitted from the final dynamic-symbol ordering.


## C ABI status (v0.22.2 integer and stack argument coverage)

On AArch64 Android, Aster `i32` function arguments and return values use the low 32-bit integer argument/result registers (`w0`–`w7` for the first eight integer arguments and `w0` for the result), matching C functions taking/returning `int`. The C harness calls Aster exports with one, eight, and twelve `int` arguments; twelve-argument functions exercise stack-passed arguments 9–12; Aster also imports Bionic `abs(int)` through PLT with `DT_NEEDED libc.so`.

An Aster-to-Aster 12-argument call additionally checks the compiler-generated outgoing stack-argument area. This remains a narrow scalar ABI slice. `ptr` and raw pointer arithmetic are documented in the pointer section below. The `i64` type (8-byte AAPCS64, see *Wider integer types*) now defines a `long` argument/return; the unsigned narrow types are language-level only and are not yet exposed as distinct C signatures. The ABI does not yet define strings, `size_t`, unions, floating-point
arguments, callbacks, variadic functions, or C header parsing. Structs are
defined since v0.23.5-dev — see *Structs* above. `i32` is not a substitute for pointer-sized or arbitrary C types.


### Pointer ABI and raw memory access (v0.22.3-dev / v0.22.4-dev)

`ptr` is a 64-bit opaque pointer value. A function may accept `ptr`, save it in a local `ptr` binding, and return a `ptr` variable, matching the AArch64 C ABI's `x0` argument/return register for the first argument. Local pointer loads and stores use 64-bit instructions and 8-byte-aligned slots. Pointer/i32 local initialization and return mismatches are diagnosed. The v0.22.4-dev extension supports `*p` as an i32 load and `*p = value;` as an i32 store, requiring the dereference operand to be `ptr`. The generated operations use `LDR Wt, [Xn]` and `STR Wt, [Xn]`. This is unchecked raw memory access: invalid pointers may fault. Aster calls to pointer-signature functions, pointer arithmetic, byte access is available through `load_u8(ptr)` and `store_u8(ptr, i32)` intrinsics, and — since v0.23.23-dev — halfword and quadword access through `load_u16`/`store_u16` and `load_i64`/`store_i64` (see *Halfword and quadword memory intrinsics* below); strings and allocation APIs are not implemented.


Raw pointer memory syntax (v0.22.4-dev):

```aster
fn load_i32(p: ptr) -> i32 {
    return *p;
}

fn store_i32(p: ptr, value: i32) -> i32 {
    *p = value;
    return *p;
}
```

Dereference loads/stores exactly one 32-bit integer. It does not imply that arbitrary pointers are valid, aligned, or large enough; the caller owns those preconditions. Pointer-to-pointer storage and byte-wise string access are not yet supported.


## Byte memory intrinsics (v0.22.6-dev)

The compiler recognizes two built-in calls (no declaration required):

- `load_u8(p) -> i32`: requires one `ptr`, emits `LDRB Wt, [Xn]`, and returns the byte as a zero-extended i32 in the range 0..255.
- `store_u8(p, value) -> i32`: requires a `ptr` followed by an i32 expression, emits `STRB Wt, [Xn]`, stores `value & 255`, and returns the original i32 expression value.

These are compiler intrinsics rather than a first-class `u8` type. They perform unchecked raw memory access; invalid pointers can fault. Example: `return load_u8(p);` and `store_u8(p, 0x1ff);` (the memory byte becomes `0xff`).


## Halfword and quadword memory intrinsics (v0.23.23-dev)

The byte pair's shape, one and three widths up. Four more built-in calls (no declaration required):

- `load_u16(p) -> i32`: requires one `ptr`, emits `LDRH Wt, [Xn]`, and returns the halfword as a zero-extended i32 in the range 0..65535. An unaligned address is accepted; the hardware grants unaligned halfword access, and `ptr + i32` is a byte offset, so `p + 3` is a legal operand.
- `store_u16(p, value) -> i32`: requires a `ptr` followed by an i32 expression, emits `STRH Wt, [Xn]`, stores `value & 0xFFFF`, and returns the original i32 expression value (the same contract as `store_u8` — the store answers what it was given, not the truncated half).
- `load_i64(p) -> i64`: requires one `ptr`, emits `LDR Xt, [Xn]`, and returns the full 64-bit value. Consumed at `i32` width it narrows to the low 32 bits, exactly as any other i64-to-i32 conversion in the language.
- `store_i64(p, value) -> i64`: requires a `ptr` followed by an i32 or i64 expression, emits `STR Xt, [Xn]`, stores the full 64 bits, and returns the original expression value. An i32 `value` widens by **sign-extension** — the same rule that stores an i32 into an `i64` local — so `store_i64(p, -1)` writes eight `0xFF` bytes; a `bool` second argument is rejected, as no `i64` slot accepts one.

Like the byte pair, these are compiler intrinsics rather than first-class `u16`/`i64` *load* types: the access width is spelled by the name, and the result enters the expression lattice as `i32` (halfword) or `i64` (quadword). They perform unchecked raw memory access; invalid pointers can fault. Example:

```aster
let blob: u8[24] = 0;
fn main() -> i32 {
    let r: i32 = store_u16(blob, 0xBEEF);          // the low 16 bits land; r is 0xBEEF
    let q: i64 = store_i64(blob + 8, 0x100000000); // 2^32 — the value a byte
    return load_u16(blob) % 251 + q % 251;         // assembly's << 32 used to drop
}
```

A program that defines its own function of one of these names shadows the intrinsic: the user's definition wins at every dispatch site (`callType`, the semantic check, and codegen), exactly as for `load_u8`/`store_u8`/`load_ptr`/`write`.


## System-call intrinsics (v0.23.40-dev)

Four more built-in calls (no declaration required) that emit a raw Linux AArch64 system call (`MOV X8, #num; SVC #0`) with **no libc** — the input side of a self-hosting compiler, companion to the `write` output primitive. A program that defines its own function of one of these names shadows the intrinsic, exactly as for `write`/`load_u8`.

- `read(fd: i32, buf: ptr, len: i32) -> i32` — syscall 63. Reads up to `len` bytes into `buf`, answers the byte count (0 at end of file). `read(0, &buf, 256)` pulls source in from stdin.
- `openat(fd: i32, path: ptr, flags: i32, mode: i32) -> i32` — syscall 56. Opens `path` relative to the directory `fd`; `AT_FDCWD` is `-100` (the current directory), `O_RDONLY` is `0`. Answers a file descriptor, or a negative `-errno`. **AArch64 has no plain `open`** — 56 *is* `openat`, four arguments.
- `close(fd: i32) -> i32` — syscall 57. Closes a descriptor, answers 0 or `-errno`.
- `fstat(fd: i32, buf: ptr) -> i32` — syscall **80**. Fills a `struct stat` at `buf`; `st_size` is the 64-bit field at offset 48 on AArch64 (`load_i64(buf + 48)`). **79 is `newfstatat`, not `fstat`.**

Every argument is checked in Sema (`callType`) and again in codegen: the count and each argument's kind (`ptr` vs `i32`), naming the offending argument. The result is the **raw kernel return**, not libc's — a failing call answers `-errno` (a `close` of a never-open descriptor is `-9`, which lands 247 in the exit status), because the intrinsic *is* the system call with no wrapper normalising it to `-1`. The `examples/copy.ast` cat copies stdin to stdout in 256-byte chunks with `read`/`write`/`close` alone:

```aster
let buf: u8[256] = 0;
fn main() -> i32 {
    let n: i32 = read(0, &buf, 256);
    while (n > 0) { write(1, &buf, n); n = read(0, &buf, 256); }
    close(0);
    return 0;
}
```


## Heap intrinsics (v0.23.41-dev)

Two more built-in calls that emit a raw system call — `mmap` (x8=222) and `brk` (x8=214) — completing the memory half of self-hosting (`SELFHOSTING-PLAN.md` M1). Aster still owns **no allocator**: these are the kernel's two ways to obtain memory, and a program that wants a heap builds one (the 25-line bump allocator in `examples/arena.ast` is the whole shape). A user function of either name shadows the intrinsic, as for every intrinsic since `write`.

- `mmap(addr: ptr, length: i64, prot: i32, flags: i32, fd: i32, offset: i64) -> ptr` — syscall 222, the widest intrinsic the language has (six arguments, two of them `i64`). A length of 0 maps a page-aligned region chosen by the kernel; a nonzero `addr` is a hint. `prot` is the usual OR of bits (1=read, 2=write, 4=exec); `flags` controls the mapping (32=`MAP_PRIVATE`, 16=`MAP_ANONYMOUS`, the pair 34 being anonymous-private); `fd` is ignored for an anonymous mapping (`-1`); **`offset` must be a multiple of the page size (4096)** — the kernel answers `EINVAL` otherwise, which as a raw syscall arrives as the pointer `-22`. Answers the mapping's address (a `ptr`, so `let heap: ptr = mmap(...)` type-checks and `heap + k` addresses it), or a negative `-errno` on failure.
- `brk(addr: ptr) -> ptr` — syscall 214. With the null pointer (`brk(z)`, `z` the null constant) it *answers* the current break without moving it; with a nonzero, page-aligned address it moves the break there and answers the new one. A program grows its own `.bss`-style region with it, or queries where one ends.

The two rules the implementation adds to the system-call contract, both of them visible only at 64 bits:

- **A 64-bit result is read at full width.** When a syscall intrinsic's result type is `Ty::Ptr` or `Ty::I64` the answer rides `MOV Xd, X0`; an `i32` result still takes the W half. Without the distinction a mapping above 4 GiB — qemu hands them out near `0x4000_0081_2000` — collapses to its low 32 bits, and the first access through the truncated address faults.
- **An `i64` argument rides at full width.** The argument staging keys on `tyIs64`, so an `i64` (a length, an offset) is staged through X exactly like a `ptr`, never truncated through W. Without it a 4 GiB `length` becomes 0 and the kernel answers EINVAL.

Every argument is checked in both passes by count and kind (the `i64` positions refuse a `ptr`; the `ptr` positions refuse an integer — the null constant excepted, per the v0.23.26-dev rule). Results are the raw kernel return (`-errno`), and **a null check is the program's job**: a failing `mmap` answers `-22`, which is not null, so the guard is `map == z` against the null constant, as the language's null-ptr rules define it. `examples/arena.ast` maps one 64 KiB page, bump-allocates three tagged nodes out of it, writes a payload through `store_i64`, reclaims, and re-allocates the same address:

```aster
let z: ptr = 0;                       // the null constant — the only integer that crosses the line
let heap: ptr = mmap(z, 65536, 3, 34, -1, 0);   // 64 KiB, RW, private|anonymous
let cursor: i64 = 0;

fn alloc(n: i64) -> ptr { let p: ptr = heap + cursor; cursor = cursor + n; return p; }
fn reclaim() -> i32 { cursor = 0; return 0; }

fn main() -> i32 {
    let a: ptr = alloc(16);
    store_i64(a, 1234605616436508552);            // 8-byte payload at offset 0
    store_u8(a + 8, 65);                          // tag byte 'A'
    ...
}
```


## The bootstrap lexer stage (v0.23.43-dev)

`SELFHOSTING-PLAN.md` M3a: the first stage of the bootstrap compiler, written
in Aster itself and frozen before the code. `bootstrap/aster.ast` reads one
Aster source from **stdin** and writes the **token stream** to **stdout**,
one token per line — no parsing, no name resolution, no output file:

```sh
aster build-obj bootstrap/aster.ast -o boot.o
aster build-obj stdlib/aster_std.ast -o std.o
aster link-obj boot.o std.o -o asterlex
echo 'fn main() -> i32 { return 0; }' | ./asterlex
```

The contract is `bootstrap/LEXER-SPEC.md` (13 sections, frozen); this section
is the summary a reader of the language needs, and where the two disagree the
frozen document wins.

**72 token kinds**, numbered in the exact order of `enum class TK` in this
compiler: `End`(0), `Ident`(1), `Number`(2), `String`(3), the 22 keywords
(`Fn`(4) … `False`(23), in the order `fn extern main let return if else while
for break continue i32 ptr bool i64 u8 u16 u32 struct include true false`),
then the operators and punctuation (`LParen`(26) … `Amp`(71)). The dump
prints the *name*; the number is part of the contract both implementations
key off.

**Character classes** are the C locale's, as exact byte ranges — the source
is required to be ASCII, and the classes must not drift with locale: space is
`0x20 0x09 0x0A 0x0B 0x0C 0x0D`, digit `0x30–0x39`, xdigit adds `0x41–0x46
0x61–0x66`, alpha is `0x41–0x5A 0x61–0x7A`. Any byte `0x80–0xFF` is refused
(E6); `0x7F` matches no class and no operator, so it falls through to E7.

**Positions** are 1-based, and a column counts **bytes**: a tab advances the
column by 1. A token's position is captured before its first byte is
consumed, after leading whitespace and comments. The `End` token's position
is after all trailing whitespace and comments — `"a\n"` ends with
`End 2 1`, `""` with `End 1 1`.

**The rules** are the host compiler's, deliberately: `//` to end-of-line and
`/* … */` block comments that do not nest (`/*/` is unterminated — after
consuming `/*` the scanner sits on `/`); identifiers `[A-Za-z_][A-Za-z0-9_]*`
with the 22 keywords recognised by exact match; numbers decimal with one
hexadecimal form (`0` alone followed by `x`/`X`, then at least one xdigit —
the prefix stays in the token text, so `0x1F` is one `Number`); string
literals decode the six escapes `\n \r \t \0 \\ \"` into a separate pool and
the token's text is the decoded value; operators are maximal-munch with one
byte of lookahead (two for `<<=`/`>>=`), so `<<=` never cuts into `<<` + `=``.

**The dump** is one line per stored token — `<KindName> <line> <col>` plus a
space-separated `<text>` field for `Ident`, `Number` and `String` (the string
re-escaped with the same six escapes) — then the `End` line. The two phases
(read+lex, then emit) exist so that a failed run leaves stdout byte-empty.

**Nine diagnostics**, one line each on stderr as `aster: error: <message>`,
exit status 1: the host compiler's seven (`unterminated block comment`,
`hexadecimal literal has no digits`, `newline in string literal`,
`unsupported string escape`, `unterminated string literal`, `non-ASCII
character …`, `unexpected character` — same words, same positions) plus two
bootstrap guards with no counterpart in `src/aster.cpp`: **E8**
`source exceeds 1048576 bytes` and **E9** `too many tokens (limit 65536)`.
Both exist because the bootstrap stores the source and the tokens in fixed
global arrays — there is no allocator at this stage — and both are recorded
divergences, not bugs to fix: the host compiler's `std::vector` is unbounded.

Two consequences of the same fixed-array discipline are worth stating,
because they look like bugs and are not: the source buffer is **exactly**
1 MiB with **no sentinel byte**, so `peek()` answers end-of-input by
comparing the cursor against the length — and an **embedded NUL therefore
ends the scan** exactly as the host compiler's `peek()` does (`"ab\0cd"`
yields `Ident "ab"` then `End 1 3`); and the token cap excludes the `End`
token, so 65536 real tokens are accepted and the 65537th is E9.

**The names are data, not code.** `bootstrap/gen_lexer_names.py` is the
single source of truth for the kind names and numbers, the keyword list and
the packed name table; it emits the generated region of `bootstrap/aster.ast`
(72 `K_*` constants, the 72-record × 12-byte packed `ktab`, the `ident_is`
helper and the `keyword_kind` chain) and `tests/lexer_names.h` (the twin's
`enum`, name array and keyword table), and it **cross-checks
`src/aster.cpp`'s `enum class TK`** so a token set that drifts fails the
generator rather than the differential. The C twin `tests/lexer-twin.c` is an
independent implementation of the same contract — a struct array instead of
five parallel arrays, `ctype` instead of byte-range comparisons, a `switch`
instead of the if-chain, `snprintf` where the Aster side uses the library's
`utoa`. Its resident suite `tests/lexer-checks.sh` [11/11] (183 checks, ten
mutation probes) was **retired in v0.23.44-dev** and its coverage folded into
`tests/parser-checks.sh`, which reuses the same lexer twin over the full
lex→parse→dump pipeline: the §9 example and the nine diagnostics pinned
byte-exact on both sides, the operator and keyword tables pinned absolutely,
the differential over a 32-case boundary corpus and the self-lexing set (the
stage reads its own source, the library's and every example), the 1 MiB and
65536-token edges, and ten mutation probes against the Aster source.

One spelling note for anyone extending `bootstrap/aster.ast`: it is compiled
by the host compiler, so its identifiers must avoid the names the host
compiler already claims — the 22 keywords and the builtins
`read write openat close fstat mmap brk load_u8 store_u8 load_u16 store_u16
load_i64 store_i64 load_ptr sizeof len`. `len` in particular is the
element-count operator wherever it appears as a callee name, which is why the
stage's helpers spell the parameter `n`.

## The bootstrap parser stage (v0.23.44-dev)

`SELFHOSTING-PLAN.md` M3b: the second stage of the bootstrap compiler, again
written in Aster itself and frozen before the code. `bootstrap/aster.ast`
extends the M3a lexer with an explicit work-stack recursive-descent parser and
an AST dumper, so the three-phase core `stdin → AST` is complete: one Aster
source in, a compact **AST dump** out on stdout, one line per node. No output
file:

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

The contract is `bootstrap/PARSER-SPEC.md` (13 sections, frozen); this
section is the summary a reader of the language needs, and where the two
disagree the frozen document wins.

**40 node kinds** in three families: `N_*` statements (5, `Program`/`Function`
/`Global`/`Param`/`Block`), `S_*` structural (10, `Return`/`If`/`While`/`Let`/
`Assign`/`IndexAssign`/`Expr`/`Break`/`Continue`/`H`), and `E_*` expressions
(25, the operators and the terminals). Each is a record in a parallel global
array indexed by an integer handle — the arena-subscript-stands-for-a-pointer
discipline that sidesteps the `kMaxStructSize=1024` and no-`union` limits of
the host compiler. The **dump** prints `<KindName> <line>:<col>` plus the
operands the node carries (the callee name for `Call`, the child handles for
compound nodes), one node per line down to the `End` line.

**The §6.1 precedence chain** is exactly C's, ten levels, each level parsed by
one function that loops over its own operator set and builds a left-leaning
tree: `logical(1) → logicalAnd(2) → bitor(3) → bitxor(4) → bitand(5) →
equality(6) → relational(7) → shift(8) → sum(9) → product(10)`. `equality`
and `relational` each admit **at most one** operator (a chained `a == b == c`
is `P54` rejected as a parse error); a binary node **inherits the left
operand's token** for its position; parentheses add no node (they only group).
`++`/`--` are statements only, so an expression has no side effects.

**The position semantics** are the host compiler's, deliberately: `Return`
sits at its *expression* (`s.line = s.expr->line`); `If` sits at its
*condition*; a call-statement's `Expr` sits at the *callee*; the group adds
no node. The same "verify against `src/aster.cpp`" discipline as the lexer
applies.

**The error catalog** is `E1`–`E9` (nine lexer diagnostics, carried over
verbatim), `P1`–`P62` (parser errors: unexpected token, missing `;`, missing
`{`/`}`, a function's argument/return/body problems, the limit gates) and
`B1`–`B22` (block/statement structural errors). Each is one line on stderr as
`aster: <file>:<line>:<col>: error: <message>`, exit status 1 — and the
parser writes **nothing** to stdout until the dump completes, so a failed run
leaves stdout byte-empty.

**The limit gates** are the lexer's E8 (1 MiB source) and E9 (65536 tokens),
plus three parser-local ones: `C1=96` expression nesting, `C2=96` statement
nesting (counting the function's own block, so 95 `if`s pass and 96 fail),
and `C3=65536` nodes — which is **defensive only**: E9 gates token count
ahead of it and the maximum nodes-per-token ratio is 1, so the node cap can
never be reached (a dense 65529-node / 65535-token source proves the headroom
and still passes).

**The names are data, not code.** `bootstrap/gen_parser_names.py` is the
single source of truth for the node-kind names and numbers; it emits the
generated region of `bootstrap/aster.ast` (the `N_*`/`S_*`/`E_*` constants and
the packed name table) and cross-checks `src/aster.cpp`'s `enum class NK` so a
node set that drifts fails the generator rather than the differential. The C
twin `tests/parser-twin.c` is an independent implementation of the same
contract — a C recursive-descent parser over a struct-array AST instead of the
Aster side's seven parallel `i32` arrays — and `tests/parser-checks.sh` [11/11]
holds the two to the frozen document with **312 checks**: the five frozen §9
examples and the 95 pinned diagnostics byte-exact on both sides, the
position/format semantics (empty / comment-only / whitespace-only input, no
trailing newline, CRLF, group-adds-no-node, binary position, prefix position,
else-if nesting, call-statement, two-phase empty stdout), the differential
over a 59-case boundary corpus and the self-parsing set (the parser reads its
own source — 7961 dump lines — and the library's — 555), the limit edges, and
**13 mutation probes** against the Aster source. Two real bootstrap bugs fell
to the suite and were fixed: **P50** fed a node id to the token lookup,
reporting the callee's position as 1:11 instead of 1:20; and **P37/P40**'s
`expected '=' in array element assignment` wrongly appended the assigned name
(`…assignmenta`).


## External pointer-argument calls (v0.22.7-dev)

An external function declaration may specify `ptr` parameters, for example:

```aster
extern fn strlen(s: ptr) -> i32;
extern fn memcmp(a: ptr, b: ptr, n: i32) -> i32;

fn string_length(s: ptr) -> i32 {
    return strlen(s);
}
```

At a call site, every argument must match the declared `ptr`/`i32` type. Pointer arguments use 64-bit AArch64 argument registers and 8-byte stack slots under AAPCS64; i32 arguments use W registers. External functions are linked through PLT imports and must be provided by a declared dependency (for Android Bionic, typically `--needed libc.so`). Strings in this release are supplied by the caller as valid NUL-terminated buffers. Aster string literals were added in v0.22.8-dev; internal Aster pointer-signature calls are supported in v0.22.9-dev.


## String literals (v0.22.8-dev)

A double-quoted string literal is an expression of type `ptr`. The compiler stores its decoded bytes in static `.rodata` and appends one NUL byte when emitting a shared object directly with `build-so`. Supported escapes are `\\`, `\"`, `\n`, `\r`, `\t`, and `\0`. For example:

```aster
extern fn strlen(s: ptr) -> i32;
fn literal_length() -> i32 {
    return strlen("Aster");
}
```

In direct `build-so` output, literal storage is emitted in a dedicated `.rodata` section mapped by a read-only, non-executable `PT_LOAD` segment; mutable `.data` remains writable. As of v0.22.12-dev, `build-obj` emits string literals in `.rodata`; PIC objects can be consumed by `link-so`, which preserves a read-only segment. v0.22.13-dev extends this support to `link-obj` and `link-pie`, which place `.rodata` in a separate read-only, non-executable load segment. v0.22.14-dev also marks generated ET_EXEC and static PIE output files executable so the shell can run them. Embedded NUL bytes are preserved in literal storage, but C string functions stop at the first NUL. Escaped quote and backslash characters are decoded by the lexer. String indexing, first-class byte types, and bounds/lifetime checks are not introduced by this feature. Internal Aster calls with pointer parameters or pointer returns are supported in v0.22.9-dev.


## Internal pointer-signature calls (v0.22.9-dev)

Aster functions may call other Aster functions with `ptr` parameters and/or a `ptr` return type. Arguments must match the declared `ptr`/`i32` types. Pointer values are passed and returned in 64-bit X registers, and pointer arguments beyond the first eight use 8-byte AAPCS64 stack slots. The compiler preserves the type distinction between pointer and integer arguments, but does not validate address provenance, bounds, nullness, alignment, or lifetime.


## Mixed pointer/integer ABI regression fixture (v0.22.10-dev)

The `examples/c_mixed_ptr_stack.ast` fixture combines alternating `ptr` and `i32` arguments across ten parameter positions and forwards them through an internal Aster call. It is intended to exercise register and stack argument placement under AAPCS64, including preservation of a pointer supplied in a stack argument slot. This is regression coverage, not a new source-language feature. Run `sh tests/c-mixed-ptr-stack-structural.sh` for host-safe checks; run `CXX=clang++ HOSTCC=clang sh tests/e2e-c-mixed-ptr-stack.sh` on an AArch64 Android/Termux device for runtime validation.


## Read-only literal storage (v0.22.11-dev)

For direct `build-so` output, decoded string literal bytes and the compiler-added NUL byte are placed in `.rodata`. The ELF maps this section using `PF_R` only; it is neither writable nor executable. The `.data` section remains separately mapped read/write. The relocatable `build-obj` path emits `.rodata`; the `link-so`, `link-obj`, and `link-pie` paths map it into a separate read-only, non-executable load segment.


## Relocatable read-only literal data (v0.22.12-dev, extended in v0.22.13-dev and v0.22.14-dev)

`build-obj` writes string literal bytes to an allocated, non-writable `.rodata` section and records each literal as a global object symbol in that section. `link-so` merges `.rodata` into an R-only `PT_LOAD` segment. In v0.22.13-dev, `link-obj` (ET_EXEC) and `link-pie` (static PIE / ET_DYN) also accept these objects and map `.rodata` on its own page-aligned, read-only, non-executable `PT_LOAD` segment. Relocations targeting literal symbols are resolved against the final `.rodata` virtual address; mutable `.data` and `.bss` remain writable.


## Multi-object `.rodata` merge regression (v0.22.16-dev)

`link-so` accepts multiple PIC ET_REL objects in a single invocation. Each object's `.rodata` bytes are appended at an offset satisfying that input section's alignment, and global object symbols are rebased to the merged section. Relocations from one object can resolve to functions defined in another object; unresolved external functions such as `strlen` remain dynamic imports provided by the declared dependency. The v0.22.16-dev regression test exercises two distinct literal-bearing objects and verifies that the merged `.rodata` remains read-only and non-executable.


## Call results with live expression temporaries (v0.22.17-dev)

A function call used as a subexpression may occur while earlier expression results are live in temporary registers. The compiler copies the call result from the AAPCS64 return register (`w0` for `i32`, `x0` for `ptr`) into the allocated temporary before restoring other live values. The destination register must be encoded as the `MOV` destination, not the source. This is covered by the multi-object `.rodata` expression `aster_multi_rodata_helper() + strlen("object-A")`.


## Three-object `.rodata` regression coverage (v0.22.18-dev)

The regression suite now links three independent PIC objects in one `link-so` invocation. The inputs deliberately reuse private compiler-generated string symbol names and contain embedded-NUL strings; functions form a call chain across object boundaries. The host harness checks that per-object symbol namespacing and `.rodata` offset rebasing remain correct after merging. This documents test coverage, not a new source-language feature.


## Five-object mutation and link-order regression coverage (v0.22.20-dev)

The regression links five PIC relocatable objects in both forward and reverse command-line order. Object D defines the mutable global `multi_shared`; object E increments it by five; object A reads it before and after the call into E. The C harness checks that string literals, a cross-object call chain, and the shared global behave identically under both input orders. This is regression coverage for existing language features, not new syntax. See `VALIDATION-v0.22.20-dev.md`.

## Four-object data-layout regression coverage (v0.22.19-dev)

The linker regression suite combines four PIC relocatable objects containing private string literals, cross-object function calls, and a mutable global defined in one object but referenced in another. This is regression coverage for private `.rodata` symbol namespacing and GOT-style references to merged writable data; it does not introduce new language syntax. See `VALIDATION-v0.22.19-dev.md`.


## Cross-shared-object imports through `link-so` (v0.22.21-dev)

A PIC ET_REL object may retain unresolved `extern fn` and `extern let` references when passed to `link-so`. These become cross-DSO imports in the resulting shared object: imported functions use PLT stubs and `R_AARCH64_JUMP_SLOT` relocations; imported global objects use GOT slots and `R_AARCH64_GLOB_DAT` relocations. `--needed` records the dependency's `DT_NEEDED` entry. The structural regression checks the actual relocation types and target sections; the Android/Termux end-to-end regression loads the resulting library and reads/writes the imported global through the dynamic linker. This adds no new source syntax.


## v0.22.23-dev: same-name symbols across shared objects

The language does not introduce new syntax for symbol visibility. The regression fixtures define identically named file-scope globals and functions in two separate shared objects, each with a distinct `DT_SONAME`. The device harness opens them with `RTLD_LOCAL`, resolves each function through its specific `dlopen` handle, and checks that mutations remain independent regardless of load order. This documents the tested loader behavior; it does not promise isolation for `RTLD_GLOBAL`, explicit dependency graphs, or other loader flags.


## 32-argument external C call coverage (v0.22.38-dev)

The `examples/c_abi_32_external_call.ast` fixture declares a 32-argument external function with alternating `ptr` and `i32` types and forwards all parameters to it. This exercises the Aster caller side of AAPCS64 across integer/pointer registers and stack slots, with the external call routed through a PLT entry. `tests/c-abi-32-external-structural.sh` checks the emitted import and relocation. `tests/e2e-c-abi-32-external.sh` uses an exported native C callback and must be run on AArch64 Android/Termux to establish runtime compatibility. This test does not cover floating-point, aggregate, or variadic ABI rules
(structs have their own suite: `tests/e2e-c-struct.sh`).

## Reading a C `float` return without a float type (v0.23.15-dev)

An `extern fn` whose C implementation returns `float` cannot be captured by
declaring it `-> i32`: the AArch64 result arrives in **s0**, while an
`extern fn … -> i32` call reads **w0** — a different physical register file,
so no aliasing exists and the `w0` read yields garbage (this was the
v0.23.14-dev bug: `examples/native_touch.ast` decoded whatever `w0` happened
to hold and the on-device app never moved a dot). The working technique is a
**bridge**: Aster emits no SIMD instruction of its own and the PLT is eagerly
bound (`DT_BIND_NOW`), so the `s0` a float-returning call leaves behind
survives to the next call — and a zero-argument `lrintf()` issued *immediately*
after (its argument read from `s0`, its `long` result in `x0`, whose low 32
bits the caller reads as the `i32` return) hands back the exact integer. The
two calls must be adjacent, with no Aster call in between:

```aster
extern fn lrintf() -> i32;   // argument: s0 (the float left by the call before)

fn event_x(ev: ptr) -> i32 {
    let junk: i32 = AMotionEvent_getX(ev, 0);   // float -> s0
    return lrintf();                            // s0 -> x0
}
```

`examples/native_touch.ast` uses this for `AMotionEvent_getX`/`getY`; the
compiler's only contribution is `ndkLibraryFor` mapping `lrint*` →
**libm.so**, without which the on-device loader aborts `dlopen` with
"cannot locate symbol". `float` *arithmetic* and float-typed Aster values
remain out of scope — this is a return-value conversion only — and
`tests/touch-coord-test.ast` executes the whole chain under qemu with
`strtof` (also a C float-returning function) standing in for `getX`, over
nine known values including half-way cases (1919.5 → 1920) and negatives.

## Indirect calls through a function pointer (v0.23.24-dev)

A function's name in a value position has been its address (a `ptr`) since the
callback-table work: the address could be stored in a variable, passed as an
argument and handed to C. What it could not do was be *called* — every call
site the compiler emitted branched through a relocated `BL`, and a `BLR` did
not exist. As of v0.23.24-dev, `fp(args)` where `fp` is a `ptr` variable is an
indirect call, compiled to `BLR X9`.

```aster
fn inc(x: i32) -> i32 { return x + 1; }

fn apply(op: ptr, x: i32) -> i32 { return op(x); }   // the callback shape

fn main() -> i32 {
    let fp: ptr = inc;
    let a: i32 = fp(40);      // 41 — through the variable
    let b: i32 = apply(inc, 40);  // 41 — the callee crossed a call as a parameter
    return a + b;
}
```

The rules, and the reasons for them:

- **The callee is a `ptr` variable — local, global, or parameter.** No parser
  rule is involved: an identifier followed by `(` has always parsed as a call,
  and the compiler decides direct versus indirect by asking whether the name
  is a *function* first. **A function name in call position is therefore still
  a direct call** — the function always wins, exactly the rule by which a
  user-defined function shadows an intrinsic. A same-named `ptr` variable does
  not capture a call site.
- **A bare `ptr` has no function type, so it has no signature.** A `ptr`
  variable carries an address, not a signature: no arity check, no parameter
  types, no return type beyond the fixed answer below. *(A **typed**
  fn-pointer — `fn(P1,..,Pn) -> R` — does carry one, since v0.23.37-dev; see
  the next section. The rules below are the bare-`ptr` contract, unchanged.)* The argument-staging consequence
  is the round's one design decision: **every scalar argument rides at 64-bit
  width**. An `i32`-declaring callee reads the low half — exactly the bits a
  32-bit stage would have put there — and an `i64`-declaring one reads a
  properly extended full register, because AAPCS64 leaves a sub-64-bit
  argument's upper half unspecified. One staging width serves both callees.
- **The call answers `i32`.** A callee returning `i64` has its low half
  delivered; consume it at 64-bit width and it is sign-extended, the same
  contract a direct call's `i32` return has always had. Wrap the value in the
  callee if the whole 64 bits matter.
- **A memory-resident function pointer is the dlsym shape.** A pointer stored
  in a struct field (a framework's callback table) is read with `load_ptr`
  into a variable and called through that. Calling through a *computed*
  pointer (`tbl[0] = inc; … tbl[0](x)`) still meets the pre-existing
  "pointer indexing/assignment is not supported yet" limitation.
- **The callee address is materialized into X9 after the arguments are in
  their registers and before SP moves.** X0–X7 hold the arguments, X8 is the
  hidden result pointer when there is one, and X9–X15 hold nothing live — every
  live temporary is parked in the frame — so the register survives to the
  `BLR X9`.
- **Static images may materialize a function address directly.** In
  `build-elf`/`build-pie`/`link-obj`/`link-pie`, `let fp: ptr = f;` links,
  because a static image knows function addresses at link time and ADRP/ADD
  is PC-relative. In `.so` output a function address still travels through a
  GOT slot, because a shared object's text cannot carry load-time relocations.

Sema refuses, each with a diagnostic naming the offending thing: a non-`ptr`
callee (an `i32`, `bool` or struct local; a local or global array; an `i32`
global), an undeclared name in call position, a **struct argument** (a
composite needs a signature to lay it out — register class, copy area, hidden
result pointer — and a `ptr` variable has none), and the address of an
`extern` function ("its location is another object's business"). A `bool`
consumed from the result is refused by the ordinary assignment rule.
`examples/indirect_call.ast` demonstrates every callee form and exits 144,
equal to its C twin (`tests/indirect-call-example-twin.c`, run side by side by
the suite's [4c/7] layer); `tests/indirect-call-checks.sh` [7/7] holds the
contract (19 differential cases against `aarch64-linux-gnu-gcc`, a
shared-object structural check, 10 rejections, a coverage map and an
8-mutant layer).

## Function types (v0.23.37-dev)

A function pointer may be declared **with its signature**. `fn(P1,..,Pn) -> R`
is a new type spelling that rides beside a `ptr` variable, so an indirect call
through it is checked and code-generated like the direct call it stands for:

```aster
fn inc(x: i32) -> i32 { return x + 1; }
fn high32(a: i64) -> i64 { return a >> 32; }
fn combine(a: i32, b: i32) -> i32 { return a * 3 + b; }

fn apply(op: fn(i32) -> i32, x: i32) -> i32 { return op(x); }

let gop: fn(i32, i32) -> i32;            // a global, null until assigned

fn main() -> i32 {
    let fp: fn(i32) -> i32 = inc;        // a local
    let a: i32 = fp(41);                 // 42 — checked and staged by the signature
    let wp: fn(i64) -> i64 = high32;
    let hi: i64 = wp(4294967296);        // 1 — a 64-bit argument at full width
    let b: i32 = apply(fp, a);           // 43 — the signature crosses a call as a parameter
    gop = combine;                       // assigned at run time
    let c: i32 = gop(7, 8);              // 29 — 7*3+8
    return a + b + c + hi;               // 115
}
```

The rules, and the reasons for them:

- **The signature rides beside the ptr, never inside `Ty`.** The storage type of
  a typed fn-pointer is still `Ty::Ptr` — an address is an address — and the
  signature is carried in parallel, exactly as array dimensions are
  (`paramDims`/`slotDims`): on the local `let`, the global and the parameter
  list in the parser, on the binding, the frame slot and the file-scope map in
  Sema and Codegen. One resolver per pass (`funcSigOf`, local then global), one
  contract. A function name in call position is still a direct call, and a
  same-named variable does not capture it — the v0.23.24-dev precedence rule
  stands.
- **A typed call is checked like a direct call.** The argument **count** is
  checked, and each argument's type runs through the same `checkArgument` a
  direct call uses — so an `i32` argument to an `i64` parameter is the same
  legal widening it always was, and a `bool` argument to an `i32` parameter is
  the same refusal. The call's type is the signature's **return type**, so
  `let r: i64 = fp(x);` type-checks.
- **Each argument is staged at the width its signature declares.** An `i32`
  argument rides in a `W` register, an `i64` one in a full `X` register
  (AAPCS64), and a **struct argument is laid out as a composite** — a 12-byte
  `Tri` splits across two registers — rather than being refused as it is for a
  bare `ptr`. This retires the v0.23.24-dev "every scalar rides at 64 bits"
  rule for typed callees; for scalars the two rules coincide (a 64-bit stage
  already served both widths), which is why only the struct case is
  load-bearing.
- **The result is read at the signature's return type** — `i64`, `ptr`, `bool`,
  `u32` or the `i32` default — where a bare-`ptr` call always answered `i32`.
- **A bare `ptr` is unchanged.** Its signature is null, so it keeps the legacy
  64-bit staging and `i32` answer, a struct argument through it is still
  refused (*"a composite needs a signature to lay it out"*), and every program
  written before this round compiles to the same bytes.
- **A global fn-pointer may be left uninitialized** (`let gop: fn(i32) -> i32;`
  zero-fills into `.bss`, exactly as a global `ptr` always could) and assigned
  at run time. `examples/indirect_call.ast`'s global form works unchanged
  because it was already a `ptr`.
- **Two positions were refused in v0.23.37-dev and are open as of v0.23.38-dev**: a **struct field** of function type and a **function returning** a function type. Both now carry a signature the same way a local does — see the two sections below.

`examples/fn_type.ast` exercises every form — a local, the `i64` width, a
fn-pointer parameter, a global assigned at run time — and exits 115, equal to
its C twin (`tests/function-type-twin.c`, run side by side by the suite's
[5/8] layer); `tests/function-type-checks.sh` [8/8] holds the contract (15
differential cases, 9 rejections, a coverage map and an 8-mutant layer).

## Callback tables: a struct field of function type (v0.23.38-dev)

v0.23.37-dev refused a struct field of function type. That refusal was a scope
line, not a verdict, and it left the shape a callback table actually has
unwritable: a `struct` of handlers had to be a `struct` of bare `ptr`s, so no
call site was checked. A field may now declare a function type, and a call may
be written where the field is:

```aster
struct Handlers {
    onClick: fn(i32) -> i32,
    onMove: fn(i32, i32) -> i32,
    tag: i32
}

fn inc(x: i32) -> i32 { return x + 1; }
fn add(a: i32, b: i32) -> i32 { return a + b; }

fn run(h: ptr<Handlers>) -> i32 {
    let a: i32 = h.onClick(41);      // 42 — checked and staged by the field's signature
    h.onClick = add;                 // an assignment is checked by signature too
    return a + h.tag;
}

fn main() -> i32 {
    let h: Handlers = Handlers { inc, add, 3 };
    return (run(&h) + h.onMove(1, 2)) % 251;
}
```

The rules, and the reasons for them:

- **The field is still eight bytes of pointer.** Its storage type is `Ty::Ptr`
  and its length is 8 — unchanged from a `ptr` field — and the signature rides
  beside it in `StructField::funcSig`, the same parallel-signature pattern the
  local, the slot and the global already use. Every existing struct therefore
  lays out byte-identically.
- **A store into the field is checked by signature, not by width.** A struct
  literal's field initializer and a field assignment both run the signature
  comparison, so `Handlers { double_fn, 0 }` where the field wants
  `fn(i32) -> i32` is refused where the literal is written. A **bare `ptr`**
  source is deliberately *not* checked (it carries no signature) — the rule is
  the same one a bare `ptr` has always had.
- **`h.onClick(x)` is its own expression kind, and that is why it works.**
  Every call site — `gen`, `checkCall`, `callType` — keys on the expression's
  name, and v0.23.24-dev's "the function always wins" rule would silently
  reroute a field whose name matches a function in scope: with `fn onClick`
  beside `Handlers.onClick`, `h.onClick(41)` would call the *function* and
  answer 100 instead of 42. The suite pins that case (`ct_clash`).
- **The call is checked and staged by the field's own signature.** A field that
  is not `fn` is refused (*"cannot call field 'tag': its type is i32, not a
  function type"*), the argument count is checked (*"wrong argument count
  calling field 'cb': expected 1, got 2"*), each argument runs through the
  shared `checkArgument`, and the call's type is the signature's return type —
  so an `i64` return is read at full width and a `bool` one as a bool.
- **An array of fn-pointer fields is refused** (*"an array of function pointers
  is not supported: Handlers.onClick"*); a plain `ptr[4]` field is unaffected.
- **A call's result may not itself be called.** `pick(0)(20)` is refused
  (*"cannot call the result of this expression: assign it to a fn(...) variable
  or a fn(...) field first"*), as is a call on a subscripted field's result.

`examples/cb_table.ast` exercises the field side — a local host, a `ptr<H>`
parameter called through and reassigned inside a helper, a read-out into a `fn`
variable — and exits 87, equal to its C twin (`tests/callback-table-twin.c`);
`tests/callback-table-checks.sh` [8/8] holds the contract (12 differential
cases, 8 rejections, a coverage map and a 6-mutant layer).

## Discarded-call statements: `foo();` and `h.onClick(41);` (v0.23.39-dev)

Aster has no "expression statement" — a call result has to land in a `let`, a
`return`, or an arithmetic position — and no `void`, so there was no spelling
for "I call this only for its side effect". A function name in call position is
still a direct call (the function always wins), and for the same reason a bare
variable or an arithmetic value can never have been a statement. v0.23.39-dev
adds the one call form worth allowing: a call written for its side effect alone,
with its result thrown away.

```aster
struct Handlers { onClick: fn(i32) -> i32, onMove: fn(i32, i32) -> i32 }

let fired: i32 = 0;
fn onClickImpl(x: i32) -> i32 { fired = fired + 1; return x + 1; }
fn onMoveImpl(x: i32, y: i32) -> i32 { fired = fired + 1; return x + y; }

fn main() -> i32 {
    let h: Handlers = Handlers { onClickImpl, onMoveImpl };
    h.onClick(41);        // fire-and-forget: the increment runs, the i32 is dropped
    h.onClick(1);
    h.onMove(10, 20);
    let s: i32 = h.onClick(100) + h.onMove(2, 3);   // the same handlers, kept
    return fired * 10 + (s % 10);                    // 56
}
```

The rules, and the reasons for them:

- **Only a call reaches it.** A `Call` or a `FieldCall` as the outermost node of
  a statement is discarded; a bare variable (`x;`), an arithmetic value
  (`a + b;`), and every assignment form keep their existing readings. The parser
  gates the branch with `isCallStatement()` — a peek that walks `h.x.y(` to the
  `(` without consuming a token, so `h.onClick(41)` (a discarded field call) is
  told from `h.field = v` (a field store) and from `h.field` (a bare read), and
  the branch runs *before* the field-assign dispatch would catch the `h.`
  spelling.
- **The discarded call is checked exactly as a kept one.** `Sema::checkStmt`'s
  `Stmt::Expr` case runs `typeOf(*s.expr)`, so a discarded `f(1, 2);` is still
  refused for argument count and a discarded `h.tag(1);` is still refused for
  being a non-function field. The narrowing is the feature: the language gains
  no meaningless expression statement, only a call that drops its answer.
- **Codegen emits the call, then releases the result register.** `gen`'s
  `Stmt::Expr` arm is `int d = gen(*s.expr); releaseTemp(d);` — the callee's
  side effects all run (a discarded `i64` call still stages at full width and
  writes its global), and the temporary `gen` returned (the top of the X0–X15
  pool) is released the same way an assignment releases the value it just
  stored, so the pool cannot leak across statements.
- **What it does not relax.** It does not make `x;` or `a + b;` statements, it
  does not weaken the assignment/`++`/`+=` positions, and it does not touch the
  "expressions are side-effect-free" design for anything but a call — a call
  already runs its body whether or not the caller keeps the answer.

`examples/call-stmt.ast` exercises both forms together (three fire-and-forget
field calls plus two value calls) and exits 56, equal to its C twin
(`tests/call-stmt-twin.c`); `tests/discard-call-checks.sh` [8/8] holds the
contract (9 differential cases, 4 rejections, a coverage map and a 4-mutant
layer).

## A function that returns a function pointer (v0.23.38-dev)

The second position v0.23.37-dev refused. A function's return type may now be
a function type, and the signature travels with it, in the return slot:

```aster
fn inc(x: i32) -> i32 { return x + 1; }
fn dbl(x: i32) -> i32 { return x + x; }

fn pick(which: i32) -> fn(i32) -> i32 {
    if (which == 0) { return inc; }
    return dbl;
}

fn apply(op: fn(i32) -> i32, v: i32) -> i32 { return op(v); }

fn main() -> i32 {
    let f: fn(i32) -> i32 = pick(0);
    let g: fn(i32) -> i32 = pick(1);
    let h: i32 = apply(pick(1), 20);   // the return slot's signature meets the parameter's
    return (f(20) + g(20) + h) % 251;  // 21 + 40 + 40
}
```

The rules:

- **What comes back is still an address.** There is no first-class function
  value; the return type is `Ty::Ptr` and the signature rides beside it.
- **`return` is checked against the return slot's signature**, so `return wide;`
  in a function declared `-> fn(i32) -> i32` is a compile error at the `return`
  — not a silent mismatch discovered at the first call.
- **A call's result answers that signature**, which is what makes
  `apply(pick(1), 20)` one check spanning two functions: the getter's promise
  and the callee's parameter, compared where the argument is written. This is
  also why parameter signatures are collected per *function name* in the
  driver, not per function body — a call site in another function has to be
  able to see what `apply` asked for.
- **The result may not be called on the spot.** `pick(0)(20)` is refused;
  assign it to a `fn(...)` variable, to a `fn(...)` field, or hand it to a
  `fn(...)` parameter — all three carry the signature with them.
- **The return slot does not change codegen.** `let f: fn(i32) -> i32 =
  pick(0);` gets its staging and result widths from `f`'s own declared type,
  which is the same signature. The return slot's worth is measured in the
  mistakes it refuses.

`examples/fn_ret.ast` exercises the return side — two getters, a hand-off to a
`fn` parameter, a zero-argument signature — and exits 108, equal to its C twin
(`tests/function-return-fn-twin.c`); `tests/function-return-fn-checks.sh`
[8/8] holds the contract (12 differential cases, 6 rejections, a coverage map
and a 6-mutant layer).
