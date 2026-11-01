# Validation — v0.23.64-dev

**Round:** "every suite runs" — the audit's P1 follow-up. A defect in the
gate, not in the compiler: **no `src/aster.cpp` change, and no byte change**
(all 121 examples produce the bytes `tests/baseline/v0.23.63-dev` records; the
snapshot is copied forward under this version's name).

**Result:** 121 suites, 0 skipped, 0 failed. APK gates 3/3.

---

## I. The claim

The audit (`AUDIT-v0.23.61-dev.md`, §5 item 11) found one coverage gap and
proposed a one-line fix:

> `tests/smoke.sh` is not in `DEFAULT_SUITES`, and `FEATURE_STATUS.md`
> credits it with covering 32-argument calls, arithmetic, comparisons,
> `while`/`break`/`continue` and `build-elf` — so those basic capabilities
> have no resident suite.

Both halves of that are true, and neither is the whole story. The interesting
question is *why* the gate let it happen, because the same reason hides more
than one script.

## II. Why it happened

The orphan check was:

```sh
for f in "$ROOT"/tests/*-checks.sh; do
    printf '%s\n' "$registered" | grep -qxF "$(basename "$f")" || orphans="$orphans $b"
done
```

`tests/*-checks.sh` is a **naming convention, not a property**. Four scripts
in `tests/` fail that glob, so the gate has never seen any of them:

| script | kind | first-ever run |
| --- | --- | --- |
| `c-ptr-memory-structural.sh` | structural twin of `e2e-c-ptr-memory.sh` | PASS |
| `e2e-so-scope.sh` | DSO scope / loader recovery / lifecycle, executed | PASS (SKIP without an AArch64 `HOSTCC`) |
| `regression-symtab.sh` | the v0.17.0 append-only symbol-table proof | **FAIL** — §III |
| `smoke.sh` | local driver | driver; §IV |

So the audit's one-line fix ("register `smoke.sh`") would have been wrong
twice over: `smoke.sh` is a *driver* that re-invokes ~28 already-registered
suites, so registering it runs them all a second time; and the same blind spot
was hiding **three real suites**, which is the larger loss.

## III. The suite that failed, and why it is not a regression

`regression-symtab.sh` compares 11 products against v0.16.0 fixtures committed
under `tests/baseline/v0.16.0`, and asserted:

```python
limit = secs_r['.shstrtab'][4] if '.shstrtab' in secs_r else len(ref)
assert masked(new[:limit]) == masked(ref[:limit]), rel + ': loaded image bytes changed'
```

Two of the seven committed cases fail. The differences, read at instruction
level:

| product | v0.16.0 | v0.23.64-dev |
| --- | --- | --- |
| `exec_plain` (`hello.ast`) | `str w0,[sp,#4]` / `ldr w1,[sp,#4]` | `str w0,[sp,#8]` / `ldr w1,[sp,#8]` |
| `pie_globals` | `str w0,[sp,#4080]` | `str x0,[sp,#4032]` |

Both are the **documented 8-byte scalar slot** — `ARCHITECTURE.md`: "Scalars
occupy one 8-byte slot each (`slot*8` byte offsets)" — which arrived with the
wide integers of v0.23.2-dev. A documented codegen change, not a regression.

Two ways to make it green were available and both were rejected:

- **Regenerating the fixtures** would make the suite pass while deleting the
  only record that `hello.ast`'s frame bytes ever moved.
- **An exemption list** (`{'exec_plain', 'pie_globals', …}`) would grow: every
  later legitimate frame change would have to be added by hand, and a list
  that grows is a list that stops being read.

What replaces the assertion is the invariant the suite is *named for*, and
which still holds of every product — **the section table is append-only**:

```python
loaded_end = max([ph[2] + ph[5] for ph in phdrs(new, en) if ph[0] == 1], default=0)
assert en['shoff'] >= loaded_end, \
    (rel, 'section table overlaps the loaded image', en['shoff'], loaded_end)
```

`p_offset + p_filesz` of the last `PT_LOAD`, so `.symtab` / `.strtab` /
`.shstrtab` cannot sit inside bytes the program itself writes. The program
header table was already compared field by field, and the per-section
comparisons are untouched — 7 products, 0 pre-existing sections changed.

Two smaller repairs came along: the suite required a pre-built `./aster`
instead of building its own (no other suite does; a fresh checkout has none),
and it now honours `$OUT`.

**One gap is recorded rather than papered over:** the committed fixtures cover
7 of the suite's 11 cases. `obj_globals`, `obj_array`, `so_math` and
`so_rtinit` were never committed, so its `ET_REL` branch — byte-for-byte
identity — **has still never executed**. Regenerating them would need a
v0.16.0 compiler.

## IV. The driver

`smoke.sh` compiles the compiler, checks 20 examples' ELF headers, then
invokes ~28 suites. Verified: **every suite it invokes is already in
`DEFAULT_SUITES`**, so its unique content is the ELF-header battery — and
registering it would re-run all 28.

It is therefore declared in an explicit allowlist, with a reason, **and the
claim is now enforced**:

```
PASS: driver suites: every suite tests/smoke.sh invokes is registered
```

A driver may only stay unregistered while everything it invokes is
registered. Otherwise "it is just a driver" is a way to add a suite nobody
runs.

## V. The gate, after

```sh
for f in "$ROOT"/tests/*.sh; do
    b=$(basename "$f")
    printf '%s\n' "$registered" | grep -qxF "$b" && continue
    case $b in
        host-toolchain-probe.sh) continue ;;   # sourced library
        guest-libc-alias.sh)     continue ;;   # sourced library
        ci.sh)                   continue ;;   # the runner itself
        run-aarch64.sh)          continue ;;   # qemu/native prefix
        run-on-device.sh)        continue ;;   # needs a real target
        smoke.sh)                continue ;;   # driver; §IV
    esac
    orphans="$orphans $b"
done
```

Enumerate everything, subtract a list where **every entry states its reason**.
Adding a script is now either a registration or a reviewed allowlist entry.

The gate was tested the way any gate should be: adding a throwaway
`tests/zzz-orphan-probe.sh` makes it fail —

```
FAIL: coverage ratchet: suites=121 (floor 121), … unregistered: zzz-orphan-probe.sh
```

— and it passes again once the file is removed.

## VI. The claim that pointed at a suite that never ran

Five `FEATURE_STATUS.md` rows credited coverage to `smoke.sh`. Four had real
coverage elsewhere and now name it:

| capability | was | now |
| --- | --- | --- |
| up to 32 call arguments | `smoke.sh` argument cases | `e2e-c-abi-32-args.sh`, `c-abi-32-args-structural.sh` |
| arithmetic `+ - * /`, unary minus, parentheses | `smoke.sh` | `operator-checks.sh`, `precedence-checks.sh` |
| comparisons `== != < <= > >=` | `smoke.sh`, `bool-checks.sh` | `bool-checks.sh`, `operator-checks.sh` |
| `build-elf` (fixed-address `ET_EXEC`) | `smoke.sh` | `write-output-checks.sh`, `linker-checks.sh`, `global-checks.sh` |

The fifth was a **genuine hole**. No resident suite executed a `while` loop
containing an unlabeled `break;` or `continue;`: the only `break` cases used
the *labeled* form (`break outer;`, from the switch round), and the only
`continue;` in a `while` sat inside a `switch`. Three witnesses now live in
`tests/condition-checks.sh` [3/9]:

| witness | expected | what it pins |
| --- | --- | --- |
| `while + unlabeled break` | 5 | `break;` leaves the loop at all |
| `while + continue` | 18 | `1+2+4+5+6` — `continue;` branches to the condition, skipping only the body's tail |
| `unlabeled break: inner only` | 33 | an unlabeled `break;` leaves **only the innermost** loop: `s` is 3, `i` still reaches 3 |

The third is the one that distinguishes the two forms; without it, a compiler
that made an unlabeled `break;` behave like a labeled one would still pass.

## VII. Gates

```
CI SUMMARY: 121 passed, 0 skipped, 0 failed (of 121 suites)
APK GATES : 3 passed, 0 skipped, 0 failed
```

| gate | after the round |
| --- | --- |
| `ci-protocol-checks.sh` | **121 suites (floor 121), 121 examples, 360 baseline rows, 35 mutation suites, no orphans**, plus the driver claim |
| `coverage-checks.sh` | **84.59% of 7554 executable lines** (floor 80%) — unchanged: no compiler change |
| `mutation-score-checks.sh` | **26 suites declare 167 mutant builds, 167/167 caught** (floors 24 / 150 / 2 per suite) |
| `version-checks.sh` | banner, the single version literal, `CMakeLists.txt`, README, `VERSION_HISTORY.md`, `ARCHITECTURE.md` and this report all name `0.23.64-dev` |

The suite count moves 118 → 121: the three orphan suites are registered. The
mutation floor moves 30 → 35 declared mutation *suites* only in the sense that
the ratchet counts them; the mutant count is unchanged at 167, because this
round adds mutants nowhere — it makes three suites that already existed run.

## VIII. What is still open

- `regression-symtab.sh`'s `ET_REL` branch has never executed (§III).
- The audit's P2 items 9 (`.so` `.eh_frame` page alignment, `kRelTlsOff`) and
  10 (`layoutStruct` overflow-checked accumulation) are still queued, as is
  item 13 (the language gaps proper: `typedef`, `const`, `void`).
- The `.so` writer places `.eh_frame` at `alignUp(afterDebugInfo, 8)` while
  declaring `p_align = pageSize`; that is congruent for the loader (vaddr ==
  offset in that layout) but deserves the empirical check item 9 asks for.

### Item 12, done along the way

Item 12 was four stale document assertions plus one missing ignore rule. All
five are closed:

| claim | repair |
| --- | --- |
| `ARCHITECTURE.md`: "`tests/smoke.sh` is the fast local subset" | stale since it has never been in the gate; now states what it actually is (a local driver with an ELF-header battery, **not** part of CI) and why it stays that way |
| `tests/parser-checks.sh` credited as the fold-in target for the retired lexer suites | marked **deleted in #261**; the lexer→parse→dump coverage it was credited with now names `tests/codegen-checks.sh`, the three-way differential |
| "there is no `char`" (flat) | contradicted §3.2, which has had character literals since v0.23.50-dev; restated as "a character literal but no `char` *type*" |
| `tests/ci.sh` writes `aster.tmp.$$` and an interrupted run leaves it behind | `.gitignore` gained `*.tmp.*` (`/aster` does not match it); verified with `git check-ignore` |
