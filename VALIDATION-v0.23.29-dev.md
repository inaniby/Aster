# Validation Report — v0.23.29-dev

**Feature: a struct field may be an array — `nums: i32[4]` inside a `struct`.**
Until this round `structDeclaration()` parsed `field: T` and stopped, so
`nums: i32[4]` was a syntax error, and the previous round ended by naming
exactly this as out of scope (*"a struct *field* that is an array"*). Four
things had to move together, and none of them alone would have been enough:

1. **`StructField` had nowhere to keep a length.** Even parsing `[4]` would not
   have made the field addressable: a field's offset is the only thing the
   layout records, and an array field needs `sizeof(element) * length` bytes.
2. **`postfix()` ran a `.` loop and then a `[` loop** — two passes — so
   `b.pts[1].a`, the first thing anyone writes with an array field, could not be
   built at all: it is a field, then an index, then a field.
3. **The element address would have been a second copy** of the scaling
   arithmetic a named array already has, and two copies of one rule is how the
   previous round's hole (3) became reachable.
4. **A struct containing an array field cannot be built by a literal** —
   `Name { … }` takes one value per field and an array field needs `length` of
   them — so the language had to offer the shape that *does* work: declare it
   and write the elements. That is new in its own right; until now every `let`
   had to carry an initializer.

```
$ ./aster build-elf examples/struct_array_field.ast -o saf && ./saf
$ echo $?
63                                     # matches the gcc twin of the same program — §4 [4/9]
```

## 1. Why this round exists

The user was offered four candidate rounds — a struct array field, taking the
address of a whole array, multi-dimensional arrays, and DWARF `.debug_info` —
and answered *"这4项一起做"*. The roadmap's first principle is that **one version
is one coherent theme**, so the four are three versions and not one:

| Version | Contents | Kind |
| --- | --- | --- |
| **v0.23.29-dev** | a struct field that is an array | language |
| v0.23.30-dev | `&arr` → `ptr`, and `T[N][M]` | language |
| v0.23.31-dev | DWARF `.debug_info` | toolchain |

That split is what keeps a regression bisectable: if the array-address work
broke something, it is not in the same commit as the field layout.

This round is the first of the three, and it is the one the previous round
explicitly deferred — which makes it the cheapest to argue: the element
addressing rule already exists (`emitElemIndex`, shift-or-`UMADDL`), the lvalue
rules already exist, and the bounds rules already exist. What was missing was a
place to *put* a length and a grammar that could reach it.

## 2. The four changes

### 2.1 `StructField` carries a length, and the layout reserves it

```cpp
struct StructField { std::string name; Ty ty; uint32_t offset = 0; uint32_t len = 0; };
```

`layoutStruct()` lays a field out at `sizeof(element) * len` bytes when `len`
is non-zero and at `tySize(ty)` when it is zero, so nothing about a scalar field
moves. The length is bounded where it is parsed:

```cpp
if(flen==0||flen>1000)
    throw Error(loc(id.line,id.col,"array field length must be between 1 and 1000"));
```

the same 1..1000 a local array takes. A length is not a new node kind: a named
`Index` carries the array's name in `e.name` and its index in `e.a`, while a
field `Index` carries the `Field` in `e.a`, the index in `e.b` and an empty
`name`. One free function tells them apart:

```cpp
static const StructField* arrayFieldOf(Ty base,const Expr& field){
    if(field.k!=Expr::Field)return nullptr;
    const StructField* f=structFieldOf(base,field.name);
    if(!f||f->len==0)return nullptr;
    return f;
}
```

It is a **free** function and not a member because `Parser` and `Sema` are two
different classes and both need it — a first cut made it a `Codegen` member and
Sema could not call it. `base` is the type of `field.a` (the *struct*), not the
field's own type; the first version passed the field's own type and every
subscript answered `cannot read field 'nums' of i32`.

### 2.2 Brackets and dots are one loop

```cpp
while(cur().k==TK::Dot||cur().k==TK::LBracket){
    if(cur().k==TK::Dot){ … e=Expr::Field(e, name); }
    else { … e=Expr::Index(e, idx, ""); }
}
```

The old shape was two loops — dots, then brackets — which can only ever produce
a dot chain followed by a bracket chain. Interleaving them is what makes
`b.pts[1].a`, `b.nums[i] = v` and `&b.pts[1]` parse, and it is a re-ordering of
two passes that never both applied to the same token before, which is why no
previously accepted expression parses differently (§3).

### 2.3 The element address is composed, not written twice

```cpp
void emitElemAddrField(const Expr& fbase,const Expr& index){
    const StructField* f=arrayFieldOf(exprType(*fbase.a),fbase);
    …
    emitStructAddr(fbase);          // local, global, or behind a pointer
    emitElemIndex(r, elem);         // shift for a power of two, UMADDL otherwise
}
```

`emitElemIndex` is v0.23.28-dev's, reused unchanged: `elemShiftOf` answers -1
for a size that is not a power of two and the emitter falls back to `UMADDL`,
which is why a 12-byte `Vec3` element is scaled by a multiply here for exactly
the reason it is inside a `Vec3[2]` local — and why there is no second copy of
that arithmetic to disagree.

### 2.4 Bounds checking split by what it knows

A named array is checked **by name** (the compiler looks the binding up); a
field has no binding, but its length is right there on the `StructField`. So
each of the two passes gained a length form next to the name form it already
had:

```cpp
static void checkArrayBounds(uint32_t len,const Expr& idx);   // Sema
void emitBoundsCheck(uint32_t len,const Expr& idx,int line);  // Codegen
```

and a constant index out of range answers
`array index out of bounds: index 9, length 4`.

### 2.5 A struct containing an array field is declared, not initialized

`structHasArrayField()` is recursive, so a struct *containing* a struct with an
array field is refused too, at both scopes:

```
struct 'Buffers' contains an array field and cannot be initialized by a literal
```

The shape that works is `let b: Buffers;` — a struct `let` with **no
initializer**, which is new: `letStatement()` accepts it for a struct type and
zero-fills the frame slots, and a struct global without an initializer lands in
`.bss`.

## 3. The round's one real bug: the zero-fill stored `x0`

An uninitialized struct local emitted

```cpp
for(int i=0;i<slots;++i)emit(0xf90003e0u|((uint32_t(slot+i))<<10));   // WRONG
```

`STR Xt, [SP, #imm]` takes its source from `Rt = bits[4:0]`, and **`Rt == 0` is
`x0`, not XZR** — the zero register is `31`. So every uninitialized struct local
was filled with whatever `x0` happened to hold at that point.

```
; before the fix, in examples/struct_array_field.ast
str x0, [sp, #8]      ; not  str xzr, [sp, #8]
```

The shipped example had been **surviving by luck**: the statement immediately
before it left `x0` at zero, so the wrong fill happened to be the right value.
The `ptr field element` battery case is the first witness that can see it — it
writes an address into `b.ptrs[1]` and then reads `b.ptrs[0]`, a *different*
element, which a wrong fill makes non-null. The encoding is now

```cpp
emit(0xf90003e0u|31u|((uint32_t(slot+i))<<10));   // Rt must be XZR (31)
```

and a source guard pins the `31u`. Mutant **m6** re-creates the bug on purpose
and the `ptr` case must catch it.

Two more defects surfaced from the same no-initializer shape, both found by
running and not by reading:

- **`emitStructAddr()`'s `Index` arm threw `cannot take the address of this
  expression`** for any non-struct element. That is a *Sema* rule about `&`
  which had been copied into codegen, and it blocked the ordinary store path
  `b.ptrs[1] = &anchor` — not just `&b.ptrs[1]`. The throw is gone; Sema's
  `AddrOf` rule still owns that boundary.
- **`Sema::checkStmt()`'s non-array `Let` branch dereferenced `*s.expr`
  unconditionally**, so `let b: Buffers;` — legal now — segfaulted inside
  `typeOf()` (exit 139). The branch begins with
  `if(!s.expr){scopes.back()[s.name]=Binding{s.ty,0};return;}`.

## 4. Why no existing program changed, argued and then measured

- **A scalar field is untouched.** `len == 0` takes the old path in
  `layoutStruct`, so offsets, load widths and types are what they were.
- **The postfix re-ordering cannot change a parse.** Two passes that never both
  applied to the same token, folded into one loop that takes them in source
  order: an expression the old grammar accepted produces the same tree.
- **The new element addressing is additive.** `emitElemAddrField` is reached only
  when `arrayFieldOf` answers non-null, and it can only answer non-null for a
  field with a length — which could not be declared before this round.
- **The zero-fill change is additive too.** The only `let` without an
  initializer that could exist before was… none: every shipped example
  initializes.

Then measured: **288 of 288 pre-existing baseline rows reproduce byte for byte**
across `build-so` / `build-elf` / `build-obj --pic`, and the three new rows are
`examples/struct_array_field.ast`'s three output modes (294 → 297 lines in
`tests/baseline/v0.23.5-dev/example-hashes.txt`).
`tests/rebuild-baseline-v0.23.29.sh` refuses to write the baseline unless both
hold.

## 5. `tests/struct-array-field-checks.sh` — nine layers, all run

| Layer | What it is | Count |
| --- | --- | --- |
| [1/9] | strict rebuild: `-std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror` | 1 |
| [2/9] | source guards pinning each change where it lives | 18 |
| [3/9] | behavioural cases under qemu | 9 |
| [4/9] | gcc-differential pairs (Aster vs `aarch64-linux-gnu-gcc -O2`), no hand-computed expectations | 2 |
| [5/9] | rejection matrix | 10 |
| [6/9] | coverage map: which case exercises which rule | 15 |
| [7/9] | mutation layer: each rule, withdrawn, is caught | 7 |
| [8/9] | byte-identity baseline | 288/288 |
| [9/9] | the shipped example, end to end | exit 63 |

### Three mutants that earned their shape the hard way

**m4** (dropping the field length so `len` is 0) had to become a
`must_not_compile`: with the length gone, `b.nums[0]` indexes a *non-array*
field and the program is refused before it can run. That is a refusal, not a red
battery — and it is the honest witness, because the mutant withdraws the
declaration shape itself.

**m5** (scaling every element by 4 instead of `sizeof(element)`) was first
witnessed by writing `b.pts[1].a` and reading it back — which is precisely the
one read that cannot see a wrong stride, since the wrong address still lands
inside the element written. The witness now reads `b.pts[0].b`, a *different*
element: under the broken stride `b.pts[1].a` lands at offset 4, which is
`b.pts[0].b`, so the read answers 100 against the real 0.

**m7** (withdrawing the field path's sign-extension) needed its `sed` anchored
on the site's own indentation, because the named-array path carries the same
`if(tyIs64(want)&&elem==Ty::I32)` rule one level out and must keep it. The
witness is `let x: i64 = b.nums[0];` on a `-5`: without the `SXTW` the value
reads as `0x00000000FFFFFFFB` and the equality against `-5` fails.

### Five resident suites updated on the record

Each one moved because the round relocated the thing it was measuring, or
because a guard's *subject* became legal. None was weakened.

| Suite | What it pinned | What it pins now |
| --- | --- | --- |
| `struct-checks.sh` | `array fields are not supported: P.a` | the rule that replaced it: a *literal* initializer for a struct that has one is refused (`struct 'P' contains an array field and cannot be initialized by a literal`) |
| `array-elem-types-checks.sh` | `struct field i32[2]` / `struct field bool[2]` refused | a **nested** array field (`i32[2][2]`) refused, and an array field of length 0 refused; both baseline filters also exclude the new example family |
| `condition-checks.sh` | 16 `rejectBool` occurrences (1 definition + 15 calls) | 17 — the 16th call is the array-field index, which needs the same "an index is not a bool" rule a named array's does |
| `wide-int-literal-checks.sh` | 1 index-leaf `SXTW` site, 7 in total | 2 and 8 — the field path owns one of its own |
| `precedence-checks.sh` | 288 pre-existing baseline rows | the same 288, with the new example family excluded from the comparison |

## 6. What this deliberately does not do

- **An array field may not itself be an array.** `xs: i32[2][2]` is refused —
  that is multi-dimensional arrays, the next language round.
- **An array field may not be initialized by a literal**, and a whole array
  field may not be assigned (`b.nums = …`).
- **An array is still not a parameter or a return value**, and a struct
  containing an array field is still copied by value under AAPCS64 — only Aster
  programs declare one.
- **No `sizeof`**, no way to ask a struct for its size, no array assignment as a
  whole — all unchanged.
- **A `ptr` element is still not ordered** (`==`/`!=` only), and a whole struct
  element is still not a register value.

## 7. Byte identity: 288 of 288

`tests/struct-array-field-checks.sh` [8/9] hashes every example in three modes
against `tests/baseline/v0.23.5-dev/example-hashes.txt` and asserts the split
directly — 288 pre-existing rows byte-identical and 3 new rows recorded — so the
two numbers cannot drift apart. `tests/rebuild-baseline-v0.23.29.sh` refuses to
write the baseline unless every old row reproduces.

## 8. Verification log

`tests/struct-array-field-checks.sh`, run on this tree
(`HOSTCC=aarch64-linux-gnu-gcc`), abridged:

```
[1/9] Strictly build Aster compiler
[2/9] Source guards: the four changes
  all four changes pinned, in both passes
[3/9] qemu: every element type of a struct array field
  i32 field element                 11
  i32 field element, global         7
  bool field element                2
  ptr field element                 4
  struct field element              8
  address of struct element         16
  12-byte element both scopes       32
  struct element copy               15
  i32 field element into i64        64
[4/9] Differential: Aster vs the target C compiler
  i32/bool/ptr elements, both scopes 31
  examples/struct_array_field.ast   63
[5/9] Rejection matrix
  index a scalar field              refused
  index a struct field              refused
  index a bool field                refused
  index a scalar field then .y      refused
  struct array field OOB            refused
  local literal of array-field struct refused
  global literal of array-field struct refused
  array field length 0              refused
  array field length 1001           refused
  struct element into an i32        refused
[6/9] Coverage map: which case exercises which rule
  cases mapped to a rule            15
[7/9] Mutation layer: each rule, withdrawn, is caught
  m1: arrayFieldOf is gone          caught
  m2: postfix splits . and [        caught
  m3: array-field struct takes a literal caught
  m4: array field length dropped    caught
  m5: struct element scaled as i32  caught
  m6: zero-fill stores x0 not XZR   caught
  m7: i32 field element not widened caught
[8/9] Byte-identity baseline
  pre-existing rows byte-identical  288
  new example rows recorded         3
[9/9] The example, end to end
  struct_array_field.ast            63
=== struct array field checks: ALL PASSED ===
```

Full CI: **86 passed / 0 skipped / 0 failed** (the suite is registered in
`tests/ci.sh` after `relro-checks.sh`).
