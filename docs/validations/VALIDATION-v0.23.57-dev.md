# Validation — v0.23.57-dev (pointer difference `p - q`)

**Round:** pointer-difference feature. The last missing pointer arithmetic after
`p + i32` (v0.22.x) and `p[i]` (v0.22.49-dev) shipped. `p - q` between two
pointers now returns the signed element count (an `i32`).

**Compiler:** `src/aster.cpp` (`ASTER_VERSION_STRING "0.23.57-dev"`), built
strictly with `g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror`.

---

## 1. What changed

| Layer | Location | Change |
|---|---|---|
| Element-stride helper | `ptrStrideType()` (new static helper, beside `ptrElemType`) | One resolver for "what does this pointer stride over" — the same `pe` `emitElemAddr` chooses for `p[i]`. An untyped `ptr` → `i32` (the one-i32 stride `p[i]` has always used), `ptr<T>` → `T`, `ptr<S>` → `S`. |
| Type rule (both twins) | `exprType` and `typeOf`, `case Expr::Sub` | `p - q` (both `Ptr`) → `Ty::I32`; rejects a stride mismatch with `pointer difference requires two pointers to the same element type`. `ptr - i32` still → `Ptr`; `i32 - ptr` / `ptr + ptr` still rejected. |
| Codegen | `gen()`, `default` arithmetic branch | New `ptr - ptr` arm: 64-bit byte gap (`SUB Xa, Xa, Xb`), then divide by the element stride — `ASR Xa, Xa, #sh` for a power-of-two stride, `SDIV Xa, Xa, Xw` for a struct stride that is not. The result rides in X and is consumed at the caller's width (an `i32` return takes the low 32 bits via `MOV W0, Wv`). |

The return type is `i32` — consistent with array indexing, and the element
count an index would name. The 64-bit byte gap is computed in X (pointers are
64-bit) so the difference of two far-apart addresses is exact; the shift/divide
produces a fully sign-extended value, so an `i64` consumer is also correct.

## 2. Instruction encodings verified against gcc

The hand-written AArch64 constants were confirmed by disassembling
`aarch64-linux-gnu-gcc -O2` output for the equivalent C:

| Stride | C (`a - b`) emits | Aster emits | Result |
|---|---|---|---|
| `i32` (4 B) | `cb010000 sub` + `9342fc00 asr #2` | `0xcb000000` + `0x93400000\|(2<<16)\|0xfc00` | `9342fc00` ✓ |
| `i64` (8 B) | `9343fc00 asr #3` | `0x93400000\|(3<<16)\|0xfc00` | `9343fc00` ✓ |
| `u8` (1 B) | `cb010000 sub` only (no shift) | `sh==0` branch, no shift | ✓ |
| struct `V3` (12 B) | `9ac10c00 sdiv` | `0x9ac00c00` (signed SDIV) | `9ac20c00` ✓ |

The SDIV constant required the signed-bit field `0xc00` over the bare
`0x9ac00000` — without it the opcode decoded as `SUBP` (subtract pointer) and
the struct case returned garbage. This was caught by the qemu self-check and
fixed before any suite run.

## 3. Behavior battery (qemu self-check, `tests/pointer-difference-checks.sh` [4/6]–[6/6])

Every stride was exercised end-to-end under `qemu-aarch64`; each program
asserts its own result and exits 0 on success.

| Case | Stride | `q - p` expected | Exit |
|---|---|---|---|
| untyped `ptr` (same array, both directions) | 4 B | 4 / −4 | 0 |
| `ptr<i32>` (both directions) | 4 B | 4 / −4 | 0 |
| `ptr<u8>` | 1 B | 6 | 0 |
| `ptr<i64>` | 8 B | 5 | 0 |
| `ptr<Row>` (8 B, `ASR #3`) | 8 B | 3 | 0 |
| `ptr<V3>` (12 B, `SDIV`) | 12 B | 3 | 0 |
| cross-category untyped `ptr` − `ptr<i32>` (same 4-B stride) | 4 B | 5 / −5 | 0 |

## 4. Rejection matrix (`[3/6]`)

| Input | Result |
|---|---|
| `ptr + ptr` | rejected — `invalid pointer arithmetic: ptr + ptr is not supported` |
| `i32 - ptr` | rejected — `invalid pointer arithmetic: expected ptr - i32` |
| `ptr<i32> - ptr<u8>` (stride 4 vs 1) | rejected — `pointer difference requires two pointers to the same element type` |
| `ptr<i32> - ptr<Row>` (scalar vs struct) | rejected — same diagnostic |

## 5. gcc differential (`tests/e2e-c-ptr-difference.sh`)

`examples/c_ptr_difference.ast` exports `aster_ptr_diff` (untyped),
`aster_ptr_diff_i32`, `aster_ptr_diff_u8`, `aster_ptr_diff_i64` and
`aster_ptr_diff_v3`. `tests/c-ptr-difference-host.c` hands each two pointers
into the same array and compares Aster's `p - q` against **C's own** `p - q`
(compiled by the host compiler). Run with `HOSTCC=aarch64-linux-gnu-gcc`
(so the host ELF runs under `qemu-aarch64` and can `dlopen` the AArch64
`.so`):

```
PASS: C -> Aster pointer difference (untyped, i32, u8, i64, struct)
PASS: Aster v0.23.57-dev pointer difference ABI test
```

On a host whose `HOSTCC` cannot emit AArch64 ELF the script SKIPs (by design,
see `tests/host-toolchain-probe.sh`); on an AArch64-native CI host it runs for
real.

## 6. Source guards (`[2/6]`)

The suite greps `src/aster.cpp` for `ptrStrideType`, the element-stride resolve
(`ptrStrideType(exprType(*e.a))`), the `ASR` emit (`0x93400000u|(uint32_t(sh)<<16)|0xfc00u`),
the `SDIV` emit (`0x9ac00c00u`), and the mismatch diagnostic — so a refactor
that drops any one of them fails first.

## 7. CI

Registered `pointer-difference-checks.sh` (main SUITES list) and
`e2e-c-ptr-difference.sh` (e2e list) in `tests/ci.sh`. Full `ci.sh` run: see
the round's commit log (impl → tests → docs, three commits, single-quoted
messages, no `stdbuf` wrapper so the qemu/交叉 subprocesses never inherit a
leaked `LD_PRELOAD`).
