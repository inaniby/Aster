# Validation — v0.23.61-dev (enumerations: `enum Name { … }`)

**Compiler:** `src/aster.cpp` (`ASTER_VERSION_STRING "0.23.61-dev"`), built
`g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror`.

**Round type:** language feature extension. Aster gains its last missing scalar
type: the enumeration. `enum Name { … }` is a **nominal, `i32`-backed** type
whose members are named `i32` constants — a C-style completion of the scalar
vocabulary (the integers, structs, and pointers were already present).

---

## 1. The change

| Aspect | Behaviour in v0.23.61-dev |
| --- | --- |
| Declaration | `enum Name { A, B=20, C }` — auto-increment from `0`, explicit `= value` (any `constantInteger`-foldable integer, so `= -1` works), trailing comma allowed, **≥1 enumerator required** |
| Enumerators | Named `i32` constants. `primary()` rewrites an enumerator `Ident` into a `Num` of its value (flagged `enumConst`) *before* any other interpretation |
| Nominal isolation | `enum Color` ≠ `enum Dir` even at equal values. `enum<->enum` needs the same `sid`; `enum <- i32` only from a fitting **constant**; `i32 <- enum` is free; everything else refused |
| Storage | 4 bytes, align 4 — `sizeof(Color) == 4`. `tySize`/`tyAlign` land on `default: 4` |
| Integer-like | `tyIsInteger` includes `Ty::Enum`, so an enum value is a legal `if`/`while` condition (zero vs non-zero) and a legal arithmetic/comparison operand alongside `i32` |
| Debug info | DWARF `DW_TAG_enumeration_type`, `DW_AT_byte_size 4`, `DW_AT_type_encoding 0x05` (signed) |

### Why nominal, not C-loose

C lets any two enums and their underlying `int` mix freely. Aster makes the enum
type **nominal**: `enum Color { Red }` and `enum Dir { North }` are distinct
types even though both hold `0`. The conversion matrix (enforced in
`tyAssignable`'s new enum branch, resolved right after the identity
short-circuit and ahead of the `Ptr`/`Bool` gates):

| Assignment | Result |
| --- | --- |
| `enum<same>  ←  enum<same>` | allowed (`to.sid == from.sid`) |
| `enum E  ←  i32 constant` | allowed **only** if `initializerFits` (e.g. `let c: Color = 99;` fits; `let c: Color = Red;` is the constant `0`) |
| `enum E  ←  i32 variable` | **refused** — a variable is not a compile-time constant |
| `i32  ←  enum E` | **free** — an enum value is already `i32` |
| cross-enum, `enum ← ptr/bool`, `ptr ← enum` | **refused** |

This also closed a latent gap: `checkStmt`'s `Let` and `Assign` scalar integer
paths had previously bypassed `tyAssignable` and only scatteredly rejected
`ptr`/`bool`. A cross-enum assignment (`let a: Color = greenFromOther;`) and an
`i32` variable into an enum (`let c: Color = someVar;`) therefore slipped
through. Both paths now route the enum case through `tyAssignable`.

### Type-system and codegen edits (all pinned by `tests/enum-checks.sh` `[2/9]`)

- **Lexer / token:** `enum` is a new keyword (`TK::Enum`), rejected as an
  identifier like the other type names.
- **`Ty::Kind`:** a new `Enum` is inserted *immediately before* `Struct` — the
  `enum Kind { I32,` prefix and `Struct };` suffix are pinned by the struct
  suites' source guards, so the insertion point is load-bearing for those guards.
  `Ty` carries its enum id in `sid`; `Ty::ofEnum(id)` mirrors `ofStruct`.
- **`tyIsInteger`** gains `|| t.k == Ty::Enum`; **`tyName`** answers
  `enumNameOf(sid)` for an enum; **`parseType`** resolves an `Ident` against
  `g_enumIndex` after the struct index.
- **`primary()`:** an `Ident` naming an enumerator folds to `Expr::Num` (value,
  `enumConst=true`) before the call/paren branch — so `Red + Green` is integer
  addition, `Red == Green` an integer comparison.
- **`tyAssignable`:** the enum branch above. **`checkStmt`:** `Let`/`Assign`
  scalar paths route enum cases through `tyAssignable`.
- **`enumDeclaration()`:** mirrors `structDeclaration()`'s name-conflict check,
  parses `{ Enumerator (= constant)? , … }`, auto-increments from `0`, folds
  negative constants through `constantInteger`, range-checks
  `[-2147483648, 2147483647]`, populates `g_enumConsts`, and requires ≥1
  enumerator.
- **DWARF (`typeRef`):** `case Ty::Enum: nm=enumNameOf(t.sid); size=4; enc=0x05;`.

---

## 2. The test suite — `tests/enum-checks.sh` (9 layers)

| Layer | What it proves |
| --- | --- |
| `[1/9]` strict build | the compiler builds under `-Werror` |
| `[2/9]` source guards | `enum` is pinned in the source (10 greps: `TK::Enum`, the `Kind` insertion, `tyIsInteger`, `tyAssignable` branch, `enumDeclaration`, DWARF `0x05`, the three `0.23.61-dev` version guards, the `Enum` insertion point) |
| `[3/9]` qemu witnesses | 9 programs each returning a **distinct** exit code: auto-increment (`Blue==2`), explicit (`South==20`), negative (`-West==1`), enum→i32 free (`2`), i32-const→enum (`5`), arithmetic (`5`), sizeof (`4`), comparison (`7`), distinct enums equal (`1`) |
| `[4/9]` gcc differential | `examples/enum_demo.ast` exits `255`, equal to its C twin `tests/enum-demo-twin.c` |
| `[5/9]` rejection matrix | 5 refusals, each with its exact compiler message: cross-enum init, i32 variable → enum, out-of-range enumerator, duplicate enum name, duplicate enumerator |
| `[6/9]` coverage | the 9 behavioural shapes are all exercised (count ≥ 9) |
| `[7/9]` mutation layer | 2 mutants, each losing exactly one rule and caught by a named case: `m1` removes `|| t.k == Ty::Enum` from `tyIsInteger` → an enum value as an `if` condition is refused; `m2` removes the free `enum→i32` → assigning an enum into an `i32` is refused |
| `[8/9]` byte baseline | the 288 pre-existing rows reproduce byte for byte; the 3 `enum_demo.*` rows are recorded (the 10 byte-baseline suites gained `^enum_demo\.` filters; the three whole-baseline suites balance the new rows) |
| `[9/9]` example e2e | `examples/enum_demo.ast` runs under qemu and returns `255`, equal to the C twin |

### Observed run (this round)

```
[3/9] qemu: enum, every witness
  auto-increment: Blue == 2              2
  explicit values: South == 20           20
  negative: -West == 1                   1
  enum -> i32 is free                    2
  i32 constant -> enum                   5
  enum arithmetic                        5
  sizeof(enum) == 4                      4
  enum comparison                        7
  distinct enums, same value, compared   1
[5/9] Rejection matrix  PASS: the rejection matrix holds
[7/9] Mutation layer
  enum-as-condition under tyIsInteger    caught
  enum -> i32                            caught
[8/9] Byte-identity baseline
  pre-existing rows byte-identical       288
  new example rows recorded              3
[9/9] The example, end to end  enum_demo.ast  255
=== enum checks: ALL PASSED ===
```

---

## 3. Byte-identity baseline

The enum round adds one example, `examples/enum_demo.ast`. Its three build modes
(`build-so`, `build-elf`, `build-obj --pic`) are recorded in
`tests/baseline/v0.23.5-dev/example-hashes.txt`. The ten byte-baseline suites
exclude `enum_demo.*` via `^enum_demo\.` filters (so the pre-existing **288**
rows stay byte-identical), and the three whole-baseline suites
(`condition`/`null-ptr`/`struct-checks`) compare the new rows directly.

One correction during validation: the originally-recorded `enum_demo.build-so`
hash was computed with a throwaway output filename; because a shared object
embeds its output filename into the dynamic string table, that hash was stale.
It was recomputed with the suite's own output name (`enum_demo.build-so`) and
the baseline now matches the compiler's deterministic output byte for byte
(`548cb5e8…`). This is a **test-harness** correction only — the compiler's
`build-so` output is deterministic once the output path is fixed, as every
other example already proves.

---

## 4. Coverage of every enum shape

Each behavioural row below is exercised by at least one `[3/9]` witness or
`[5/9]` refusal:

| Shape | Exercised by |
| --- | --- |
| auto-increment enumerators | `Blue == 2` |
| explicit `= value` | `South == 20` |
| negative explicit value | `-West == 1` |
| enum → i32 (free) | `enum -> i32 is free` (2) |
| i32 constant → enum (fits) | `i32 constant -> enum` (5) |
| enum arithmetic (folded consts) | `enum arithmetic` (5) |
| `sizeof(enum) == 4` | `sizeof(enum) == 4` (4) |
| enum comparison | `enum comparison` (7) |
| distinct enums, equal value, compared | `distinct enums, same value, compared` (1) |
| cross-enum assignment refused | `[5/9]` cross-enum init |
| i32 variable → enum refused | `[5/9]` i32 variable → enum |
| out-of-range enumerator refused | `[5/9]` enumerator out of i32 range |
| duplicate enum name refused | `[5/9]` duplicate enum name |
| duplicate enumerator refused | `[5/9]` duplicate enumerator |

---

## 5. Conclusion

`enum` ships as a nominal, `i32`-backed enumeration: enumerators are real `i32`
constants that fold into the existing integer machinery, the type is isolated by
`sid` so cross-enum and `i32`-variable-into-enum assignments are refused, `i32 ←
enum` is free, and size/condition/arithmetic semantics all fall out of
`tyIsInteger` including `Ty::Enum`. The suite exercises every shape, refuses the
five illegal programs with their exact diagnostics, and the two mutants each lose
exactly one rule and are caught. The pre-existing **288** byte-baseline rows are
unchanged, and `examples/enum_demo.ast` agrees with its C twin (exit `255`) under
both gcc and qemu. Evidence: `tests/enum-checks.sh` `[9/9]` and
`examples/enum_demo.ast` / `tests/enum-demo-twin.c`.
