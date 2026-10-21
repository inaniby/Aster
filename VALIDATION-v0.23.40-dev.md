# Validation Report — v0.23.40-dev

**Feature: raw system calls — `read`, `openat`, `close`, `fstat` — the input
side of self-hosting.** Asked *"编译器距离自举还差什么？"* the honest answer was
"~80% there in principle, but two hard blockers", and the first was blunt:
`write`(x8=64) and `exit`(x8=93) were the *only* system calls the compiler
emitted, so a program could print and quit but **never read a byte in**. This
round adds the four system calls a bootstrap needs to pull a source file in and
push an ELF out — all `SVC #0`, all zero-libc — and writes `SELFHOSTING-PLAN.md`
as the roadmap it is milestone M0 of. The constraint held throughout: no libc, no
external allocator, everything inside `src/aster.cpp` as raw AArch64.

```
# examples/copy.ast — a cat, in 256-byte chunks, on read/write/close alone

let buf: u8[256] = 0;
fn main() -> i32 {
    let n: i32 = read(0, &buf, 256);
    while (n > 0) { write(1, &buf, n); n = read(0, &buf, 256); }
    close(0);
    return 0;
}
```

```
# the numbers are the AArch64 ones, and getting them wrong is the bug that shipped
#   read    = 63   (correct on the first cut)
#   close   = 57   (correct on the first cut)
#   fstat   = 80   (NOT 79 — 79 is newfstatat; the first cut used 79 and silently
#                   stopped filling the stat buffer; pinned by the m_fstat probe)
#   openat  = 56   (there is NO plain `open` on AArch64; the first cut spelled a
#                   3-arg `open` at 56, which is openat, and failed outright)
```

## 1. Why this round exists

The bootstrap-readiness analysis found a language that could already express a
compiler's data model — structs with `ptr<自身>` self-reference, `i64` for 64-bit
ELF fields, byte memory intrinsics (`load_u8`/`store_i64`) for little-endian
serialization, global arrays up to 1,048,576 for I/O and AST buffers, recursion
(two-pass: every function is known before `check`), and `write`+`exit` for output
— but with **no way to read a byte in**. `read`/`openat`/`close`/`fstat` close
that gap with nothing but `SVC #0`; the memory and `argc`/`argv` gaps are M1 and
the stdin/stdout channel in `SELFHOSTING-PLAN.md`.

## 2. The AArch64 numbering is the load-bearing detail

`exit`(93) and `write`(64) had already pinned the asm-generic syscall table, but
the input side needed three more numbers and two of them are traps: **AArch64 has
no plain `open`** (56 is `openat(dirfd, path, flags, mode)` — four arguments,
`AT_FDCWD=-100` for the current directory), and **`fstat` is 80, not 79** (79 is
`newfstatat`). The first cut used 79 for `fstat` and a three-argument `open`; the
differential suite caught both — `fstat` silently stopped filling the stat buffer
(so `st_size` read back as 0) and `open` failed with a bad call shape. The
resident `m_fstat` mutation probe renumbers 80→79 and asserts the suite notices
the divergence, so the numbering cannot regress silently. `read`(63) and
`close`(57) were right on the first cut.

## 3. `syscallInsn` is `write`'s staging, factored once

Every intrinsic funnels through one helper — park every live temporary in the
frame, generate each argument, stage it through the scratch grid, load x0..xn,
`MOV X8, #num; SVC #0`, read the i32 result from w0, restore — the exact register
dance `write` performs because **x0/x1/x2 are simultaneously the syscall argument
registers and the first three temporaries of the w0–w15 pool**. Two of the
hazards `write` had already survived were re-learned here, and both are pinned:

- **The destination temporaries must be allocated up front and distinct.** An
  early cut allocated `ri = temp()` and `releaseTemp(ri)` inside the same loop
  iteration, so `temp()` handed back the *same* register every time — loading
  argument *i* clobbered x0 already staged for an earlier one. The strace told
  the story plainly: `read(256, 0x402000, 256)` — the fd slot held the *count*.
  Allocating all destinations first (`std::vector<int> rs; … rs[i]=temp()`) makes
  them 0,1,2,… distinct, and the `MOV Xi, Xri` become the identity moves `write`
  relies on.
- **They must be released top-down.** `releaseTemp` is strict LIFO
  (`r != nextTemp-1` is an internal error); releasing the destinations front-to-
  back threw *"temporary registers released out of order"*. Releasing in reverse
  fixed it. `write` had always released `r2; r1; r0` — the same rule, re-learned.

## 4. The contract is `write`'s, in Sema and in codegen

`Sema::callType` types each argument and answers `i32`; `gen` re-checks with
`exprIsPtr` (codegen has no `typeOf` — it reads the syntax) and dispatches only
when the program has **not** defined a same-named function, so a user `fn read`
shadows the intrinsic exactly as it shadows `write`. All four intrinsics refuse
the wrong argument count and the wrong argument kind, naming the offending
argument — 7 rejections in the suite pin this.

## 5. The results are the raw kernel return, not libc's

A failing call answers **`-errno`** — a `close` of a never-open descriptor
returns `-9`, which lands 247 in the exit status — because the intrinsic *is* the
system call, with no wrapper normalising it to `-1`. That is the honest
libc-free contract, and it is why the `close_badfd` case's C oracle uses the
same raw `SVC` in inline asm: every glibc entry point, `close()` *and* even
`syscall()`, converts `-9` to `-1` and would diverge for a reason that is not a
bug. (The oracle was `syscall(SYS_close, …)` first and still diverged; inline
asm was the only fair comparison.)

## 6. Coverage: one resident suite, `tests/syscall-io-checks.sh`

- **(1) Strict `-Werror` rebuild** (`-Wall -Wextra -pedantic`), the CI flags.
- **(2) 5 gcc-differential cases**, each an Aster source and a C source run
  against an `aarch64-linux-gnu-gcc` oracle on stdout bytes and exit status:
  `cat_stdin` (256-byte stdin cat, 1700 bytes copied), `chunked7` (7-byte reads —
  the count carried across loop iterations is what a clobbered x0 corrupts),
  `openat_read` (`openat`+`read`+`write`+`close` of a real file), `fstat_size`
  (the 8 raw bytes of `st_size` at offset 48), `close_badfd` (raw `-EBADF` → exit
  247, oracle via inline-asm `SVC`).
- **(3) 7 rejections** — the argument contract for all four intrinsics (wrong fd
  kind, wrong buffer kind, wrong count, missing `openat` mode, `close`/`fstat`
  argument kinds).
- **(4) 2 mutation probes** — `m_fstat` renumbers `fstat` 80→79 and asserts the
  suite diverges from the oracle; `m_read_dispatch` deletes the `read` dispatch
  and asserts `cat_stdin` stops compiling. Each asserts both the break and the
  "before" fact, so a probe that goes blind fails the suite.

## 7. Nothing that exists moves

The new branches are keyed on the intrinsic names and reached only by a program
that calls one of them and has not defined a same-named function. `write`/`exit`
behave exactly as before; a program that never names `read`/`openat`/`close`/
`fstat` compiles to the bytes it always did. **`tests/rebuild-baseline-v0.23.40.sh`:
321 → 324 lines, the other 321 byte-identical** — it filters this round's `copy`
rows (and `fn_type`/`cb_table`/`fn_ret`/`call-stmt`'s, which the 309-row
comparison has always filtered), asserts the 309 pre-existing rows reproduce
before it writes anything, and lands the total at 324. The six baseline-filter
suites (`array-address`, `array-elem-types`, `multi-dim-array`, `precedence`,
`sizeof-len`, `struct-array-field`) each gain `copy` in their FILTER; their
pre-existing assertion stays 288.

One more tripwire moved with it: `narrow-int-abi-checks.sh` counts the
`loadStackOff(`/`storeStackOff(` call sites that can land past the 12-bit range
and must go through the fallback-aware wrappers. The shared `syscallInsn`
staging loops add one of each (16 → 17 and 11 → 12), exactly the increment the
suite recorded for the `write` intrinsic in v0.23.21-dev (+3/+1); the suite's
comment now carries both entries. A first full-CI run caught this — 97 passed,
1 failed — and the fix is the count with its rationale, not a workaround.

## 8. Deliberately not included

- **No heap.** The bootstrap gets its memory from a global arena over
  `u8[1<<20]` buffers with a bump pointer written in Aster (M1), or later from
  `mmap`/`brk` intrinsics — never from an external allocator. Zero-dependency
  holds.
- **No `argc`/`argv`.** `main` stays `() -> i32` and is still `_start`; the
  bootstrap reads source from stdin (`read(0, …)`) and writes its ELF to stdout
  (`write(1, …)`), so the shell redirect supplies the filename.
- **No generic `syscall(n, …)` dispatcher, no `mmap`/`brk` yet.** Those are M1.
  Only the four calls a file-reading compiler needs shipped.

## 9. What this closes, and what it opens

It closes the first of the two hard self-hosting blockers (input). The second —
dynamic memory — is M1, and the analysis already established it is solvable
without touching the language (a global arena) or with one more syscall pair
(`mmap`/`brk`). What opens: a bootstrap compiler can now, today, read an Aster
source from stdin and write bytes to stdout on raw syscalls with no libc — which
is exactly the shape of `examples/copy.ast`, and exactly what `SELFHOSTING-PLAN.md`
M3's `aster.ast` will need. Full CI: **all suites green**, this round's suite
registered in `tests/ci.sh`.
