# VALIDATION-v0.23.72-dev — the second full source audit

**Version:** `0.23.72-dev` · **Theme:** a read-only, full-source audit with
execution-backed verdicts · **Byte impact:** none — the compiler source is
v0.23.71-dev's `d5f073b9` except for the version constant.

This round adds no feature and fixes no defect. It re-runs the
`AUDIT-v0.23.61-dev.md` method against a compiler whose gate is fully green,
and reports what a green gate cannot see. The deliverable is a finding, not a
behaviour change: **13 confirmed defects (2 P0, 8 P1, 3 P2)** and **7
meta-findings about the gate itself**. All fixes are routed to later versions
so that each round keeps one coherent theme.

## 1. Strict build and the generated-table contract

| Check | Result |
| --- | --- |
| `g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp` | PASS (`BUILD_EXIT=0`) |
| `python3 bootstrap/gen_lexer_names.py --check` | PASS (83 tokens / 32 keywords, unchanged) |
| `python3 bootstrap/gen_parser_names.py --check` | PASS |
| Quoted version literal `"0.23.72-dev"` in `src/aster.cpp` | exactly 1 |
| `./aster --version` | `Aster bootstrap compiler v0.23.72-dev` |
| `CMakeLists.txt` project version | `0.23.72` |
| `src/aster.cpp` line count | 13778 (`ARCHITECTURE.md` claims `~13k`, within ±10%) |

No reserved word is added: 32 keywords, `tls` still contextual. The lexer name
table, `bootstrap/aster.ast`, the parser name table and `tests/lexer_names.h`
are untouched. The version literal has exactly one home in the source.

## 2. Scope and method

| Item | Value |
| --- | --- |
| `src/aster.cpp` | 13,778 lines |
| `bootstrap/aster.ast` | 5,475 lines |
| Resident suites in `DEFAULT_SUITES` | 128 |
| `examples/*.ast` | 127 |
| Frozen baseline rows | 378 |
| APK gates | 3 |

Five parallel **read-only** review routes (front end and semantics; codegen and
the call ABI; ELF writers and the linker; DWARF, APK and periphery; gate
effectiveness and the self-hosting chain) returned 30 candidates — 20 marked
"confirmed", 10 "to be measured". Route two's items 3 and 4 merged into one
root cause, giving 29 independent verdicts.

**Discipline.** A source-level inference was never counted as a defect. Every
candidate was compiled into a probe and run on `qemu-aarch64` with a control
group that takes the correct code path. Third-party oracles:
`aarch64-linux-gnu-gcc -static -O2` for C semantics,
`aarch64-linux-gnu-objdump -d` for the emitted encoding,
`aarch64-linux-gnu-readelf -SW/-lW` for ELF contracts, and `bump_align.py`
(rewriting the ELF64 `Shdr+48 sh_addralign` field) to reach the
external-object high-alignment path that Aster's own writers never declare.

**The eight-bit exit-code trap.** A process exit code keeps only its low 8
bits: `10852 & 0xff = 100` and `10752 & 0xff = 0` produced two false negatives
in the first probe round. Every "read back a value" check is therefore a
conditional return (`if (v == expected) { return 0; } return 1;`), never a
direct return of the value.

## 3. Verdicts

| # | Defect | Level |
| --- | --- | --- |
| F-01 | `layoutArgs` does not set `ngrn = 8` on spill, so the eighth argument is written by neither loop | **P0** |
| F-02 | `sh << 10` overflows imm3 / the option field: reserved encoding (SIGILL) or lost scaling | **P0** |
| F-03 | A `u64` global constant expression is refused under signed-`i64` overflow rules | P1 |
| F-04 | Tag-namespace collision is order-dependent; a struct silently shadows an alias | P1 |
| F-05 | `switch(enum)` does not range-check case values, so they are silently truncated | P1 |
| F-06 | An overflowing constant skips the compile-time bounds check and wraps to the array's start | P1 |
| F-07 | Wide compare/divide/modulo pick the condition code from "either operand is unsigned" | P1 |
| F-08 | `.tbss` starts at fixed 16-byte alignment while declaring `maxTlsAlign` | P1 |
| F-09 | `.data`/`.bss` start only `pageSize`-aligned while declaring a larger alignment | P1 |
| F-10 | `link-so`'s `maxTlsAlign` is dead; `PT_TLS p_align` is always 16 | P1 |
| F-11 | `DerefAssign` does not type-check its right-hand side | P2 |
| F-12 | `parseObject` wrongly rejects legal `sh_addralign = 0` on TLS/data sections | P2 |
| F-13 | `@embed` has no absolute-path / traversal / symlink constraint (threat-model dependent) | P2 |

Also recorded but **not** counted as defects: 6 static observations awaiting
dynamic reproduction (S-01, S-03…S-07), 2 items the reviewers themselves
marked unreachable (S-02, S-08), 1 refuted inference (X-01: `0x_a` is rejected
with `hexadecimal literal has no digits`, not accepted as `0xa`), and 1 known
structural debt (K-01, the `typeOf` / `exprType` divergence and the TypedIR
exemption list) carried forward from the previous audit.

### The two P0s, with their controls

| Probe | Result |
| --- | --- |
| F-01 `sum(1,…,7,T{10,20,30})` | `EXIT=0`; expected 60 — the aggregate is never written |
| 8 scalars | `EXIT=88` — correct, all in x0–x7 |
| 6 scalars + `T` in x6/x7 | `EXIT=60` — correct, aggregate not spilled |
| 9 scalars, 9th on stack | `EXIT=9` — correct, `ngrn` already 8 |
| F-02 stride 2^5 / 2^6 / 2^7 | `EXIT=132` (SIGILL), objdump `undefined` |
| F-02 stride 2^8 / 2^9 / 2^10 | `EXIT=1`; `0x6000/0x6400/0x6800` decode as `LSL/UXTX` |
| F-02 32-byte struct element | `EXIT=132` — `emitElemIndex` shares the bad encoding |
| stride 2^3 / 2^4 | `EXIT=0` — `UXTW #3/#4` are legal |
| non-power-of-two strides | `EXIT=0` — the `UMADDL` branch is correct |

`8b215610` decodes to `ADD X16,X16,W1,UXTW #5`; imm3 = 5 exceeds UXTW's 0–4.
`8 << 10 = 0x2000` carries into the option field, changing `0b010` (UXTW) to
`0b011` (LSL/UXTX). A C oracle settles the mixed-sign comparison and division
cases (F-07): `int64_t a = -5; uint32_t b = 3; return a < b;` exits 1, while
Aster's `i64` × `u32` case exits 0.

### Gate meta-findings (reproduced where marked)

| # | Finding | Evidence |
| --- | --- | --- |
| G-01 | A zero-assertion `exit 0` suite is classified `PASS` | reproduced: `zz_audit_probe.sh` → `1 passed, 0 skipped, 0 failed` |
| G-02 | `CI_SKIP_APK_GATE=1` skips all three gates and the verdict stays green | reproduced: `0 passed, 1 skipped, 0 failed` |
| G-03 | Three-way differential has no oracle for the "both reject" path | static |
| G-04 | Coverage ratchet is a static grep with a hard-coded floor (121/120/360/30) | static; 128/127/378/42 today |
| G-05 | Baseline pins only `build-so` / `build-elf` / `build-obj --pic`, and filters one example | static |
| G-06 | Some mutation layers use whole-file hash differences instead of invariants | static |
| G-07 | Parallel grouping keys on a literal `/tmp/` grep | static |

**Why they matter.** F-01 and F-02 need only a runtime argument and a variable
index; existing suites almost all use constant indexes and constant
right-hand sides. F-08/F-09/F-10 change no example's bytes at all, so 378
zero-drift rows are blind to them by construction. The throwaway suite used for
G-01/G-02 was deleted from the working tree after the experiment.

## 4. Evidence corpus (deliberately not a suite)

`tests/audit-evidence/v0.23.72-dev/` holds **34 files**: 30 `.ast` probes,
one C oracle (`F07_oracle.c`), one binary asset (`tiny.bin`), `EVIDENCE.md`,
and `bump_align.py`.

It is **not** registered in `tests/ci.sh`'s `DEFAULT_SUITES` and does not
appear in `tests/smoke.sh`. `tests/ci-protocol-checks.sh`'s orphan check only
enumerates `tests/*.sh`, so a subdirectory of `.ast`/`.c`/`.bin`/`.py`/`.md`
files cannot be mistaken for an orphan suite. More importantly, these programs
**intentionally retain the defects**: registering them as a suite would assert
that the bug is present. v0.23.73-dev onward converts them into real
regression suites.

`EVIDENCE.md` carries the per-probe command, measured exit status, control
result, objdump output, ELF section-header surgery commands, and the two
reproduced gate false-positives.

## 5. Zero byte drift

| Check | Result |
| --- | --- |
| `tests/baseline/v0.23.72-dev/example-hashes.txt` row count | 378 |
| `cmp` against `tests/baseline/v0.23.71-dev/example-hashes.txt` | byte-identical |
| Suite count / example count / APK gates | 128 / 127 / 3, unchanged |
| `CRITICAL` list | 19, unchanged |

Because the only source edit is the version macro, no emitted instruction or
section byte can move. The CI suites that recompute and compare all 378 rows
(`alias-const-checks.sh`, `elf-metadata-checks.sh` and the other
baseline-pinning suites) are the independent confirmation; §7 records their
green result.

## 6. Version and documentation landing

| Item | Change |
| --- | --- |
| `src/aster.cpp` | `ASTER_VERSION_STRING` `0.23.71-dev → 0.23.72-dev` (the only edit) |
| `CMakeLists.txt` | `0.23.71 → 0.23.72` |
| `README.md` | title + the v0.23.72-dev summary paragraph |
| `VERSION_HISTORY.md` | new top entry for v0.23.72-dev |
| `FEATURE_STATUS.md`, `ARCHITECTURE.md`, `docs/language-reference.md`, `ROADMAP.md` | status lines → v0.23.72-dev |
| `ROADMAP.md` | new shipped version row; the backlog row that still called the `ET_REL` branch "never executed" is corrected (closed in v0.23.71-dev) |
| `AUDIT-v0.23.61-dev.md` | top note: its original status line was a point-in-time summary; all its findings were closed across v0.23.62–v0.23.71 |
| `AUDIT-v0.23.72-dev.md` | new — the report |
| `VALIDATION-v0.23.72-dev.md` | new — this file |
| `tests/version-checks.sh` | unchanged; its four status-line guards now check `0.23.72-dev` implicitly |
| Version guards | 13 suites × 2 lines `0.23.71-dev → 0.23.72-dev` (the source pin and its failure message). Historical `v0.23.71-dev` comments in `embed-checks.sh`, `regression-symtab.sh` and `embed-align-checks.sh` are left alone. |
| Previous-baseline row count | `embed-align-checks.sh` derives `PREV` dynamically; with v0.23.72-dev added, that resolves to v0.23.71-dev's **378** rows, so its `375` assertion and label become `378`. The 13 filtered suites' `297` and the two full-baseline suites' `378` stay unchanged — this round adds no example and no row. |

`ARCHITECTURE.md`'s `~13k lines` claim is left alone: 13,778 is inside the
±10% window and the guard passes. Historical counts elsewhere (115/115 suites,
360 baseline rows, 24 suites / 155 mutants) describe older releases and are
deliberately left untouched.

## 7. Gate

`LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc CI_JOBS=3 bash tests/ci.sh`

```
CI SUMMARY: 128 passed, 0 skipped, 0 failed (of 128 suites)
APK GATES : 3 passed, 0 skipped, 0 failed
CI_EXIT=0
```

`CI_JOBS=3` is an isolation setting, not a different gate: `tests/ci.sh` still
runs all 128 suites and all three APK gates, each in its own copy of the tree.
The container's cgroup memory limit is 8 GiB and one strict build of
`src/aster.cpp` peaks at ~610 MiB, so 24-way parallelism overlapped enough
`cc1plus` processes to OOM-kill them; the 3-way run peaks at ~3.5 GiB.

`tests/version-checks.sh` (15 checks) and `tests/ci-protocol-checks.sh` (33
checks, coverage ratchet 128 suites / 127 examples / 378 baseline rows / 42
mutation suites / no orphans) are green.

**The first full run was stopped mid-way and is recorded rather than hidden.**
It reached 45 `PASS` rows before 12 suites had reported
`FAIL: the version constant is not 0.23.71-dev` (a 13th, `literals-checks.sh`,
carried the same stale guard but had not run yet): the version-landing batch
had bumped `src/aster.cpp` and `CMakeLists.txt` but the test-side guards had
not yet been realigned. A related second issue was found while auditing that
realignment: `embed-align-checks.sh` derives the previous release's baseline
dynamically, so with `tests/baseline/v0.23.72-dev/` present its `PREV` became
the 378-row v0.23.71-dev snapshot while the assertion still demanded 375.
Both are release-process fixes, not compiler changes: the 26 guard lines and
the one row-count assertion were corrected, four affected suites were re-run
standalone (all `PASS`, including the 378-row assertions), and the full gate
above is the second run.

**This green result is the field evidence for meta-findings 1 and 4.** All 13
defects in `AUDIT-v0.23.72-dev.md` are present in this exact build; a fully
green CI with 378 zero-drift rows did not detect a single one. That is the
finding the round exists to record — the fixes are deliberately deferred to
v0.23.73-dev onward so that this round stays a pure audit.

### Re-verification on the delivered binary

The two P0 probes were run once more against the strict-built
`./aster` that ships with this version (the same binary the gate uses), with
their control groups:

| Probe | Measured | Meaning |
| --- | --- | --- |
| `F01_stack_arg_lost` | `EXIT=0` | expected 60 — the eighth argument is still missing |
| `F01_ctl_8_scalars` | `EXIT=88` | control: correct |
| `F01_ctl_agg_in_x6x7` | `EXIT=60` | control: correct |
| `F01_ctl_9th_on_stack` | `EXIT=9` | control: correct |
| `F02_ctl_sh4` | `EXIT=0` | control: `UXTW #4` is legal |
| `F02_stride_sh5` | `EXIT=132` | SIGILL — reserved encoding |
| `F02_stride_sh8` | `EXIT=1` | scaling lost |
| `F02_ctl_nonpow2` | `EXIT=0` | control: `UMADDL` path is correct |
| `F02_struct32` | `EXIT=132` | SIGILL — `emitElemIndex` shares the defect |

So the audit's headline is not a claim about an older build: the delivered
compiler passes every gate and still miscompiles these programs.
