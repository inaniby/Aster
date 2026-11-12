# VALIDATION — v0.23.79-dev

**Theme:** close the link-and-project-config contract — the three audit defects
that v0.23.78-dev deliberately left open (D-03 `checkInitOrder`, D-04 dead
`page-size`, D-05 SysV `.tbss`). **This round changes compiler behaviour** by
fixing those three, but adds no shipped example and records no byte drift.

The starting point is `fa3b910cd14febc9e21d4e69ad9f3f042e7ad0ed`
(v0.23.78-dev, `HEAD == origin/main`). The audit queue (`AUDIT-v0.23.77-dev.md`
§7) assigns D-03 / D-04 / D-05 to one coherent theme; this round is that theme.
§7a is the completed full-CI run.

## 1. Strict build and version identity

```sh
g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o ./aster
```

`BUILD_EXIT=0`; banner `Aster bootstrap compiler v0.23.79-dev`;
`#define ASTER_VERSION_STRING "0.23.79-dev"` in `src/aster.cpp`;
`project(aster_bootstrap VERSION 0.23.79 LANGUAGES CXX)` in `CMakeLists.txt`.
`tests/version-checks.sh` passes (banner, CMake version, README title,
VERSION_HISTORY's newest heading, the four opening status lines, the
`ARCHITECTURE.md` line-count claim, and `VALIDATION-v0.23.79-dev.md`'s
existence).

## 2. The three defects, before and after

| Defect | Before (D-03/D-04/D-05) | After |
| --- | --- | --- |
| D-03 | `initRefs` collected the target *name* of every `R_AARCH64_ABS32` relocation, so an `extern fn` call's `CALL26` to an imported function — which writes no object state — was treated as a cross-object initializer read and `checkInitOrder` refused the link with "initializers must run in link order" | `initRefs` skips a relocation whose target is a function symbol (`.info & 0xf == STT_FUNC`) *and*, independently, a `CALL26`/`JUMP26` relocation; both `link-obj` and `link-so` mirrors carry the same filter; a genuine cross-object data read (`let x: i32 = imported();` where `imported` is a *data* global) is still refused (A-21 kept) |
| D-04 | `parseProjectFile` parsed `page-size`, range-checked it through `pageSizeOr`, stored it into the `Spec`, then `filePage` ignored `spec.pageSize` entirely (`const uint64_t filePage = ps;`) — a `16 KiB` project produced the same `PT_LOAD` alignment as the default `4 KiB` | `filePage` is `cliPageSet ? ps : (spec.pageSize ? spec.pageSize : ps)`, so an explicit project `page-size` reaches `pageSize` for all four writers; a CLI `--page-size` still wins; an out-of-range value is still refused by `pageSizeOr` |
| D-05 | the SysV `.so` writer set `.tbss` `sh_offset` to the end of `.tdata` (`sh_addr`-relative file offset) and hard-coded `ptls.align = 16`; `layoutObject` never promoted `tlsAlign` above 16, so a TLS global with `@align(64)` was laid out at 64 by the section table but described as 16 in the program header, and inconsistently between the two `.so` writers | `layoutObject` derives `L.tlsAlign = max(4, g->align)` over every TLS global; the SysV writer maps `.tbss` at `sh_offset == sh_addr` and forwards `L.tlsAlign` to `ptls.align`; the static and `build-so` header paths now read `tdataAlign`/`tbssAlign` back from the section table, so every writer agrees |

The decisive behaviour was measured, not assumed: a cross-object `extern fn`
call (helper defined in `b`, called from `a`) links in every object order after
the fix and was refused before; a `16 KiB` project's `PT_LOAD` alignment is
`0x4000` after and `0x1000` before; a TLS block with `@align(64)` reports
`sh_addralign = 64` and `PT_TLS p_align = 64` in all three writer paths after
and `16` before.

## 3. Implementation

Six source edits in `src/aster.cpp`:

1. `initRefs`: skip a function-symbol target (`s.info & 0xf == 2`) and a
   `CALL26`/`JUMP26` (`r.type == 283`/`282`) relocation — two independent
   filters, both at two call sites (the collector and the mirror).
2. `filePage`: `const uint64_t filePage = cliPageSet ? ps : (spec.pageSize ? spec.pageSize : ps);`
3. `layoutObject`: `for (...) L.tlsAlign = max(L.tlsAlign, max(g->align, 4));`
   over `tlsInit` and `tlsZero`.
4. SysV `.tbss`: `setSh(kTbssIdx, nTbss, 8, 0x1|0x2|0x400, tbssVaddr, tbssVaddr, tbssSize, 0, 0, tlsAlign, 0);` (off == addr).
5. SysV `PT_TLS`: `ptls.align = tlsAlign;`.
6. the static / `build-so` section headers now read `tdataAlign` / `tbssAlign`
   back from the parsed section table, so a high `@align` reaches the section
   header in every writer.

The `impl` batch also moves the version identity: `ASTER_VERSION_STRING` →
`0.23.79-dev`, CMake project version → `0.23.79`. 21 hard version guards were
re-pinned; `tests/ci.sh` registered the new suite in `DEFAULT_SUITES` **and**
`CRITICAL` (151 → 152 suites); a byte-identical 393-row snapshot was copied into
`tests/baseline/v0.23.79-dev/`.

## 4. The 9-layer resident suite

`tests/link-project-contract-checks.sh`, registered in `CRITICAL` so a `rc=77`
skip cannot silently hide it (G-08).

| Layer | Content |
| --- | --- |
| 1 | Strict `-Werror` build and the `0.23.79-dev` version guard |
| 2 | Python source guards: the two `initRefs` filters, the `filePage` derivation, the `L.tlsAlign` derivation (count == 3), the `.tbss` identity map, `ptls.align = tlsAlign` |
| 3 | Static binary oracle: an independent Python ELF64 section-table reader — `.tbss off == addr`, `sh_addralign` and `PT_TLS p_align` agree, across a 9-value TLS spectrum (16..16384) and both `.so` writers; no binutils as primary judge |
| 4 | Behavioural matrix: the D-03 order matrix (3 call orders + the data-read control), the D-04 project matrix (exe/apk/test, project `page-size` vs CLI priority), the D-05 writer matrix (default + high-align, both `.so` writers plus the static `build-elf`) |
| 5 | C oracle: GNU `ld`'s `.so` agrees on `PT_TLS p_align` with both section alignments; a `0x4000` `PT_LOAD` is produced for a `16 KiB` page-size project |
| 6 | `build-elf`, `build-pie`, `build-obj`, `build-so`, `link-obj`, `link-pie`, `link-so` plus `-g` / `--bounds-check` |
| 7 | Coverage census: 34 invariants measured, floor 30 |
| 8 | **6/6 mutations caught** — both D-03 filters removed, project `page-size` discarded, explicit `--page-size` dropped, `tlsAlign` no longer derived, `.tbss off != addr` restored, `PT_TLS p_align` hard-coded to 16 |
| 9 | Byte baseline: zero drift against the previous snapshot and all 393 rows reproduced |

Cross-host discipline: AArch64 ELFs go through `$RUNNER`, C oracles through
`$HOSTCC`, and the primary oracle is pure Python, so an x86_64+qemu box and a
native AArch64/Termux host assert exactly the same things.

## 5. Older suites realigned

- 21 hard `grep -qF '#define ASTER_VERSION_STRING "0.23.78-dev"'` guards were
  re-pinned to `0.23.79-dev`; zero old guards remain.
- `tests/ci.sh`: 152 suites, no duplicates; the new suite is in both lists.
- `tests/ci-protocol-checks.sh` re-run: 152 suites, 132 examples, 393 baseline
  rows, 61 mutation suites, no orphans.
- `tests/mutation-score-checks.sh` re-run: the new suite's six mutants and its
  `FAIL: mutation '...' went unnoticed` survivor assertion are both in the
  census; all declared mutants are caught.
- `linker-checks.sh` and `e2e-global-deep.sh` (the A-21 data-read refusal) were
  re-run as part of the full CI and stay green — the D-03 fix does not relax a
  genuine cross-object ordering refusal.

## 6. Byte baseline: zero drift

No shipped example sets `page-size` in `aster.proj`, and none declares a TLS
`@align` above the default, so no example was added and no frozen row was
re-recorded — the three fixes change only objects/projects that exercise those
inputs.

```text
tests/baseline/v0.23.78-dev/example-hashes.txt  393 rows
tests/baseline/v0.23.79-dev/example-hashes.txt  393 rows, cmp -s identical
new suite [9/9]:  zero drift vs previous snapshot 393 rows; rows reproduced 393
```

## 7. Gate results

### 7a. Full CI

```sh
LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc CI_JOBS=3 bash tests/ci.sh
```

```text
CI SUMMARY: 152 passed, 0 skipped, 0 failed (of 152 suites)
APK GATES : 3 passed, 0 skipped, 0 failed
CI_EXIT=0
```


No `CI_ALLOW_MISSING=1`, no `CI_SKIP_APK_GATE=1`; `CI_JOBS=3` on the 8 GiB
runner. The new `link-project-contract-checks.sh` is in `CRITICAL`, so its
result cannot be a silent skip. Every one of the 152 suites ran against the
final source and docs.

### 7b. Resident suite, standalone

```text
LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc RUNNER=tests/run-aarch64.sh \
    sh tests/link-project-contract-checks.sh
[1/9] … [9/9] — D-03 order matrix, D-04 project matrix, D-05 9-value TLS
spectrum across both writers, C oracle, 34 invariants, 6/6 mutations caught,
393 rows zero drift and 393 reproduced. PASS.
```

## 8. File inventory

| Batch | Files |
| --- | --- |
| impl | `src/aster.cpp` (six defect fixes + version macro), `CMakeLists.txt` |
| tests | `tests/link-project-contract-checks.sh` (new), `tests/ci.sh`, `tests/baseline/v0.23.79-dev/example-hashes.txt` (new), and 21 `tests/*-checks.sh` version guards |
| docs | `README.md`, `VERSION_HISTORY.md`, `FEATURE_STATUS.md`, `ROADMAP.md`, `ARCHITECTURE.md`, `docs/language-reference.md`, `AUDIT-v0.23.77-dev.md` (follow-up note), `VALIDATION-v0.23.79-dev.md` (this file) |

## 9. Still open

This round closes D-03 / D-04 / D-05 and the G-08 gate-meta item (the new suite
lives in `CRITICAL`). The audit's three lower-severity observations, and the
remaining gate meta-findings G-01…G-07, remain open and keep their queued themes
in `AUDIT-v0.23.77-dev.md` §7. The frozen snapshot still has no row that
exercises `page-size` or a strict TLS `@align`; the new resident suite is the
nail, which is a deliberate trade-off recorded here rather than a claim that the
baseline now covers them.
