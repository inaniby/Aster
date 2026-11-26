# Validation Report — v0.23.36-dev

**Feature: `--bounds-check` now guards array *parameter* subscripts, closing the
one array shape the run-time guard could not see.** `--bounds-check`
(since v0.23.1-dev) already traps an out-of-range access into a global or local
array with a `BRK #1` (SIGTRAP, exit 133); a parameter was the exception,
because the two length tables everything else reads from —
`localArrayLength[slot]` and `arrayLengths[name]` — were never filled for a
parameter. This round adds a third, narrow table, `paramArrayLength[slot]`, read
*only* by the two check sites, so `fn f(a: i32[4]) { a[i] }` and `a[i] = v`
emit the same `CMP widx, #len` + `B.LO` over `BRK #1` as a local/global array —
a constant out-of-range subscript (`a[4]`) is still rejected at compile time,
flag or no flag, and a multi-dimensional parameter (`a[i][j]`) is checked per
dimension through the existing per-dimension walk. A default build emits no test
at all (`emitBoundsCheck` opens with `if(!boundsCheck) return;`), so no
pre-existing byte moves: **309 of 309** baseline rows reproduce and the round
adds no `examples/*.ast`.

```
# tests/array-param-bounds-checks.sh [4/9] — read/write under qemu, with and without --bounds-check

fn f(a: i32[4], k: i32) -> i32 { return a[k]; }
fn main() -> i32 { let arr: i32[4] = 7; return f(arr, 2); }          default -> exit 7   , --bounds-check -> exit 7
fn main() -> i32 { let arr: i32[4] = 7; return f(arr, 4); }          default -> exit ?   , --bounds-check -> exit 133
```

## 1. Why this round exists

`--bounds-check` (v0.23.1-dev) is the run-time half of array safety: a dynamic
subscript that folds to nothing at compile time is lowered to a length test that
traps instead of silently reading or overwriting neighbouring memory. It covered
two array shapes — a global `let buf: i32[8]` and a local `let a: i32[4]` — and
explicitly left the third untouched. Two rounds named that third as out of scope
on purpose: v0.23.34-dev noted *"the array length is not part of the parameter
type … so there is no bounds check on a parameter — same as C"*, and
v0.23.35-dev closed the length into the parameter only for `sizeof`/`len` —
*"the dimensions answer these two operators and nothing else: a parameter
subscript stays unchecked"* — with its own validation report ending on the open
item: *"a bounds-checked array parameter is the round that would close that."*
This is that round.

The reason a parameter was invisible to the guard is mechanical, and it is the
reason the fix is small rather than risky. The length a local or global array is
checked against lives in `localArrayLength[slot]` (local) or `arrayLengths[name]`
(global); an array *parameter* never had an entry in either, because a parameter
decays to a pointer and carries no length in those tables. So `emitBoundsCheck`
was handed `0` for a parameter and returned immediately (`if(!length) return;`).

## 2. The fix is a third length table that nothing else reads

`Codegen` gained one new member:

```cpp
std::map<int,uint32_t> paramArrayLength;   // frame slot -> element count of an ARRAY PARAMETER
```

filled in the parameter-setup pass from the dimensions the v0.23.35 round
already carries on the function:

```cpp
if(tyIsPtrToElem(pt)){
    pointerSlots[slot]=true; slotElemTypes[slot]=ptrElemType(pt);
    if(i<f.paramDims.size() && !f.paramDims[i].empty()){
        slotDims[slot]=f.paramDims[i];                       // feeds the multi-dimensional walk
        paramArrayLength[slot]=(uint32_t)dimsProduct(f.paramDims[i]);
    }
}
```

The separation is the whole design. `gen(Var)` decides whether a bare `a` in an
expression resolves to the frame slot or to the *pointer value* stored in that
slot by testing `localArrayLength.count(slot)`: a local array has an entry and
`a` is the slot; a parameter does not, and `a` is the decayed pointer. Handing a
parameter a `localArrayLength` entry would flip that test and make every call
that relies on the decayed pointer silently resolve `a` to the frame slot —
exactly the kind of quiet break a parameter is prone to. `paramArrayLength` is
consulted *only* by the check sites (`if(paramArrayLength.count(slot)){ … }`),
so the addressing machinery, `arrayLengthOf`, and `AddrOf` are untouched. That
is also why a default build moves not a byte: the two tables codegen reads for
addressing never change.

## 3. Two guarded paths, identical to local/global

**Read — `a[i]`** routes through `emitElemAddr`'s pointer branch. After the index
register is generated, the round inserts the two calls:

```cpp
if(paramArrayLength.count(slot)){
    checkArrayBounds(paramArrayLength.at(slot), index);   // always-on compile-time check
    emitBoundsCheck(paramArrayLength.at(slot), index, r); // opt-in run-time trap
}
```

**Write — `a[i] = v`** routes through `gen(Stmt::Assign)`. The existing call
emits the local/global check; the round adds a parameter arm immediately after:

```cpp
if(!s.name.empty()){ int aslot=lookup(s.name);
    if(aslot>=0 && paramArrayLength.count(aslot)){
        checkArrayBounds(paramArrayLength[aslot], *s.idx);
        emitBoundsCheck(paramArrayLength[aslot], *s.idx, r);
    }
}
```

Both call the same `emitBoundsCheck` a local/global array does: `CMP widx, #len`
+ `B.LO +2` skipping `BRK #1` (encoding `0xd4200020`). So an out-of-range
run-time parameter read or write raises **SIGTRAP, exit 133** under exactly the
same flag, and the same `if(!boundsCheck) return;` at the top of `emitBoundsCheck`
means a default build emits no test and behaves exactly as before (and exactly as
C). A compile-time-constant out-of-range subscript (`a[4]` on an `i32[4]`) is
rejected by the always-on `checkArrayBounds` named-parameter overload —
**with or without** the flag — with the message `array index out of bounds for
'a': index 4, length 4`.

## 4. Multi-dimensional parameters check per dimension for free

A 2-D parameter `a: i32[2][3]` needs no second code path. The *same* setup line
that fills `paramArrayLength` also fills `slotDims[slot]` from `f.paramDims[i]`;
once `slotDims` holds the dimensions, the existing `emitIndexAddr` per-dimension
walk (`indexChainOf` → one `emitBoundsCheck` per level against `dims[k]`) applies
automatically. The round's own suite proves a row out-of-range (`a[2][0]`) and a
column out-of-range (`a[0][3]`) each trap under the flag, while a valid `a[1][2]`
runs clean. This is the same "the parameter already carried the dimensions"
leverage the v0.23.35 round used for `sizeof`/`len`, now also feeding the
run-time guard.

## 5. Coverage: `tests/array-param-bounds-checks.sh` [8/9]

1. a strict `-Werror -pedantic` rebuild;
2. **source guards** pinning the new member (`paramArrayLength`), its init fill
   (`slotDims[slot]=f.paramDims[i]` and `paramArrayLength[slot]=dimsProduct(...)`),
   the read-side guard (`if(paramArrayLength.count(slot)){`), the write-side guard
   (`if(!s.name.empty()){int aslot=lookup(s.name);`), and that `arrayLengthOf` still
   consults `localArrayLength` — the separation the design depends on, named at the
   guard so it cannot be collapsed later;
3. **acceptance under qemu** — in-range read and write through a parameter return
   the same value with and without `--bounds-check` (a default build is not a trap,
   and the flag's presence does not change a legal result);
4. **trap acceptance** — out-of-range read, out-of-range write, and a negative
   subscript each raise SIGTRAP (exit 133) under `--bounds-check`, and none of the
   three traps on a default build;
5. **multi-dimensional parameter** checked per dimension — a valid `a[1][2]` runs,
   a row OOB (`a[2][0]`) and a column OOB (`a[0][3]`) both trap;
6. **compile-time rejection** — a constant out-of-bounds parameter read (`a[4]` on
   `i32[4]`) is refused at compile time, flag or no flag;
7. **a gcc-differential pair** — Aster (`--bounds-check`) against the
   cross-compiled twin `tests/array-param-bounds-twin.c` (`pick(int a[4], int k)
   { return a[k]; }`) for in-range parameter reads; both exit 6 (the sum of four
   picked elements), and no expected value is hand-computed;
8. **a 2-mutant layer** — m1 clears the `paramArrayLength` init: the out-of-range
   read must now run without trapping (the mutant no longer traps, the suite's
   witness expects exit 0); m2 drops only the two read-side check *calls* in
   `emitElemAddr` (the `if` guard stays, now empty), so the out-of-range read
   falls through without trapping (the mutant no longer traps).

## 6. Nothing that exists moves

```
$ HOSTCC=aarch64-linux-gnu-gcc RUNNER="qemu-aarch64 -L /usr/aarch64-linux-gnu" sh tests/ci.sh
========================================
CI SUMMARY: 93 passed, 0 skipped, 0 failed (of 93 checks)
========================================
```

The round adds no example, no syntax and no change to the two length tables
codegen reads for addressing, so the byte baseline is unchanged: **309 of 309**
rows reproduce (the same 309 as v0.23.35-dev, because the only new artifact is a
test suite, not an `examples/*.ast`). `tests/rebuild-baseline-v0.23.36.sh` is
unnecessary — the suite's own layers assert the 309 rows are untouched — and the
new suite is the only addition to `ci.sh`'s `SUITES` list (92 → 93 checks). Every
pre-existing suite passes, including the byte-baseline walk and `version-checks`
(which requires this report to exist, named with the version's own prefix).

## 7. Deliberately not included

* **A default-on parameter check.** The `--bounds-check` opt-in rule the
  v0.23.1 round set stands: a parameter subscript is unchecked unless the flag is
  given, exactly as a local/global one. Nothing in this round changes whether
  `emitBoundsCheck` is reached.
* **Any change to `gen(Var)`'s frame-slot/pointer resolution for a parameter.**
  The parameter's *stride* and *decay* are untouched; only its run-time *bounds*
  gain a guard. `return a;` stays refused and `a = ...` stays a type error.
* **A `localArrayLength` entry for parameters.** Deliberately avoided, as §2
  explains — it would silently flip `gen(Var)`'s slot/pointer test and break
  callers that rely on the decayed pointer. The mutant layer guards the
  separation.
* **A new example.** There is no observable end-to-end behaviour worth shipping as
  a standalone example that the suite's qemu/ twin/ mutant layers do not already
  pin, and adding one would move the byte baseline for no reason.

## 8. Full CI

```
$ HOSTCC=aarch64-linux-gnu-gcc RUNNER="qemu-aarch64 -L /usr/aarch64-linux-gnu" sh tests/ci.sh
========================================
CI SUMMARY: 93 passed, 0 skipped, 0 failed (of 93 checks)
========================================
```

One suite is new (`array-param-bounds-checks.sh`, registered in `ci.sh` beside
`array-address-checks.sh`); every pre-existing suite passes, including the
byte-baseline walk (309/309), `version-checks` (which verifies this report and
the version string), and the five suites whose `[8/9]` filters were already
extended for the v0.23.34-dev/v0.23.35-dev array rounds. The full run is the
same 92 suites as v0.23.35-dev plus one, and no compiler source outside the four
edits in §2 moved.

## 9. What this closes, and what it opens

The round closes the v0.23.34-dev/v0.23.35-dev *"parameter bounds check absent"*
line for the run-time guard — the single item the previous two array rounds named
as out of scope. It does so without touching the compile-time `sizeof`/`len`
answers (already closed in v0.23.35-dev), and without disturbing the byte-level
reproducibility that those rounds established. What it opens is nothing new: the
parameter is now guarded by the same opt-in flag as every other array shape, so
the language's run-time array safety is complete across global, local and
parameter arrays — one coherent rule, three shapes.
