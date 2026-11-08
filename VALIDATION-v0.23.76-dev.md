# VALIDATION — v0.23.76-dev

**Theme:** F-08 / F-09 / F-10 / F-12 — the ELF section-alignment contract.
One rule: a section's declared `sh_addralign` is a promise its `sh_addr` keeps.

This report records what was actually run. §7a is the completed full-CI run.

## 1. Strict build and version identity

```sh
g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o ./aster
```

`BUILD_EXIT=0`, banner `Aster bootstrap compiler v0.23.76-dev`,
`ASTER_VERSION_STRING "0.23.76-dev"` at `src/aster.cpp:91`,
`project(aster_bootstrap VERSION 0.23.76 LANGUAGES CXX)` in `CMakeLists.txt`,
`src/aster.cpp` 13,938 lines.

## 2. Five defects reproduced, then repaired

The four audit findings were re-reproduced against the shipped v0.23.75-dev
binary with `tests/audit-evidence/v0.23.72-dev/bump_align.py`, which rewrites
an ELF64 section header's `sh_addralign` in place. A link then consumes that
object; nothing in an `.ast` source can express a stricter declared alignment,
which is why no shipped example ever caught these.

| Id | Before (v0.23.75-dev) | After (v0.23.76-dev) |
| --- | --- | --- |
| F-08 | `.tdata/.tbss=32` → `.tbss Addr=0x402050`, `0x50 % 32 = 16` while `Align=32` | `.tbss Addr=0x402060`, `0x60 % 32 = 0`; `PT_TLS p_align=0x20`; program returns 17 |
| F-09 | `.data=8192` → `.data Addr=0x403000`, `% 8192 = 4096` while `Align=8192` | `.data Addr=0x404000`, `% 8192 = 0`; program returns 7 |
| F-10 | `link-so` with `.tdata/.tbss=32` → `PT_TLS p_align=0x10`, output identical to the 16-aligned build | `p_align=0x20`, `.tdata/.tbss` headers declare 32, and the 16 vs 32 builds differ |
| F-12 | `addralign=0` → `aster: error: ...: unsupported .tdata section attributes` (while `.rodata=0` was accepted) | accepted; `.tdata`/`.tbss` normalise to 16, `.data`/`.bss` to 4, `.rodata` stays 1 |
| adjacent | ↑ with TLS alignment 4096+, `link-obj` output ran past the PT_LOAD and took SIGSEGV (before: 17, after the alignment fix alone: 139) | the 16..16384 spectrum returns 17 at every step |

The fifth row is an adjacent defect the spectrum exposed. `linkObjects`
resolved kind-5 symbols as `tbssVaddr + off` where `off` already contained the
`.tbss` block base, so the base was counted twice. At a 16-byte block the
doubled offset landed in zero padding and merely *looked* correct; once
F-08 made the start 4096-aligned, the TLS load ran past the RW PT_LOAD. The
fix drops the extra base in `linkObjects` but keeps it in
`linkSharedObjects`, whose writer resolves TLS offsets as `tlsVaddr + off` —
`tls-checks.sh`'s TPREL64 addend assertion (0 / 4 / 8 / 0x10 / 0x14) is what
caught a first attempt that removed both.

## 3. Implementation

| Point | Change |
| --- | --- |
| `writeElfBytes` | `dataStartAlign = max(pageSize, dataAlign, bssAlign, tlsAlign)` for the data PT_LOAD start; `tbssFileOff = alignUp(tlsFileEnd, tlsAlign)` |
| `linkObjects` | same `dataStartAlign` from the merged maxima; `tbssVaddr = alignUp(tlsVaddr+mergedTls.size(), maxTlsAlign)`; kind-5 offsets no longer add the block base a second time |
| `SoDynSpec` | new `uint64_t tlsAlign = kTlsBlockAlign` |
| `linkSharedObjects` | `spec.tlsAlign = maxTlsAlign` |
| `writeSharedObjectDyn` | `tdataVaddr`/`tbssVaddr` align to `spec.tlsAlign`; `ptls.align = spec.tlsAlign`; both TLS `setSh` calls declare `spec.tlsAlign` |
| `parseObject` | `sectionAlignOrMinimum(a,minimum)` normalises 0 to 16 (`.tdata`/`.tbss`) or 4 (`.data`/`.bss`); `.rodata` keeps its existing 1 |

`validSectionAlign` itself is unchanged: non-powers-of-two, values below the
section minimum and values above 65536 are still refused. The merge loop in
`linkSharedObjects` still adds the `.tbss` base once, because its writer needs
offsets relative to `tlsVaddr`.

## 4. The 9-layer resident suite

`tests/section-align-contract-checks.sh`, registered in `DEFAULT_SUITES` and
`CRITICAL`. It is self-contained: it writes its own `.ast` corpus and its own
ELF section-header surgery tool into its work directory, so CI does not depend
on the read-only audit evidence directory.

| Layer | Content |
| --- | --- |
| 1 | strict build + version guard |
| 2 | 19 source guards (two `dataStartAlign` sites, both `.tbss` starts, the normaliser, `SoDynSpec.tlsAlign`, four writer sites, both linker `.tbss` bases; absence of the old fixed-16/page-only code) |
| 3 | eight refusal diagnostics: `.tdata`/`.tbss`/`.data`/`.bss` at 2, 3, 5 and 131072, each with the exact `unsupported .<sec> section attributes` message |
| 4 | behavioural matrix: 10 TLS alignments (16..16384), 7 `.data` alignments (4..65536), five zero-alignment normalisations, 5 `link-so` alignments; every case asserts `Addr % Align == 0` and runs to 17 / 7 |
| 5 | independent ELF64 binary parser (struct-unpacks Ehdr/Phdr/Shdr/Sym directly) cross-checked against GNU `readelf -SW/-lW` on four representative outputs |
| 6 | four writers (`build-elf`, `build-pie`, `build-so`, `build-obj`) and two links (`link-pie`, `link-obj`), with `readelf -h` type assertions and execution |
| 7 | coverage census: 71 invariants |
| 8 | six mutations, **6/6 caught** |
| 9 | byte baseline |

The suite asserts `Addr % Align == 0` through an independent parser, not just
by reading back the writer's own output with the writer's own assumptions.

## 5. Older suites realigned

- 18 version guards `0.23.75-dev → 0.23.76-dev`.
- Six `prev_rows` assertions `390 → 393` (the previous baseline is now the
  393-row v0.23.75-dev file).
- One stale source pin in `elf-metadata-checks.sh`: the `.so .tbss` `setSh`
  guard now follows `spec.tlsAlign`.
- `tls-checks.sh`, `embed-align-checks.sh` and all row-count assertions are
  unchanged — the example count did not change and the zero drift holds.

## 6. Byte baseline: exact drift range

An A/B over **132 examples × 3 writer modes** with the committed v0.23.75-dev
compiler and the v0.23.76-dev compiler found **zero moved rows** and no new
`FAILED` rows. The frozen v0.23.75-dev baseline and the new
`tests/baseline/v0.23.76-dev/example-hashes.txt` are byte-identical.

| Measure | Value |
| --- | --- |
| v0.23.75-dev rows | 393 |
| Inherited rows whose hash changed | **0** |
| New rows | 0 |
| v0.23.76-dev rows | **393** |

No new shipped example was added. These defects only appear when a *link*
consumes an object whose section headers declare a stricter alignment; an
`.ast` source cannot produce such an object, so adding an example would pin
nothing. The resident suite's constructed-input cases are the evidence.

## 7. Gate results

| Gate | Result |
| --- | --- |
| Strict build | `BUILD_EXIT=0` |
| `section-align-contract-checks.sh` | 9/9 PASS, 6/6 mutants caught, 71 invariants |
| `tls-checks.sh` | PASS (TPREL64 addends unchanged for the `build-so` path) |
| `version-checks.sh` | ALL PASSED |
| `ci-protocol-checks.sh` | 33 checks passed, 0 failed — 134 suites, 132 examples, 393 baseline rows, 48 mutation suites, no orphans |
| `mutation-score-checks.sh` | PASS — 38 suites declare 236 mutant builds, 236/236 caught (100%) |
| `coverage-checks.sh` | PASS — 84.92% of 7776 executable lines (floor 80%) |
| 26 high-risk existing suites, individually | 26/26 PASS, 0 failures (`ci-protocol`, `mutation-score`, `coverage`, `alias-const`, `const-fold-u64`, `front-sema`, `stack-arg-abi`, `stride-scale`, `signedness`, `elf-metadata`, `embed-align`, `tls`, `object`, `linker`, `array-address`, `type-strictness`, `bool`, `operator`, `wide-int`, `page-size`, `layout-boundary`, `char`, `union`, `void`, `literals`, `enum`) |
| Full CI (`LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc CI_JOBS=3 bash tests/ci.sh`) | **PASSED** — 134 passed, 0 skipped, 0 failed; APK 3 passed; `CI_EXIT=0` (§7a) |

### 7a. Full CI

One run, from a clean start, with

```sh
LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc CI_JOBS=3 bash tests/ci.sh
```

It finished in 1h02m53s with no restart and no fix-up:

```text
CI SUMMARY: 134 passed, 0 skipped, 0 failed (of 134 suites)
APK GATES : 3 passed, 0 skipped, 0 failed
CI_EXIT=0
```

The 134 suites are the 133 inherited from v0.23.75-dev plus the new
`section-align-contract-checks.sh`. All three APK gates (`native_render`,
`icon_text_demo`, `native_touch`) passed, no suite was skipped and no suite
failed. Before the run, the 26 high-risk existing suites were also verified
individually (§7): 26/26 passed.

The green gate covers exactly the tree that is committed: the strict build,
the 393-row frozen baseline, the realigned guards, the new 9-layer suite and
the shipped `./aster` binary were all in place before CI started, and no
worktree file was edited during the run. The log is `/tmp/ci_v02376.log`.

## 8. File inventory

| Path | Role |
| --- | --- |
| `src/aster.cpp` | version macro + `dataStartAlign`, `.tbss` start, `sectionAlignOrMinimum`, `SoDynSpec.tlsAlign`, four `writeSharedObjectDyn` sites, both linker `.tbss` bases |
| `CMakeLists.txt` | `VERSION 0.23.76` |
| `tests/section-align-contract-checks.sh` | 9-layer resident suite (self-contained corpus + ELF surgery + parser oracle) |
| `tests/ci.sh` | `DEFAULT_SUITES` + `CRITICAL` registration |
| `tests/baseline/v0.23.76-dev/example-hashes.txt` | 393-row frozen baseline, byte-identical to v0.23.75-dev |
| 25 existing test scripts | 18 version guards, six `prev_rows`, one stale pin |
| `README.md`, `VERSION_HISTORY.md`, `ROADMAP.md`, `FEATURE_STATUS.md`, `ARCHITECTURE.md`, `docs/language-reference.md`, `AUDIT-v0.23.72-dev.md` | docs |
| `VALIDATION-v0.23.76-dev.md` | this report |

## 9. Still open

Every code-level defect from the second full source audit is now closed. The
seven gate meta-findings (G-01…G-07), the dynamic observation items
(S-01/S-03…S-07), the `K-01` semantic decision and the `F-13` design decision
remain as recorded in `AUDIT-v0.23.72-dev.md` §8 / §9. In particular G-04's
coverage ratchet and G-06's mutation census are still grep-level evidence, and
the byte baseline still pins three writer modes rather than every contract —
which is exactly why this round's suite carries its own constructed inputs.
