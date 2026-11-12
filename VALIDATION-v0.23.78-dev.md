# VALIDATION — v0.23.78-dev

**Theme:** give the three audit repairs that landed upstream on the `v0.23.77-dev`
line (D-01 / D-02 / D-09 of `AUDIT-v0.23.77-dev.md` §3) a numbered release and a
resident 9-layer gate. **This round changes no compiler behaviour.**

The starting point is `a235ed29814b050e9233095c11b96a4edc1b9ad2`, three commits
past the audited `6e7a148`: `e9bb50d` (bootstrap `char`), `f6dc30a` (the three
externally reproduced defects) and `a235ed2` (the touch-example comment). Those
commits fixed the defects but did not bump the version, register a resident
suite, add a high-slot `f64` assertion, or produce a validation report. This
round supplies exactly that. §7a is the completed full-CI run.

> `github.com:443` was unreachable from this sandbox, so the three remote
> commits were reconstructed locally through the GitHub Git Data API
> (blob → tree → commit, every SHA verified against the remote) before the
> worktree was reset. `HEAD == origin/main == a235ed2` was the clean baseline.

## 1. Strict build and version identity

```sh
g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o ./aster
```

`BUILD_EXIT=0`; banner `Aster bootstrap compiler v0.23.78-dev`;
`#define ASTER_VERSION_STRING "0.23.78-dev"` in `src/aster.cpp`;
`project(aster_bootstrap VERSION 0.23.78 LANGUAGES CXX)` in `CMakeLists.txt`.
`tests/version-checks.sh` passes (banner, CMake version, README title,
VERSION_HISTORY's newest heading, the four opening status lines, the
`ARCHITECTURE.md` line-count claim, and `VALIDATION-v0.23.78-dev.md`'s
existence).

## 2. What was already fixed upstream, and what was still missing

| Defect | Upstream repair (`f6dc30a`) | Gate before this round | Gate after this round |
| --- | --- | --- | --- |
| D-01 | `if(want<=4095u)` twice; an oversized compact frame keeps the default 8192 frame that `ADD X16, SP, #8192` already describes | 6 lines in `frame-size-checks.sh`, one `grep` of the bound | [2/9] both bounds pinned; [3/9] no overflowing `ADD X16,SP` word in any of 8 frames; [4/9] the full spectrum; [8/9] m4 |
| D-02 | `loadVarT`/`storeVarT` F64 imm12 is `slot`, not `slot*8` | no high-slot case anywhere; a caller-stack escape had no assertion | [2/9] both expressions pinned; [3/9] `strd` imm12 at slots 0/1/7/128 plus an `objdump` cross-check of `str d0,[sp,#1024]`; [4/9] caller sentinel; [8/9] m1–m3 |
| D-09 | `seenDot` / `seenExp` in the number loop, so `1.5.2` and `1e2e3` are refused | 5 lines in `float-literal-checks.sh` | [2/9] both guards pinned; [4/9] two refusals + four legal controls; [5/9] the C oracle also refuses both; [8/9] m5–m6 |

The decisive upstream behaviour was measured, not assumed: small compact frames
(pad ≤ 466) emit a legal unshifted `ADD X16,SP,#imm` with imm ≤ 4095 and lose
`0x91400bf0`; large compact frames (pad ≥ 467) keep `0x91400bf0` and get no
patch at all; all eight sizes return 8 in both layouts. The high-slot `f64`
store used to land at `[sp,#8192]` — one word past the 8 KiB frame, in the
caller's stack — and a caller sentinel returned 20 before and 0 after.

## 3. Implementation

**No compiler behaviour changed.** The `impl` batch is the version identity
only: `ASTER_VERSION_STRING` → `0.23.78-dev` and the CMake project version →
`0.23.78`. In particular no two-word `ADD X16` split was reintroduced; D-01
keeps the upstream fallback. 19 hard version guards were re-pinned,
`tests/ci.sh` registered the new suite in `DEFAULT_SUITES` **and** `CRITICAL`
(150 → 151 suites), and a byte-identical 393-row snapshot was copied into
`tests/baseline/v0.23.78-dev/`.

## 4. The 9-layer resident suite

`tests/frame-slot-contract-checks.sh`, registered in `CRITICAL` so a `rc=77`
skip cannot silently hide it (G-08).

| Layer | Content |
| --- | --- |
| 1 | Strict `-Werror` build and the `0.23.78-dev` version guard |
| 2 | Python source guards: both F64 immediates, no `(slot*8)` encoding, F32's factor of two preserved, exactly two `if(want<=4095u)` bounds, the `frameBytes` 8192 clamp, `seenDot`/`seenExp` |
| 3 | Static binary oracle: an independent Python ELF64 section-table reader decodes `.text` words with **no binutils** — `spadd`, `badspadd` (no shifted `ADD X16,SP` other than the legal `0x91400bf0`), `strd`/`ldrd`/`strs`/`ldrs`, `etype`; optional GNU `objdump` cross-check |
| 4 | Behavioural matrix: 8 compact frame sizes × compact/normal, `f64` slots 0/1/7/128 with f32/i32 controls and a caller sentinel, nine FP parameters, and the D-09 refusal/acceptance controls |
| 5 | C oracle built with `$HOSTCC` and run through `$RUNNER` (0 / 8), plus the C compiler's own refusal of `1.5.2` / `1e2e3` |
| 6 | `build-elf`, `build-pie`, `build-obj`, `build-obj --pic`, `build-so`, `link-obj`, `link-pie`, `link-so`, plus `-g` and `--bounds-check` |
| 7 | Coverage census: 59 invariants measured, floor 55 |
| 8 | **6/6 mutations caught** — both F64 scales, the f32 scale substituted, both `want<=4095u` bounds removed, the fractional-part guard removed, the exponent guard removed |
| 9 | Byte baseline: zero drift against the previous snapshot and all 393 rows reproduced |

Cross-host discipline: AArch64 ELFs go through `$RUNNER`, C oracles through
`$HOSTCC`, and the primary oracle is pure Python, so an x86_64+qemu box and a
native AArch64/Termux host assert exactly the same things. `link-pie` takes the
non-PIC object (a PIC object keeps its source-level `main` and defines no
`_start`); the PIC object is checked as `ET_REL` on its own and fed to `link-so`.

## 5. Older suites realigned

- 19 hard `grep -qF '#define ASTER_VERSION_STRING "0.23.77-dev"'` guards were
  re-pinned to `0.23.78-dev`; zero old guards remain.
- `tests/ci.sh`: 151 suites, no duplicates; the new suite is in both lists.
- `tests/ci-protocol-checks.sh` re-run: 151 suites, 132 examples, 393 baseline
  rows, 61 mutation suites, no orphans (33 checks passed, 0 failed).
- `tests/mutation-score-checks.sh` re-run: 40 suites declare 248 mutant builds
  (floors 24 suites / 150 mutants / 2 per suite), all caught; the new suite's
  six mutants and its `FAIL: mutation '...' went unnoticed` survivor assertion
  are both in the census.

## 6. Byte baseline: zero drift

No shipped example uses `--compact-frames`, and none uses `f64`/`f32`, so no
example was added and no frozen row was re-recorded.

```text
tests/baseline/v0.23.77-dev/example-hashes.txt  393 rows
tests/baseline/v0.23.78-dev/example-hashes.txt  393 rows, cmp -s identical
new suite [9/9]:  zero drift vs previous snapshot 393 rows; rows reproduced 393
```

## 7. Gate results

### 7a. Full CI

```sh
LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc CI_JOBS=3 bash tests/ci.sh
```

```text
CI SUMMARY: 151 passed, 0 skipped, 0 failed (of 151 suites)
APK GATES : 3 passed, 0 skipped, 0 failed
CI_EXIT=0
```

No `CI_ALLOW_MISSING=1`, no `CI_SKIP_APK_GATE=1`; `CI_JOBS=3` on the 8 GiB runner. The new `frame-slot-contract-checks.sh` is in `CRITICAL`, so its result cannot be a silent skip. Every one of the 151 suites ran against the final source and docs.

### 7b. Resident suite, standalone

```text
LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc RUNNER=tests/run-aarch64.sh \
    sh tests/frame-slot-contract-checks.sh
[1/9] … [9/9] — 8/8 frame sizes correct in both layouts, 7/7 f64 probes,
D-09 two refusals / four controls, C oracle 0/8 plus its own two refusals,
four writers + two links + two flags, 59 invariants, 6/6 mutations caught,
393 rows zero drift and 393 reproduced. PASS.
```

## 8. File inventory

| Batch | Files |
| --- | --- |
| impl | `src/aster.cpp` (version macro only), `CMakeLists.txt` |
| tests | `tests/frame-slot-contract-checks.sh` (new), `tests/ci.sh`, `tests/baseline/v0.23.78-dev/example-hashes.txt` (new), and 19 `tests/*-checks.sh` version guards |
| docs | `README.md`, `VERSION_HISTORY.md`, `FEATURE_STATUS.md`, `ROADMAP.md`, `ARCHITECTURE.md`, `docs/language-reference.md`, `AUDIT-v0.23.77-dev.md` (follow-up note), `VALIDATION-v0.23.78-dev.md` (this file) |

## 9. Still open

This round deliberately changes no compiler behaviour. The audit's other three
confirmed defects (D-03 `checkInitOrder`, D-04 dead `page-size`, D-05 SysV
`.tbss`), the three lower-severity observations, and all eight gate
meta-findings (G-01 … G-08) remain open and keep their queued themes in
`AUDIT-v0.23.77-dev.md` §7. The frozen snapshot still has no row that
exercises `--compact-frames` or `f64`; the new resident suite is the nail,
which is a deliberate trade-off recorded here rather than a claim that the
baseline now covers them.
