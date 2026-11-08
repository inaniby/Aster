# VALIDATION-v0.23.74-dev — frontend semantics: four static rules + DerefAssign

**Version:** `0.23.74-dev` · **Theme:** F-03, F-04, F-05, F-06 + F-11 from
`AUDIT-v0.23.72-dev.md` §8 · **Translation unit:** `src/aster.cpp` (13897
lines, one C++17 file).

This round is deliberately narrow: five *static* rules that the compiler
applied to the wrong type, applied in the wrong declaration order, or skipped
entirely. No new syntax, no code-generation change, and — measured, not
asserted — no byte of any program written before this round moved.

---

## 1. Strict build and version identity

```sh
g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o ./aster
```

`BUILD_EXIT=0`. `ASTER_VERSION_STRING` is `0.23.74-dev` (exactly one quoted
literal in the source), `CMakeLists.txt` carries `project(aster_bootstrap
VERSION 0.23.74)`, and `./aster --help` names `0.23.74-dev`. The four document
status lines (README title, VERSION_HISTORY's first `##`, ROADMAP,
ARCHITECTURE, FEATURE_STATUS, `docs/language-reference.md`) are realigned.

## 2. The five defects, reproduced then repaired

Every probe lives in `tests/audit-evidence/v0.23.72-dev/`. The "before" column
was re-measured with the v0.23.73-dev compiler; the "after" column with this
round's compiler. Controls are unchanged.

| Probe | Before | After |
| --- | --- | --- |
| `F03_ctl_runtime` | `BUILD_OK EXIT=0` | `BUILD_OK EXIT=0` |
| `F03_ctl_single_literal` | `BUILD_OK EXIT=0` | `BUILD_OK EXIT=0` |
| `F03_u64_global_const` | `REJECTED addition overflows i64 …` | `BUILD_OK EXIT=0` |
| `F04_ctl_alias_only` | `BUILD_OK EXIT=5` | `BUILD_OK EXIT=5` |
| `F04_ctl_reverse` | `REJECTED type alias conflicts with a struct: P` | same message |
| `F04_label_shadow` | `REJECTED type mismatch initializing 'v': expected P, got i32` | `REJECTED struct name conflicts with a type alias: P` |
| `F05_ctl_i32_subject` | `REJECTED case value does not fit …` | same message |
| `F05_switch_enum_case` | `BUILD_OK EXIT=1` | `REJECTED case value does not fit the switch subject type` |
| `F06_ctl_const_oob` | `REJECTED array index out of bounds … index 4, length 4` | same message |
| `F06_overflow_index` | `BUILD_OK EXIT=11` | `REJECTED array index constant expression overflows or is invalid` |
| `F11_ctl_assign_bool` | `REJECTED type mismatch assigning variable: a` | same message |
| `F11_deref_bool` | `BUILD_OK EXIT=1` | `REJECTED type mismatch assigning through a pointer: expected i64, got bool` |

## 3. Implementation

| Fix | Change | Why this shape |
| --- | --- | --- |
| F-03 | `foldConst(const Expr& e,bool u64Target=false)`; two u64 initializer slots pass `ty.k==Ty::U64`; `Add`/`Sub`/`Mul`/`Shl` wrap through `uint64_t` in that mode | The historical i64 overflow message is pinned by `operator-checks.sh` and `tests/codegen-twin.c`. Deleting it would have widened every target, so the wrap is opt-in per slot. `i32`/`i64`/`u32` refusals are asserted in the new suite. |
| F-06 | `constantShape(const Expr&)` reads AST shape only; `foldedIndex(const Expr&,int64_t&)` folds, raises on a constant-shaped failure, or reports dynamic; all three `checkArrayBounds()` sites call it | A dynamic index must still be dynamic (the run-time / `--bounds-check` path owns it). Only the "constant-shaped but unfolded" hole is closed. |
| F-04 | `rejectTagConflict(const Token&,const std::string&)` called from `structDeclaration()` (struct + union), `enumDeclaration()` and `typeAliasDeclaration()` | One check for all three entry points kills the order dependence. Historical messages are kept verbatim so `alias-const-checks.sh`'s guards and refusal matrix keep pinning the same refusals. |
| F-05 | `case Ty::Enum: return enumValueFits(folded);` in `caseValueFits()` | An enum is an i32 underneath; `initializerFits()` already used the same predicate. The suite's mutation anchors on the two-line context so it cannot hit the identical line in `initializerFits()`. |
| F-11 | Sema `Stmt::DerefAssign` calls `checkValue(ptrElemType(inner),*s.expr,actual,"type mismatch assigning through a pointer",false)` when `tyIsPtrToElem(inner)` | Codegen already derives the same element to choose the store width. `refuseNarrow=false` matches the element/field store carve-out; an untyped `ptr` stays on its historical 64-bit store, witnessed by two accepted probes. |

## 4. Two 9-layer resident suites

| Layer | `const-fold-u64-checks.sh` (F-03 + F-06) | `front-sema-checks.sh` (F-04 + F-05 + F-11) |
| --- | --- | --- |
| 1 | strict build + version guard | strict build + version guard |
| 2 | 9 source guards (wrap flag, two slots, `constantShape`, `foldedIndex`, three gates, the old bypass absent) | 7 source guards (three entry points, both enum tables, the checked store, the old scattered check absent) |
| 3 | 10 static diagnostics: `: error: … at L:C`, a source caret, the two distinct bounds refusals, and the three preserved i64 messages | 14 static diagnostics with position + caret; the three failure families must stay distinct |
| 4 | shipped example → 15; five wrap shapes; two accepted array indexes; 11 refusals | shipped example → 28; seven accepted programs (including two untyped-`ptr` witnesses); 14 refusals with exact messages |
| 5 | `tests/const-fold-u64-twin.c` via `aarch64-linux-gnu-gcc -static` → 15 | `tests/front-sema-twin.c` → 28 |
| 6 | `build-elf` / `build-pie` / `build-so` / `build-obj --pic`, `readelf -h` type assertions, PIE runs → 15 | same four writers, PIE runs → 28 |
| 7 | 38 invariants exercised | 46 invariants exercised |
| 8 | 6 mutations, 6 caught | 6 mutations, 6 caught |
| 9 | 3 baseline rows reproduced; 384 inherited rows unchanged | 3 baseline rows reproduced; 384 inherited rows unchanged |

Both suites are registered in `DEFAULT_SUITES` and `CRITICAL` in
`tests/ci.sh`. Their survivor assertion uses the census-wide
`FAIL: mutation '$1' went unnoticed` wording.

### Mutations (12/12 caught)

| Suite | Mutants |
| --- | --- |
| const-fold-u64 | u64 slots lose the wrap flag (2 sites); addition no longer wraps; left shift no longer wraps; `constantShape` ignores binary operators; folding failure is silent again (3 sites reverted to `constantInteger`) |
| front-sema | struct / enum / type-alias entry points each drop the cross-check; `caseValueFits`' Enum arm returns true; `DerefAssign` check removed; `DerefAssign` checks `Ty::Bool` instead of the element |

Every mutant is built with the same strict compiler flags under `-w` and must
be caught by the full `mut_check` — the shipped example's exit status, the
accepted corpus, and every refusal — not by a single witness.

## 5. Older suites realigned, not weakened

The new `foldConst` signature and the shared tag check made four existing
source pins stale. Each was re-pinned to the code that now owns the rule:

| File | Realignment |
| --- | --- |
| `tests/operator-checks.sh` | guard → `~foldConst(*e.a,u64Target)` |
| `tests/integer-cast-checks.sh` | guard → `castConstValue(foldConst(*e.a,u64Target),e.ty)` |
| `tests/alias-const-checks.sh` | m6 now neutralises `rejectTagConflict`'s alias-table branch; the refusal still must be noticed |
| `tests/type-strictness-checks.sh` | the `checkValue(...,false)` carve-out census goes 2 → 3, documenting the new `DerefAssign` site |

18 high-risk existing suites were run individually: the 10 touched by the
first pass (7 pass, 3 stale), the 11 after re-pinning (all pass), plus the
neighbouring bounds / cast / literal suites. `F04_ctl_reverse` still emits the
historical `type alias conflicts with a struct: P`, and `i32`/`i64` global
overflow refusals are unchanged.

## 6. Byte baseline — exact drift range

`tests/baseline/v0.23.74-dev/example-hashes.txt` was recomputed from all 131
shipped examples under all three pinned writers (`build-so`, `build-elf`,
`build-obj --pic`), then the three `address_of_abi` rows every release filters
were removed:

| Measure | Value |
| --- | --- |
| v0.23.73-dev rows | 384 |
| Inherited rows whose hash changed | **0** |
| New rows (`const_fold_u64`, `front_sema` × 3 modes) | 6 |
| v0.23.74-dev rows | **390** |

The drift range is therefore exactly the 6 new keys; no earlier program moved.
13 per-suite "pre-existing output rows" assertions were realigned 303 → 309,
two full-diff row assertions 384 → 390, and three `prev_rows` assertions
378 → 384.

## 7. Gate results

| Gate | Result |
| --- | --- |
| Strict build | `BUILD_EXIT=0` |
| 18 high-risk existing suites, individually | 18 pass |
| `const-fold-u64-checks.sh` | 9/9 PASS, 6/6 mutants caught |
| `front-sema-checks.sh` | 9/9 PASS, 6/6 mutants caught |
| `ci-protocol-checks.sh` | 33 checks passed, 0 failed — 132 suites, 131 examples, 390 baseline rows, 46 mutation suites, no orphans |
| `mutation-score-checks.sh` | PASS — 36 suites declare 224 mutant builds, 224/224 caught (100%) |
| `coverage-checks.sh` | PASS — 84.88% of 7772 executable lines (floor 80%) |
| Full CI (`LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc CI_JOBS=3 bash tests/ci.sh`) | **132 passed, 0 skipped, 0 failed**; APK gates 3/3; `CI_EXIT=0` — see §7a |

### 7a. Full CI

The run completed after 52m 05s of wall time with the mandated command and
environment:

```sh
LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc CI_JOBS=3 bash tests/ci.sh
```

```
CI SUMMARY: 132 passed, 0 skipped, 0 failed (of 132 suites)
APK GATES : 3 passed, 0 skipped, 0 failed
CI_EXIT=0
```

`132` is two more than v0.23.73-dev's `130`: the two new 9-layer resident
suites. All three APK verification gates (`native_render`, `icon_text_demo`,
`native_touch`) passed. No suite was skipped, no suite failed, and no rerun
was needed to obtain the green gate. The full log is `/tmp/ci_v02374.log`
(a transient artifact, not committed).

After the run, three historical prose comments were de-numbered: they still
named v0.23.72-dev's 378-row baseline, which is two releases stale. The edits
are in `tests/alias-const-checks.sh`, `tests/embed-align-checks.sh`, and
`tests/stack-arg-abi-checks.sh`, and touch only a `#` comment and one
`printf` progress line — no assertion, guard, or mutation pin changed. All
three suites were re-run individually afterwards and returned `EXIT=0`, so the
committed tree is behaviourally identical to the tree the full CI measured.

## 8. File inventory

| Path | Role |
| --- | --- |
| `src/aster.cpp` | version macro + the five fixes |
| `CMakeLists.txt` | `VERSION 0.23.74` |
| `examples/const_fold_u64.ast`, `examples/front_sema.ast` | shipped witnesses (15, 28) |
| `tests/const-fold-u64-twin.c`, `tests/front-sema-twin.c` | host C oracles |
| `tests/const-fold-u64-checks.sh`, `tests/front-sema-checks.sh` | 9-layer resident suites |
| `tests/ci.sh` | `DEFAULT_SUITES` + `CRITICAL` registration |
| `tests/baseline/v0.23.74-dev/example-hashes.txt` | 390-row frozen baseline |
| 22 existing test scripts | version guards, row assertions, four stale pins |
| `README.md`, `VERSION_HISTORY.md`, `ROADMAP.md`, `FEATURE_STATUS.md`, `ARCHITECTURE.md`, `docs/language-reference.md`, `AUDIT-v0.23.72-dev.md` | docs |
| `VALIDATION-v0.23.74-dev.md` | this report |

## 9. Still open

F-07 (signedness in compare/divide/modulo), F-08/F-09/F-10/F-12 (ELF section
alignment contracts), the seven gate meta-findings (G-01…G-07), six static
observations and K-01 remain queued one theme per version on §8's route. The
audit evidence under `tests/audit-evidence/v0.23.72-dev/` is intentionally
still **not** registered in `DEFAULT_SUITES`: those programs reproduce
defects, they do not assert them.
