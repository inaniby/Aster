# Validation Report — v0.23.30-dev

**Feature: an array has an address — `&buf` is a `ptr`, in all three shapes a
named array takes (a local `T[N]`, a file-scope `T[N]`, and a struct's
`cells: i32[4]` field).**
Until this round `&` was defined for a struct lvalue and nothing else, so
`let p: ptr = &buf;` answered `'&' is only defined for a struct lvalue, not …`
and an array was the one thing in the language a function could not be handed —
which is why every array a function touches in the shipped corpus is a global.

```
$ ./aster build-elf examples/array_address.ast -o aa && ./aa
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
| v0.23.29-dev | a struct field that is an array | language — shipped |
| **v0.23.30-dev** | `&arr` → `ptr` | language — this round |
| v0.23.31-dev | `T[N][M]` | language |
| v0.23.32-dev | DWARF `.debug_info` | toolchain |

The roadmap had originally scheduled `&arr` **together with** `T[N][M]` in
v0.23.30-dev, on the grounds that both are "an array is a thing with an address
and a shape". Building it showed the two share no code: `&arr` is one branch in
`Sema::typeOf` over an address that is already being computed, while `T[N][M]`
needs the type system to carry a recursive length through the parser (several
`[N]` pairs), sema (a length vector) and codegen (nested scaling). Two changes
with no line in common are two versions, so they were split and `.debug_info`
moved to v0.23.32-dev.

## 2. The observation the round is built on: the address was already there

This is why the round is small in bytes. A named array **is decayed at
declaration**:

- a local `T[N]`'s `Binding.ty` is `Ty::Ptr`, and `gen(Var)` already emits
  `ADD Xd, SP, #slot*8` for it — that instruction *is* "the array name decays to
  its address", and it is how `let p: ptr = buf;` has always worked;
- a global `T[N]`'s `typeOf` answers `Ty::Ptr` too, and `emitGlobalAddress`
  materializes it;
- a struct array field's base is `emitStructAddr`, which since v0.23.29-dev
  handles local, global and behind-a-pointer.

So there is **no parser change, no new instruction and no new encoding**. The
only thing missing was the rule letting `&` ask for an address that was always
being computed. `&buf == buf` holds as an address, and that equality is one of
the twelve battery cases.

## 3. The one change: `Sema::typeOf`'s `AddrOf` arm

```cpp
case Expr::AddrOf: {
    if(!isLValue(*e.a))
        throw Error(loc(…,"'&' requires a variable, a field, or a dereferenced ptr<S>"));
    Ty aelem; uint32_t alen=0;
    if(arrayOperandOf(*e.a,aelem,alen)){
        if(tySize(aelem)!=4u)
            throw Error(loc(…,"'&' on an array needs a 4-byte element type: this array's elements are "
                            +tyNameFull(aelem)+", and a ptr indexes at 4 bytes"));
        return Ty::Ptr;
    }
    const Ty inner=typeOf(*e.a);
    if(!tyIsStruct(inner))
        throw Error(loc(…,"'&' is only defined for a struct lvalue, not "+tyNameFull(inner)));
    return Ty::ptrTo(inner.sid);
}
```

and the predicate it calls:

```cpp
bool arrayOperandOf(const Expr& e,Ty& elem,uint32_t& len){
    if(e.k==Expr::Var){
        if(const Binding* b=find(e.name)){
            if(!b->len)return false;              // a scalar local, or a ptr
            elem=b->elem; len=b->len; return true;
        }
        if(arrayGlobals.count(e.name)){           // a file-scope T[N]
            elem=arrayElemTypeOf(e.name); len=arrayLengthOf(e.name); return true;
        }
        return false;
    }
    if(e.k==Expr::Field){                         // a struct's array field
        const StructField* f=arrayFieldOf(typeOf(*e.a),e);
        if(!f||!f->len)return false;
        elem=f->ty; len=f->len; return true;
    }
    return false;
}
```

### 3.1 Why it asks about the length and not the type

Because the array is decayed, an `i32[4]` and a `ptr` are **the same type** —
`Ty::Ptr` — so no amount of inspecting `Binding.ty` can tell them apart. The
question "is this an array?" is therefore a question about the *length*: does
this binding have one, is this name in `arrayGlobals`, does this
`StructField` carry one. That is the round's central insight, and mutant **m2**
is the mistake it exists to prevent — it makes the local arm answer `b->ty`
(the decayed 8-byte type) instead of `b->elem`, and an ordinary `i32[4]` is then
refused by the 4-byte gate.

### 3.2 Why the gate is a refusal and not a feature

`p[i]` on a `ptr` has always been `*(p + i*4)`, and Aster has no pointer type
that carries a stride. Handing over the address of an `i64[4]` would therefore
be **silently lying** about the distance between elements. The honest answers are
two — refuse, or invent a fatter pointer — and the second is a type-system
change, not a one-line gate. So `tySize(aelem) != 4u` throws, and the diagnostic
names the element type and says why:

```
'&' on an array needs a 4-byte element type: this array's elements are i64, and a ptr indexes at 4 bytes
```

Admitted: `i32[N]`, `u32[N]`, `bool[N]` (a 4-byte 0/1 slot an element) and an
`S[N]` whose `sizeof(S)` is 4. Refused: `i64`, `u8`, `u16`, `ptr`, and a
12-byte struct — in all three shapes.

### 3.3 Why the result is a plain `ptr` and not a `ptr<T>`

The address of an array is the address of its first element, and `ptr` is the
type that indexes, stores and passes. A `ptr<S>` would also have brought
struct-field syntax (`p.f`) to something whose fields are elements, which is not
a thing the language has. The struct branch below it is untouched and still
answers `ptr<S>`.

## 4. Why no existing program changed, argued and then measured

- **The arm is additive.** Every operand that is not an array takes exactly the
  path it took before — the two pre-existing `&` rules are still there, and are
  pinned again by [2/9] and [5/9] because the round rewrites the arm that owns
  them.
- **An array address is reachable only through `&arr`,** which was a compile
  error before this round, so no program that compiled can reach the new code.
- **No codegen changed at all.** `emitStructAddr` already covered all three
  bases, and no encoding was added.

Then measured: **288 of 288 pre-existing baseline rows reproduce byte for byte**
across `build-so` / `build-elf` / `build-obj --pic`, and the three new rows are
`examples/array_address.ast`'s three output modes (297 → 300 lines in
`tests/baseline/v0.23.5-dev/example-hashes.txt`).
`tests/rebuild-baseline-v0.23.30.sh` refuses to write the baseline unless both
hold.

## 5. `tests/array-address-checks.sh` — nine layers, all run

| Layer | What it is | Count |
| --- | --- | --- |
| [1/9] | strict rebuild: `-std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror` | 1 |
| [2/9] | source guards pinning the new rule, its three arms, and the two old rules it must not have displaced | 11 |
| [3/9] | behavioural cases under qemu | 12 |
| [4/9] | gcc-differential pairs (Aster vs `aarch64-linux-gnu-gcc -O2`), no hand-computed expectations | 3 |
| [5/9] | rejection matrix | 14 |
| [6/9] | coverage map: which case exercises which rule | 18 |
| [7/9] | mutation layer: each rule, withdrawn, is caught | 7 |
| [8/9] | byte-identity baseline | 288/288 + 3 |
| [9/9] | the shipped example, end to end | exit 63 |

### 5.1 The twelve battery cases

Every shape an array's address can take, and the two properties that are easy to
get wrong:

| Case | Exit | What it pins |
| --- | --- | --- |
| local array by reference | 28 | the local arm, read through a `ptr` parameter |
| written through a reference | 5 | a store through one that the **caller** must see, not a copy |
| global array by reference | 44 | the `arrayGlobals` arm |
| bool array by reference | 3 | `bool[N]` is a 4-byte slot an element |
| u32 array by reference | 100 | the other 4-byte integer width |
| 4-byte struct array by ref | 10 | `sizeof(S) == 4`, so `S[N]` travels |
| array field by reference | 10 | `&s.cells`: field base + offset |
| array field behind `ptr<S>` | 9 | the same, where the base is a pointer value |
| address in a variable | 12 | the address kept, indexed at a **computed** offset |
| two arrays, two addresses | 3 | two frame slots do not alias |
| reference passed onward | 18 | a reference handed to a second callee |
| `&buf` and `buf` agree | 7 | the round's premise: `&buf` is the decayed name |

### 5.2 Two mutants that earned their shape

**m2** (the local arm answers the decayed type) is described in §3.1. It is a
`must_not_compile`: the mutant makes a legal program a compile error, which is a
refusal and not a red battery, and that is the honest witness — the mutant
withdraws the round's central distinction.

**m7** drops the `*8` from the frame address
(`addImm(kGlobalBase,31,(uint32_t)slot)`), so `&a` names the wrong place for
every array past slot 0. That is the exact shape of the **v0.22.50-dev
frame-base bug**, with the same kind of invisibility: an array in slot 0 is
unaffected, so the witness declares a `pad` local first, then reads 7 out of
`i32[4] = 7` — and must *differ*, because a wrong offset is not a predictable
wrong answer.

The other five: **m1** withdraws the whole predicate (every array address falls
through to the struct-only rule); **m3** and **m4** withdraw the global arm and
the field arm respectively; **m5** withdraws the 4-byte gate (so an `i64[2]`
must now compile — accepted, where the real compiler refuses it); **m6** makes
`&arr` answer the element type instead of `ptr`.

### 5.3 Fourteen rejections, six of which pin rules that must *not* have moved

The gate is tested in all three shapes and for five element types (`i64`, `u8`,
`u16`, `ptr`, a 12-byte struct). Then:

- `&buf` into an `i32` parameter — `argument type mismatch calling takes at
  argument 1: expected i32`;
- `&` of a `ptr` variable, an `i32` variable, a `bool` variable, a scalar struct
  field — `'&' is only defined for a struct lvalue, not …`;
- `&f()` — `'&' requires a variable, a field, or a dereferenced ptr<S>`;
- `&a[0]` on an `i32[2]` — still refused, because `&` on an element is still
  struct-only. Opening `&` for a whole array must not have opened it for an
  element.

### 5.4 Three resident suites updated on the record

Each one compares the byte baseline, and `examples/array_address.ast` is new —
so each had to be told it is new rather than pre-existing. None was weakened:
all three still assert the same **288** pre-existing rows.

| Suite | What changed |
| --- | --- |
| `precedence-checks.sh` | the baseline filter gained `-e '^array_address\.'`, and its comment now says three *families* are excluded (it said two, from before v0.23.29-dev) |
| `array-elem-types-checks.sh` | same filter |
| `struct-array-field-checks.sh` | same filter, and its comment now says four families |

## 6. What this deliberately does not do

- **An array is still not a parameter or a return value.** `&arr` hands the
  address over; the callee sees a `ptr`.
- **No pointer type that carries a stride.** An array whose element is not 4
  bytes wide still cannot be handed over at all — that is the gate in §3.2, not
  a bug.
- **`&a[0]` on a non-struct element is still refused**, as it always was.
- **No multi-dimensional arrays** (`T[N][M]`, now v0.23.31-dev), and no nested
  array field (`xs: i32[2][2]`), which is the same work.
- **No `sizeof`**, and no way to ask an array for its length in an expression.
- **No `&arr` where a `ptr<S>` is expected** — the result is a plain `ptr`.

## 7. Byte identity: 288 of 288

`tests/array-address-checks.sh` [8/9] hashes every example in three modes
against `tests/baseline/v0.23.5-dev/example-hashes.txt` and asserts the split
directly — 288 pre-existing rows byte-identical and 3 new rows recorded — so the
two numbers cannot drift apart. `tests/rebuild-baseline-v0.23.30.sh` refuses to
write the baseline unless every old row reproduces.

## 8. Verification log

`tests/array-address-checks.sh`, run on this tree
(`HOSTCC=aarch64-linux-gnu-gcc`), abridged:

```
[1/9] Strictly build Aster compiler
[2/9] Source guards: the new rule and its three arms
  all guards present                 ok
[3/9] qemu: every shape an array address takes
  local array by reference           28
  written through a reference        5
  global array by reference          44
  bool array by reference            3
  u32 array by reference             100
  4-byte struct array by ref         10
  array field by reference           10
  array field behind ptr<S>          9
  address in a variable              12
  two arrays, two addresses          3
  reference passed onward            18
  &buf and buf agree                 7
[4/9] Differential: Aster vs the target C compiler
  local + global + write-through     7
  array field, behind a ptr<S>       20
  examples/array_address.ast         63
[5/9] Rejection matrix
  & of a local i64[2]                refused
  & of a local u8[2]                 refused
  & of a local u16[2]                refused
  & of a local ptr[2]                refused
  & of a 12-byte struct array        refused
  & of a global i64[2]               refused
  & of an i64 array field            refused
  &buf into an i32 parameter         refused
  & of a ptr variable                refused
  & of an i32 variable               refused
  & of a bool variable               refused
  & of a scalar struct field         refused
  & of a call result                 refused
  & of an i32 array element          refused
[6/9] Coverage map: which case exercises which rule
  cases mapped to a rule             18
[7/9] Mutation layer: each rule, withdrawn, is caught
  m1: arrayOperandOf is gone         caught
  m2: local arm reads the decayed type caught
  m3: global arm is gone             caught
  m4: array-field arm is gone        caught
  m5: the 4-byte gate is gone        caught
  m6: &arr answers the element type  caught
  m7: frame address not scaled       caught
PASS: seven mutated compilers each lose exactly one rule, and the checks notice
[8/9] Byte-identity baseline
  pre-existing rows byte-identical   288
  new example rows recorded          3
PASS: byte-identity baseline holds
[9/9] The example, end to end
  array_address.ast                  63
PASS: the example runs and returns the value its C twin returns
=== array address checks: ALL PASSED ===
```

Full CI: **87 passed / 0 skipped / 0 failed** (the suite is registered in
`tests/ci.sh` after `struct-array-field-checks.sh`).
