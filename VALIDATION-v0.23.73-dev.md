# VALIDATION-v0.23.73-dev — fix the two P0s

**Version:** `0.23.73-dev` · **Theme:** the first repair round after
`AUDIT-v0.23.72-dev.md` — F-01 (AAPCS64 C.12 stack arguments) and F-02 (UXTW
imm3 overflow) · **Status:** shipped

Two code-generation defects that survived a fully green `128/128` CI are fixed
here. Neither adds syntax, neither changes a single byte of any program written
before this round. The full gate is green at **130 suites / APK 3 gates**, and
the frozen byte baseline is **384 rows: 378 inherited rows byte-identical, 6
new rows for the two new examples**.

## 1. Strict build and the generated-table contract

| Check | Result |
| --- | --- |
| `g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp` | PASS (`BUILD_EXIT=0`) |
| `python3 bootstrap/gen_lexer_names.py --check` | PASS (83 tokens / 32 keywords, unchanged) |
| `python3 bootstrap/gen_parser_names.py --check` | PASS |
| Quoted version literal `"0.23.73-dev"` in `src/aster.cpp` | exactly 1 |
| `./aster --version` | `Aster bootstrap compiler v0.23.73-dev` |
| `CMakeLists.txt` project version | `0.23.73` |
| `src/aster.cpp` line count | 13,804 (`ARCHITECTURE.md` claims `~13k`, within ±10%) |
| `tests/version-checks.sh` | 15/15 PASS |

## 2. The fix, and where it lives

| Fix | Edit in `src/aster.cpp` |
| --- | --- |
| F-01 | `layoutArgs`: the spill branch now sets `ngrn = 8` (AAPCS64 C.12), so once an argument cannot fit in registers every later argument goes on the stack. The caller's outgoing-argument loop changed from `for (i = 8; i < nargs; ++i)` to a full walk `for (i = 0; i < nargs; ++i)` that skips `lay.reg[i] >= 0`. A slot *below* 8 can itself be a stack argument, and starting at 8 lost it entirely. |
| F-02 | New `emitScaledAdd(idxReg, scale)` owns the single scaling rule. A power of two with `sh <= 4` keeps `ADD X16,X16,Widx,UXTW #sh`; every other scale takes `UMADDL` with an explicit 32-bit multiplier emitted by MOVZ/MOVK. `emitElemIndex` (element size) and `emitElemStride` (outer row stride) both delegate to it. `elemShiftOf`'s comment now records that the ASR path (pointer difference) has no imm3 limit, while the UXTW path does. |

The old F-02 code put `sh` into `imm3` (3 bits) and `option` (bits 15–13):
`sh = 5..7` are reserved encodings (SIGILL under qemu), and `sh >= 8` carries
into `option`, turning UXTW into LSL/UXTX so the scale silently disappears. The
non-power-of-two `UMADDL` branch was already correct, which is why the defect
only hit power-of-two scales at or above 2^5. F-01's window was equally narrow:
seven scalars already in x0–x6, then a 9–16-byte aggregate (`need = 2`) at
slot 8, then more scalars.

## 3. Field evidence: the audit probes flip, the controls do not

All probes come from `tests/audit-evidence/v0.23.72-dev/` and were rebuilt with
this round's `./aster`. Read-back checks use a conditional return — an exit
status keeps only its low 8 bits, so `1041 & 0xff == 17` would mask the answer.

| Probe | v0.23.72-dev | v0.23.73-dev | Meaning |
| --- | --- | --- | --- |
| `F01_stack_arg_lost` | `EXIT=0` | **`EXIT=60`** | the eighth argument is now written |
| `F01_ctl_8_scalars` | `88` | `88` | control: all in x0–x7 |
| `F01_ctl_agg_in_x6x7` | `60` | `60` | control: aggregate fits in registers |
| `F01_ctl_9th_on_stack` | `9` | `9` | control: pure stack argument |
| `F02_stride_sh5` | `132` (SIGILL) | **`0`** | reserved `UXTW #5` replaced by `umaddl` |
| `F02_stride_sh8` | `1` | **`0`** | `LSL #0` scaling lost → exact `umaddl` |
| `F02_stride_sh10` | `1` | **`0`** | `LSL #2` scaling lost → exact `umaddl` |
| `F02_struct32` | `132` | **`0`** | `emitElemIndex` now scales 32-byte elements |
| `F02_ctl_sh4` | `0` | `0` | control: `uxtw #4` still legal |
| `F02_ctl_nonpow2` | `0` | `0` | control: `UMADDL` path unchanged |

`aarch64-linux-gnu-objdump -d` confirms the mechanism: the 2^5 probe now
contains `umaddl x16, w2, w1, x16`, while the 2^4 control still contains
`add x16, x16, w1, uxtw #4`. The `aggOnStack` call site in
`examples/stack_arg_abi.ast` reserves `sub sp, sp, #0x20` and stores the
12-byte aggregate at `[sp,#0..15]` plus the two following scalars at
`[sp,#16]` and `[sp,#24]`.

**The strongest ABI witness is cross-language.** A `struct {int a,b,c;}`
callee with ten parameters was compiled by `aarch64-linux-gnu-gcc`, its empty
housekeeping sections stripped with `objcopy`, and then linked by Aster's
`link-obj` against an Aster caller that declares it `extern fn`. The resulting
image returns the C callee's own expected value. A second exported function
with nine scalar arguments agrees as well, and a pure-C oracle independently
confirms the expected 1041. This checks Aster's caller layout against the real
AAPCS64 contract, not just against Aster's own callee.

## 4. Two new 9-layer resident suites

Both are registered in `DEFAULT_SUITES` and `CRITICAL`, and both pin their
three frozen baseline rows plus the "no inherited row moved" invariant.

`tests/stack-arg-abi-checks.sh`:
1. strict `-Werror` build and version guard; 2. four source guards on both
edits; 3. static disassembly of the 32-byte outgoing area and its three
stores; 4. a seven-case behavioural matrix (8/12/16-byte aggregates at every
position, two aggregates, 16 scalars, a nested call) plus the shipped example;
5. the gcc callee / `link-obj` cross-language call and a pure-C oracle;
6. `link-obj` across two Aster objects, `build-pie`, `build-so`; 7. coverage
census; 8. six mutations; 9. byte baseline.

`tests/stride-scale-checks.sh`:
1. strict build; 2. seven source guards (including that the old unconditional
fold is absent); 3. an instruction-encoding sweep over 2^0..2^12 and a
100000-byte row, decoding every `ADD (extended register)` word to assert
`option == UXTW` and `imm3 <= 4` with no `undefined` or `uxtx`; 4. 17
behavioural cases with variable indexes; 5. a gcc twin over six witnesses;
6. five addressing paths (local, global, struct field, array parameter, typed
pointer, 3-D chain); 7. coverage census; 8. six mutations; 9. byte baseline.

**A mutation-hunting note worth keeping.** Three mutants initially survived
because a wrong scale used for *both* the write and the read agrees with itself:
`pow2 = true` on a stride-7 row, a dropped MOVK on a 100000-byte row, and the
non-power-of-two case. The probes were made asymmetric (they now also read a
neighbouring element a wrong scale would corrupt), and `mut_check` additionally
asserts the emitted `umaddl` / `movk` directly. All **12 mutations** in the two
suites are now caught; `mutation-score-checks.sh` reports **34 suites declaring
212 mutant builds, 212/212 caught (100%)**.

## 5. Zero byte drift

| Check | Result |
| --- | --- |
| `tests/baseline/v0.23.72-dev/example-hashes.txt` | 378 rows |
| `tests/baseline/v0.23.73-dev/example-hashes.txt` | **384 rows** |
| Inherited rows that moved | **0** (independently recomputed: 129 examples × 3 modes, minus the usual 3 `address_of_abi` rows) |
| New rows | 6 — `stack_arg_abi.*` and `stride_scale.*` × `build-so` / `build-elf` / `build-obj --pic` |
| Expected `FAILED` rows | 58, unchanged |
| `tests/alias-const-checks.sh` full baseline assertion | realigned 378 → 384 |
| `tests/embed-align-checks.sh` previous-baseline assertion | stays 378 (PREV resolves to v0.23.72-dev) |

`AUDIT-v0.23.72-dev.md` §8 predicted that repairing these paths might move a
few existing examples. No example in the corpus uses a spilled eighth aggregate
or a stride at/above 2^5, so the drift range turned out to be exactly zero.
Both new suites assert this at layer 9.

## 6. Version and documentation landing

| Item | Change |
| --- | --- |
| `src/aster.cpp` | version macro `0.23.72-dev → 0.23.73-dev`; the two F-01 edits, `emitScaledAdd`, and the two delegating callers |
| `CMakeLists.txt` | `0.23.72 → 0.23.73` |
| `README.md` | title + the v0.23.73-dev summary paragraph |
| `VERSION_HISTORY.md` | new top entry for v0.23.73-dev |
| `FEATURE_STATUS.md` | status line → v0.23.73-dev; two new shipped rows (C.12 stack arguments, exact scaling) |
| `ARCHITECTURE.md`, `docs/language-reference.md`, `ROADMAP.md` | status lines → v0.23.73-dev |
| `ROADMAP.md` | new **shipped** version row |
| `AUDIT-v0.23.72-dev.md` | top note: F-01/F-02 fixed in v0.23.73-dev, the other 11 defects and 7 meta-findings remain open; §8's first route row marked landed. The original findings are preserved, not rewritten. |
| `tests/ci.sh` | `DEFAULT_SUITES` 128 → **130**, `CRITICAL` 19 → **21** |
| Version guards | 13 suites × 2 lines `0.23.72-dev → 0.23.73-dev` (26 lines) |
| Baseline row-count assertions | 13 suites' pre-existing row count `297 → 303` (the 2 new examples × 3 modes are not in their FILTER); `alias-const-checks.sh` and `elf-metadata-checks.sh` current-baseline assertions `378 → 384`. The three `prev_rows = 378` assertions stay: PREV resolves to v0.23.72-dev. |
| `examples/` | 127 → **129** (`stack_arg_abi.ast`, `stride_scale.ast`) |
| `VALIDATION-v0.23.73-dev.md` | new — this file |

## 7. Gate

```
LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc CI_JOBS=3 bash tests/ci.sh
```

`CI_JOBS=3` is the memory-safe parallelism for this container's 8 GiB cgroup
limit (a single strict build peaks near 610 MiB; `CI_JOBS=24` OOM-killed
several `cc1plus` processes).

| Gate | Result |
| --- | --- |
| `tests/version-checks.sh` | 15/15 PASS |
| `tests/ci-protocol-checks.sh` | 33 checks PASS — coverage ratchet 130 suites / 129 examples / 384 baseline rows / 44 mutation suites / no orphans |
| `tests/mutation-score-checks.sh` | 34 suites, 212 mutants, 100% caught |
| `tests/stack-arg-abi-checks.sh` (standalone) | 9/9 layers PASS |
| `tests/stride-scale-checks.sh` (standalone) | 9/9 layers PASS |
| Full CI | **`130 passed, 0 skipped, 0 failed` / `APK GATES: 3 passed, 0 skipped, 0 failed`** (`CI_EXIT=0`) |

**Three full runs, all recorded.** The first was stopped after three suites
when a pre-flight sweep of hard-coded row counts found that adding two examples
changes more than suite registration: 13 suites assert a `297`-row
"pre-existing output" census whose FILTER does not know the new examples (it
becomes 303), and `elf-metadata-checks.sh` pins the *current* baseline at 378
instead of 384. Those are release-process realignments, not compiler changes;
the 52 + 1 assertions were corrected and the touchpoint suites re-run
standalone.

The second run went end to end and reported `128 passed, 2 failed`. Both
failures were stale *source pins* in resident suites, exposed by F-02 moving
element scaling into the new `emitScaledAdd` leaf — not compiler regressions,
and not a moved baseline byte. `array-elem-types-checks.sh` pinned the old
XZR/SP wording, and its m1/m2 mutants withdrew rules through `elemShiftOf`,
which now serves only the ASR pointer-difference path, so neither mutant
touched element scaling any more. `struct-array-field-checks.sh` pinned the
removed `movInt(sz,tySize(elem))` immediate in m5: the sed matched nothing,
exited 0, and left a "mutant" byte-identical to the real compiler. Both were
re-pinned to `emitScaledAdd` (m1/m2 force `scale=4` / `scale=1` there; m5
withdraws the element size at that call), and both `mutate()` helpers now
reject a sed script that changes nothing, so a stale pin fails loudly instead
of reporting a false "caught". Both suites re-ran standalone to 9/9 —
array-elem-types with 15/15 mutants caught, struct-array-field with 7/7 —
before the third run.

Nothing is hidden: the logs are `/tmp/ci_v02373.log` (stopped),
`/tmp/ci_v02373_run2.log` (128/2) and `/tmp/ci_v02373_final.log` (the green
gate above). The two failures were test bookkeeping against a changed source
shape; no shipped example and no baseline row moved.

## 8. What is still open

This round fixes exactly two of the 13 confirmed defects. Still open, on the
route in `AUDIT-v0.23.72-dev.md` §8:

| Version | Theme |
| --- | --- |
| v0.23.74-dev | Front-end semantics: F-03/F-04/F-05/F-06 + F-11 |
| v0.23.75-dev | Signedness: F-07 |
| v0.23.76-dev | ELF alignment contract: F-08/F-09/F-10/F-12 |
| later | Gate hardening G-01…G-07; dynamic evidence for S-01…S-07; F-13 as a design decision; K-01 needs a semantic ruling first |

The 7 gate meta-findings are untouched and still reproduce: a fully green CI
remains capable of hiding a zero-assertion suite, a skipped APK gate and a
static coverage floor. This round's two new suites are conventional resident
suites; they do not fix the gate. A later round owns that.
