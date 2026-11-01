# Validation — v0.23.65-dev

**Round:** "where the layout arithmetic runs out" — the audit's items 9 and
10. Two fixes, one correction to a suite, and **no byte change**: all 121
examples compile to the bytes `tests/baseline/v0.23.64-dev` records, so the
snapshot is copied forward under this version's name.

**Result:** 122 suites, 0 skipped, 0 failed. APK gates 3/3.

---

## I. What the audit asked for

> 9. 实测验证第二部分的 ELF/链接器项，优先 `.so` 的 `.eh_frame` 页对齐（影响
>    Android 15+ 16KB 设备）与 `kRelTlsOff` 越界
> 10. `layoutStruct` 改用带溢出检查的累加，并把尺寸上限校验前移

Both turned out to be the same question — *what happens when layout arithmetic
runs out of room* — and both had an answer worse than a refusal: the number
**wrapped**.

## II. `kRelTlsOff`: a mask where a check belonged

Local-exec TLS addresses a variable as `TPIDR_EL0 + offset`. The codegen emits

```asm
MRS  X16, TPIDR_EL0
MOVZ X17, #0
MOVK X17, #0, LSL#16
ADD  X16, X16, X17
```

and the internal relocation `kRelTlsOff` (4096, chosen so it cannot collide
with a real `R_AARCH64_*` number) fills both immediates. A `MOVZ`/`MOVK` pair
carries **32 bits**. The fill was:

```cpp
const uint32_t val=uint32_t((target-tlsVaddr)&0xffffffffu);
```

A mask is not a check. Reachable, and cheaply: 513 declarations of
`tls let gN: i64[1048576] = 0;` — a 10 KB source — put `g512` at offset
exactly 2^32, which became 0, which is where `g0` lives.

| program | v0.23.64-dev | correct |
| --- | --- | --- |
| `g512[0] = 1; return i32(g0[0]);` with 513 × 8 MiB thread-locals | **1** | 0 |
| the same with 512 (last offset `0xFF800000`) | 0 | 0 |

Not a crash: two variables silently became the same eight bytes. The mask is
gone; the check sits at the point of the lossy conversion and names what did
not fit:

```
error: thread-local variable '__aster_tls_g512' sits at offset 4294967296 in
the thread-local block, which does not fit the 32-bit MOVZ/MOVK pair a
local-exec access carries (limit 4294967295)
```

The 512-declaration case is now a **witness**, not a coincidence — the
boundary is asserted from both sides.

## III. `layoutStruct`: 2^32 wrapping to 0

The accumulation was `uint32_t off` and the size limit ran *after* the loop:

```cpp
s.size = (off + align - 1u) & ~(align - 1u);
...
if(s.size>kMaxStructSize) throw ...
```

The caps that were supposed to make that safe — an array field is at most 1000
elements, a struct is at most 1024 bytes — multiply instead of adding, because
a field may be an **array of structs**. `8192 × (1024 × 512) = 2^32` exactly:

| fields | element | total | what v0.23.64-dev did |
| --- | --- | --- | --- |
| 8192 | `L1[512]`, L1 = 1024 B | 2^32 | wrapped to **size 0** → `0 > 1024` is false → **accepted**, `sizeof` reported 0, every field laid over the zero-size slot |
| 4195 | `L1[1000]` | 4 295 680 000 | wrapped to 712 704 → refused as *"struct Big is too large: 712704 bytes"* — a size that never existed |

The second row is the nastier one to read: a diagnostic that is not wrong
about the verdict and is wrong about every number in it.

Fixed by doing both things the audit asked for. The accumulation is 64-bit, so
it cannot wrap; the limit is enforced **as fields are placed**, so there is no
window in which a nonsense size is held; and the message names the field that
crossed:

```
error: struct Big is too large: field 'f0' reaches offset 524288 (limit 1024 bytes)
```

Two consequences worth recording:

- `kMaxStructSize` moved to **namespace scope**, because the check now lives in
  `layoutStruct` rather than in its caller. The caller passes its declaration
  token in (`layoutStruct(s,id)`), so the refusal still carries `at L:C`.
- A 32-bit **span ceiling** guards `f.offset` independently of the size limit,
  so raising `kMaxStructSize` later cannot quietly reintroduce the wrap. The
  rounded-up size is still asserted too, though with `kMaxStructSize = 1024`
  and every alignment a divisor of it the per-field check has always fired
  first. The invariant is kept because it is the assertion that says what
  `s.size` *is*, not because it currently fires.

## IV. Item 9's other half: measured, and sound

`.so` `.eh_frame` page alignment was the audit's first priority. It is fine —
and finding that out **corrected the suite that was supposed to be checking
it**.

`tests/page-size-checks.sh` asserted, for every `PT_LOAD`:

```python
assert off % page == 0 and vaddr % page == 0
```

That is start-alignment. The contract is **congruence**: `p_vaddr == p_offset
(mod p_align)`, which is what a loader needs, because it mmaps from
`p_vaddr & ~(page-1)` at file offset `p_offset & ~(page-1)`. GNU ld settles
which reading is real:

| GNU ld `-Wl,-z,max-page-size=` | second `PT_LOAD` | start-aligned | congruent mod `p_align` | congruent mod 16 384 |
| --- | --- | --- | --- | --- |
| 4096 | off `0xe30` / vaddr `0x1e30`, align `0x1000` | **no** | yes | **no** |
| 16384 | off `0x3e30` / vaddr `0x7e30`, align `0x4000` | **no** | yes | yes |

The stronger assertion could never have failed, because **no image in the
corpus carried a `.eh_frame`**. That is what `-g` is: the shared writers give
`.eh_frame` / `.eh_frame_hdr` their own `PT_LOAD`, at `0x10840` under 16 KB —
congruent, not start-aligned. Without `-g` the fourth layer was measuring
three segments where a shipped debug `.so` has four.

So the suite now:

- runs the whole matrix **with `-g`** as well (24 images instead of 12);
- asserts congruence, plus `p_align == page`;
- asserts that `-g` really does add a segment, so the paragraph above cannot
  quietly stop being true;
- asserts the GNU ld differential — at least one of its `PT_LOAD`s is congruent
  and **not** start-aligned — so the correction cannot rot into "anything
  goes".

Aster's images are congruent at either setting (`p_vaddr == p_offset` up to the
link base); what the 4 KB default lacks is `p_align` itself, which is why
`--page-size` exists.

## V. The suite

`tests/layout-boundary-checks.sh` (9 layers), registered in `DEFAULT_SUITES`
and `CRITICAL`:

| layer | content | result |
| --- | --- | --- |
| [1/9] | strict build (`-Werror -Wall -Wextra -pedantic`) | PASS |
| [2/9] | source guards pinning both ceilings — and asserting the mask is **gone** (`grep -c '& 0xffffffffu)' == 0`) | PASS |
| [3/9] | 7 qemu witnesses: four struct layouts unchanged, two proving thread-locals do not alias, and the last legal block offset (511 × 8 MiB) | PASS |
| [4/9] | 6 C differential cases (`tests/layout-boundary-twin.c`) | PASS |
| [5/9] | 6 refusals — 2^32 struct, 712 704 struct, three ordinary-limit shapes, offset 2^32 | PASS |
| [6/9] | counts on **both** sides (≥6 witnesses, ≥6 refusals) | 7 / 6 |
| [7/9] | 3 mutants | 3/3 caught |
| [8/9] | 360-row byte baseline | 360/360 identical |
| [9/9] | one shape (struct + thread-local) × 3 modes, running to 42 | PASS |

The twin is explicit about what it does **not** twin. Reproducing a 4 GiB
thread-local block in C would mean asking a C compiler for a 4 GiB per-thread
allocation, and the property under test belongs to Aster's own code sequence —
so the TLS half is twinned on the property the defect destroyed (two
thread-locals hold independent values), not on the size.

The mutants each withdraw one ceiling and must be caught by a program the real
compiler refuses:

| mutant | withdrawal | caught by |
| --- | --- | --- |
| m1 | `if(off>0xffffffffULL)` → `if(false)` — the mask returns | 513 × 8 MiB thread-locals |
| m2 | 32-bit accumulator **and** no per-field check — the defect's exact shape, leaving only the after-the-loop check on a size that has already wrapped | 8192 fields reaching 2^32 |
| m3 | both size checks removed | one field past 1024 |

m2 is a two-edit mutant on purpose: reverting the accumulator alone is *not*
caught, because the per-field check fires first. That is the round's honest
answer to "which edit is load-bearing" — the per-field check is what fixes the
bug, the 64-bit accumulation is what keeps the diagnostic from naming a number
that never existed.

## VI. Gates

```
CI SUMMARY: 122 passed, 0 skipped, 0 failed (of 122 suites)
APK GATES : 3 passed, 0 skipped, 0 failed
```

| gate | after the round |
| --- | --- |
| `ci-protocol-checks.sh` | 122 suites, 121 examples, 360 baseline rows, no orphans |
| `coverage-checks.sh` | line coverage of `src/aster.cpp` above the 80% floor |
| `mutation-score-checks.sh` | 27 suites declare 170 mutant builds; a green gate means all of them are caught |
| `version-checks.sh` | banner, the single version literal, `CMakeLists.txt`, README, `VERSION_HISTORY.md`, `ARCHITECTURE.md` and this report all name `0.23.65-dev` |

The suite count moves 121 → 122.

## VII. What is still open

- `regression-symtab.sh`'s `ET_REL` branch has **still never executed**: only 7
  of its 11 fixtures were ever committed, and the missing four would need a
  v0.16.0 compiler to regenerate.
- The audit's item 13 — the language gaps proper (`typedef`, `const`, `void`).
- The `typeOf()` / `exprType()` unification (the P1 root cause), unchanged and
  still deliberately open: it is a semantic decision, and closing it moves
  bytes.
- `--page-size 65536` is not modelled anywhere. Aster would accept it; whether
  any device needs it is unverified.
