# Validation Report — v0.23.47-dev

**Feature: the closed loop — `SELFHOSTING-PLAN.md` M4, the bootstrap compiler
compiling itself.** This is the round the whole M0–M3 arc existed for: the host
compiler builds `bootstrap/aster.ast`, that binary compiles its own source, and
the result compiles the source again to a **byte-identical** binary — the fixed
point `boot2 == boot3 == boot4`. The host `src/aster.cpp` is again changed in
exactly one place, the version constant; everything else lives in
`bootstrap/aster.ast`, `tests/codegen-twin.c` and the suite. Three real defects
stood between M3d's green suite and the closed loop, and all three are fixed on
**both** sides of the differential:

```
// bootstrap/aster.ast — the fixed point, end to end (x86 host, qemu-aarch64):
//   aster build-elf bootstrap/aster.ast -o boot.host      # stage 1, host-built
//   boot.host < bootstrap/aster.ast > boot2.elf           # stage 2, self-built
//   boot2.elf < bootstrap/aster.ast > boot3.elf           # stage 3
//   boot3.elf < bootstrap/aster.ast > boot4.elf           # stage 4
//   $ md5sum boot2.elf boot3.elf boot4.elf
//   039861a5347af8b7d9843ed14c68c6fb  boot2.elf
//   039861a5347af8b7d9843ed14c68c6fb  boot3.elf
//   039861a5347af8b7d9843ed14c68c6fb  boot4.elf
```

## 1. Why this round exists

M3d shipped a stage that lowers Aster to AArch64 and an ELF writer that
produces a standalone `ET_EXEC`. `CODEGEN-SPEC.md` §13 had explicitly parked
the last step — *"不在 M3d 范围（属 M4 闭环自举）：`bootstrap/aster.ast` 自身编译"*
— because the stage declared four `extern fn` (`strlen`/`utoa`/`itoa`/`memcmp`)
and a standalone image cannot resolve an external symbol (§10 C9). M4 closes
that, and closing it surfaced two latent codegen bugs that no green suite had
any way to see, because the twin is a *byte* oracle: it agrees with whatever
the stage emits, including a wrong emission both sides share.

## 2. The three fixes

### 2.1 Self-containedization — the stage links against nothing

The four library routines the stage used to import are now written in the
stage's own subset, immediately above `bputraw` (the emitter that consumes
them): `reverse_digits` (carried along because `utoa` ends by calling it),
`utoa`, `itoa`, `memcmp` — same bodies as `stdlib/aster_std.ast`, so the stage
prints byte for byte what it printed when the library supplied them. `strlen`
was declared but never called, so it is gone. The stage's own source now needs
no external symbol, and a standalone `ET_EXEC` of it is legal:

- `build-obj bootstrap/aster.ast` → **35551 instructions, 210 functions, 628
  globals** (M3d's final: 35197/204/627; the +6 functions are the four inlined
  routines plus the two the short-circuit fix adds, §2.3).
- `link-obj boot.o` alone → rc=0, one UND symbol (the ELF null), 142208 text
  bytes. The gate's delivery shape follows: `tests/codegen-checks.sh` links
  `verifybin` from `boot.o` **alone** — the old two-object shape would now be a
  duplicate-symbol *failure* (`memcmp` and friends defined on both sides), which
  is the self-containedization proving itself at link time. The library keeps
  its own suite (`tests/stdlib-checks.sh`); this one is about the stage.

### 2.2 `a % b` — the MSUB operand order

`gen_combine` lowered `a % b` as `SDIV/UDIV` into a quotient `q`, then
`emit_msub(a, a, b, q)`. The helper's signature is `emit_msub(rd, rn, rm, ra)`
— the architectural `MSUB Rd, Ra, Rn, Rm` with `Ra` **last** — so the old call
emitted `MSUB a, q, a, b`, i.e. `a = q − a*b`, not `a = a − q*b`. Every modulo
answered a wrong number. The call is now `emit_msub(a, q, b, a)`
(`MSUB a, a, q, b` → `a = a − q*b`), in the stage **and** in the twin, which had
the same signature and the same slip. This is the bug class a byte differential
is blind to: both sides emitted the same wrong word, so the gate stayed green
while the arithmetic was wrong. It was caught by an arithmetic probe — `41 % 7`
answering something other than 6 — and pinned after the fix on both sides
(`qemu-aarch64` exit 6 from host-built and self-built binaries alike, §5).

### 2.3 `&&` / `||` — true short-circuit, or the stage cannot compile itself

The blocker that actually broke the self-compile: `gx_push_bin` pushed **both**
operands of `E_And`/`E_Or` before the combine ran, so the right operand was
evaluated even when the left had already decided the result. On the stage's own
source that is fatal, not merely impure: `reduce_prefixes` guards its operator
stack with `while (osp > bottom && oprec[osp - 1] == 11)` — with `osp == 0`,
`bottom == 0`, the left conjunct decides and the right conjunct reads
`oprec[-1]`. The out-of-bounds load feeds `uxtw`, which sign-extends the
garbage to a wild index, and the stage dies with **SIGSEGV (rc=139) on any
input** — which is exactly what the first self-built `boot2` did, while the
host-built binary (same source, different backend) was fine.

The fix gives the two operators a real lazy right operand, on both sides:

- `gx_push_logical(n, wt)` pushes a **state-2 logical frame** plus **only the
  left operand** (`gx_state[top]=2`, left at `TY_I32`); `gx_dispatch` routes
  `E_And`/`E_Or` there instead of `gx_push_bin`.
- `gen_expr_at`'s LIFO loop grows `if (st == 2) { gen_logical(n, wt); continue; }`
  beside the state-1 combine case.
- The new `gen_logical` emits the comparison of the already-computed left side,
  presets the answer to the value the operator takes when the left decides
  (`0` for `&&`, `1` for `||`), branches over the right operand
  (`B.EQ`/`B.NE` to a fresh `lskip`), evaluates the right operand **inside the
  fall-through** via a nested `gen_expr_at(r, TY_I32, gx_top)` (the nested-base
  rule of CODEGEN-SPEC §6.1), moves it into the answer register, frees it, and
  places `lskip`. The old `E_And`/`E_Or` block inside `gen_combine` is gone.
- Both operands still normalise to 0/1 (the §6.2 uniform rule), so `a && b`
  answers an `i32` bool exactly as before — only the *evaluation order*
  changed. The stage's own source is the witness: the same
  `osp > bottom && oprec[osp-1] == 11` now compiles to a compare-and-branch
  that skips the `oprec` read, and the self-compile reaches the end.

The twin (`tests/codegen-twin.c`) mirrors all four edits, and the gate holds the
two together: `ALL CODEGEN CHECKS PASSED` (§5) — every accepted program still
byte-identical, which is the frozen criterion of CODEGEN-SPEC §13.2.

## 3. One environmental trap, named so it never costs an afternoon again

`qemu-aarch64` **silently exits 1 on an ELF whose file mode is not executable**
— no syscall, no diagnostic, nothing in `-strace` or `-d int`; the guest never
starts. Products written through a shell `>` are mode 644, so a correct binary
"fails" while a byte-identical copy with `chmod +x` runs. The M3d notes record
the same trap from the other side ("qemu 要求 ELF 文件有可执行权限"). This round
hit it as a false alarm: two files with the *same md5* disagreed on exit status
until `ls -l` showed `755` vs `644`. **Any runtime comparison of a produced ELF
must `chmod +x` it first** — the runtime checks in §5 all do.

## 4. What the suite proves (resident, `tests/codegen-checks.sh`)

Unchanged in shape, one delivery change (§2.1), all six stages green:

| Stage | Result |
| --- | --- |
| 1/6 strict host build (`-Werror`) | PASS |
| 3/6 generated-table freshness | PASS |
| 4/6 delivery shape — `build-obj` + `link-obj` (boot.o alone) + twin build | PASS |
| 4/6 zero-dependency — exactly 1 UND (the ELF null) | PASS |
| 5/6 differential over `examples/*.ast` + `tests/codegen-fixtures/*.ast` | **115 programs: 48 byte-identical on accept, 67 both rejected, 0 divergence** |
| 6/6 mutation probes against `bootstrap/aster.ast` | **7/7 diverge from the twin** |

The probes (syscall number, main's return path, the `exit` intrinsic's `ic_sig`
entry, the `BL` opcode, bit 4 of `B.cond`, `e_entry`, the `.rodata` base) still
apply and still diverge after all three fixes — the fixes moved code the probes
do not target.

## 5. The closed loop, measured

All on the x86 host under `qemu-aarch64` (`tests/run-aarch64.sh`), all products
`chmod +x`ed (§3).

**The fixed point.** `boot.host` (host-built, `build-elf`) compiles
`bootstrap/aster.ast` to `boot2.elf` — **rc=0, no SIGSEGV**, 218328 bytes.
`boot2.elf` compiles the source to `boot3.elf` (rc=0), `boot3.elf` to
`boot4.elf` (rc=0), and `boot2 == boot3 == boot4` byte for byte (md5
`039861a5347af8b7d9843ed14c68c6fb`). The stage is a fixed point of its own
codegen: compiling its own source again changes nothing.

**The self-built compiler is the oracle's equal.** `boot2.elf` run over the
whole corpus against the C twin: **115 programs, 48 byte-identical on accept,
67 both rejected, 0 divergence** — the same numbers the gate gets from the
host-built `verifybin`. The binary that compiled itself agrees with the
independent twin exactly where the host-built one does.

**Runtime equivalence with the host.** Every corpus program both sides accept
is built by the host compiler and by `boot2.elf`, both products run under
qemu, exit code **and** stdout compared: **47/47 identical** (the 48th accepted
program, `exit_intrinsic.ast`, exercises the `exit()` intrinsic the bootstrap
has and the host does not, so the host cannot build it — `boot2`'s product
exits 42 as it should). The minimal chain of CODEGEN-SPEC §13.1 holds:
`arithmetic.ast` (`6*7-42` → 0), `write_hello.ast` (stdout `Hello, World!`),
and the modulo probe `41 % 7` → 6 from both toolchains (§2.2).

**What is intentionally *not* byte-equal.** `boot2.elf != boot.host`: the
subset backend materialises addresses as `mov`+`movk`×3 where the host uses
`adrp`+`add` (CODEGEN-SPEC §11, ten deliberate differences), and the products
likewise differ from the host's `build-elf` output — two `st_size` bytes in
`.symtab` on `return_42`, the symbol size written in words rather than bytes.
Neither difference reaches a loadable byte; the differential that governs is
twin ↔ stage, and it is green on both the host-built and the self-built stage.

## 6. Reproduction

```sh
# 0) the resident gate (builds everything from source, ~1 min)
sh tests/codegen-checks.sh          # ALL CODEGEN CHECKS PASSED

# 1) the closed loop
g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o aster
./aster build-elf bootstrap/aster.ast -o boot.host
sh tests/run-aarch64.sh ./boot.host < bootstrap/aster.ast > boot2.elf
sh tests/run-aarch64.sh ./boot2.elf < bootstrap/aster.ast > boot3.elf
sh tests/run-aarch64.sh ./boot3.elf < bootstrap/aster.ast > boot4.elf
md5sum boot2.elf boot3.elf boot4.elf          # three equal digests

# 2) the self-built compiler against the twin, over the corpus
#    (same three-way shape as the suite's stage 5/6, with boot2.elf)
```

## 7. Files

- `bootstrap/aster.ast` — self-containedization (§2.1: the four routines
  inlined, the extern declarations and the stale M3b build-shape header
  replaced); the MSUB operand order (§2.2); `gx_push_logical` /
  `gen_logical` / state-2 frames for `&&` and `||` (§2.3).
- `tests/codegen-twin.c` — the MSUB operand order and the short-circuit fix,
  mirrored.
- `tests/codegen-checks.sh` — the delivery shape: `verifybin` links from
  `boot.o` alone (the mutants likewise), comments updated.
- `bootstrap/CODEGEN-SPEC.md` — the M3d "out of scope, M4 will close it" note
  and the #261 verifybin description updated to the self-contained shape.
- `src/aster.cpp` — the version constant only.
