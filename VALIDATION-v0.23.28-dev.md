# Validation Report — v0.23.28-dev

**Feature: an array's element type is the type written before the `[N]`.**
Aster's type lattice is complete — `i32` `u32` `i64` `u8` `u16` `ptr` `bool` and
a struct, each with a size, an alignment and a set of rules. What was not
complete is what a type means *inside an array*: `T[N]` could only ever be
`T = an integer`. Three places in the compiler disagreed with the sentence, and
one rule was missing underneath all three:

1. **A local `bool[N]`, `S[N]` or `ptr[N]` did not parse.** `letStatement()`
   opened the `[N]` suffix only after an integer type, and a local `ptr[N]`
   carried a refusal of its own (`local pointer arrays are not supported`).
2. **A global `bool[N]` or `S[N]` did not parse.** `globalDeclaration()`'s Bool
   branch and Struct branch never looked for a `[`, although the scalar branch
   two dozen lines below them did.
3. **`typeOf(a[i])` answered `i32`** whatever the element really was, while
   codegen loaded and stored at the element's real width — so `let q: Point =
   a[1];` was a type error against itself.
4. **A struct element cannot be scaled by a shift.** A struct's size is a
   multiple of its alignment and need not be a power of two (`{ i32, i32, i32 }`
   is 12), and the old `tyShift` answered 2 for every type it did not name.

```
$ ./aster build-elf examples/array_elem_types.ast -o aet && ./aet
$ echo $?
127                                    # matches the gcc twin of the same program — §4 [4/9]
```

## 1. Why this round exists: the types are complete, the element is not

The user asked one question: *"现在编译器基本类型有哪些，需要扩充完善没？"*
The survey came back in two halves. The **types** need nothing — eight of them,
each defined, each covered. The **array** is where the survey found a gap: the
element type of `T[N]` is the one place a type declaration was parsed and then
not believed.

Three holes and one rule were offered, ordered by risk, and the lowest-risk one
was chosen: *"补齐数组元素类型（推荐）"* — make `bool[N]`, `S[N]` and a local
`ptr[N]` work. The other two stay on the roadmap (a struct *field* that is an
array; an element type for a `ptr` local's subscript).

Hole (3) is the interesting one, because it is not a missing feature but a
**disagreement inside the compiler**: sema said `i32`, codegen said the element's
width, and both were believed. Nothing in the suite noticed, because no shipped
program could contain the disagreement (a `Point` element could not be declared).
Fixing it is what makes `&a[i]` and a whole-element copy type-check — which is
what a struct array needs before it is useful at all.

## 2. The three holes and the one rule

### 2.1 A local array's `[N]` is open to every element type

```cpp
// was: if(tyIsInteger(ty)){ … }  — and `ptr` was refused outright
if(eat(TK::LBracket)){
    auto n=need(TK::Number,"expected array length");
    unsigned long long cnt=unsignedLiteral(n,"array length");
    if(cnt==0||cnt>1000)throw Error(loc(id.line,id.col,"local array length must be between 1 and 1000: "+id.s));
    need(TK::RBracket,"expected ']' after array length");
    s.isArray=true;s.count=(uint32_t)cnt;
}
```

The element type is `s.ty` — the type already parsed, before the `[`. Sema's
`Binding` carries it (`Ty elem`) next to the length, and codegen records it in
`slotElemTypes`, so a later `a[i]` reads it back from either pass rather than
re-deriving it from the name.

### 2.2 Both closed global branches parse `[N]`

Three branches, three identical `[N]` parsers now (`grep -c` asserts 3). For a
struct, `layoutObject` repeats the constant aggregate's bytes once per element:

```cpp
if(tyIsStruct(g.ty)){
    const uint64_t n=g.isArray?g.count:1;
    …
    for(uint64_t i=0;i<n;++i)L.data.insert(L.data.end(),g.rawData.begin(),g.rawData.end());
```

which is what "every element is a copy of the initializer" means in bytes.

### 2.3 `typeOf(a[i])` answers the element type

```cpp
case Expr::Index: {
    …
    return arrayElemTypeOf(e.name);      // was: return Ty::I32;
}
```

### 2.4 A struct element is scaled by a multiply, not by a shift

```cpp
static int elemShiftOf(Ty t){
    const uint32_t sz=tySize(t);
    if(sz==0||(sz&(sz-1))!=0u)return -1;   // the old tyShift returned 2 here
    int s=0;while((1u<<s)!=sz)++s;
    return s;
}
void emitElemIndex(int idxReg,Ty elem){
    const int sh=elemShiftOf(elem);
    if(sh>=0){ emit(0x8b200000u| … |(uint32_t(sh)<<10)| …); return; }
    const int sz=temp();
    emit(movInt(sz,tySize(elem)));
    emit(0x9ba00000u| … );               // UMADDL X16, Wsz, Widx, X16
    releaseTemp(sz);
}
```

**The fallback's first spelling was wrong, and wrong in the one way AArch64
punishes quietly.** The natural way to widen a 32-bit index is
`ADD X16, XZR, Widx, UXTW #0` — but in the *extended* add the field `Rn == 31`
is the **stack pointer**, not `XZR`. That instruction added `SP`, so every struct
array read through this path walked off the frame: a 12-byte element both
globally and locally **segfaulted** (exit −11) before the fix. `UMADDL` reads
both operands as the 32-bit values they are and needs no zero-extension of its
own. The trap is recorded in a comment next to the emit, and a source guard
asserts the comment is still there.

### 2.5 One address for every path

`emitElemAddr(name, index)` is now the single place a read, a store, a field of
one and `&a[i]` compute `base + index*sizeof(T)` and the bounds check, over
three bases — a local `T[N]` at its frame slot, a fixed-size global by
`ADRP`+`ADD`, and a `ptr` local at the one `i32` stride it has always used.
They cannot disagree about where an element lives again, which is the structural
reason hole (3) was reachable in the first place.

## 3. Why no existing program changed, argued and then measured

- **The addressing agrees for every scalar.** `elemShiftOf` returns the same log2
  the old `tyShift` returned for 1, 2, 4 and 8 bytes. Only a non-power-of-two
  size takes the new path, and only a struct can have one — and no struct array
  existed.
- **The three holes were unreachable, not reachable-and-unused.** A local
  `bool[2]`, a global `Point[2]` and a local `ptr[2]` were all compile errors
  before this round, so no shipped example can contain one.
- **`typeOf(Index)` returning the element type** can only differ from `i32` where
  the element is not `i32` — which, again, could not be declared.

Then measured: **288 of 288 pre-existing baseline rows reproduce byte for byte**
across `build-so` / `build-elf` / `build-obj --pic`, and the three new rows are
`examples/array_elem_types.ast`'s three output modes (291 → 294).
`tests/rebuild-baseline-v0.23.28.sh` refuses to write the baseline unless both
hold.

## 4. `tests/array-elem-types-checks.sh` — nine layers, all run

| Layer | What it is | Count |
| --- | --- | --- |
| [1/9] | strict rebuild: `-std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror` | 1 |
| [2/9] | source guards pinning each hole and the rule where it lives | 24 |
| [3/9] | behavioural cases under qemu, expectations derived by hand first | 24 |
| [4/9] | gcc-differential pairs (Aster vs `aarch64-linux-gnu-gcc -O2`), no hand-computed expectations | 6 |
| [5/9] | rejection matrix | 28 |
| [6/9] | coverage map: which case exercises which rule | 30 |
| [7/9] | mutation layer: each rule, withdrawn, is caught | 15 |
| [8/9] | byte-identity baseline | 288/288 |
| [9/9] | the shipped example, end to end | exit 127 |

### Two mutants that earned their shape the hard way

**m2** (a 12-byte element scaled by 1) was first pinned to
`t[2].a = 5; return t[0].a` and **survived**. At one byte per element index 2
lands *two bytes into* `t[0].a` — and the only byte a process exit status
carries is the low one, which the store never touched. The witness moved to
index 4, whose wrong address is `t[0].b`'s first byte: 5, against the real 0.

**m6** (an element is not an lvalue) was first pinned to `a[i].f = v` and also
survived: `isLValue` is what `&` asks, and the field store runs through a
different gate. The witness is `&a[i]`, refused in sema — one layer above m7,
which withdraws `emitStructAddr`'s element arm in codegen.

### Eleven resident suites updated on the record

The first seven moved because the round relocated the thing they were measuring.
They were found by running them, one at a time, as the source changed:

| Suite | What it pinned | What it pins now |
| --- | --- | --- |
| `condition-checks.sh` | `genBool`'s two delegations | three — an element is a condition |
| `for-loop-checks.sh`, `local-array-checks.sh` | three `ADD Xd, SP, #slot*8` frame bases | four — the fourth is `emitElemAddr`'s |
| `precedence-checks.sh` | two copies of the local array range message | three — sema's array branch answers the element type, so a bool array carries the check too |
| `runtime-bounds-checks.sh` | `emitBoundsCheck(e.name,*e.a,r)` | the two calls inside `emitElemAddr` |
| `sema-checks.sh` | `Binding { ty, len }` | `Binding { ty, len, elem }` |
| `pointer-index-checks.sh` | `pointer indexing/assignment is not supported yet` | the element-type rule: `p[0]` on a ptr still names an `i32` |

The full CI run then surfaced four more, all of them the same story told in a
different dialect — a guard whose *subject* became legal, or a site that
became shared:

| Suite | What broke | What it pins now |
| --- | --- | --- |
| `local-array-checks.sh` | `let p: ptr[2] = 0;` was refused; it is legal now | the element type instead: `a[0] = true` on a local `i32[2]` is refused with `type mismatch assigning array element of 'a': expected i32, got bool` |
| `wide-int-checks.sh` | `static uint32_t tyShift(Ty t)` | `static int elemShiftOf(Ty t){` — the same numbers for every scalar, **-1** for a size that is not a power of two |
| `wide-int-literal-checks.sh` | three index SXTW leaves (local / global / ptr), nine in total | one shared leaf (caught three times: 54 / 57 / 58), seven in total; `slotElemTypes[slot]=elem;` written in three places, not one; `M6a`/`M6b` merged into `M6`, and `M11` re-aimed from the ptr leaf to the element's **load width** (81 / 82 / 87) |
| `condition-checks.sh` | `array init = true` refused as *non-constant* | refused as a *type* mismatch (`expected i32, got bool`), which is what it is; mutants `m4` and `m6` re-aimed (below) |

None of them were weakened: each was updated because the round moved the thing
it was measuring, not because the measurement failed.

#### Two condition mutants that had to be re-aimed

**m4** was "the fold chokepoint folds a bool literal again" — `constantInteger`
refusing `true`. That refusal is now defence in depth: every bool-literal path
(sema's array branch, `initializerFits`, the global gate, the struct-field
reader) carries its own type check, so removing the fold guard alone no longer
changes a single accept/reject decision — verified by running the mutant against
eleven bool-literal programs in both scopes. m4 now withdraws the other half of
the same "bool is not int" rule: the **0/1 integer constant a bool slot accepts**
(the two `isBoolConstant` copies, sema's and codegen's, which are one rule
stated twice). The witness is `let b: bool = 1;`.

**m6** was the global-initializer gate alone. That gate gained a twin in
`initializerFits` this round (`true` fits a bool slot and only a bool slot), so
with only the first lifted the program dies one line later with
`global initializer does not fit in i32: g (1)`. m6 lifts both.

## 5. What this deliberately does not do

- **A struct field may not be an array.** `struct P { x: bool[2] }` is still
  refused (`array fields are not supported: P.x`) — that is a different feature,
  with its own layout and initializer questions.
- **A `ptr` local's subscript has no element type.** `p[i]` still means
  `*(p + i*4)`. Making a pointer's stride depend on a declared type is a
  language-design question, not a gap.
- **A whole struct element is not a value.** A struct has no register form; copy
  it (`let c: Point = a[1];`), read it field by field, or take `&a[i]`.
- **No multi-dimensional arrays**, no `sizeof`, no array parameters or return
  values, no array assignment as a whole — all unchanged.
- **A `ptr` element is not ordered.** `==`/`!=` only, as for any ptr.

## 6. Byte identity: 288 of 288

`tests/struct-checks.sh` [4/8] and `tests/null-ptr-checks.sh` [8/9] re-hash
every example in three modes against
`tests/baseline/v0.23.5-dev/example-hashes.txt` and pass with the round's
compiler; `tests/array-elem-types-checks.sh` [8/9] asserts the split directly
(288 pre-existing rows byte-identical, 3 new rows recorded) so the two numbers
cannot drift apart. `tests/rebuild-baseline-v0.23.28.sh` refuses to write the
baseline unless every old row reproduces.

## 7. Verification log

`tests/array-elem-types-checks.sh`, run on this tree (`HOSTCC=aarch64-linux-gnu-gcc`):

```
[1/9] Strictly build Aster compiler
[2/9] Source guards: the three holes and the addressing rule
  all three holes closed and the rule pinned, in both passes
[3/9] qemu: every element type, in both scopes, at every width
  global bool[4] read                1
  local bool[3] write+read           2
  global bool[3] write               5
  local bool[2] store false          6
  bool[4] under a while              4
  bool element as an argument        1
  local ptr[3]                       4
  global ptr[2]                      5
  ptr element into ptr<P>            3
  global Point[3]                    8
  local Point[3] field write         16
  Point field +=                     6
  12-byte element, both scopes       32
  12-byte element, local only        7
  struct with an i64 field           2
  nested subscript + field           4
  &a[i] and a[i] as a value          64
  an element as a parameter          7
  i64[2] at 8 bytes/elem             1
  u8[4] at 1 byte/elem               1
  u16[4] at 2 bytes/elem             1
  i32[4] unchanged                   10
  ptr local: i32 stride              9
  bool scalar                        1
[4/9] Differential: Aster vs the target C compiler
  bool arrays, both scopes           7
  ptr arrays, both scopes            3
  struct arrays: 8 and 12 bytes      7
  element widths: 1, 2, 8            15
  &a[i] and a whole-element copy     64
  examples/array_elem_types.ast      127
[5/9] Rejection matrix
  local bool[2] = 2                  refused
  local bool[2] = 1 + 1              refused
  local bool[2] = 0 - 1              refused
  local i32[2] = true                refused
  local i32[2] = &g                  refused
  local i32[2] = a ptr var           refused
  local ptr[2] = 7                   refused
  local ptr[2] = true                refused
  boolarr[0] = 2                     refused
  ptrarr[0] = 7                      refused
  i32arr[0] = true                   refused
  & of an i32 element                refused
  & of a ptr element                 refused
  a struct element as a value        refused
  struct field i32[2]                refused
  struct field bool[2]               refused
  local bool[0]                      refused
  local bool[1001]                   refused
  global bool[0]                     refused
  global Point[0]                    refused
  bool[2] index 5                    refused
  Point[2] index 3                   refused
  ptr[2] index 9                     refused
  index an i32 scalar                refused
  index a struct scalar              refused
  bool[2] = a call                   refused
  u8 element into a bool             refused
  bool element into an i32           refused
[6/9] Coverage map: which case exercises which rule
  cases mapped to a rule             30
[7/9] Mutation layer: each rule, withdrawn, is caught
  m1: elemShiftOf is tyShift again   caught
  m2: a 12-byte element scaled by 1  caught
  m3: local elements scaled as i32   caught
  m4: global elements scaled as i32  caught
  m5: typeOf(Index) is i32 again     caught
  m6: an element is not an lvalue    caught
  m7: emitStructAddr skips elements  caught
  m8: a bool element is not a condition caught
  m9: no a[i].f dispatch             caught
  m10: local arrays, integers only   caught
  m11: a bool global is never an array caught
  m12: a struct global is never an array caught
  m13: a bool[2] = true is refused   caught
  m14: bool fits anything            caught
  m15: ptr[2] takes an integer       caught
PASS: fifteen mutated compilers each lose exactly one rule, and the checks notice
[8/9] Byte-identity baseline
  pre-existing rows byte-identical   288
  new example rows recorded          3
PASS: byte-identity baseline holds
[9/9] The example, end to end
  array_elem_types.ast               127
PASS: the example runs and returns the value its C twin returns
=== array element type checks: ALL PASSED ===
```

## 8. Full CI

The full pipeline (`tests/ci.sh`, all suites + the APK verification gate) was run
after the four record-update fixes in this round were folded in:

```
CI SUMMARY: 85 passed, 0 skipped, 0 failed (of 85 checks)
```

Every resident suite passed — `c-*` structural suites, the mutation/baseline
suites, the new `array-elem-types-checks.sh`, and the three APK verification
gates (`native_render`, `icon_text_demo`, `native_touch`). Exit code 0.

| CI | v0.23.27-dev | v0.23.28-dev |
|---|---|---|
| Result | 84 passed / 0 skipped / 0 failed | **85 passed / 0 skipped / 0 failed** |
| Checks | 84 | 85 (+1: `array-elem-types-checks.sh`) |
| Baseline rows | 291 (288 unchanged + 3 new) | 294 (291 unchanged + 3 new) |
| New resident suite | `precedence-checks.sh` | `array-elem-types-checks.sh` |

## 9. What this unblocks

- **A struct array is now usable**, which is the shape every real Aster program
  that keeps a table of records wants: `Point[4]`, `Triple[2]`, a table of
  callbacks as `ptr[4]`, a table of flags as `bool[8]`.
- **The element-type rule is one sentence**, and it is now true in the parser, in
  sema and in codegen at once — the three places that had their own opinion of
  what `a[i]` is are one place.
- **The next two items are smaller for it.** A struct field that is an array, and
  an element type for a `ptr` local's subscript, are both now questions about one
  rule rather than about three parsers.
