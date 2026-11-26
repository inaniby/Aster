# Validation — v0.23.19-dev

**A `u8` argument never arrived, and the cause was not the ABI: an unscaled
byte offset above 4095 turned a `STRB` into a `LDRB`.**

```aster
fn g(a: u8) -> u8 { return a; }
fn main() -> i32 { return g(200) == 200 ? 11 : 0; }
```

v0.23.18-dev exits **0**. A `u8` parameter had not worked since `u8` was
introduced in v0.23.2-dev, five releases earlier, and no suite in the tree had
ever called a function with one — v0.23.18-dev's 54 wide-integer cases all
used `i32` and `i64` values.

---

## 1. Why it did not look like an ABI problem

The first thing to establish was *which* narrow paths were broken, because the
obvious hypothesis — "the narrow ABI is wrong" — predicts that all of them are.
It predicts wrong. A 12-probe matrix against the v0.23.18-dev binary:

| Probe | old | new |
| --- | --- | --- |
| `u8` parameter (200) | **FAIL** | PASS |
| `u8` parameter (255) | **FAIL** | PASS |
| two `u8` parameters | **FAIL** | PASS |
| `u8` after an `i64` parameter | **FAIL** | PASS |
| `u8` as the 9th argument (on the stack) | **FAIL** | PASS |
| `u8` through a nested call | **FAIL** | PASS |
| `u16` parameter (40000) | PASS | PASS |
| `u16` parameter (65535) | PASS | PASS |
| `u32` parameter (4000000000) | PASS | PASS |
| `i64` parameter (4294967297) | PASS | PASS |
| `u8` local | PASS | PASS |
| `u8` global array element | PASS | PASS |

Six failures, and every one of them is a **`u8` argument**. `u8` locals,
globals, array elements and struct fields are fine; `u16`, `u32` and `i64`
arguments are fine. A type-based explanation has to account for `u8`-the-local
being correct while `u8`-the-parameter is not, and it cannot. What separates
them is not the type, it is the **offset**.

## 2. The mechanism: bit 12 lands on bit 22

AArch64's unsigned immediate offset is width-scaled, so its *range* differs for
every width:

| Encoding | scale | byte-offset range |
| --- | --- | --- |
| `LDRB` / `STRB` | **unscaled** | 0 .. 4095 |
| `LDRH` / `STRH` | 2 | 0 .. 8190, even |
| `LDR` / `STR W` | 4 | 0 .. 16380, 4-aligned |
| `LDR` / `STR X` | 8 | 0 .. 32760, 8-aligned |

`loadStackT` / `storeStackT` shifted the byte offset left by 10 for *every*
width. For a `u8` offset past 4095 that does not wrap onto a neighbouring byte
and it is not rejected: **bit 12 of the offset lands on bit 22 of the
instruction**, which is exactly the bit that separates `STRB` (`0x39000000`)
from `LDRB` (`0x39400000`). The caller stored the argument by loading it:

```
; wanted:  STRB  w0, [sp, #4160]
; emitted: 0x390003e0 | (4160 << 10)  =  0x394003e0  ->  LDRB w0, [sp, #64]
```

Every call argument is staged in the scratch area at `4160 + callDepth*256`,
which is past 4095 for *every* call — so this was not a corner case, it was the
only case. The callee then read whatever the uninitialized stack held, which is
why `g(200)` returned 0.

The three survivors are explained by the same table:

- **`u16` on arithmetic alone.** `4160/2 == 2080` fits, and even the deepest
  scratch (`4160 + 14*256 + 31*8 == 7992`) is 3996 after the shift.
- **Struct fields cannot reach it.** A struct is capped at 1024 bytes.
- **Locals and globals sit at small offsets** — under 4095, where the unscaled
  encoding is correct.

So the truthful statement of the defect is *"unscaled byte offsets above 4095
are broken"*, not *"u8 parameters are broken"*, and the two differ in where the
fix belongs: in the encoding helpers, not in `layoutArgs()`.

## 3. The repair

```cpp
static bool stackOffFits(uint32_t off,Ty t){
    if(t==Ty::U8) return off<=4095u;                     // unscaled 12 bits
    if(t==Ty::U16)return off<=8190u&&(off&1u)==0u;       // imm12 << 1
    if(tyIs64(t)) return off<=32760u&&(off&7u)==0u;      // imm12 << 3
    return off<=16380u&&(off&3u)==0u;                    // imm12 << 2
}
void loadStackOff(int reg,uint32_t off,Ty t){
    if(stackOffFits(off,t)){emit(loadStackT(reg,off,t));return;}
    if(reg==kGlobalBase){emitAddOff(17,31,off);emit(loadAtT(reg,17,0,t));return;}
    emitAddOff(kGlobalBase,31,off);emit(loadGlobalT(reg,t));
}
void storeStackOff(int reg,uint32_t off,Ty t){
    if(stackOffFits(off,t)){emit(storeStackT(reg,off,t));return;}
    if(reg==kGlobalBase){emitAddOff(17,31,off);emit(storeAtT(reg,17,0,t));return;}
    emitAddOff(kGlobalBase,31,off);emit(storeGlobalT(reg,t));
}
```

One range test per width, and one fallback that stages the address through
`x16` — or `x17`, when `x16` is itself the operand, because `emitAddOff` would
otherwise overwrite the value about to be stored. All **23** previous direct
`emit(loadStackT(...))` / `emit(storeStackT(...))` sites now go through the two
helpers. A fitting offset emits the encoding it always did, so nothing
pre-existing moves by a byte.

## 4. `tests/narrow-int-abi-checks.sh` — seven layers, all run

| Layer | What it is | Result |
| --- | --- | --- |
| [1] | strict `-Werror` rebuild of the compiler | clean |
| [2] | **15 source guards** | all present |
| [3] | 2 rejections | both rejected |
| [4] | **21 qemu cases in four groups** (A–D) | all correct |
| [5] | 8 C differential comparisons + **a real cross-language link** | agree |
| [6] | **6 compiler mutations** | all 6 caught |
| [7] | 7 documented blind spots | written down |

Wall clock: **41 s**.

**[2] The guards** pin each of the four range tests (`off<=4095u`,
`off<=8190u&&(off&1u)==0u`, `off<=32760u&&(off&7u)==0u`,
`off<=16380u&&(off&3u)==0u`), both fallback helpers, both `x16`-is-the-target
branches, the counted call sites (13 loads, 10 stores) and the absence of any
bare `emit()` of the raw encodings — the last one is what stops someone
reintroducing the defect at one site while the helpers stand there correct.

**[3] The rejections** confirm that fixing delivery did not loosen typing: an
`i64` argument into a `u8` or `u16` parameter still fails with
`argument type mismatch calling g at argument 1: expected u8, got i64`.

**[4] The cases.** A: narrow arguments in registers (7). B: narrow arguments on
the stack, from the 9th onward (4). C: mixed widths, nesting, recursion (5).
D: forward guards at small offsets — the local, global, local-array, struct-field
and narrow-variable paths that were *already* correct and must stay correct (5).
Group E (3 cases) is in [5], because it can only run through a real link.

Every case returns its own number as a non-zero exit code, so a wrong value
cannot masquerade as a clean run.

## 5. The C differential, and the cross-language link

Eight of the cases are compiled by `aarch64-linux-gnu-gcc -O2 -fwrapv` and must
return the same exit code as Aster. That catches an expectation that is wrong in
the same way the compiler is, which a qemu self-check cannot.

A test that only ever calls Aster from Aster would also pass on a stack layout
nothing else uses. So [5] does the thing that actually has to work: an Aster
object is linked against a real C object.

```sh
aarch64-linux-gnu-gcc -O2 -c host.c -o host.raw.o
aarch64-linux-gnu-objcopy -R .eh_frame -R .rela.eh_frame -R .data -R .bss \
                          -R .comment -R .note.GNU-stack host.raw.o host.o
aster build-obj l.ast -o l.o && aster link-obj l.o host.o -o l.a64
```

The `objcopy` step is not decoration: Aster's linker accepts only the sections
it emits itself, and a C object arrives with `.eh_frame` (allocated but unknown)
and an empty `.data`/`.bss` whose attributes Aster refuses. Stripping them
removes no instruction — the host is three leaf functions with no data of their
own. Three calls are then verified through that link, including
`c_ninth_u8(0,0,0,0,0,0,0,0,200) == 200`, which is the one that proves the
**stack layout**: the 9th argument is where gcc puts it, not merely where Aster
puts it.

## 6. The mutation layer, and the three mutants that survived

Six mutants, each a different way to lose a narrow argument, each of which must
be caught by a *named* case:

| Mutant | Caught by |
| --- | --- |
| M1 U8 range test always true | 11 12 |
| M2 U8 limit raised past the range | 11 12 |
| M3 store fallback uses the wrong base | 11 12 35 |
| M4 store fallback stages the wrong offset | 11 12 35 |
| M5 load fallback reads past the staged address | 21 23 24 |
| M6 load side skips the range test | 11 12 21 23 24 35 |

**The first draft had three survivors, and that was the informative part.**
They are worth recording, because each says something true about the code:

1. **Removing the load-side `x16`-is-the-target branch is an equivalent
   mutant.** `emitAddOff` leaves the address in `x16` and the very next
   instruction consumes `x16` as its base, so `LDRB W16, [X16]` is correct
   without `x17`. The store side is a different matter — there, staging through
   `x16` would destroy the value — which is why both branches stay and read the
   same way. The mutant was replaced with one that is observable at the same
   site: a wrong offset inside `loadAtT` (M5).
2. **Changing `emitAddOff`'s chunk split slides the whole scratch area.** Every
   access to a scratch slot goes through the same helper, so the store and the
   load move together and the value still round-trips — visible in the object
   bytes (`add x16, x16, #0x840` instead of `#0x41`), invisible in an exit code.
   The suite pins the constant with a source guard instead, and says so.
3. **`g(0) == 0` passes under the defect too.** Uninitialized stack usually
   reads as zero, so case 13 is a forward guard and never a discriminator —
   the same rule v0.23.18-dev established for consistently-truncated
   expectations. It stays in group A; it left M1's discriminator list.

A mutation layer that cannot fail is not evidence, and three mutants that
cannot be caught are a finding about the suite, not a footnote.

## 7. Byte identity: 261 of 261

Direct A/B against the v0.23.18-dev binary, 87 examples × `build-elf`,
`build-so`, `build-obj --pic`: **mismatches = 0**.

No example in the tree passes a `u8` or `u16` argument — which is precisely why
the defect lasted five releases, and also why the fix moves no byte. The only
source delta beyond the fix is the version constant (and one comment).

## 8. What this suite deliberately cannot see

Stated in [7] of the suite itself, and summarised here:

- An uninitialized stack byte that happens to hold the expected value would let
  the original defect pass. It does not here, but it is why the discriminators
  use 200 and 255.
- The struct-field path (`loadAtT`/`storeAtT`) carries the same unscaled
  arithmetic, but a struct is capped at 1024 bytes, so a field offset cannot
  reach 4096. If that cap is ever raised, this suite does not cover what happens
  next.
- A `u8` argument's high bits are unspecified under AAPCS64, so the C
  differential compares values the callee normalizes itself, not raw register
  contents.
- The mutation layer proves the range test and both fallbacks are *seen*; it
  cannot prove the four ranges are the *right* numbers. The cross-language link
  is what does that.
- `emitAddOff`'s chunk size (§6.2), the load-side `x17` branch (§6.1), and the
  store-side branch, which no Aster program reaches today but which stays
  because removing it would make `emitAddOff` overwrite the value it is about
  to store.

## 9. Verification log

| Step | Result |
| --- | --- |
| Strict rebuild (`-Werror`) | clean |
| `tests/narrow-int-abi-checks.sh` | [7/7] PASS — 15 guards, 2 rejections, 21 qemu cases + 3 linked, 8 differential, 6 mutations, 7 documented blind spots (41 s) |
| Old compiler (v0.23.18-dev) on the 12-probe matrix | 6 PASS / 6 FAIL — every failure a `u8` argument (§1) |
| New compiler on the same matrix | 12 PASS / 0 FAIL |
| Direct A/B vs v0.23.18-dev | 261 builds, **0 differing** |
| Cross-language link (Aster object + gcc object) | 3 calls agree, incl. the 9th (stack) argument |
| Full `tests/ci.sh` | see §10 (74/0/1 on the first run — §9; 75/0/0 after) |

## 9. A regression this round introduced, and the CI that caught it

The mechanical part of the repair — routing all 23 direct
`emit(loadStackT(...))` / `emit(storeStackT(...))` sites through the new
helpers — also rewrote two lines that `struct-checks.sh` had pinned by literal
text: the prologue that saves the hidden result pointer (`storeStackT(8,
kSretSlot, Ty::I64)`) and the reload that brings it back for a nested `sret`
call. The first full CI run was therefore **74 passed / 1 failed**
(`struct-checks.sh`: "the sret pointer is not saved in the prologue"), and the
two guards now pin the new spelling.

That is the second round in a row where a bulk rewrite invalidated someone
else's guard, so the check is now mechanical rather than remembered: every
`grep -F '<literal>'` and every `grep -cF` count guard in `tests/*.sh` was
extracted and re-evaluated against the new source (181 literal guards, 37
count guards). The two sret pins were the only casualties; nothing else moved.
The same reason makes [2] of the new suite pin the *absence* of any direct
`emit()` of the raw encodings — a helper that is correct while one call site
bypasses it is the exact shape of this round's defect.

## 10. Full CI

```
========================================
CI SUMMARY: 75 passed, 0 skipped, 0 failed (of 75 checks)
========================================
```

Up from **74/0/0** in v0.23.18-dev: the one new suite is
`narrow-int-abi-checks.sh`, and nothing else moved. Wall clock 17:55 — the new
suite adds 41 s of it. (The first run of this round was 74/0/1; see §9.)

| | v0.23.18-dev | v0.23.19-dev |
| --- | --- | --- |
| CI | 74 passed / 0 skipped / 0 failed | **75 passed / 0 skipped / 0 failed** |
| direct A/B | 259/261 (2 = `c_struct_abi`) | **261/261 byte-identical** |
| suites covering narrow values | `wide-int-checks.sh` only | + `narrow-int-abi-checks.sh` |

## 11. What this unblocks

A narrow value now survives a call, which closes the last item on the gap list
that was *recorded, not fixed* two rounds ago. It also removes the standing
excuse for not testing the remaining C-ABI surface with narrow arguments: the
`e2e-c-abi*` suites can now take `u8`/`u16` parameters in both directions,
which is where the next disagreement with gcc would most likely be found.
