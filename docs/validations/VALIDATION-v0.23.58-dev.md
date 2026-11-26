# Validation — v0.23.58-dev (address-of `&` completion)

**Round:** address-of completion. `&` was only defined for a struct lvalue
(`&s` → `ptr<S>`) and for a whole array (`&arr` → `ptr`, since v0.23.30-dev). A
scalar, a scalar struct field, a `bool`, a `ptr`-typed value and an array
element all fell under the old struct-only diagnostic and were refused. This
round makes `&` address **every** lvalue, answering `ptr<T>` (or `ptr<S>` for a
struct) that strides at the element's real width — `&arr[2]` for an `i64[4]` is
a `ptr<i64>` indexed at eight bytes, and `&p[1]` through a `ptr<i32>` lands on
the second `i32`.

**Compiler:** `src/aster.cpp` (`ASTER_VERSION_STRING "0.23.58-dev"`), built
strictly with `g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror`.

---

## 1. What changed

The round adds **no parser change and no new instruction**. It relaxes the
type rule that had been refusing these shapes and routes every new codegen path
to an already-existing, byte-stable helper (`emitElemAddr` for an array element,
`emitPtrElemAddr` for a typed-pointer base). Three edits, all in `src/aster.cpp`:

| Layer | Location | Change |
|---|---|---|
| Type rule (`typeOf`, `AddrOf`) | ~line 6460 | The old `if(!tyIsStruct(inner)) throw …` guard is gone. A struct lvalue still answers `Ty::ptrTo(inner.sid)` (the dedicated `ptr<S>` shape, byte-identical with every prior round); every other addressable operand now answers `tyPtrToElem(inner)` — `ptr<T>` carrying the element's kind/sid and `tySize(inner)` as `ew`, so the result strides at the element's real width. |
| Type rule twin (`exprType`, `AddrOf`) | ~line 3145 | The same relaxation in the codegen-side resolver: struct → `Ty::ptrTo(inner.sid)`, otherwise `tyPtrToElem(inner)`. The two parallel resolvers (`exprType` for codegen, `typeOf` for sema) now agree on the new answer. |
| Codegen (`emitStructAddr`, `Index` branch) | ~line 4588 | After the existing `ptr`/`array` arms, a new `if(e.name.empty())` block reads `exprType(*e.a)`; if it is a `ptr<T>` (`tyIsPtrToElem`) it routes `&p[k]` through `emitPtrElemAddr(*e.a, *e.b, ptrElemType(baseType))` — the new typed-pointer-base path. Otherwise it scales by the element width through `emitElemAddr(e.name, *e.a)`. The old `'&' is only defined for a struct lvalue, not …` diagnostic is removed entirely. |

`arrayOperandOf` (line 6265) only treats a `Var`/`Field` base as an array, so
before this round `&p[i]` where `p` is a `ptr<T>` fell through the struct gate
and was refused. The new `tyIsPtrToElem` arm catches exactly that case.

### Type-answer matrix (post-round)

| Operand | `&` answer | Codegen path |
|---|---|---|
| struct lvalue (`&s`, `&pt`) | `ptr<S>` (`Ty::ptrTo(sid)`) | `emitStructAddr` Field/whole-struct arm (unchanged) |
| scalar local/global (`&x`, `&g`) | `ptr<T>` (`tyPtrToElem`) | `emitElemAddr` (frame slot / global address, no scaling) |
| scalar struct field (`&s.a`) | `ptr<T>` (`tyPtrToElem`) | `emitStructAddr` Field branch (unchanged) |
| array element (`&a[i]`) | `ptr<T>` (element width) | `emitElemAddr` (base + i·sizeof(T)) |
| element through a typed pointer (`&p[i]`, `p: ptr<T>`) | `ptr<T>` | `emitPtrElemAddr` (the new path) |
| whole array (`&arr`) | `ptr<T>` | unchanged since v0.23.30-dev |

## 2. Still rejected, by design

| Input | Result |
|---|---|
| `&` on a `ptr`-typed operand (`&p` where `p` is a bare `ptr`) | refused — no element type can be named, so no `ptr<T>` can be formed (the stride is unknown) |
| `&` on a non-lvalue (`&(x+1)`, `&5`) | refused — `'&' requires a variable, a field, or a dereferenced ptr<S>'` |
| `&` on a call result | refused — not an lvalue (the `isLValue` check is untouched) |

The suite pins the **negative** side too: the old `'&' is only defined for a
struct lvalue, not …` string must be *absent* from `src/aster.cpp`, so the
struct-only gate cannot silently creep back.

## 3. Behavior battery (qemu self-check, `tests/address-of-checks.sh` [3/5])

Every stride is exercised end-to-end under `qemu-aarch64`; each program asserts
its own result and exits with the expected code. Arrays use **distinct** element
values so a wrong stride changes the exit code rather than passing by coincidence.

| Case | Stride | Expected exit | Why it proves the stride |
|---|---|---|---|
| scalar local `&x` → `*p` | — | 7 | `&x` is `ptr<i32>`, loaded back |
| global scalar `&g` store | — | 9 | store through `&g` is seen by the global |
| scalar field `&s.a` → `*p` | — | 11 | `ptr<i32>` into a struct field |
| `i32` element `&a[2]` | 4 B | 3 | distinct `a = {1,2,3,4}`; lands on 3 |
| `i64` element `&w[1]` | 8 B | 20 | distinct `w = {10,20,30}`; 8-byte stride lands on 20, **not** 10 |
| through typed ptr `&p[1]` (`p: ptr<i32>`) | 4 B | 2 | new `emitPtrElemAddr` path; lands on `arr[1] = 2` |
| chain `(&arr)[2]` (`&base[2]`) | 4 B | 3 | distinct; lands on `arr[2] = 3` |
| struct `&s` regression | — | 4 | `ptr<S>` shape still answers `p.a` |
| whole-array `&arr` regression | — | 4 | decays to `ptr<i32>`, `p[3] = 4` |

## 4. Feature example checksum (`examples/address_of.ast`, [5/5])

The example folds all nine strands into one checksum: `y*1000000 + gv*10000 +
val*100 + e0*1000 + i32(e1)*10 + v2*100 + v3*10 + v4 + v5` =
`7*1000000 + 99*10000 + 11*100 + 1*1000 + 20*10 + 2*100 + 3*10 + 4 + 11` =
**7992545**. Its low byte (**225**) is asserted by the suite, so any stride
regression in any strand changes the exit code.

## 5. gcc differential (`tests/e2e-c-address-of.sh`)

`examples/address_of_abi.ast` exports five functions a C harness drives:

| Aster export | Shape | C compares against |
|---|---|---|
| `aster_elem(p: ptr<i32>, k)` | `&p[k]` then load | C's own `p[k]` (stride 4) |
| `aster_elem_i64(w: ptr<i64>, k)` | `&w[k]` then load | C's own `w[k]` (stride 8) |
| `aster_thru(p: ptr<i32>)` | `&p[1]` (typed-pointer base) | C's own `p[1]` |
| `aster_field_a(pt: ptr<Pt>)` | `&pt.a` then load | C's own `pt->a` (offset 0) |
| `aster_field_b(pt: ptr<Pt>)` | `&pt.b` then load | C's own `pt->b` (offset 4) |

`tests/c-address-of-host.c` `dlopen`s the AArch64 `.so` (built by Aster) and
`dlsym`s each export; to satisfy `-Werror=pedantic` the function pointers are
read with `memcpy(&fn, &s_*, sizeof fn)` rather than a direct object→function
cast. Run with `HOSTCC=aarch64-linux-gnu-gcc` so the host ELF runs under
`qemu-aarch64` and can load the AArch64 object. Verified **PASS** locally:

```
PASS: C -> Aster address-of ABI (i32 elem, i64 elem, thru-ptr, field a, field b)
PASS: Aster v0.23.58-dev address-of ABI test
```

On a host whose `HOSTCC` cannot emit AArch64 ELF the script SKIPs (by design,
see `tests/host-toolchain-probe.sh`).

## 6. Source guards (`[2/5]`)

The suite greps `src/aster.cpp` for: the `ptr<S>`-keeping rule
(`if(tyIsStruct(inner))return Ty::ptrTo(inner.sid);`), the new `&` type-rule
comment, the typed-pointer-base block (`if(tyIsPtrToElem(baseType)){`), the
`emitPtrElemAddr(*e.a,*e.b,ptrElemType(baseType));` call, its codegen comment,
**and** the *absence* of the old struct-only refusal string — so a refactor
that drops any one of them, or reopens the old refusal, fails first.

## 7. Byte baseline (nine suites, [8/9])

`address_of.ast` contributes three new rows to `tests/baseline/v0.23.5-dev/
example-hashes.txt` (build-so / build-elf / build-obj `--pic`). The nine
byte-identity suites (`array-address`, `array-elem-types`, `integer-cast`,
`literals`, `multi-dim-array`, `precedence`, `sizeof-len`, `struct-array-field`,
`switch`) each gained `^address_of\.` and `^address_of_abi\.` to their `FILTER`
(`address_of_abi` is a `.so`-only example with no baseline rows — it is filtered
so it never enters the count). Every one of the nine now sorts both sides of the
baseline diff (`grep -v $FILTER … | LC_ALL=C sort`), so the glob order of
`examples/*.ast` can no longer make a pre-existing row *appear* to move; the
pre-existing count stays **288** in every suite.

## 8. CI

Registered `address-of-checks.sh` (main SUITES list) and `e2e-c-address-of.sh`
(e2e list) in `tests/ci.sh`. Full `ci.sh` run: see the round's commit log
(impl → tests → docs, three commits, single-quoted messages, no `stdbuf`
wrapper so the qemu/`交叉` subprocesses never inherit a leaked `LD_PRELOAD`).
