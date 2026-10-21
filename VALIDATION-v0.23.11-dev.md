# Validation — v0.23.11-dev

**A syntax fuzzer, and proof that it can still fail (P4.4).**

The question that started this release: *the compiler crashed on a legal
program and nothing in the suite caught it — how do we make that impossible to
repeat?* v0.23.10-dev's move-then-deref bug (six sites reading a moved-from
`unique_ptr`) segfaulted Aster on a negative literal, a `!`, and a `*p = v`.
The strict build was clean and the focused diagnostics suite passed — neither
exercises a unary prefix — and only the full `ci.sh` caught it, across nine
suites plus both APK gates. This release adds the guard for that entire class
of bug.

---

## The property, and how it is checked

`tests/fuzz-checks.sh` (7 checks, registered in `ci.sh`) asserts exactly one
thing about 2,000 generated inputs:

> every input either **compiles** (exit 0) or is **rejected cleanly** (exit 1).
> Anything else — a signal, an abort, a timeout — is a crash.

The corpus comes from `tests/fuzz-gen.py`, seeded (`--seed`, default
`20261013`) so a run is reproducible, and it is four kinds deep rather than a
stream of random bytes:

| kind | share | why it is there |
| --- | --- | --- |
| **fixed seeds** | 10 | every unary/assignment path that has actually crashed, spelled plainly (`-1`, `!x`, `&x`, `*p = 5`, …). Not random, so the "can this fuzzer still fail" proof has something guaranteed to hit. |
| **light mutation** | ~490 | ONE edit to a real example. Still nearly valid, which is what gets past the parser into Sema and codegen. |
| **heavy mutation** | ~390 | 1–4 edits: delete a span, insert junk, truncate, duplicate a line, substitute characters, inject newlines/tabs (which moves every reported line/column and stresses the diagnostics renderer too). |
| **token soup** | ~280 | random token streams — mostly lexer food, and the lexer is part of the surface. |
| **skeleton** | ~830 | a valid frame (`fn main() -> i32 { … }`) filled with random statements and expressions: the kind that actually reaches code generation. |

## Three guards that keep the suite honest

**1. The corpus must actually reach the compiler's interior.** The suite
asserts a **nonzero share of inputs compile**. A corpus where everything is
rejected at the first token would report "0 crashes" while testing nothing past
the lexer — a green run that means nothing. The light-mutation kind was added
precisely because the first draft only reached 33/2000; it now reaches **76**.

**2. The suite must still be able to fail.** Step 6 copies `src/aster.cpp`,
re-injects the v0.23.10-dev bug verbatim (`z->a = std::move(x);` *before*
`z->line = x->line;`), builds that copy, and requires the fuzzer to crash it.
The injection is verified to have applied before the run, so a stale `sed`
cannot turn the proof into a no-op. **44 inputs crash the injected build** —
so the zero in step 4 is evidence rather than the absence of a test.

**3. A crashing process leaves a core file behind, and step 6 crashes one on
purpose.** The first runs of this suite dropped **139 core dumps (~39 MB) into
the project root** — once per run, including every CI run. The suite was
polluting the workspace it was supposed to be guarding, and doing so *because
it was passing*. `ulimit -c 0` at the top of the script fixes it: a full run
now leaves **0** core files, and crash detection is unaffected because it reads
the exit status rather than looking for a core.

## Coverage beyond the main loop

`build-elf` is not the only path through the compiler, so a 300-input subset
also takes **`build-obj --pic`** and **`build-so`** — different codegen:
PLT/GOT entries, relocations, a different ELF header. Both are 0 crashes.

## Evidence

| Stage | Result |
| --- | --- |
| Strict build (`-Werror`) | zero warnings, `BUILD OK` |
| `tests/fuzz-checks.sh` | PASS (7/7) — 2,000 inputs, 0 crashed, 76 compiled, 301 through `.o`/`.so` |
| Injected-bug proof | 44 inputs crash the injected build → the suite can still fail |
| Delivered APK rebuild | `icon-text-demo.apk` rebuilt with v0.23.11-dev and re-verified: `validate_apk.py` ALL CHECKS PASSED, `aster verify-apk` OK (v1 + v2) |
| `tests/ci.sh` (full gate) | **44 passed, 23 skipped, 0 failed** (of 67 checks), exit 0 |
| Exit status | 0 |

The total rose from 43 to **44** passed because `fuzz-checks.sh` is now in the
gate; every suite that passed in v0.23.10-dev still passes. The APK gates
(`native_render`, `icon_text_demo`) are both green, each verified two ways
(`validate_apk.py` and `aster verify-apk`). The 23 skips are the e2e C-ABI
suites, which self-skip on the x86_64 sandbox by design and run for real on an
AArch64 runner. Gate runtime went from ~8:00 to ~8:35 — the fuzzer's 34 s is
the whole increase.

## Regression proof

- **Strict compile:** `g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror
  src/aster.cpp -o aster` → no warnings.
- **Byte-level A/B against v0.23.10-dev:** the v0.23.10-dev compiler was
  rebuilt from the delivered archive and both compiled every `examples/*.ast`:
  **40 standalone-buildable examples, all 40 outputs byte-identical, 0
  differing** (the other 44 sources are split declarations, `.so` parts, the
  NativeActivity demos and C-ABI fixtures — not standalone-buildable by design,
  and rejected identically by both versions). No emitted byte moved.
- **Diagnostics:** untouched in this release; `diagnostics-checks.sh` still 6/6
  inside the full gate.

## What was not changed

No code-generation path was touched. The only source delta is the version
constant (`kVersion`, `kUsage`); everything else added is test code. This
release adds a guard, not behavior.

## How to run it

```sh
sh tests/fuzz-checks.sh                       # 2,000 seeded inputs, ~34 s
FUZZ_COUNT=300 sh tests/fuzz-checks.sh        # a quick local pass, ~5 s
FUZZ_SEED=7 sh tests/fuzz-checks.sh           # a different region of the space
sh tests/ci.sh                                # the full gate, fuzz included
```

A crash is reported with the input that caused it:

```
  CRASH (exit 139): tmp-fuzz-checks/corpus/fuzz_00000.ast
FAIL: 1 input(s) crashed the compiler
```
