# Validation — v0.23.13-dev

**`include`: a multi-file program stops retyping its own signatures (P3.4).**

The question that started this release: *who checks that my `extern` matches the
function I actually wrote?* Nobody. A two-file Aster program shared a signature
by **retyping** it —

```
main.ast                          defs.ast
extern fn add2(n: i32) -> i32;    fn add2(n: i32) -> i32 { return n + 2; }
```

— and nothing in the toolchain ever compared the two. The linker matches by
name, so a retyped arity, a retyped return type or a typo in the name links,
runs, and returns garbage without a word. The README said as much: *imports are
resolved by name only*. `include "PATH";` at the top level now brings another
file's declarations into this one, and what crosses is **the signature read out
of the file that holds the body** — so it cannot drift, because it is not a
second copy.

---

## What is asserted, and by whom

`tests/include-checks.sh` (12 checks, registered in `ci.sh`). The assertion
that matters is **not** "a build with `include` succeeded" — that would pass
for a feature that also dragged the body across. It is **byte-identity**:

> an object built from a file that writes `include "sub/defs.ast";` must be
> `cmp`-identical to one built from a file that hand-writes the two `extern`
> lines the include stands for.

An `include` that does anything more *or less* than supply those declarations
cannot pass. The symbol table is checked directly as well: `add2` and `total`
must be `UND` in `main.o`, which is what "the body and the initializer stayed in
the other file" looks like. And because that could still be satisfied by a
declaration that is merely *shaped* right, the suite also runs the program:
`add2(7)` must come back as **9** under qemu.

## The twelve checks

| # | Check |
| --- | --- |
| 1 | **Source guards** — the keyword, the top-level dispatch, the body-clearing merge, and the `@embed` exclusion are all still in the source |
| 2 | **A two-file program compiles, links and runs** — `build-obj` both, `link-obj`, run: `add2(7)` = 9 |
| 3 | **Declarations only, by byte-identity** — `cmp` against the hand-written `extern` version; `add2`/`total` are `UND` in `main.o` |
| 4 | **The path resolves against the file that wrote it** — built from a working directory holding a *decoy* `sub/defs.ast` that is not valid Aster source, so cwd-based resolution fails loudly instead of quietly compiling the wrong file |
| 5 | **`--include-dir` overrides**, is required when the file is not next to the including one, and yields the same object |
| 6 | **A repeat is a no-op**, and a **diamond** (two files that both include a third) still compiles |
| 7 | **A cycle is an error that names the chain** — self-include and a three-file cycle, each message naming every file involved |
| 8 | **A local definition supersedes an included declaration**, while two definitions in one file are still an error |
| 9 | **An included file's `@embed` bytes do not come across** |
| 10 | **A missing include is an error naming the path it looked for** |
| 11 | **`-g` is unaffected** — `-g` does not move a byte of `.text`, and linking the two `-g` objects yields one unit per file, each naming only its own lines |
| 12 | **The suite can still fail** — four compiler mutations, each of which must be caught |

Check 12 is what makes the green run mean something. Each mutation is a `sed`
into a **copy** of the source, and each is guarded: if the `sed` stops matching
(because the line was refactored), the suite fails loudly rather than compiling
the unmutated file and quietly passing.

| mutation | what it breaks | how it is caught |
| --- | --- | --- |
| drop the top-level `include` dispatch | the syntax stops existing | the two-file build fails |
| resolve the path against the working directory | check 4's decoy is picked up | the decoy-directory build fails |
| an included function arrives as a **definition** | the body comes across | the object no longer matches the hand-written one |
| a local definition no longer supersedes | "include, then define" breaks | `supersede.ast` is rejected |

## Two design decisions worth stating

**Declarations only.** An included function becomes `external` with its body
dropped; an included global is rebuilt field by field (a `Global` owns its
initializer through a `unique_ptr`, so it cannot be copied) carrying only its
name, type, array-ness and alignment. This is C's *header* model rather than
C's "`#include` a `.c` file" trick, and the reason is the one this release is
about: a textual copy can drift, a declaration read from the definition cannot.
It also means the two files still compile to two objects and still link —
nothing about the object format, the linkers or the ABI changes, which is what
the 210/210 byte-identity below is really saying.

**A cycle needs a stack, not a set.** "Have I seen this file?" cannot tell a
cycle from a diamond: a file reached through a cycle is *part-way through being
parsed*, while one reached twice through a diamond is finished. So the parser
keeps both — a `done` set and a `stack` — shared by reference with every
sub-parser, because the stack has to outlive the sub-parser that is part-way
through it. **And the order matters**: the cycle check runs *before* the `done`
check, because a file in a cycle is in `done` too. Checking `done` first turns
every cycle into a silent no-op — which is precisely what happened during
development, when a self-include was accepted without a diagnostic and check 7
caught it.

## Evidence

| Stage | Result |
| --- | --- |
| Strict build (`-Werror`) | zero warnings, `BUILD OK` |
| `tests/include-checks.sh` | PASS (12/12) |
| `examples/include_demo_{main,defs}.ast` | build + link + run: exits 9 (`add2(7)`) |
| `tests/version-checks.sh` | PASS (6/6) |
| Four injected mutations | all four caught |
| Byte-level A/B vs v0.23.12-dev | **210/210** byte-identical (40/40 `build-elf`, 85/85 `build-obj`, 85/85 `build-so`), 0 differing |
| `tests/ci.sh` (full gate) | **47 passed, 23 skipped, 0 failed** (of 70 checks), exit 0 |
| Exit status | 0 |

The gate total rises from 45 to **47** passed (70 checks, up from 68) because
`include-checks.sh` and `version-checks.sh` join it; every suite that passed in
v0.23.12-dev still passes. The 23 skips are the e2e C-ABI suites, which
self-skip on the x86_64 sandbox by design and run for real on an AArch64
runner. Both APK gates (`native_render`, `icon_text_demo`) are green, each
verified two ways.

## Three things the gate caught on the way

**1. `--embed-dir` and `--include-dir` were both silently doing nothing.**
Making path resolution build-wide introduced a `g_srcPathOpts` published from
`main()`, but the publish sat *before* `parseArgs` ran — so both directories
were still empty when the parser asked for them. It surfaced as
`--include-dir did not supply the file`, and it would equally have broken
`@embed`: the same struct carries `embedDir`. Publishing now happens at the end
of the argument parse (and after `build-apk`'s own argv loop, which reads a
different set of options). A "build-wide" setting published before its inputs
exist is a setting that is always empty, and nothing complains about empty.

**2. A self-include was accepted silently.** The `done` check preceded the cycle
check, so the cycle-detection code was unreachable — every cycle looked like a
repeat. Only the stack distinguishes them, and only ordering the stack check
first makes it fire. Check 7 now covers both the cycle *and* the diamond,
because the fix has to preserve one while rejecting the other.

**3. The version string had two homes, and one of them was stale.** The usage
banner carried its own copy and still read `v0.23.12-dev` while the binary was
v0.23.13-dev. Nothing caught it because nothing looked — so a new
`tests/version-checks.sh` looks: the banner, the README title, the newest
`VERSION_HISTORY` entry and the presence of `VALIDATION-<version>.md` must all
agree with the one macro, and the literal must appear exactly **once** in the
source. A version you can edit in two places is a version you will edit in one.

That last failure also exposed a weaker guard next door: `embed-checks.sh`
mutates `--embed-dir` into a no-op by re-spelling one line of
`resolveEmbedPath`, and my refactor had moved that line. The suite asserts each
mutation's anchor still exists (`anchor for ignores-embed-dir appears 0 times`),
so it failed instead of silently testing nothing — which is the behaviour a
mutation test has to have. The anchor was updated to the new code.
