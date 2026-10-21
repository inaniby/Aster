# Validation — v0.23.12-dev

**`.debug_line`: the debugger can find your source (P4.2).**

The question that started this release: *I can read the disassembly — so which
`.ast` line produced this instruction?* Until now the answer was "count
backwards by hand". Nothing Aster emitted named a source line at all, so
`lldb`, `gdb` and `addr2line` could name an address but never a line, and a
breakpoint could not be expressed in source terms. `-g` / `--debug-line` now
emits a real **DWARF v4 `.debug_line`** table: one row per statement, at the
instruction that statement begins at, naming the source file.

---

## What is asserted, and by whom

`tests/debugline-checks.sh` (9 checks, registered in `ci.sh`). The assertion
that matters is **not** "a `.debug_line` section exists" — a table that is
merely non-empty proves nothing. It is the **line set**:

> for a source whose statement lines are known by inspection, the set of lines
> in the decoded table must be *exactly* those lines — every statement line
> appears, and no line that holds no statement does.

The test source is 14 lines; its statement lines (including each function
prologue) are `1 2 3 6 7 8 9 10 12`. Blank lines, closing braces, and
declarations that are not statements must not appear. A table that attributes a
statement to its neighbour's line fails, which is exactly the bug the suite's
own mutation step injects.

**Two independent readers must agree row for row.** `tests/debugline-decode.py`
is written for this suite — it walks the ELF64 section table by hand, runs the
line-number state machine, and prints `addr line path` with no pyelftools and
no objdump in the loop. Where `llvm-dwarfdump` is installed it decodes the same
file and the two must agree on every row; the decoder was separately validated
against `gcc -g -gdwarf-4` output as an external control. The end-sequence
address is additionally required to equal the end of `.text` **exactly** — a
sequence that stops short would silently drop the last function from the table.

## The nine checks

| # | Check |
| --- | --- |
| 1 | **Off by default** — no `.debug_line` in an executable, a PIE, an object, or a shared object built without `-g` |
| 2 | **`-g` is additive** — the section appears, and `readelf -x .text` of the `-g` build is `cmp`-identical to the same build without it |
| 3a | every row names our file, and a line inside `1..14` |
| 3b | the decoded **line set equals `1 2 3 6 7 8 9 10 12`** exactly |
| 3c | addresses ascend, and every row lands inside `[.text, .text+.size)` |
| 4 | **`llvm-dwarfdump` agrees row for row**, and the sequence ends at `text_end` |
| 5 | PIE: same line set, addresses image-relative (not fixed) |
| 6 | the object carries `.debug_line` **and** `.rela.debug_line`, with `R_AARCH64_ABS64` against the `.text` section symbol |
| 7 | a two-object `link-obj` yields **one unit per object**, the second starting at or after the first ends, with per-file line assertions (`4 main.ast`, `5 main.ast`, `3 defs.ast`, `4 defs.ast`) |
| 8 | a shared object keeps the table, with the same line set |
| 9 | **the suite can still fail** — an off-by-one is injected into a copy of the source and the assertion above must notice |

Step 9 is what makes the green run mean something. The mutation is
`s.line` → `s.line+1` in the row recorder; the suite builds that copy (never
the real source), decodes it, and requires the line set to differ:

```
FAIL: line set mismatch: table has [1 3 4 6 8 9 10 11 13], source has [1 2 3 6 7 8 9 10 12]
```

The injection is verified to have applied first, so a stale `sed` cannot turn
the guard into a no-op.

## The one genuinely new problem: an object file does not know its own address

An executable can write final vaddrs into the line program directly. A
relocatable `.o` cannot — only the linker knows where its `.text` will land. So
every `set_address` operand is written as **0** and its offset recorded as a
patch site, and `.rela.debug_line` carries one `R_AARCH64_ABS64` (**257**, a
relocation type Aster had never emitted before) per site against a local
`STT_SECTION` symbol for `.text`. Both linkers then raise each site to
`textVaddr + objectTextOffset`.

This is also what makes check 7 come out right: a unit's rows are relative to a
text base that does not exist until the merge, so `link-obj` of two `-g`
objects produces **two units**, each covering its own address range, rather than
one table straddling both. Observed on this release:

```
array_extern_main.ast   0x401000 – 0x401004
array_extern_defs.ast   0x40106c – 0x401074
```

## Evidence

| Stage | Result |
| --- | --- |
| Strict build (`-Werror`) | zero warnings, `BUILD OK` |
| `tests/debugline-checks.sh` | PASS (9/9), ~34 s |
| `llvm-dwarfdump` cross-read | agrees row for row; sequence ends exactly at `text_end` |
| Injected off-by-one | caught: `[1 3 4 6 8 9 10 11 13]` ≠ `[1 2 3 6 7 8 9 10 12]` |
| Byte-level A/B vs v0.23.11-dev | **40/40** executables, **84/84** objects, **84/84** shared objects byte-identical, 0 differing |
| `.text` invariance under `-g` | identical (`cmp` on `readelf -x .text`) |
| `tests/ci.sh` (full gate) | **45 passed, 23 skipped, 0 failed** (of 68 checks), exit 0 |
| Exit status | 0 |

The gate total rose from 44 to **45** passed (68 checks, up from 67) because
`debugline-checks.sh` joined it; every suite that passed in v0.23.11-dev still
passes. The 23 skips are the e2e C-ABI suites, which self-skip on the x86_64
sandbox by design and run for real on an AArch64 runner. Both APK gates
(`native_render`, `icon_text_demo`) are green, each verified two ways.
Gate runtime: ~12 min.

## Two things the gate caught on the way

**1. A source guard that matched a constructor's whole signature.**
`runtime-bounds-checks.sh` proved `--bounds-check` reaches `Codegen` by
`grep -qF`-ing the constructor's *entire* parameter list. Adding one option
(`bool debugLine=false`) broke it, and the suite reported `FAIL: boundsCheck is
not threaded into Codegen` — a true statement about a string, and a false one
about the code. The guard now matches the member initializer
`boundsCheck(runtimeBoundsCheck)`, which is what the check actually means and
which does not care how many options the constructor takes. A guard that
re-spells a signature is a guard that has to be edited every time the signature
moves, and the edit is indistinguishable from weakening it.

**2. `ci.sh` deleted the evidence of its own failures.** The first full run of
this release came back with two failures; by the time I looked, the per-suite
logs were gone, because cleanup ran unconditionally at the end. One failure
turned out to be the guard above (reproducible, fixed); the other — a one-off
`apk-checks.sh` failure — I could not diagnose at all, and it has not recurred
in four subsequent runs. `ci.sh` now keeps `ci-artifacts/` and prints its path
when the run is red, and still leaves nothing behind when it is green. A gate
that throws away its only record of a red run is how a real failure becomes an
unreproducible mystery; if that `apk-checks` failure is real, the next red run
will say so.

## Regression proof

- **Strict compile:** `g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror
  src/aster.cpp -o aster` → no warnings.
- **Byte-level A/B against v0.23.11-dev:** the v0.23.11-dev compiler was
  rebuilt from the delivered archive and both compiled every `examples/*.ast`
  three ways. All **40** standalone-buildable examples are byte-identical under
  `build-elf`; **84/84** under `build-obj`; **84/84** under `build-so`. No
  emitted byte moved, because every new section is laid out *after* everything
  that already existed and the new section indices are allocated last — so no
  existing offset or index shifts — and because the flag is off by default.
- **`--bounds-check` plumbing guard:** adding a parameter to `Codegen`'s
  constructor broke a source guard in `runtime-bounds-checks.sh` that matched
  the constructor's full signature. The guard now matches the member
  initializer `boundsCheck(runtimeBoundsCheck)` instead, which is both what the
  check actually means and immune to the signature gaining options.

## What was not changed

No instruction-selection path was touched. The rows are collected beside the
instructions and never influence them; the addition is a section, a relocation
type, and a table.

## How to run it

```sh
sh tests/debugline-checks.sh                       # the whole suite, ~34 s
./aster build-elf examples/… -g -o /tmp/a.elf      # then:
python3 tests/debugline-decode.py /tmp/a.elf       # addr line path, per row
python3 tests/debugline-decode.py --units /tmp/a.elf   # file, first addr, last addr
llvm-dwarfdump --debug-line /tmp/a.elf             # independent reader
sh tests/ci.sh                                     # the full gate
```

A `-g` build of a 14-line two-function source decodes as, for example:

```
0x401000 6 …/lines.ast
0x401004 7 …/lines.ast
0x40100c 8 …/lines.ast
0x401014 9 …/lines.ast
0x401034 10 …/lines.ast
0x401044 1 …/lines.ast
0x401054 2 …/lines.ast
0x401064 3 …/lines.ast
```
