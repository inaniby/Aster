# VALIDATION-v0.23.75-dev — signedness: the promoted result type decides

**Version:** `0.23.75-dev` · **Theme:** F-07 from `AUDIT-v0.23.72-dev.md` §8 ·
**Translation unit:** `src/aster.cpp` (13908 lines, one C++17 file).

One coherent theme: the compiler already computed the type of every binary
expression with `promoteInt`, then ignored that type when choosing condition
codes and divide opcodes. This round makes one rule have one home. No syntax,
no Sema rule, no new rejection — and, measured rather than asserted, no byte
of any program written before this round moved.

---

## 1. Strict build and version identity

```sh
g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o ./aster
```

`BUILD_EXIT=0`. `ASTER_VERSION_STRING` is `0.23.75-dev` (exactly one quoted
literal in the source), `CMakeLists.txt` carries `project(aster_bootstrap
VERSION 0.23.75)`, and `./aster --help` names `0.23.75-dev`. The document
status lines (README title, VERSION_HISTORY's first `##`, ROADMAP,
ARCHITECTURE, FEATURE_STATUS, `docs/language-reference.md`) are realigned.

## 2. The defect, reproduced then repaired

Every probe lives in `tests/audit-evidence/v0.23.72-dev/` for the audit's own
cases, and in the generated `tmp-signedness-checks/work/` corpus for the
121-case matrix. The "before" column was measured with the v0.23.74-dev
compiler, the "after" column with this round's compiler; the oracle column is
`aarch64-linux-gnu-gcc -static -O2` running the equivalent C program.

| Probe | Before | After | gcc oracle |
| --- | --- | --- | --- |
| `F07_ctl_both_i64.ast` (`a:i64=-5 < b:i64=3`) | `EXIT=1` | `EXIT=1` | `1` |
| `F07_mixed_sign_cmp.ast` (`a:i64=-5 < b:u32=3`) | `EXIT=0` | `EXIT=1` | `1` |
| `F07_mixed_sign_div.ast` (`-84 / 2 == -42`) | `EXIT=0` | `EXIT=1` | `1` |
| `a:i64=-84 < b:u32=5` | `EXIT=0` | `EXIT=1` | `1` |
| `a:i64=-84 / b:u32=5 == -16` | `EXIT=0` | `EXIT=1` | `1` |
| `a:i64=-84 % b:u32=5 == -4` | `EXIT=0` | `EXIT=1` | `1` |
| `a:u32=84 > b:i64=-5` | `EXIT=0` | `EXIT=1` | `1` |
| `examples/signedness.ast` (six witnesses) | `EXIT=0` | `EXIT=63` | `63` |

The full matrix is **16 type pairs × 6 comparators + 12 pairs × div/mod + one
comparison-as-bool-value = 121 cases**. Before the fix **48** disagreed with
the gcc oracle (32 ordered comparisons and 16 div/mod); afterwards **0** do.
`==` / `!=` were never affected — their condition codes do not depend on
signedness. All eight affected pairs share one shape: a 64-bit signed operand
mixed with a narrower unsigned one, in either operand order.

Disassembly read-back of the same three code paths:

| Program | Before | After |
| --- | --- | --- |
| `i64 × u32` `a < b` in an `if` | `b.cs` (unsigned HS) | `b.ge` (signed LT inverted) |
| `i64 × u32` `a / b` | `udiv x0` | `sdiv x0` |
| `i64 × u32` `let t: bool = a < b` | `cset w0, cc` (LO) | `cset w0, lt` |
| `u32 × u32` control, `a < b` | `b.cs` | `b.cs` (unchanged) |
| `u32 × u32` control, `a / b` | `udiv w0` | `udiv w0` (unchanged) |

## 3. Implementation

```cpp
// v0.23.75-dev (F-07): signedness belongs to the *promoted* result type, not
// to the individual operands.
static bool opIsUnsigned(Ty a,Ty b){return tyIsUnsigned(promoteInt(a,b));}
```

`promoteInt` itself is unchanged. The four sites that used to ask
`tyIsUnsigned(ta)||tyIsUnsigned(tb)` now call the helper:

| Site | Line | Effect |
| --- | --- | --- |
| `genBool` CSET | 5748 | condition code for a comparison materialized as a bool value |
| `emitCondition` | 5831 | inverted condition on the branch to the false target |
| `Expr::Mod` | 4738 | SDIV/UDIV feeding the MSUB remainder |
| `Expr::Div` / arithmetic | 4932 | opcode bit 10 selecting UDIV vs SDIV |

Operand widths are untouched (`cmpTy` / `wideOp` still decide W vs X), so a
mixed `i64 × u32` pair keeps its 64-bit CMP and only the condition flips.
Comments at `tyIsUnsigned`, the `%` promotion note and the division opcode
were rewritten to describe the promoted-result rule.

## 4. The 9-layer resident suite

`tests/signedness-checks.sh`, registered in `DEFAULT_SUITES` and `CRITICAL`:

| Layer | Content |
| --- | --- |
| 1 | Strict `-Werror` build + `0.23.75-dev` version guard |
| 2 | Eight source guards: the helper, `promoteInt`'s 64-bit rule, four call sites, absence of the old operand-wise spelling |
| 3 | Six instruction-level `objdump` invariants (three repaired paths + three unchanged controls) |
| 4 | 121-case behavioural matrix + shipped example (`63`) |
| 5 | `tests/signedness-twin.c` (`63`) and a generated 121-case gcc matrix oracle diffed against the reference model |
| 6 | `build-elf` / `build-pie` / `build-so` / `build-obj --pic` with `readelf -h` types and a PIE run (`63`) |
| 7 | Coverage census: 139 invariants exercised (floor 130) |
| 8 | Six mutations, **6/6 caught** |
| 9 | Byte baseline: three new rows reproduced, 390 inherited rows unchanged |

The reference model in layer 4 is written independently of `src/aster.cpp`
(it is C's usual arithmetic conversion rule); layer 5 re-derives every one of
the 121 expected values with the host gcc, so a mistake in the model cannot
quietly become the suite's oracle. The six mutations are: revert to the
operand-wise rule, break `promoteInt`'s signed 64-bit rule, force the CSET
condition unsigned, force the branch condition unsigned, force division to
UDIV, force the remainder divide to UDIV.

## 5. Older suites realigned

- One stale source pin: `tests/bool-checks.sh` pins
  `comparisonCond(c.k,opIsUnsigned(ta,tb))^1`.
- 17 version guards: `0.23.74-dev` → `0.23.75-dev` (the quoted literal and
  the failure message; historical prose naming older shipped versions is left
  alone).
- 13 suites: pre-existing output rows `309 → 312`.
- 2 full-diff row assertions: `390 → 393`.
- 5 `prev_rows` assertions: `384 → 390`.
- `tests/ci.sh`: `signedness-checks.sh` added to `DEFAULT_SUITES` and
  `CRITICAL`.

The `operator-checks.sh` shift pin (`tyIsUnsigned(ta)?0x400u:0x800u`) and its
mutation remain valid: a right shift still takes the left operand's type.

## 6. Byte baseline: exact drift range

An A/B over **131 examples × 3 writer modes** with the v0.23.74-dev and
v0.23.75-dev compilers found **zero moved rows**: no shipped example contains
a 64-bit signed operand mixed with a narrower unsigned one.

| Measure | Value |
| --- | --- |
| v0.23.74-dev rows | 390 |
| Inherited rows whose hash changed | **0** |
| New rows (`signedness` × 3 modes) | 3 |
| v0.23.75-dev rows | **393** |

The drift range is therefore exactly the 3 new keys; no earlier program moved.

## 7. Gate results

| Gate | Result |
| --- | --- |
| Strict build | `BUILD_EXIT=0` |
| `signedness-checks.sh` | 9/9 PASS, 6/6 mutants caught, 139 invariants |
| 18 high-risk existing suites, individually | 17 PASS; one `version-checks.sh` failure was a stale in-tree `./aster` binary, rebuilt with the strict command and then ALL PASSED |
| `version-checks.sh` | ALL PASSED |
| `ci-protocol-checks.sh` | 33 checks passed, 0 failed — 133 suites, 132 examples, 393 baseline rows, 47 mutation suites, no orphans |
| `mutation-score-checks.sh` | PASS — 37 suites declare 230 mutant builds, 230/230 caught (100%) |
| `coverage-checks.sh` | PASS — 84.91% of 7773 executable lines (floor 80%) |
| Full CI (`LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc CI_JOBS=3 bash tests/ci.sh`) | **133 passed, 0 skipped, 0 failed; APK 3 passed; `CI_EXIT=0`** (§7a) |

### 7a. Full CI

Two runs, recorded as they happened:

| Run | Outcome |
| --- | --- |
| First | Interrupted by the sandbox at 24/133 suites (18:08 UTC+8); the log has no failure lines and no `CI_EXIT=` line, so it is an aborted run, not a red gate. Preserved as `/tmp/ci_v02375.interrupted.log`. |
| Second | Restarted from scratch with the same command, finished in 55m06s: `CI SUMMARY: 133 passed, 0 skipped, 0 failed (of 133 suites)`, `APK GATES : 3 passed, 0 skipped, 0 failed`, `CI_EXIT=0`. |

The second run covered all 133 registered suites — the 132 inherited from
v0.23.74-dev plus `signedness-checks.sh` — and all three APK gates (`native_render`, `icon_text_demo`,
`native_touch`) passed. No suite was skipped, and no suite needed a fix-up
after the restart.

While the second run was in progress, four read-only probes for the *next*
release were re-confirmed against this exact v0.23.75-dev binary (F-08 `.tbss`
start, F-09 `.data` start, F-10 `PT_TLS p_align`, F-12 `addralign = 0`); they
write only to `/tmp` and changed no worktree file, so the green gate above is
unaffected.

## 8. File inventory

| Path | Role |
| --- | --- |
| `src/aster.cpp` | version macro + `opIsUnsigned` + four decision sites |
| `CMakeLists.txt` | `VERSION 0.23.75` |
| `examples/signedness.ast` | shipped witness (63) |
| `tests/signedness-twin.c` | host C oracle (63) |
| `tests/signedness-checks.sh` | 9-layer resident suite |
| `tests/ci.sh` | `DEFAULT_SUITES` + `CRITICAL` registration |
| `tests/baseline/v0.23.75-dev/example-hashes.txt` | 393-row frozen baseline |
| 25 existing test scripts | version guards, row assertions, one stale pin |
| `README.md`, `VERSION_HISTORY.md`, `ROADMAP.md`, `FEATURE_STATUS.md`, `ARCHITECTURE.md`, `docs/language-reference.md`, `AUDIT-v0.23.72-dev.md` | docs |
| `VALIDATION-v0.23.75-dev.md` | this report |

## 9. Still open

F-08 / F-09 / F-10 / F-12 (ELF section-alignment contracts), the seven gate
meta-findings (G-01…G-07), six static observations and K-01 remain queued one
theme per version on §8's route. The audit evidence under
`tests/audit-evidence/v0.23.72-dev/` is intentionally still **not** registered
in `DEFAULT_SUITES`: those programs reproduce the defects as they were found.
