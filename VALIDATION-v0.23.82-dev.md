# VALIDATION — v0.23.82-dev

**Theme:** the §6.3 round of the audit report (linker/DWARF/ABI hardening),
plus the post-gate re-pins and `resources.arsc` alignment,
`version-code`/`version-name` in `aster.proj`, the AsterUI submodule pointer
to v2.10, and a `DT_NEEDED` derivation fix for project-mode APKs that the
AsterUI migration caught. **This round changes compiler behaviour** in the
§6.3 items, the `resources.arsc` alignment, the `aster.proj` version fields,
and the `DT_NEEDED` derivation; the frozen snapshot moves on exactly five
`.build-so` rows, all five re-pinned deliberately (see §6).

The starting point is `e729840` (v0.23.79-dev, the audit base). The audit
report's §6.3 is the plan; this round is that plan, followed by the re-pin
round, the project version fields, the submodule pointer, and the
`DT_NEEDED` fix. §7a is the five-chunk full-CI run, §7b the re-pin rerun,
§7c the `DT_NEEDED` verification.

## 1. Strict build and version identity

```sh
g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o /tmp/aster-v82-strict
```

`BUILD_EXIT=0`, zero bytes of warnings; banner `Aster bootstrap compiler
v0.23.82-dev`; `#define ASTER_VERSION_STRING "0.23.82-dev"` in `src/aster.cpp`;
`project(aster_bootstrap VERSION 0.23.82 LANGUAGES CXX)` in `CMakeLists.txt`.
`aster doctor` reports `13 ok, 0 warnings, 0 failures`. `src/aster.cpp` is
17,066 lines. `tests/version-checks.sh` passes in full on the final tree
(banner, CMake version, README title, VERSION_HISTORY's newest heading, the
four opening status lines, the `ARCHITECTURE.md` line-count claim,
`VALIDATION-v0.23.82-dev.md`'s existence, plus the suite-count, line-count
band and mutation-census checks added by the §6.4 documentation round, which
is in the working tree on top of this version).

## 2. The changes, before and after

| Change | Before | After |
| --- | --- | --- |
| ELF-P2-1 | `writeSharedObject` wrote a function address as a plain value, so five example `.so` builds failed the baseline (their `build-so` rows recorded `FAILED`) | function addresses get GOT slots (`R_AARCH64_RELATIVE`); the five rows now build and their `dlopen` + `main()` agree with `build-elf` |
| ELF-P2-2 | `dynIndex` could hold the same name twice; the two classifiers had no guard against a symbol changing kind between translation units | `dynIndex` de-duplicated by name; both classifiers refuse a kind conflict |
| ELF-P2-3 | `buildSymbolTable` had no TLS branch, so a thread-local symbol was classified as an ordinary object | TLS symbols take the `STT_TLS` branch |
| ELF-P2-4 / S-11 | `writeElfBytes` did not check `.rodata` alignment, so a misaligned section could be written silently | a `.rodata` alignment invariant is enforced at write time |
| ELF-P2-5 / S-01 | `resolveRelocations` patched relocations without a bounds check at the loop top | an out-of-bounds patch is refused before it is applied |
| S-10 | DWARF short-form fields and an `exprloc` wraparound could corrupt a debug unit | both fixed; `llvm-dwarfdump --verify` stays clean |
| S-04 | `buildApk` did not check the ELF64 `PT_LOAD` layout of the library it packaged | an APK whose `.so` fails the `PT_LOAD` check is refused |
| D-01 root fix | the compact-frame incoming-base encoding topped out at a 12-bit immediate (4095), so a frame past that fell back to the 8 KiB layout | `emitIncomingBase` + `framePairX16`, a two-word `ADD`/`SUB` pair, bound 4095 → 8191 |
| `resources.arsc` | `buildApk` only page-aligned the `.so`, so `resources.arsc` landed at an unaligned offset (observed 11249, %4=1) and installs on other phones failed with -124 | the manifest and `resources.arsc` are aligned via extra fields (no raw gaps); `Verify` and `validate_apk.py` gain contiguity checks; a user installed the fixed v2.8.1 package with the system installer |
| `aster.proj` version | a project had no version identity; `aster build` always wrote version-code 1 / version-name "1.0" | `version-code` (1..2100000000) and `version-name` (non-empty) are parsed; `aster build` passes both to `buildApk`; `doctor` reports the version for APK projects |
| DT_NEEDED | `linkSharedObjects` took the passed-in `needed` list verbatim, so the project-mode `aster build` APK branch (which passes `{}`) produced a `.so` with 0 `DT_NEEDED` while its PLT/GOT stubs called `liblog`/`libandroid`/`libc`/`libm`; `validate_apk.py` [3b] refused the package (20 UND imports with no `DT_NEEDED`) | `linkSharedObjects` derives `DT_NEEDED` from the imports through `ndkLibraryFor` — the same derivation `buildSoFromSource` applies — preserving and de-duplicating user `--needed` entries; `link-so` is fixed by the same change. A project-mode APK importing `__android_log_print` now carries `liblog.so` and validates |
| Submodule | `stdlib/asterui` was registered at `ceebcad` while the AsterUI repo had moved on through v2.8–v2.10 | pointer registered at `225bccf` (v2.10: DEBUG overlay, delay API, variable-height virtual list + Badge) |

The suspected i64 live-temp `STR W` truncation was verified not to exist
(`storeLocal`/`loadLocal` are dead code) and is not a change. The
`link-project-contract` suite's `filePage`/`initRefs`/`tlsAlign` rules from
v0.23.79-dev are untouched.

## 3. Implementation

Six commits on `main` after `e729840`:

| Commit | Content |
| --- | --- |
| `1fcccf3` | Audit remediation and §6.3 linker/DWARF/ABI (59 files, +7033/−322): F1–F6, E-01/E-02, P1 batch, §6.2 P2, H-1–H-4, §6.3 items, gate hardening, governance (SECURITY, CONTRIBUTING, GitHub CI, issue/PR templates, Apache-2.0 LICENSE) |
| `7841360` | Post-§6.3 re-pins, tar-race tolerance, and `resources.arsc` alignment (8 files, +284/−57) |
| `5eab7b7` | `version-code` / `version-name` in `aster.proj` (2 files, +56/−3) |
| `166821b` | AsterUI submodule pointer to v2.10 (`225bccf`) |
| `a53ca33` | Version bump to v0.23.82-dev (26 files, +418/−25, including the new 393-row snapshot) |
| `449ad2a` | `DT_NEEDED` derivation in `linkSharedObjects` (2 files, +32, including the `project-checks.sh` [13/19] regression) |

The version bump itself moves only the version identity: `ASTER_VERSION_STRING`,
the CMake project version, the README title, the `language-reference.md`
"Applies to" line, and the 21 hard version guards. The version string reaches
no ordinary product output (it appears in the stdout banner, the build-cache
`.meta` `version` line, the APK manifest `Created-By`, and the `-g` DWARF
producer only), so the 393-row snapshot copies byte-identical from
v0.23.79-dev.

## 4. The gate, in five chunks

The full gate (153 suites) was run in five chunks on the §6.3 tree
(`1fcccf3`, binary md5 `89859420…`), because a single `ci.sh` run takes
about three hours at `CI_JOBS=2` on this 7.7 GiB box. The chunks are
C1=38, C2=31, C3=25, C4=18, C5=41 suites, no repeats. Logs:
`~/workspace/full-ci-s63-chunk{1..5}.log`. Each chunk runs its own APK gate
(3/3), so the APK gates total 15/15.

The first-run totals are 141 passed and 12 failed — and the 12 are accounted
for, not waived: 9 are C1's stale-baseline rows (re-verified 9/9 in §7b), 2
are C3's `tar` races (rc=125, re-run 2/2), 1 is C5's `ui-checks.sh`
isolation-layout failure (passes in the `~/workspace/ui-gate/` scratch
layout, which is the documented way to run that suite). No
`CI_ALLOW_MISSING=1`, no `CI_SKIP_APK_GATE=1`.

## 5. DT_NEEDED verification (post-gate fix, this round)

The fix (`449ad2a`) was verified on the final tree, each suite run by hand
against the strict-built binary:

| Suite | Result |
| --- | --- |
| `tests/project-checks.sh` | rc=0 PASS (19 layers, including the new [13/19] NDK regression: a project-mode APK importing `__android_log_print` must validate) |
| `tests/linker-checks.sh` | rc=0 PASS |
| `tests/e2e-so-import.sh` (`HOSTCC=aarch64-linux-gnu-gcc`) | rc=0 PASS (18 `dlopen`/`dlsym` checks; cross-`.so` imports work for both the direct `build-so` and the PIC ET_REL → `link-so` paths) |
| `tests/so-dyn-checks.sh` | **rc=1 FAIL** — see below |

The A/B probe for the fix: a minimal project importing only
`__android_log_print`, built with the old compiler (`./aster` before the
fix) gives a `.so` with 0 `DT_NEEDED`; built with the new compiler it
carries `liblog.so` (plus `SONAME`), and `validate_apk.py` reports ALL
CHECKS PASSED.

**The `so-dyn` finding (open, not waived).** `so-dyn-checks.sh` pins the
`link-so` output `tmp-dyn-import-linked.so` to exactly
`['libdyn.so']` (line 228), but the derivation now emits
`['libdyn.so', 'libc.so']` — `ndkLibraryFor` falls through to `libc.so`
for the non-NDK imports (`add`, `mul`, `counter`). A/B on the same object:
the pre-fix binary (`~/workspace/projects/Aster-env/aster`, md5
`8a632a5a…`, v0.23.79-dev) links 1 `DT_NEEDED` (`libdyn.so`); the fixed
binary (`./aster`, md5 `0b04ed66…`, v0.23.82-dev) links 2 (`libdyn.so`,
`libc.so`). The cross-`.so` imports still load and run (`e2e-so-import`
PASS above), so this is a structural-pin mismatch, not a loading failure —
and it matches what `build-so` already does for the same imports (pinned
at line 199 as `['libdyn.so', 'libc.so']`, "plus auto libc.so fallback").
The decision — re-pin line 228 to `['libdyn.so', 'libc.so']`, or refine the
derivation so `link-so` does not add `libc.so` for symbols another user
`.so` provides — is pending; nothing here was changed to hide it.

## 6. Byte baseline: five rows moved, the rest identical

No shipped example sets `page-size` in `aster.proj`, declares a TLS
`@align` above the default, or imports an NDK symbol, so the only rows that
move are the five `.build-so` rows ELF-P2-1 fixed. Each was re-recorded
deliberately after verifying its `dlopen` + `main()` agrees with its
`build-elf`:

```text
call-stmt.build-so  11d3cfb7735d5c5b376b7482417ebc5ad3067a269e4b8b49562020c0a0bc12bb
cb_table.build-so   947716730eaf3014ab884fbdcce82bd5a2971c2806fb5e3ba50f71568ecac75b
fn_ret.build-so     05691e3f04c928d5915e22959cd912179f01360eec2c72128931872c8dde5e30
fn_type.build-so    9d132d4000748afdb398527125e1be7c1cc5a71a16ddc8e53d9bacfa51d33b11
type_alias.build-so 4adaa01f6ab0c318cda73de27ccd23cbc6c19c313a47a4841ee67900dca90b32
```

```text
tests/baseline/v0.23.79-dev/example-hashes.txt  393 rows
tests/baseline/v0.23.82-dev/example-hashes.txt  393 rows, cmp -s identical
  to v0.23.79-dev as it stands after the re-pins (7841360)
```

A note for the next re-pin: the gate stops at the first mismatching row,
so the number of rows it reports is a lower bound, not the full set — the
first report said two rows, the full reproduction found five. And a `.so`
hash reproduces only when the output file is named with the baseline key
itself (the basename lands in the FILE symbol).

## 7. Gate results

### 7a. Full CI, five chunks

```sh
LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc CI_JOBS=2 bash tests/ci.sh   # per chunk
```

```text
chunk 1: CI SUMMARY: 29 passed, 0 skipped, 9 failed (of 38 suites)   APK GATES: 3/3
chunk 2: CI SUMMARY: 31 passed, 0 skipped, 0 failed (of 31 suites)   APK GATES: 3/3
chunk 3: CI SUMMARY: 23 passed, 0 skipped, 2 failed (of 25 suites)   APK GATES: 3/3
chunk 4: CI SUMMARY: 18 passed, 0 skipped, 0 failed (of 18 suites)   APK GATES: 3/3
chunk 5: CI SUMMARY: 40 passed, 0 skipped, 1 failed (of 41 suites)   APK GATES: 3/3
```

The 9 chunk-1 failures are the stale-baseline suites (`struct`,
`layout-boundary`, `elf-metadata`, `alias-const`, `section-align-contract`,
`frame-slot-contract`, `link-project-contract`, `condition`, `null-ptr` —
each failing on a `cb_table.build-so FAILED` / `call-stmt.build-so
baseline moved` line). The 2 chunk-3 failures are `tar` races (rc=125,
`full-ci-s63-chunk3-rerun.log`: 2 passed, 0 failed). The 1 chunk-5 failure
is `ui-checks.sh` under `ci.sh`'s isolation layout, which cannot run that
suite; it passes in `~/workspace/ui-gate/` (`ui-checks-s63.log`).
Effective total after the three follow-ups: **153/153, APK gates 15/15**.

### 7b. Re-pin rerun, standalone

```sh
bash tests/ci.sh   # the 9 chunk-1 suites, after 7841360
```

```text
CI SUMMARY: 9 passed, 0 skipped, 0 failed (of 9 suites)
APK GATES : 3 passed, 0 skipped, 0 failed
```

Log: `~/workspace/full-ci-repin.log`. The rerun also re-pinned
`frame-slot-contract` to the D-01 two-word encoding (8191 bound guards,
`0x914007f0` accepted by the oracle) and the `elf-metadata` mutation to
neuter both `need=4/8` guards.

### 7c. DT_NEEDED suites, standalone

`project-checks.sh` rc=0, `linker-checks.sh` rc=0,
`e2e-so-import.sh` (`HOSTCC=aarch64-linux-gnu-gcc`) rc=0 — see §5 for the
detail, including the open `so-dyn-checks.sh` failure.

## 8. File inventory

| Batch | Files |
| --- | --- |
| §6.3 + audit remediation | `src/aster.cpp`, `tests/ci.sh`, `tests/validate_apk.py`, `tests/bounds-mutate.py` (new), `tests/resolve-reloc-harness.cpp` (new), `tests/proj-meta-mutate.py`, `tests/apk-semantic-mutate.py`, `SECURITY.md` (new), `CONTRIBUTING.md` (new), `.github/workflows/ci.yml` (new), `LICENSE` (new), issue/PR templates (new), and the affected suites (59 files, +7033/−322) |
| re-pins + arsc | `src/aster.cpp`, `tests/ci.sh`, `tests/validate_apk.py`, `tests/apk-checks.sh`, `tests/frame-slot-contract-checks.sh`, `tests/elf-metadata-checks.sh`, `tests/link-project-contract-checks.sh`, `tests/baseline/v0.23.79-dev/example-hashes.txt` (5 rows) |
| project version fields | `src/aster.cpp`, `tests/project-checks.sh` |
| submodule pointer | `stdlib/asterui` (gitlink `ceebcad` → `225bccf`) |
| version bump | `src/aster.cpp`, `CMakeLists.txt`, `README.md`, `docs/language-reference.md`, 21 suite version guards, `tests/baseline/v0.23.82-dev/example-hashes.txt` (new) |
| DT_NEEDED | `src/aster.cpp`, `tests/project-checks.sh` |
| docs (this round) | `VERSION_HISTORY.md`, `VALIDATION-v0.23.82-dev.md` (this file), `ROADMAP.md`, `ARCHITECTURE.md`, `FEATURE_STATUS.md` |

Not committed, by design: `AUDIT-v0.23.79-dev.md` (the external fifth-round
audit, not our change) and the legacy `asterui/` tree (superseded by the
submodule, kept locally only).

## 9. Still open

- **`so-dyn-checks.sh` fails on the final tree** (see §5): `link-so` now
  emits `['libdyn.so', 'libc.so']` where the suite pins `['libdyn.so']`.
  The fix is either a one-line re-pin or a derivation refinement; it is
  recorded here rather than silently adjusted.
- ELF-P2-6 (multi-dimensional subscript chains, `regs[8]`/`dims[8]`) and
  S-09 (FDE remap fork) were out of §6.3 scope and are still open.
- K-01 (Typed IR: unify Sema `typeOf` with Codegen `exprType`, remove the
  `semaTypeIsPlaceholder` exemptions) and the single-file split remain
  architectural work, queued for §6.4/§6.5; `ROADMAP.md` is the tracker.
- The frozen snapshot still has no row exercising `page-size`, a strict TLS
  `@align`, or an NDK import; the resident suites (`project-checks`,
  `link-project-contract`, `so-dyn`) are the nails, which is a deliberate
  trade-off recorded here rather than a claim that the baseline now covers
  them.
