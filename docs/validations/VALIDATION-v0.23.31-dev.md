# Validation Report — v0.23.31-dev

**Feature: a second subscript — `T[N][M]`, where `a[i]` is a row and `a[i][j]`
the element, in every shape a one-dimensional array takes (a local, a file-scope
global, and a struct field).**
Until this round a subscript was the last thing you could do to an array: `a[i]`
*was* the element, and that was the end of the expression, so a grid had to be
flattened by hand (`a[i*3+j]`, with the row length re-derived at every use).

```
$ ./aster build-elf examples/multi_dim_array.ast -o mda && ./mda
$ echo $?
255                                    # matches the gcc twin of the same program — §4 [4/9]
```

## 1. Why this round exists

The user was offered four candidate rounds — a struct array field, taking the
address of a whole array, multi-dimensional arrays, and DWARF `.debug_info` —
and answered *"这4项一起做"*. The roadmap's first principle is that **one version
is one coherent theme**, so the four are three versions and not one:

| Version | Contents | Kind |
| --- | --- | --- |
| v0.23.29-dev | a struct field that is an array | language — shipped |
| v0.23.30-dev | `&arr` → `ptr` | language — shipped |
| **v0.23.31-dev** | `T[N][M]` | language — this round |
| v0.23.32-dev | DWARF `.debug_info` | toolchain |

`T[N][M]` is the item two previous rounds each named as out of scope:
v0.23.28-dev ended with *"no multi-dimensional array"* and v0.23.29-dev with
*"a nested array field is multi-dimensional arrays, the next language round"*.
It was scheduled together with `&arr` twice and split out twice, the second time
by v0.23.30-dev's own build: the two share no code.

## 2. The observation the round is built on: it is the same decay, one level in

C has never worked the way Aster did: `a[i]` on an `int[2][3]` is a *row* — the
address of three ints — and `a[i][j]` is the element. Aster already has exactly
that shape, because an array name **decays to a `ptr`** and v0.23.30-dev made
that address reachable by name:

| Expression | Type | Meaning |
| --- | --- | --- |
| `grid` | `ptr` | the whole 2×3 block |
| `grid[i]` | `ptr` | a **row** — the address of `M` elements |
| `grid[i][j]` | `i32` | the element |

So the round adds **no `Ty::Kind`, no array type in the lattice, and no
pointer-with-a-stride**. The type system does not move at all. What changes is
only *which number each subscript multiplies by*:

```
stride(dimension k) = dims[k+1] * … * dims[L-1] * sizeof(elem)
```

For the innermost subscript that is `sizeof(elem)` — the one stride a
one-dimensional array has always had, which is why no pre-existing byte moves —
and for an outer one it is the product of the dimensions below it: **12** for a
row of a 2×3 `i32` grid, **24** for a row of a 2×3 `i64` one, **4** for a row of
a 2×3 `u8` one. A short chain (`a[i]` on a 2-D array) still strides by
everything below the level it reaches, because the row it addresses is
`dims[1]` elements wide.

## 3. The five changes, none of them a new mechanism

### 3.1 One `[N]` per dimension, at every declaration site

```cpp
std::vector<uint32_t> arrayDimList(const std::string& what,uint32_t limit,const std::string& subject){
    std::vector<uint32_t> dims;
    while(cur().k==TK::LBracket){
        ++p;                                                    // the '['
        auto n=need(TK::Number,("expected "+what).c_str());
        unsigned long long cnt=unsignedLiteral(n,what.c_str());
        if(cnt==0||cnt>limit)
            throw Error(loc(n.line,n.col,what+" must be between 1 and "+std::to_string(limit)+": "+subject));
        need(TK::RBracket,("expected ']' after "+what).c_str());
        dims.push_back((uint32_t)cnt);
    }
    return dims;
}
// The total element count of a dimension list, and the guard that keeps a
// multi-dimensional declaration inside the same total-element limit the
// one-dimensional spelling has always had.
uint32_t dimsTotal(std::vector<uint32_t>& dims,uint32_t limit,const std::string& what,
                   const std::string& subject,unsigned line,unsigned col){
    if(dims.empty())return 1;
    uint64_t total=1;
    for(uint32_t d:dims)total*=d;
    if(total>limit)
        throw Error(loc(line,col,what+" must be between 1 and "+std::to_string(limit)+": "+subject));
    return (uint32_t)total;
}
```

`arrayDimList` is the one `[N]`-reader a local, a global in all three branches,
and a struct field already shared; it now loops. `dimsTotal` is new and applies
the *same* limit the one-dimensional spelling always did — to the **total**
element count, so `i32[1000][1000]` is refused exactly as `i32[1000000]` is, and
`i32[0][3]` is refused where the length is read. `count` stays the total element
count, so the frame reservation, the broadcast initializer, `.data`/`.bss`
sizing and `layoutStruct` are all untouched.

### 3.2 One chain shape, and a count that rides beside it

```cpp
E indexSubscripts(const std::string& name,unsigned line,unsigned col,unsigned& subs){
    subs=1;
    need(TK::LBracket,"expected '['");
    E first=expr();need(TK::RBracket,"expected ']' after array index");
    if(cur().k!=TK::LBracket)return first;                 // one subscript: itself, as always
    E target(new Expr(Expr::Index));target->name=name;…;target->a=std::move(first);
    while(cur().k==TK::LBracket){                          // each subscript above it: another Index
        ++p;E j=expr();need(TK::RBracket,…);
        E z(new Expr(Expr::Index));z->a=std::move(target);z->b=std::move(j);z->name="";
        …;target=std::move(z);
        ++subs;
    }
    return target;
}
```

This is the shape `postfix()` already builds for the same expression read, so
**`a[i][j] = v` and `a[i][j]` reach the same address computation**, and a single
subscript still comes back as itself — the one-dimensional path is unchanged in
every respect. The count rides along in `Stmt::subs` because a chain and a bare
subscript cannot be told apart by looking at the expression alone
(`a[b[0][1]]` writes one subscript that happens to be a chain), and Sema needs
the difference to tell a row store from an element store.

### 3.3 Sema walks the chain, checking every subscript

```cpp
IndexChain ch;
if(indexChainOf(e,ch)){
    if(ch.level>=ch.dims->size())
        throw Error(loc(e.line,e.col,"too many subscripts for "+ch.what+": it has "
                        +std::to_string(ch.dims->size())+" dimension"+(ch.dims->size()==1?"":"s")));
    const Expr* n=&e;
    for(uint32_t l=ch.level+1;l-->0;){
        const Expr& index=(l==0&&!n->name.empty())?*n->a:*n->b;
        const Ty idxTy=typeOf(index);
        if(idxTy==Ty::Ptr)throw Error(loc(e.line,e.col,"pointer indexing is not supported yet"));
        rejectBool(idxTy,"an array index");
        if(l==0&&!n->name.empty())checkArrayBounds(n->name,index);
        else checkArrayBounds((*ch.dims)[l],index);
        if(l>0)n=n->a.get();
    }
    return ch.level+1<ch.dims->size()?Ty::Ptr:ch.elem;
}
```

Three things in one loop. **Dimension *k*'s bounds come from `dims[k]`** — level
0 against `dims[0]`, level 1 against `dims[1]`. **The answer is a row unless
this is the innermost subscript** (`ch.level+1 < ch.dims->size()` → `Ty::Ptr`).
And **every subscript is checked**: the first version of this round checked only
the outermost node, and `a[true][0]` — a bool literal as the *inner* index —
compiled, which is exactly the hole the per-level walk closed. The named base
node carries its subscript in `a`; every node above it carries its subscript in
`b`.

### 3.4 Codegen computes every subscript first, the base address after

```cpp
const unsigned levels=depth+1;
int regs[8];
for(unsigned k=0;k<levels;++k){
    const Expr& index=(k==0)?(cur->name.empty()?*cur->b:*cur->a):*nodes[depth-k]->b;
    checkArrayBounds((*dims)[k],index);
    regs[k]=gen(index);
    emitBoundsCheck((*dims)[k],index,regs[k]);
}
// … the base address …
uint64_t stride=tySize(elem);
for(size_t k=levels;k<dims->size();++k)stride*=(*dims)[k];   // a short chain still includes what is below
for(int k=(int)levels-1;k>=0;--k){
    emitElemStride(regs[k],stride);
    releaseTemp(regs[k]);
    if(k>0)stride*=(*dims)[k];
}
```

The order is the one real subtlety: **the subscripts are all evaluated before
the base address is materialized**, because evaluating a subscript can
materialize a global's address into X16 — which is exactly where the base is
about to go. The scales are then applied innermost first so the temporaries
release in the order they were taken (the additions commute, so the summation
order is nobody's business but the register allocator's). `emitElemStride` is a
shift for a power-of-two stride and a 32-bit `MOVZ`/`MOVK` materialize plus
`UMADLL` otherwise — v0.23.28-dev's rule, reused unchanged; a row stride is a
product of dimensions, so for a large global it can pass 16 bits and the low
half alone is not enough.

### 3.5 A store to a row is refused, and the single subscript is the hard case

```cpp
case Stmt::IndexAssign: {
    std::string rowWhat;
    if(indexChainIsRow(*s.idx,&rowWhat))
        throw Error(loc(s.line,s.col,"cannot assign to "+rowWhat+"[i]: it addresses a row, not an element"));
    if(rowWhat.empty()&&s.subs<2){                          // one subscript, as itself
        const std::vector<uint32_t>* d=arrayDimsOfName(s.name);
        if(d&&d->size()>1)
            throw Error(loc(s.line,s.col,"cannot assign to '"+s.name+"'[i]: it addresses a row, not an element"));
    }
    …
```

A store to a row is as meaningless as a store to the array itself, so it is
refused in both spellings: the chain form (`indexChainIsRow` — `a[0][1] = 5` on
a 3-D array, and the field spelling) and the single-subscript form, which
arrives from the parser as *itself* and is told apart from a chain by the count
the parser records. A one-dimensional array — one subscript, one dimension —
falls through untouched.

## 4. The four holes this round found in its own first draft

Each one is a rejection-matrix row now, and each was found by the suite rather
than by reading:

1. **`a[1] = 5` on a two-dimensional array was accepted.** A single subscript
   comes back from the parser as a bare expression, so the row test that looks
   at the chain's shape never saw it. The fix is `Stmt::subs` (§3.5).
2. **`a[true][0]` compiled.** The first chain walk checked only the outermost
   subscript, so an inner `bool` literal rode through. The fix is the per-level
   loop (§3.3).
3. **`x[0][1]` on a scalar reported the wrong error.** The ptr-chain check
   ("pointer indexing is not supported yet") was placed before the inner
   subscript's own type error, so it hijacked the message from
   `cannot index non-array variable: x`. It now sits after `typeOf(*e.a)` and
   `rejectBool`, and intercepts only an empty name — a genuine `ptr` base.
4. **The one-dimensional bounds message regressed.** The chain path took over
   the last remaining `checkArrayBounds(uint32_t, …)` call, so a one-dimensional
   read answered the *unnamed* form (`array index out of bounds:` without the
   array's name) — which `array-bounds-checks.sh` pins. The level-0 named base
   now calls the named overload again.

## 5. Why no existing program changed, argued and then measured

- **The chain path is only entered with two or more subscripts.** The chain
  shape — an `Index` whose name is empty and whose left side is itself an
  `Index` — only exists when the parser builds it, and the parser builds it only
  for a second `[`. A one-dimensional subscript never reaches `emitIndexAddr`;
  its own emit paths keep the emission order they have always had.
- **The innermost stride is the element size** — the one scale a
  one-dimensional array has always applied — so the last level of a chain and a
  one-dimensional `a[i]` reach the same instruction.
- **Storage and layout do not move.** `count` stays the total element count;
  `dimsTotal` applies the existing limit to the same total.
- **A multi-dimensional declaration did not parse before this round**, so no
  program that compiled can reach any of the new code.

Then measured: **288 of 288 pre-existing baseline rows reproduce byte for byte**
across `build-so` / `build-elf` / `build-obj --pic`, and the three new rows are
`examples/multi_dim_array.ast`'s three output modes (300 → 303 lines in
`tests/baseline/v0.23.5-dev/example-hashes.txt`).
`tests/rebuild-baseline-v0.23.31.sh` refuses to write the baseline unless both
hold.

## 6. `tests/multi-dim-array-checks.sh` — nine layers, all run

| Layer | What it is | Count |
| --- | --- | --- |
| [1/9] | strict rebuild: `-std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror` | 1 |
| [2/9] | source guards pinning the five changes, in both passes | 28 |
| [3/9] | behavioural cases under qemu | 12 |
| [4/9] | gcc-differential pairs (Aster vs `aarch64-linux-gnu-gcc -O2`), no hand-computed expectations | 4 |
| [5/9] | rejection matrix | 22 |
| [6/9] | coverage map: which case exercises which rule | 36 |
| [7/9] | mutation layer: each rule, withdrawn, is caught | 8 |
| [8/9] | byte-identity baseline | 288/288 + 3 |
| [9/9] | the shipped example, end to end | exit 255 |

### 6.1 The twelve battery cases

Every chain shape, both scopes, and the three element widths that make a stride
interesting:

| Case | Exit | What it pins |
| --- | --- | --- |
| 2-D element write and read | 42 | the innermost subscript strides by the element size |
| row address to a function | 15 | `a[i]` is a ptr, and it travels like `&buf` |
| global 2-D grid | 22 | the same chain at file scope, `.bss` zero-fill |
| 3-D walk | 8 | the middle subscript strides by the product below it |
| 3-D row to a function | 11 | a row of a 3-D grid is two dimensions short |
| struct field 2-D | 6 | the field's offset composed with both strides |
| i64 grid, stride 24 | 88 | a non-power-of-two row stride, by multiply |
| u8 grid, stride 1 | 5 | a one-byte element, both strides at width |
| computed subscripts | 61 | the same with variable indexes, both levels |
| a row is a ptr value | 4 | a short chain assigned to a `ptr`, then indexed |
| compound assign on 2-D | 42 | `a[i][j] OP=` reads back through the same chain |
| 2-D inside for loops | 9 | a chain in a loop body, indexes varying |

### 6.2 The eight mutants, and why they are of three kinds

The rules are of three kinds, and the mutant layer says so by construction:

- **Withdrawing a refusal** must **now compile** — the mutant accepts what the
  real compiler refuses, and the rejection matrix above is what pins the
  refusal. **m3** checks only the outermost subscript again (so `a[true][0]`
  compiles); **m4** withdraws the single-subscript row-store check (so
  `a[1] = 5` is accepted).
- **Withdrawing an acceptance path** must **not compile** — a program that used
  to build now does not. **m5** stops building a chain, so `a[0][1] = 5` leaves
  the second subscript unconsumed; **m6** stops consuming the leading `[`, so
  no array declaration parses at all — the one-dimensional spelling included;
  **m7** and **m8** drop the local and the global dimension registration, so a
  two-dimensional array is refused where its address is computed.
- **Damaging arithmetic** must **diverge**. **m1** drops the short-chain stride
  so a row is one element wide, witnessed by a row-sum of 15 that becomes 9.
  **m2** drops the outer stride multiply, and its witness deliberately reads
  `a[0][2]` rather than the element it just wrote — a read back through the same
  broken chain *cancels* the damage, so the witness lands on an element the
  broken *fill* had written last (3 real, 5 broken).

### 6.3 Twenty-two rejections

Four spellings of the row store (single subscript, compound, 3-D, field) plus a
`for` step; a row into an `i32` and into an `i32` parameter; two levels on a
`ptr`; a bool subscript at either level; three bounds messages (outer, inner,
negative); a zero dimension; a too-large total; three bases that are not arrays
(scalar, unknown, 1-D global and field in the too-many-subscripts spelling);
and a row in a condition.

### 6.4 Ten resident suites updated on the record

Five were known while the round was being built; the first full CI run surfaced
five more — all count guards whose subject this round legitimately grew, which
is the pattern v0.23.24-dev and v0.23.28-dev recorded before it. Every count
was raised to the number the source has, with the new site named at the guard;
none was weakened.

| Suite | What changed |
| --- | --- |
| `array-bounds-checks.sh` | the 1-D message is pinned through the chain path, which is why §4's fourth hole was caught |
| `array-elem-types-checks.sh` | `struct P { x: i32[2][2] }` was a *rejection* — **legal now** — so the row became an acceptance; m5/m10/m11/m12 re-aimed at the spellings this round rewrote; the baseline filter gained this round's family |
| `struct-array-field-checks.sh` | two source guards re-spelled (`StructField` now carries `dims`), m4 re-aimed at the new `push_back`, the baseline filter gained this round's family |
| `precedence-checks.sh` | the baseline filter gained this round's family |
| `array-address-checks.sh` | the baseline filter gained this round's family |
| `condition-checks.sh` | `rejectBool(` occurrences 17 → 18 — the 17th call is the per-level chain walk |
| `wide-int-literal-checks.sh` | SXTW leaves 8 → 9 — the ninth is the chain read's own leaf, the twin of the one-dimensional statement two arms below it; a new guard pins `const Ty elem=ch.elem;` |
| `local-array-checks.sh` | `ADD Xd, SP, #slot*8` frame bases with `sh=0`: 4 → 5 — the fifth is `emitIndexAddr`'s, the chain path's own local base |
| `for-loop-checks.sh` | the same frame-base count, 4 → 5, for the same reason |
| `sema-checks.sh` | `struct Binding { … }` gained `std::vector<uint32_t> dims;` and the guard re-spelled |

The mechanical re-evaluation of every other count guard in the tree found no
sixth casualty: `emitBoundsCheck(name,index,r);` is still 2 (the chain uses the
length form), and `local array initializer does not fit in ` is still 3.

## 7. What this deliberately does not do

- **An array is still not a parameter or a return value.** A row is a `ptr` —
  the exact value `&buf` produced in v0.23.30-dev — and it travels the same way.
- **A row may not be stored to, and it is not a truth value.** `a[1] = 5` is
  refused, and so is `if (a[1])` — a row is a ptr, and a ptr is not a truth
  value.
- **A chain may not run past the innermost dimension** (`a[0][1]` on an
  `i32[3]` is `too many subscripts for 'a': it has 1 dimension`).
- **No pointer type that carries a stride**, and no `sizeof`, and no way to ask
  an array for its length in an expression — so an `i64[N][M]`'s row still
  cannot be handed to a `ptr` parameter with a wrong stride; it is used as a
  value or not at all, exactly as before.
- **No nested-array-element-as-value change**: a whole struct element still has
  no register form, and the element rules of v0.23.28-dev/v0.23.29-dev are
  reused rather than rewritten.

## 8. Byte identity: 288 of 288

`tests/multi-dim-array-checks.sh` [8/9] hashes every example in three modes
against `tests/baseline/v0.23.5-dev/example-hashes.txt` and asserts the split
directly — 288 pre-existing rows byte-identical and 3 new rows recorded — so the
two numbers cannot drift apart. `tests/rebuild-baseline-v0.23.31.sh` refuses to
write the baseline unless every old row reproduces (it asserts 300 before it
writes 303).

## 9. Verification log

`tests/multi-dim-array-checks.sh`, run on this tree
(`HOSTCC=aarch64-linux-gnu-gcc`), abridged:

```
[1/9] Strictly build Aster compiler
[2/9] Source guards: the five changes
  all five changes pinned, in both passes
[3/9] qemu: every chain shape, hand-derived
  2-D element write and read         42
  row address to a function          15
  global 2-D grid                    22
  3-D walk                           8
  3-D row to a function              11
  struct field 2-D                   6
  i64 grid, stride 24                88
  u8 grid, stride 1                  5
  computed subscripts                61
  a row is a ptr value               4
  compound assign on 2-D             42
  2-D inside for loops               9
[4/9] Differential: Aster vs the target C compiler
  2-D and 3-D, rows to a function    33
  i64 and u8 grids, struct field grid 71
  global grid, both scopes, shared rows 19
  examples/multi_dim_array.ast       255
[5/9] Rejection matrix
  1-D then two subscripts            refused
  2-D then three subscripts          refused
  row store, single subscript        refused
  row compound store                 refused
  row store on 3-D                   refused
  row store, field                   refused
  row store in a for step            refused
  row into an i32                    refused
  row into an i32 parameter          refused
  two levels on a ptr                refused
  bool subscript, outer              refused
  bool subscript, inner              refused
  outer subscript out of bounds      refused
  inner subscript out of bounds      refused
  negative subscript                 refused
  zero dimension                     refused
  total too large                    refused
  scalar, two subscripts             refused
  unknown, two subscripts            refused
  1-D global, two subscripts         refused
  1-D field, two subscripts          refused
  row in a condition                 refused
[6/9] Coverage map: which case exercises which rule
  cases mapped to a rule             36
[7/9] Mutation layer: each rule, withdrawn, is caught
  m1: a row strides by the element   caught
  m2: every level strides by the element caught
  m3: only the outer subscript is checked caught
  m4: a single subscript may store a row caught
  m5: no chain for a second subscript caught
  m6: the leading [ is not consumed  caught
  m7: local dimensions not registered caught
  m8: global dimensions not registered caught
PASS: eight mutated compilers each lose exactly one rule, and the checks notice
[8/9] Byte-identity baseline
  pre-existing rows byte-identical   288
  new example rows recorded          3
PASS: byte-identity baseline holds
[9/9] The example, end to end
  multi_dim_array.ast                255
PASS: the example runs and returns the value its C twin returns
=== multi dimensional array checks: ALL PASSED ===
```

Full CI: **88 passed / 0 skipped / 0 failed** (the suite is registered in
`tests/ci.sh` after `array-address-checks.sh`).
