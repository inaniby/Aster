# Validation Report — v0.23.41-dev

**Feature: raw memory — `mmap` and `brk` — the second hard blocker on the
self-hosting route.** M0's report ended with *"No heap … the bootstrap reads
stdin and writes stdout"*, and the bootstrap's next need is bytes it can hand
back: a compiler that reads a source file in has to put a token stream and an
AST somewhere. This round adds the kernel's two ways to obtain memory —
`mmap` (x8=222) and `brk` (x8=214) — as raw `SVC #0` through the same factored
`syscallInsn` helper M0 built, and ships `examples/arena.ast` to show the whole
shape a compiler needs is a 25-line bump allocator on top. The constraint held
throughout: no libc, no external allocator, everything inside `src/aster.cpp`
as raw AArch64. This is milestone M1 of `SELFHOSTING-PLAN.md`.

```
# examples/arena.ast — the shape of a compiler's memory: one page, a cursor,
# and no allocator anywhere

let heap: ptr = 0;
let cursor: i32 = 0;

fn alloc(n: i32) -> ptr {
    let p: ptr = heap + cursor;
    cursor = cursor + n;
    return p;
}
fn reclaim() -> i32 { cursor = 0; return 0; }

fn main() -> i32 {
    let z: ptr = 0;
    heap = mmap(z, 65536, 3, 34, -1, 0);        // 64 KiB, RW, private|anon
    if (heap == z) { write(1, "MAP-FAIL\n", 10); return 1; }
    let a: ptr = alloc(16);
    let b: ptr = alloc(16);
    let c: ptr = alloc(16);
    store_u8(a + 0, 65);                        // 'A'
    store_i64(a + 8, 1234605616436508552);      // 0x1122334455667788
    ...
    write(1, a + 8, 8);                         // print A's payload
    ...
    reclaim();                                  // cursor = 0
    let a2: ptr = alloc(16);                    // ... and the same address again
    return same * 100 + tag + sum;              // exits 12, equal to arena-twin.c
}
```

```
# two generalizations of syscallInsn carry the round, and both are 64-bit rules
#   result: Ty::Ptr / Ty::I64 answers MOV Xd, X0 (an i32 still takes the W half)
#           — qemu's mappings sit near 0x4000_0081_2000, ~70 TB, where a W read
#             truncates to 0x0081_2000 and the first access faults
#   argument: the staging loop keys on tyIs64(tys[i]), so an i64 length or
#             offset rides through X like a ptr — a 4 GiB length through W
#             becomes 0, and the kernel answers EINVAL
```

## 1. Why this round exists

M0 left a compiler-bootstrap able to read bytes in (`read`/`openat`/`fstat`)
and write bytes out (`write`), but with **nowhere to put them**: memory was the
8 KiB frame, globals, and C-ABI pointers the program obtains itself. The plan's
M1 named two ways out — a global arena (`u8[1<<20]` plus a bump pointer, pure
Aster, no compiler change) or the kernel's `mmap`/`brk` — and this round takes
the second, because it is the one that *scales past a fixed image*: an arena
global is a size chosen at compile time, while `mmap` asks the kernel for
exactly as much as the parse needs and can ask again. The discipline is
unchanged: Aster still owns **no allocator**. The intrinsics hand back an
address; `examples/arena.ast` demonstrates that everything above that — a
cursor, a tag byte, a reclaim — is ordinary Aster on ordinary `store_i64`/
`load_u8`, with no runtime, no libc, and nothing new to learn.

## 2. The contract is the syscall one, in Sema and in codegen

`mmap(addr: ptr, length: i64, prot: i32, flags: i32, fd: i32, offset: i64) -> ptr`
is the **widest intrinsic the language has** — six arguments, two of them `i64`
— and `brk(addr: ptr) -> ptr` both queries (the null pointer answers the
current break without moving it) and grows (a nonzero, page-aligned address
moves it and answers the new one). Both are checked in Sema's `checkCall` and
again in `gen` by count and kind, naming the offending argument: the `i64`
positions refuse a `ptr` and a `bool` (a length is not an address), the `ptr`
positions refuse an integer (the null constant excepted, per the v0.23.26-dev
rule — and since the intrinsics type their `ptr` arguments through
`exprType`, where a bare `0` is an `i32`, the null spelling is a **named
binding**, `let z: ptr = 0;`, exactly as `examples/arena.ast` documents in its
header comment). Codegen's `callType` learns the pair — `mmap`/`brk` answer
`Ty::Ptr` — which is what makes `let heap: ptr = mmap(...)` and
`heap + cursor` type-check; it is the first registration besides `load_ptr`,
and without it the expression fell to the `i32` fallback and the declaration
was refused as a type mismatch (caught by the first smoke test, not by the
suite — the suite was written after).

## 3. Two width rules, both invisible at 32 bits

`syscallInsn` had exactly one width decision — read the result from `w0` — and
`mmap` breaks it, because an address is 64 bits and qemu hands them out around
`0x4000_0081_2000` (≈70 TB, high word nonzero). A truncated read would collapse
to `0x0081_2000` and the first `store_u8` through it would fault, so the
result read keys on the result type: `Ty::Ptr`/`Ty::I64` take `MOV Xd, X0`, an
`i32` still takes `MOV Wd, W0`. The same asymmetry exists on the argument side:
the staging loop chose its register by `tys[i]==Ty::Ptr`, so an `i64` argument
— `mmap`'s `length` and `offset` — would be staged through W and silently
truncated. The condition becomes `tyIs64(tys[i])` (i64 *and* ptr), the
generalization being one token; the proof that it matters is
`tests/heap-checks.sh`'s `mmap_huge`, a real 4 GiB mapping whose length is
`0x1_0000_0000` — truncated to 0 it draws EINVAL, the intrinsic answers `-22`
as a pointer, and the poke faults. The resident `m_mmap_result` and
`m_mmap_argwidth` probes force each width decision back to 32 bits and require
the battery to go red.

## 4. The kernel's rules are the contract

Results are the **raw kernel return**, M0's contract held: a failing call
answers `-errno` *in pointer form*. This round's case is `mmap`'s
**page-aligned `offset`** — the first cut of the file-mapping test used
`offset=8`, the kernel answered EINVAL (`-22`), and the program then read a
byte at address `-22` and died with SIGSEGV. The strace said it plainly
(`mmap(…, 0x8) = -1 EINVAL`); the fix is the test's (a two-page 8192-byte
file, mapped at `offset=4096`), and the case now pins the rule. The same
contract makes the **null check the program's job**: `-22` is not null, so
`map == z` cannot see it — a failing `mmap` must be checked against the null
constant the language already has, and `examples/arena.ast` does exactly that
(`if (heap == z) { write(1, "MAP-FAIL\n", 10); return 1; }`).

## 5. Coverage: one resident suite, `tests/heap-checks.sh`

- **(1) Strict `-Werror` rebuild** (`-Wall -Wextra -pedantic`), the CI flags.
- **(2) Locate the oracle** — `aarch64-linux-gnu-gcc` and the qemu runner (the
  same harness `syscall-io-checks.sh` uses), plus a generated 8192-byte
  two-page input file.
- **(3) 5 differential cases**, each an Aster source against a C oracle on
  stdout bytes and exit status: `mmap_anon` (one anonymous page poked at five
  offsets spanning it — 0, 1, 7, 255, 4095 — exits 165), `mmap_huge` (a real
  4 GiB `length`, exits 65), `mmap_file` (`openat`→`fstat`→`mmap` at
  `offset=4096` of the two-page file, 32 bytes read back one at a time through
  `load_u8`, exits 0), `brk_grow` (query the break, grow it a page, poke three
  offsets backwards, exits 150 — its oracle is the same raw `SVC` pair in
  inline asm, because glibc's `brk()` answers an *int* where the system call
  answers the new break), and `arena_example` (the shipped example against its
  C twin `tests/arena-twin.c`, exits 12).
- **(4) 10 rejections** — the argument contract for both intrinsics: `mmap`
  with five or seven arguments, an integer `addr`, a `ptr`/`bool` `length`, a
  `ptr` `prot`, a `ptr` `offset`, `brk` with zero or two arguments, an integer
  `brk` argument — each naming the argument it refuses.
- **(5) 2 shadowing cases** — a user `fn mmap` / `fn brk` wins over the
  intrinsic at every dispatch site (the round's new names join the twelve
  already shadow-tested).
- **(6) 5 mutation probes** — `m_mmap_num` (222→223) and `m_brk_num`
  (214→215) renumber the calls; `m_mmap_result` forces the 32-bit result read;
  `m_mmap_argwidth` stages the `i64` length through W; `m_mmap_dispatch`
  deletes the `gen` dispatch block. Each asserts both the break and the
  "before" fact, so a probe that goes blind fails the suite.

## 6. Nothing that exists moves

The new branches are keyed on the intrinsic names and reached only by a program
that calls one and has not defined a same-named function; `write`/`read`/
`openat`/`close`/`fstat` and every non-syscall program are untouched.
**`tests/rebuild-baseline-v0.23.41.sh`: 324 → 327 lines, the other 324
byte-identical** — it filters this round's `arena` rows (and the seven example
families the 309-row comparison has always filtered), asserts the 309
pre-existing rows reproduce before it writes anything, and lands the total at
327. The six baseline-filter suites (`array-address`, `array-elem-types`,
`multi-dim-array`, `precedence`, `sizeof-len`, `struct-array-field`) each gain
`^arena\.` in their FILTER; their pre-existing assertion stays 288. The
width generalization of `syscallInsn` — the one change that touches shared
code — moved not one pre-existing byte: the `write` path is `i32`-result and
`i32`/`ptr`-argument throughout, so both new conditions take their old arms
for every existing program.

The narrow-int-abi tripwire did **not** move this round (17/12, set by
v0.23.40-dev): the staging loop gained no new `loadStackOff(`/`storeStackOff(`
call site, only a wider register choice inside the existing ones.

## 7. Deliberately not included

- **No allocator, no `malloc`.** The intrinsics hand back an address; the
  bump allocator is 25 lines of Aster (`examples/arena.ast`). Aster will not
  own a heap manager, and nothing here normalises toward one.
- **No `munmap`(215), no `mprotect`(226), no generic `syscall(n, …)`.** The
  bootstrap needs to *obtain* memory, not to hand it back or re-protect it; a
  generic dispatcher is a different (and larger) design question. Both numbers
  are noted in the version history so the next round does not have to
  re-derive them.
- **No `argc`/`argv`.** `main` stays `() -> i32` and is still `_start`; stdin
  and stdout remain the bootstrap's channel, as in M0.

## 8. What this closes, and what it opens

It closes the **second** of the two hard self-hosting blockers: a bootstrap
compiler can now read its source in (M0) and put a data structure of unbounded
size in memory (M1) with no libc and no external allocator. What opens is M2 —
the Aster standard library (memcpy/strlen/a hash table over this memory,
written in Aster) — and then M3, the bootstrap compiler itself. Full CI:
**all suites green** (this round's suite registered in `tests/ci.sh` right
after `syscall-io-checks.sh`).
