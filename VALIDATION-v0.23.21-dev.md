# Validation Report — v0.23.21-dev

**Feature: the `write(fd, buf, len)` output primitive.** One `write(2)` system
call (`x8 = 64`) added to the compiler, so a static `build-elf` program can
print without libc, without a `.so`, and without a `dlopen` host.

```
$ ./aster build-elf examples/write_hello.ast -o write_hello && ./write_hello
Hello, World!                                    # exit 0
```

## 1. Why this round exists: the process model was never the obstacle

The round began with a question, not a defect: after walking through a
hello-world that needed two files (an Aster `.so` exporting a `puts`-calling
function, plus a C host that `dlopen`ed it), the obvious question was *why*.
The answer required separating two things that looked like one:

- **`build-elf` has no libc** — by design. Its ELFs are static, carry no
  `DT_NEEDED`, and that is part of the contract the 273-line byte baseline
  pins. Its libc story is the Android one: `build-so --needed libc.so`, loaded
  by a NativeActivity host.
- **`build-elf` already had a process model.** `main` *is* `_start`
  (`elfNameOf`, `src/aster.cpp`: `return n=="main"?std::string("_start"):n`),
  and `main`'s `return` already emits `MOV X8, #93; SVC #0` — the `exit`
  system call (`src/aster.cpp`, the `isMain` epilogue).

Output was the one capability outsourced to libc for no reason deeper than
"no intrinsic existed for it". This round closes that: `write` is one more
system call, same shape as `exit`, and the `.so` path is untouched.

## 2. The feature

```c
fn main() -> i32 {
    let n: i32 = write(1, "Hello, World!", 14);
    return 0;
}
```

`write(fd: i32, buf: ptr, len: i32) -> i32`. Semantics:

- **System call, not libc.** `x8 = 64` (`write`), arguments in `x0`/`x1`/`x2`,
  byte count returned in `x0`. A static ELF stays static.
- **The type system needed no change.** `callType` already answers `Ty::I32`
  for any name absent from `functionArities` (`src/aster.cpp`), so both
  `exprType` and the semantic pass classify `write` correctly for free. Only
  two sites carry logic: Sema's `checkCall` (argument contract) and codegen's
  `Call` case (instruction emission) — exactly the `load_u8`/`store_u8`
  pattern.
- **The value is i32 in, i32 out**, like the byte intrinsics: `MOV Wd, W0`
  leaves the upper half zero, and the byte count is never negative, so
  widening it later cannot diverge. `tests/write-output-checks.sh`'s
  `i64_count` case pins exactly that.

## 3. The round's real lesson: `x0/x1/x2` are two things at once

They are the syscall argument registers **and** the first three temporaries
of the `w0–w15` pool. Three successive implementation attempts failed on that
collision, each in a different place, and each failure is now a resident
regression case:

**Failure 1 — EBADF (exit 247).** The first version moved each argument into
its syscall register as it was generated and freed its temporary. The next
argument's `gen` reused that register: the fd sat in `x0`, the buffer's `gen`
took `w0` for its own, and the syscall ran with the *buffer as the fd*.

**Failure 2 — the count summed with itself (4 instead of 6).** The second
version staged all three arguments through the frame's scratch grid
(`4160 + callDepth*256`, as `emitCallSeq` does) but then loaded straight into
`x0`. In `total = total + write(1,"ab",2)`, `gen(total)` lived in `w0`; the
argument load overwrote it; the following `add w0, w0, w1` added the byte
count to itself. The output was still correct (`ababab`, six bytes) — only
the arithmetic lied, which is the most dangerous kind of wrong.

**Failure 3 — the same, carried across iterations.** The identical shape
inside a `while` loop, where the clobbered value is the loop-carried total.

**The shipped version** borrows `emitCallSeq`'s discipline wholesale:

```cpp
const int live=nextTemp;
for(int r=0;r<live;++r)emit(storeLocal(r,1020+r));   // park every live temp
... stage three args into the scratch grid; load into fresh temps; move ...
emit(0xd2800000u|(64u<<5)|8u);                        // MOV X8, #64
emit(0xd4000001u);                                    // SVC #0
int d=temp();emit(0x2a0003e0u|uint32_t(d));          // MOV Wd, W0
for(int r=live-1;r>=0;--r)emit(loadLocal(r,1020+r)); // restore
```

A syscall preserves every register but `x0`, so the argument loading is the
only thing that can hurt — but that is exactly what an expression's live
temporaries are exposed to. The kernel was never the problem; the compiler's
own register allocator was.

## 4. `examples/write_hello.ast` — one file, one step

The round's example is the smallest complete program that prints: a single
`.ast` that builds to a static ELF and speaks for itself. Before this round
the same sentence needed the two-file `.so`-plus-host dance; that path still
exists (it is the Android story) and is not touched.

## 5. `tests/write-output-checks.sh` — four layers, all run

Registered in `tests/ci.sh` after `narrow-value-coverage.sh`.

**[1/4] Strict build.** `c++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror`
— zero warnings.

**[2/4] Tool probe.** Locates `aarch64-linux-gnu-gcc` (the independent
oracle) and a runner (`qemu-aarch64` or an AArch64 host); SKIPs cleanly
without either. A native cc on an x86 box is detected and rejected.

**[3/4] Differential battery — 16 cases, three channels each.** Every case
has an Aster source and a C twin compiled by
`aarch64-linux-gnu-gcc -O2 -fwrapv` (the shadowing twins add `-fno-builtin`,
so gcc does not fold their calls); both run under qemu; **stdout bytes,
stderr bytes and the exit status** are all compared (`cmp -s` on the two
captured streams, numeric compare on the statuses). A wrong fd, a wrong
length, a wrong buffer or a wrong count each fail a case. No expected value
is hand-computed anywhere — gcc is the oracle on every channel, which is the
discipline `narrow-value-coverage.sh` established and this suite extends from
one channel (exit code) to three.

| Case | What it pins |
|---|---|
| `hello_stdout` | the basic path, 14 bytes on fd 1 |
| `hello_stderr` | fd 2 — the fd argument really is the fd |
| `zero_len` | a zero-length write returns 0 and prints nothing |
| `bss_bytes` | the buffer is a run-time-filled global array, not a literal |
| `offset_write` | `p + 2` is a *byte* offset (ptr+int does not scale) |
| `rodata_two` | two literals — two independent `.rodata` bases |
| `i64_count` | the count consumed at 64-bit width |
| `accumulate` | **COVERAGE_MAP** — failure 2 |
| `loop_multi` | **COVERAGE_MAP** — failure 3 |
| `nested_expr` | **COVERAGE_MAP** — two writes in one expression |
| `helper_call` | `write` in a non-main function, a call among the arguments |
| `shadow_write` | a user-defined `fn write` is an ordinary call, not the intrinsic |
| `shadow_write_same_sig` | same name, *same signature* — the user's still wins |
| `shadow_load_u8` | the shadowing rule covers the pre-existing intrinsics too |
| `shadow_load_ptr` | ... including the one whose return type is `ptr` |
| `shadow_store_u8` | ... and the store side |

**[3/4b] Rejections — 4 cases.** The argument contract: a string length, a
string fd, an integer buffer, two arguments — each rejected with the
diagnostic that names the offending argument.

**[4/4] Coverage map.** `accumulate`, `loop_multi`, `nested_expr` are
declared in the case list *and* asserted present by name. Delete one and the
map itself fails: the three failures above must never be deletable
silently.

## 6. The defect the first full CI run caught: an intrinsic swallowed the user's function

With the suite written and the baseline rebased, the first full `ci.sh` came
back **76 passed, 2 failed of 78**. One failure was the new feature's own
suite-mates (the source-guard counts, below); the other was not the new
feature at all:

```
runtime-bounds-checks.sh:
error: write expects (fd: i32, buf: ptr, len: i32) at 8:18
```

That suite's helper function is literally named `write`. The intrinsic
dispatch matched on the **name alone** — in `callType`, in Sema's `checkCall`,
and in codegen's `gen` `Call` case — so any program defining
`fn write(...)`, `fn load_u8(...)`, `fn load_ptr(...)` or `fn store_u8(...)`
had its own function silently replaced by the intrinsic. Four releases of the
intrinsic family had never met this, because nothing had ever called one
`write`; the new primitive created the collision, and the full CI — not the
feature's own suite — is what found it. A suite testing only the new feature
would have shipped it.

**The fix** is one rule at all three sites: `&&!arities.count(e.name)` —
the user's function wins, always. `load_ptr`'s pointer-return registration
in `compileProgram` became conditional on the same question instead of
unconditional, and the `exprYieldsPtr` special case that hard-coded
`load_ptr` was deleted in favour of the set mechanism. Five shadowing cases
(`shadow_write`, `shadow_write_same_sig` — the same signature, so only the
name rule can tell them apart — plus one per pre-existing intrinsic) keep it
fixed, each gcc-differential with `-fno-builtin`.

The second failure was the source guard doing its job:
`narrow-int-abi-checks.sh` pins the number of `loadStackOff(` /
`storeStackOff(` call sites in `aster.cpp` (13/10), and the `write` path adds
three load sites and one stage site — updated to 16/11 with a comment
explaining where each new site comes from.

## 7. What this deliberately does not do

- **No libc in `build-elf`.** That road runs through `__libc_start_main` —
  TLS, stdio buffers, the atexit chain — and would trade the
  static-self-contained contract (and every existing ELF's structure) for one
  function.
- **No `exit_group` (94).** `exit` (93) is what `main`'s return has always
  emitted; changing it would re-record every ELF row in the baseline for zero
  benefit while the language has no threads.
- **No change to the `.so` path.** `--needed libc.so` plus a host remains the
  Android story.

## 8. Byte identity: 276 of 276

The A/B baseline (`tests/baseline/v0.23.5-dev/example-hashes.txt`, asserted
by `tests/struct-checks.sh` [4/8]) grew **273 → 276 lines**: three new rows
record `examples/write_hello.ast` across `build-so` / `build-elf` /
`build-obj --pic`. The regeneration diff is exactly those three lines — the
273 pre-existing rows are byte-identical, which is expected twice over: the
version constant is not embedded in generated objects, and the new code path
is reachable only through the new `write` name, which no pre-existing example
uses.

## 9. Verification log

| Step | Result |
|---|---|
| Strict `-Werror` build of the modified compiler | clean |
| `write_hello.ast` under qemu | `Hello, World!`, exit 0, 14 bytes |
| Return value of `write` | 14 (the count), not 0 or EBADF |
| Boundary matrix (fd 2, len 0, `.bss` buffer, loop, nested, helper, offset, i64 count) | all correct before the suite was written |
| `struct-checks.sh` [4/8] baseline | **276 recorded outputs reproduced byte for byte** |
| `tests/write-output-checks.sh` | **all layers pass** (16 differential + 4 rejections + 3 map) |
| Failure modes 1–3 reproduced, then fixed | each was observed as a real wrong answer before the fix |
| First full CI (before the fixes) | **76 passed, 2 failed** — `runtime-bounds-checks.sh` (intrinsic swallowing a user's `fn write`), `narrow-int-abi-checks.sh` (stale guard counts) |
| Shadowing defect fixed, guards updated | `callType`/`checkCall`/`gen` + conditional `load_ptr` registration; 5 new differential cases |
| `runtime-bounds-checks.sh` re-run after the fix | **all checks pass** — the suite's own `fn write` helper is an ordinary call again |
| `narrow-int-abi-checks.sh` re-run after the fix | **all checks pass** — guards at 16/11 |
| Final full CI | see §10 |

## 10. Full CI

```
========================================
CI SUMMARY: 78 passed, 0 skipped, 0 failed (of 78 checks)
========================================
```

| CI | v0.23.20-dev | v0.23.21-dev |
|---|---|---|
| Result | 77 passed / 0 skipped / 0 failed | **78 passed / 0 skipped / 0 failed** |
| Checks | 77 | 78 (+1: `write-output-checks.sh`) |
| Baseline rows | 273 (261 unchanged + 12 new) | 276 lines (273 unchanged + 3 new) |
| New resident suite | `compiler-other-faces-audit.sh` | `write-output-checks.sh` |

The first full run of this release was **76 passed, 2 failed** (§6); both
failures were fixed in the source and the suite, and the clean rerun above is
the number of record.

## 11. What this unblocks

- **Single-file printing.** `write` + `main`'s `exit` is a complete, host-free
  I/O pair for the static ELF path. Debugging output, self-checks and
  diagnostics no longer require the `.so`+host dance.
- **The shape for future system primitives.** `write` is the first intrinsic
  that is a syscall rather than a memory access; the park-stage-move-restore
  pattern it established is the template any future syscall-taking intrinsic
  must follow, and `write-output-checks.sh`'s coverage map is where its
  regressions live.
- **Still open, in the order the difficulty audit argued:** hexadecimal
  literals and an optional `else` (pure syntax relief); the narrow-memory
  intrinsics `load_u16`/`load_i64`/`store_u16`/`store_i64` (the last cell of
  the round-4 narrow matrix — today reading a `u16`/`i64` through a pointer
  is eight hand-assembled `load_u8`s with a `<< 32` trap in the middle);
  function-pointer calls (a language-design round of its own).
