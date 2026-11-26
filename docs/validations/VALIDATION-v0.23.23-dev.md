# Validation Report — v0.23.23-dev

**Feature: the raw-memory width ladder is complete — `load_u16`/`store_u16`
(halfword) and `load_i64`/`store_i64` (quadword).** Four intrinsics in the
established shape, dispatched at three sites each behind the shadow guard; no
new encoding, no frame-layout change, no ABI change.

```
$ ./aster build-elf examples/narrow_mem.ast -o narrow_mem && ./narrow_mem
$ echo $?
246                                     # matches the gcc twin of the same program — §7
```

## 1. Why this round exists: the last cell of the narrow matrix

Round 4's difficulty audit ranked **narrow memory intrinsics** first, and the
reason is visible in the code rather than in a wishlist. The byte pair
(`load_u8`/`store_u8`, v0.22.6-dev) made raw memory reachable one byte at a
time, and `load_ptr` reads a pointer out of memory — but the two widths real
data actually arrives in had no spelling. Reading an `i64` out of a buffer
meant eight `load_u8`s, seven shifts and seven ors, and that assembly is
**wrong in a way a self-comparison cannot see**: `<< 32` on an `i32` is a
32-bit shift whose hardware count wraps, so `1 << 32` is **1** — measured this
round, not assumed:

```
$ aster build-elf probe.ast -o probe && ./probe; echo $?
69        # (1 << 32) % 251 = 1, (1 << 31) % 251 = -187, returned as 1*256 + (-187)
```

The high word of a hand-assembled quadword therefore comes back as the low
word, and because both sides of a self-comparison are assembled the same wrong
way, no test written that way could ever fail. In C the same read is one line.
The gap had survived because nothing was *broken*: this is an API-missing
difficulty, and the LDRH/STRH/LDR X/STR X encodings had existed since the
stack-path work — the round's four intrinsics are dispatch and contract, not
new instruction selection.

## 2. The feature: four intrinsics, three sites each, one new rule

Each intrinsic gained a branch in each of the three dispatch sites —
Sema's `checkCall`, codegen's `callType`, and codegen's `gen` `Call` case —
and every branch carries the v0.23.21-dev shadow guard
(`&&!arities.count(e.name)` / `&&!functionArities.count(e.name)`), because
**the user's function wins, always**. The contracts mirror the byte pair
exactly:

| Intrinsic | Sema answers | Codegen | Contract |
|---|---|---|---|
| `load_u16(p)` | `Ty::I32` | `LDRH Wa, [Xa]` | zero-extended, 0..65535; unaligned `p+3` accepted |
| `store_u16(p, v)` | `Ty::I32` | `STRH Wv, [Xn]` | writes `v & 0xFFFF`; answers the **original** `v` |
| `load_i64(p)` | `Ty::I64` | `LDR Xa, [Xa]` | the full 64 bits; narrows to the low 32 at `i32` width |
| `store_i64(p, v)` | `Ty::I64` | `STR Xv, [Xn]` | eight bytes; answers the original `v`; `i32` widens by **sign-extension**; `bool` rejected |

`callType` answers `Ty::I64` for the two quadword names (the halfword pair
shares the existing `i32` fallthrough, exactly like the byte pair); no
`pointerReturnFunctions` registration is needed because all four answer
integers, and `exprYieldsPtr` is untouched.

The one genuinely new rule is the widening inside `store_i64`:

```cpp
int v=gen(*e.args[1],Ty::I64);int a=gen(*e.args[0]);
emit(0xf9000000u|(uint32_t(a)<<5)|uint32_t(v)); // STR Xv, [Xa]
```

`gen(..., Ty::I64)` applies the same rule that stores an `i32` into an `i64`
local — `Var`'s SXTW, `Num`'s `emitMov64` — so `store_i64(p, -1)` lands eight
`0xFF` bytes and reads back as `-1`. Without the width argument the value is
stored zero-extended (`0x00000000FFFFFFFF`) and the round's showcase case
silently disagrees with C; the mutation layer's m6 reverts exactly this call
and requires the battery to go red. The `bool` rejection is the second half of
the same discipline: no `i64` slot accepts a bool anywhere else in the
language, and this store is not where that changes.

## 3. The width ladder, before and after

| Access through a `ptr` | v0.23.22-dev | v0.23.23-dev |
|---|---|---|
| 8-bit read | `load_u8` | `load_u8`, unchanged |
| 16-bit read | eight `load_u8`s + shifts + ors | **`load_u16`** |
| 32-bit read | `*p` (LDR W) or four byte loads | unchanged |
| 64-bit read | eight `load_u8`s + shifts + ors — with the `<< 32` trap | **`load_i64`** |
| 8-bit write | `store_u8` | `store_u8`, unchanged |
| 16-bit write | eight `store_u8`s | **`store_u16`** |
| 64-bit write | eight `store_u8`s — high word silently lost | **`store_i64`** |

## 4. `tests/narrow-memory-checks.sh` — seven layers, all run

Registered in `tests/ci.sh` after `syntax-relief-checks.sh`.

**[1/7] Strict build.** `-Werror`, zero warnings.

**[2/7] Source guards.** Each of the four names is pinned in all three
dispatch sites *with its shadow guard*; the `callType` i64 answer is pinned;
the four encodings are pinned — including "`// LDR Xa, [Xa]` must now appear at
least twice", because `load_ptr` already emits one and `load_i64` must add its
own; and the exact widening call `int v=gen(*e.args[1],Ty::I64);…` is pinned,
because without that text the sign-extension case would silently agree with a
broken compiler.

**[3/7] Tool probe.** Locates `aarch64-linux-gnu-gcc` (the independent oracle)
and a runner; SKIPs cleanly without either; a native cc on an x86 box is
detected and rejected.

**[4/7] Differential battery — 24 cases, gcc-differential.** Each case has an
Aster source and a C twin compiled by `aarch64-linux-gnu-gcc -O2 -fwrapv`, both
run under qemu, exit statuses compared — no hand-computed expectation anywhere.
Halfword: round trip, truncation past 16 bits (`0x1BEEF`), zero-extension read
as `i32` *and* as `i64`, an **unaligned** `blob+3` halfword (the twin uses
`memcpy` so the oracle itself assumes no alignment), a loop, a helper.
Quadword: round trip, the **`0x100000000` trap value** the old shift-and-or
lost, the negative and positive `i32` widenings, narrowing back to `i32`, a
string literal's bytes at quadword width, read-modify-write, a loop at 1e9
scale, a helper with a `ptr` parameter, and a call result feeding arithmetic
directly at `i32` width (the path `callType`'s i64 answer feeds — added when
the first mutation-layer run proved nothing else pinned it). Aliasing: a
halfword store observed through a quadword load (little-endian layout).
Shadowing: each intrinsic shadowed by a user function, a same-signature
`load_i64`, and a *partial* shadow — `store_u16` is the user's function while
`load_u16` stays intrinsic — proving the guard is per name, not a global
switch.

**[5/7] Rejection matrix — 8 cases.** An integer where a `ptr` belongs, wrong
arity, a string value for `store_u16`, a string or a `bool` value for
`store_i64` — each demanding the diagnostic that names the offending argument.

**[6/7] Coverage map.** Twelve contract regressions must stay resident: the
two round trips, the truncation-and-answer contract, both zero-extension
widths, the trap value, the widening, the narrowing, the call-arith path, and
the three shadowing shapes. Deleting one without updating the map fails the
map.

**[7/7] Mutation layer — 7 mutants.** Each intrinsic's dispatch disabled (its
case must stop compiling — gen's fallthrough throws *call to undeclared
function*); the `callType` i64 answer removed (`i64_call_arith` must disagree
with the oracle, because the modulo would run on the low 32 bits alone); the
widening call reverted to `gen(*e.args[1])` (`i64_widen_neg` must disagree —
`-1` stored as `0x00000000FFFFFFFF`); and the `load_u16` shadow guard removed
(`shadow_load_u16` must disagree — the intrinsic would read `"x"` instead of
answering 7). A check that passes on a damaged compiler is not checking
anything.

## 5. What this deliberately does not do

- **It does not add signed narrow loads** (`load_i8`/`load_i16`). A signed
  narrow read composes from the unsigned intrinsic plus the language's
  arithmetic shift, and the signed-16 spelling was never the felt gap.
- **It does not add `load_u64`.** There is no `u64` type for it to answer
  with; `i64` is the only 64-bit type, and `load_i64` is its load.
- **It does not make the intrinsics first-class narrow *load* types.** The
  byte pair's precedent is "the intrinsic answers `i32`, the width is the
  access"; widening the `u16` type's role in the expression lattice is a
  separate, larger round.
- **It does not touch `*p`, pointer indexing, or any existing intrinsic's
  contract by one byte.**

## 6. Byte identity: 279 of 279

`tests/struct-checks.sh` [4/8] re-hashes every example in three modes
(`build-so`, `build-elf`, `build-obj --pic`) against
`tests/baseline/v0.23.5-dev/example-hashes.txt` and **passed with the round's
compiler: all 279 rows byte-identical** — the 276 pre-existing rows unchanged
(the new code is reachable only through the four new names; the version
constant is not embedded in generated objects) and 3 new rows recording
`examples/narrow_mem.ast`. The diff against the previous recording is three
additions and zero changes.

## 7. Verification log

| Step | Result |
|---|---|
| Strict `-Werror` build of the modified compiler | clean |
| `1 << 32` on an `i32` (the trap the round closes) | 1 — the shift count wraps, measured |
| `examples/narrow_mem.ast` vs its gcc twin | both exit 246 |
| `narrow-memory-checks.sh` [4/7] battery | **24/24 match the C oracle** |
| `narrow-memory-checks.sh` [5/7] rejections | **8/8** rejected with the naming diagnostic |
| `narrow-memory-checks.sh` [7/7] mutations | **7/7** correctly turn the battery red |
| `u16_trunc` twin, first attempt | the *twin* was wrong (C's assignment-expression value); Aster's documented "answers the original" contract held — the corrected twin is what pins it |
| `struct-checks.sh` [4/8] baseline | **279 recorded outputs reproduced byte for byte** |
| Related suites re-run locally | `write-output`, `syntax-relief`, `narrow-value`, `other-faces-audit`, `diagnostics` — all green |
| Full CI | see §8 |

## 8. Full CI

```
========================================
CI SUMMARY: 80 passed, 0 skipped, 0 failed (of 80 checks)
========================================
```

| CI | v0.23.22-dev | v0.23.23-dev |
|---|---|---|
| Result | 79 passed / 0 skipped / 0 failed | **80 passed / 0 skipped / 0 failed** |
| Checks | 79 | 80 (+1: `narrow-memory-checks.sh`) |
| Baseline rows | 276 (all unchanged) | 279 (276 unchanged + 3 new) |
| New resident suite | `syntax-relief-checks.sh` | `narrow-memory-checks.sh` |

## 9. What this unblocks

- **Real data becomes readable.** A `u16`/`i64` field in a buffer, a window
  struct's 64-bit member, a wide counter in a table — all one intrinsic call,
  with the sign-extension and truncation rules pinned against gcc rather than
  against hope. The eight-load shift-and-or idiom (and its silent `<< 32`
  trap) is retired.
- **The intrinsic family is now width-complete at every rung the language has
  a type for**: byte (`load_u8`), halfword (`load_u16`), word (`*p`),
  doubleword (`load_i64`), pointer (`load_ptr`). What remains is not a width
  but a *kind*: signed narrow loads (composable), and the wider design
  question of first-class narrow types.
- **Still open, in the order the difficulty audit argued:** function-pointer
  calls (a language-design round of its own — taking a function's address
  shipped long ago, but Aster never emits a `BLR`, so it cannot call through
  one), then the debug-information slice (`.debug_info` on top of the
  v0.23.12-dev line table).
