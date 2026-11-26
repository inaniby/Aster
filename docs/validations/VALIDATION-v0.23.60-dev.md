# Validation — v0.23.60-dev (the `T(x)` cast widened past the integers)

**Compiler:** `src/aster.cpp` (`ASTER_VERSION_STRING "0.23.60-dev"`), built
`g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror`.

**Round type:** language feature extension. The explicit cast `T(x)`, introduced
in v0.23.48-dev as the six integer spellings (`i32 i64 u8 u16 u32 u64`), is
extended to also accept `bool` and `ptr`/`ptr<S>` as targets.

---

## 1. The change

The cast `T(x)` is a function-shaped primary (`i32(x)`, `bool(x)`, `ptr(x)`,
`ptr<i32>(x)` — not `(i32)x`). Previously only integer targets/operands were
legal; `ptr` and `bool` were refused with `cannot cast ptr to u8`-style
messages. v0.23.60-dev admits every conversion C permits that does not touch a
struct:

| Direction | Status | Why |
| --- | --- | --- |
| integer → integer | unchanged | narrowing = low bits; widening = source signedness |
| bool ↔ integer | **new** | a bool is a 0/1 `i32`; bits reinterpret directly. integer→bool is the one non-trivial direction — normalized to 0/1 at run time |
| integer ↔ ptr | **new** | an address's bits are an integer and vice versa; `i32(p)` takes the low 32 bits the way C does |
| `ptr<S>` ↔ `ptr<U>` | **new** | a typed pointer reinterprets as another typed pointer; the 64-bit value is unchanged, nothing emitted |
| struct on either side | **rejected** | a composite never converts to/from a scalar or address |
| bool ↔ ptr | **rejected** | an address is neither a truthiness nor a number |

### The one non-trivial direction: integer → bool

A bool is a 0/1 `i32`; a bare nonzero integer is not itself 0/1, so the cast
normalizes at run time: `gen(Cast)` for a bool target emits `CMP`+`CSET W, ne`
(the same 0/1 a bool comparison produces), so `bool(x)` agrees with `x != 0`
whether stored, returned, or combined. `castConstValue` folds the same way
(`case Ty::Bool: return v!=0?1:0;`), so `i32(bool(5))` is `1`, not `5`.

### Type-system and codegen edits (all pinned by `tests/cast-conversions-checks.sh` `[2/9]`)

- **Parser** (`primary()`): the cast-target recognizer now also accepts `TK::Bool`
  (`case TK::Bool: t=Ty::Bool;`) and `TK::Ptr` (with an inline `<T>`/`<<S>` angle
  bracket parse for `ptr<i32>`/`ptr<Point>`), and resolves the target type *before*
  the `(operand)` — the old ordering refused `ptr<i32>(x)` with "expected '(' after
  cast type".
- **Type systems** (both `typeOf` and `exprType` answer `e.ty` for `Expr::Cast`, so
  the typed-IR guard at `gen()` stays honest).
- **Codegen** (`gen(Cast)`): operand generated at the target width first; integer→
  bool normalized to 0/1; every other new direction is a bit reinterpretation.
- **`genBool`**: routes a `Cast` to bool through `gen(Cast, Ty::Bool)` so
  `(bool)x` is a usable boolean expression.
- **Constant folder** (`castConstValue`): `bool` arm folds to 0/1.

---

## 2. Behavioural witnesses (`tests/cast-conversions-checks.sh` `[3/9]`)

Eleven hand-derived AArch64 programs, each returning the value it is named for, so
a wrong fold or normalization is the exit code. All run under `qemu-aarch64`
(or an AArch64 host):

```
bool -> i32 (true=1, false=0)           exit 1
bool -> u64 (true=1, false=0)           exit 2
bool -> u8  (true=1, false=0)           exit 3
int -> bool, nonzero is true            exit 4
int -> bool, zero is false              exit 8
int -> bool, negative is true           exit 5
int -> ptr -> i64 round trip            exit 16
ptr -> i32 takes low 32 bits            exit 32
int -> ptr keeps high bits              exit 17
ptr<S> -> ptr<U> reads the field        exit 64
typed ptr -> untyped -> i32             exit 65
```

`int -> ptr keeps high bits` (`i64(ptr(0x100000000)) == 0x100000000`) confirms
the 64-bit address is preserved through the reinterpretation; `ptr -> i32 takes
low 32 bits` confirms `i32` of an address reads only the low 32 bits, exactly as
C does. The `ptr<S> -> ptr<U>` witness stores `9` into a `Point.x`, re-tags the
`ptr<Point>` to a `ptr<i32>`, dereferences, and reads back `9` — proving the
re-tag is a no-op on the bits.

### gcc differential (`[4/9]`)

`examples/cast-conversions.ast` is compiled by Aster and by its C twin
`tests/cast-conversions-twin.c` (same program, same 8-group structure, every
group returning a distinct bit and the whole `|`'d together), each run under
`qemu-aarch64` cross-built with `aarch64-linux-gnu-gcc`. Both exit **255**. The
twin is the oracle: Aster's conversion rules must agree with C's, and they do,
byte-for-byte, on the exit code.

---

## 3. Rejection matrix (`[5/9]`)

The new refusals hold, with exact messages:

```
bool -> ptr        "cannot cast bool to ptr"      (the bool<->ptr crossing)
ptr -> bool        "cannot cast ptr to bool"      (the bool<->ptr crossing)
struct -> integer  "cannot cast struct"           (struct on the source side)
cast without paren "expected '(' after cast type" (syntax)
cast unclosed      "expected ')' after cast operand" (syntax)
ptr< no closing >  "expected '>' after the type in a ptr<...> cast" (syntax)
ptr< of unknown    "unknown struct type in ptr<"   (syntax)
```

`tests/integer-cast-checks.sh`'s rejection matrix is realigned to the same
boundaries (11 refusals): the old `ptr(0)` / `bool(1)` / `u64(ptr)` / `u64(bool)`
rejections are gone because those spellings are now legal; what remains illegal is
the syntax cases, the narrow-slot discipline, and the two ever-illegal crossings
(struct on either side, bool↔ptr).

---

## 4. Coverage (`[6/9]`) and mutation layer (`[7/9]`)

- **Coverage:** `grep -c '^check '` over the behavioural layer requires ≥ 11
  behavioural cases (the eleven witnesses above). The two type systems, the
  constant folder, the backend, and `genBool` are each reached for every shape.
- **Mutation layer (5 mutants, each observably wrong):** each mutant removes one
  rule; a case must notice.
  - `m1` compiles out the integer→bool normalization (`if(e.ty==Ty::Bool)` →
    `if(false)`): `i32(bool(x))` stays `5` instead of becoming `1` — `must_differ`.
  - `m2` re-refuses bool→integer (`if(toInt)` → `if(toInt && !fromBool)`): the real
    compiler accepts `i32(true)`, the mutant refuses — `must_reject`.
  - `m4` re-refuses integer→ptr (`if(toPtr&&!fromBool)` → `if(false)`) —
    `must_reject`.
  - `m5` re-refuses integer→bool (`if(toBool&&fromInt)` → `if(false)`) —
    `must_reject`.
  - `m6` forgets the target width when generating the operand (`int a=gen(*e.a,e.ty)`
    → `int a=gen(*e.a)`): `i64(ptr(0x100000000))` truncates to `0` —
    `must_differ`.

All five are caught; the suite asserts "five mutated compilers each lose exactly
one rule, and the checks notice".

---

## 5. Byte-identity baseline (`[8/9]`)

`examples/cast-conversions.ast` is the round's own example and is excluded from
the pre-existing comparison; its three rows (build-so / build-elf / build-obj
--pic) are recorded in `tests/baseline/v0.23.5-dev/example-hashes.txt`, and the
layer asserts it appears in all three modes. The pre-existing count is unchanged:

```
pre-existing rows byte-identical   288
new example rows recorded          3
```

No pre-existing example moved a byte — the widening only adds new legal spellings;
the integer→integer path (which every pre-existing example's casts use, if any) is
byte-for-byte what it was. The twelve byte-baseline suites
(`struct-checks`, `null-ptr-checks`, `condition-checks`,
`array-address-checks`, `precedence-checks`, `struct-array-field-checks`,
`array-elem-types-checks`, `multi-dim-array-checks`, `sizeof-len-checks`,
`switch-checks`, `literals-checks`, `integer-cast-checks`) gained a
`^cast-conversions\.` filter so the 288-row byte-identity assert is preserved.

---

## 6. The example, end to end (`[9/9]`)

`examples/cast-conversions.ast` runs under `qemu-aarch64` and returns **255** —
the same value its C twin returns — exercising every widened direction in one
program.

---

## 7. Regression surface

- `tests/integer-cast-checks.sh` source guard updated to the new general refusal
  message; its rejection matrix realigned to the widened boundaries (13 → 11
  refusals); its 9-mutant layer (integer↔integer, the u64 grid, literal ceilings)
  is unaffected by the widening and still passes.
- `tests/cast-conversions-checks.sh` is registered in `tests/ci.sh`.
- Full CI (`LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc bash tests/ci.sh`)
  green; the 288-row byte baseline holds across all twelve baseline suites.
