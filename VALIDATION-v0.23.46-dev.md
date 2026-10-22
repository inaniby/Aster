# Validation Report — v0.23.46-dev

**Feature: the fourth and final stage of the bootstrap compiler itself — code
generation and ELF emission — and, like M3a/M3b/M3c, a round with no compiler
change at all.** `SELFHOSTING-PLAN.md` M3d takes the AST that M3c type-checks and
lowers it: one Aster source in on **stdin**, a static AArch64 `ET_EXEC` ELF out
on **stdout**. On failure a single `aster: error: <Cxx> at L:C` reaches stderr
and **no bytes** reach stdout, exit status 1. The contract was frozen *before*
the implementation (`bootstrap/CODEGEN-SPEC.md`, 13 sections, 526 lines, every
instruction encoding verified against `aarch64-linux-gnu-as` + `objdump`). The
only edit to `src/aster.cpp` is the version constant.

```
// bootstrap/aster.ast — the driver, after #261 rewired it (the stage no longer
// dumps the AST; it emits an ELF).
fn main() -> i32 {
    let rc: i32 = read_source();
    if (rc != 0) { return rc; }
    rc = lex();
    if (rc != 0) { return rc; }
    let prog: i32 = parse_program();
    if (prog == 0 || perr != 0) { return 1; }
    if (sema(prog) != 0) { return 1; }
    rc = cg_collect(prog);
    if (rc != 0) { return rc; }
    rc = cg_gen_program(prog);
    if (rc != 0) { return rc; }
    rc = elf_emit(prog);
    if (rc != 0) { return rc; }
    flush_out();
    return 0;
}

// bootstrap/aster.ast — ic_sig, the intrinsic signature table. The low three
// bits are the arity, then one 3-bit type tag per argument, then the syscall
// number from bit 21 up (0 = a memory-family intrinsic, which has no number).
fn ic_sig(ic: i32) -> i32 {
    if (ic == IC_LOAD_PTR)  { return 1 | (TY_PTR << 3); }
    if (ic == IC_LOAD_I64)  { return 1 | (TY_PTR << 3); }
    if (ic == IC_LOAD_U8)   { return 1 | (TY_PTR << 3); }
    if (ic == IC_LOAD_U16)  { return 1 | (TY_PTR << 3); }
    if (ic == IC_STORE_I64) { return 2 | (TY_PTR << 3) | (TY_I64 << 6); }
    if (ic == IC_STORE_U8)  { return 2 | (TY_PTR << 3) | (TY_I32 << 6); }
    if (ic == IC_STORE_U16) { return 2 | (TY_PTR << 3) | (TY_I32 << 6); }
    if (ic == IC_WRITE)     { return 3 | (TY_I32 << 3) | (TY_PTR << 6) | (TY_I32 << 9) | (64 << 21); }
    if (ic == IC_READ)      { return 3 | (TY_I32 << 3) | (TY_PTR << 6) | (TY_I32 << 9) | (63 << 21); }
    if (ic == IC_OPENAT)    { return 4 | (TY_I32 << 3) | (TY_PTR << 6) | (TY_I32 << 9) | (TY_I32 << 12) | (56 << 21); }
    if (ic == IC_CLOSE)     { return 1 | (TY_I32 << 3) | (57 << 21); }
    if (ic == IC_FSTAT)     { return 2 | (TY_I32 << 3) | (TY_PTR << 6) | (80 << 21); }
    if (ic == IC_MMAP)      { return 6 | (TY_PTR << 3) | (TY_I64 << 6) | (TY_I32 << 9) | (TY_I32 << 12) | (TY_I32 << 15) | (TY_I64 << 18) | (222 << 21); }
    if (ic == IC_BRK)       { return 1 | (TY_PTR << 3) | (214 << 21); }
    return 1 | (TY_I32 << 3) | (93 << 21);   // IC_EXIT
}
fn ic_argc(s: i32) -> i32 { return s & 7; }
fn ic_argty(s: i32, i: i32) -> i32 { return (s >> (3 + 3 * i)) & 7; }
fn ic_nr(s: i32) -> i32 { return (s >> 21) & 255; }
```

## 1. Why this round exists

M3 is the bootstrap compiler itself, built stage by stage with no compiler
change at any step. M3a (lexer) turned a source into a token stream. M3b (parser)
turned that stream into a tree. M3c (semantic pass) turned the tree into a
*guarantee* — every remaining error was a type error, and the dump was
provably M3b's. All three wrote text to stdout.

M3d is where the stage stops talking about programs and starts producing them.
That is a different kind of claim, and it needs a different kind of evidence:
"the two implementations print the same bytes" is now "the two implementations
emit the same *machine code*", and a wrong byte is no longer a wrong character
in a listing, it is a program that crashes under qemu. So the contract was
frozen first (`CODEGEN-SPEC.md`), the encoders were checked against `as` before
any of them were wired, and the differential was raised from "same dump" to
**byte-identical ELF on every accepted program**.

## 2. The contract frozen before the code

`bootstrap/CODEGEN-SPEC.md` (13 sections, 526 lines) pins what both
implementations must do, and it was written before the lowering existed:

- **Three passes.** `cg_collect` (string and global address allocation, function
  labels, the runtime-init list), `cg_gen_program` (linear expansion into
  `textw: i32[262144]`), `elf_emit` (fixup backfill plus the symbol, string and
  section tables, once every address is known).
- **Seven type tags** with their width and signedness rules — mirroring the
  host's `gen(want)` consumer-width propagation, with `SXTW` where an i32 is
  consumed as a 64-bit value and unsigned condition codes for `u8`.
- **An AAPCS64 subset**: arguments in `X0`–`X7`, stack arguments at
  `[SP+8*(k-8)]`, `main` compiled as `_start`, and every return path lowered to
  `MOV X8,#93; SVC #0`.
- **A 1024-slot × 8 B frame layout**: 0..31 outgoing arguments, 32..531
  parameters and locals, 800..899 the call-scratch grid, 900..949 live-temporary
  spill, 1022 the call-result transfer slot, 1023 `X30`.
- **Iterative `gen_expr`** — an explicit work stack, because a `dense.ast`-class
  left-associative chain of 30k+ nodes would blow the bootstrap's own call stack
  (the host `build-elf` *does* segfault on that input at rc=139; the bootstrap's
  iterative walk handles it, rc=184).
- **25 expression forms and 9 statement forms**, lowered node by node, with the
  pointer asymmetry spelled out: `p ± integer` is a byte offset (`SXTW`), while
  `p[i]` scales by the element width (`UXTW #sh`).
- **15 intrinsics** (§8) and their signatures.
- **A fixed-base ELF layout** (§9) so that no address fixup is ever needed.
- **The `C1`–`C15` error catalog** (§10), each entry anchored to a host message
  where one exists.
- **The 10 deliberate divergences from the host's `build-elf`** (§11) — recorded,
  not fixed.
- **The byte-identical twin clause** (§12) and **the self-hosting criteria** (§13).

## 3. Why three passes and not one

The addresses are needed before the bytes are, and the bytes are needed before
the ELF header is. `cg_collect` walks the program and assigns every string a
`.rodata` offset, every global a `.data`/`.bss` address, every function a label,
and records which globals need runtime initialisation. `cg_gen_program` then
lowers each function into `textw`, freely emitting `BL <label>` and
`ADRP`-free absolute addresses because the bases are already fixed — and
registering a fixup wherever a branch distance is not yet known. `elf_emit`
finally back-patches those fixups (`B.cond` imm19, `B`/`BL` imm26) and writes the
sections, the three `PT_LOAD` segments and the tables.

The split is what makes the fixed-base layout possible, and the fixed-base
layout is what makes a one-pass ELF writer correct: with `.text@0x401000`,
`.rodata@0x600000` and `.data@0x800000` known before the first instruction is
emitted, there is no relocation to resolve later and nothing to rewrite.

## 4. The fifteen intrinsics

| Family | Intrinsics | Number |
| --- | --- | --- |
| syscall (8) | `write` `read` `openat` `close` `fstat` `mmap` `brk` `exit` | 64, 63, 56, 57, 80, 222, 214, 93 |
| memory (7) | `load_ptr` `load_i64` `store_i64` `load_u8` `store_u8` `load_u16` `store_u16` | — |

`exit` (93) is the one the bootstrap adds that the host has no builtin for —
the host's `main` return *is* the exit. All fifteen funnel through one factored
argument-staging path: park the live temporaries, evaluate each argument into the
scratch grid, load `x0..xn`, `MOV X8,#nr; SVC #0`, read the result back at the
intrinsic's own result width (a `ptr`/`i64` result through `X`, an `i32` result
through `W` with `SXTW` when the consumer wants 64 bits), then restore.

M3c skips signature checking for intrinsics, so codegen performs it (`ic_check`):
arity and per-slot type, with messages mirroring the host verbatim —
`<name> expects a ptr argument` for the single-argument memory family, and the
host's own ordinal spellings ("first argument", "sixth argument") for the rest.

## 5. The ELF image

| Field | Value |
| --- | --- |
| `.text` vaddr / file offset | `0x401000` / `0x1000` |
| `.rodata` vaddr | `0x600000` |
| `.data` vaddr | `0x800000` |
| `.bss` | `alignUp(0x800000 + data_size, 8)` |
| segments | three `PT_LOAD`: R+X, R, R+W |
| `e_entry` | `0x401000` — always, whether or not there is a stub |
| `e_machine` | 183 |

When any global has a non-constant initialiser, the entry is a stub —
`BL __aster_init; B main` — and `__aster_init` assigns those globals in
declaration order. Otherwise `main` sits at offset 0. Either way `e_entry` is
`0x401000`, which is why the value is a constant in the writer and not a
computed field.

The section list is `null`, `.text`, `.rodata`?, `.data`?, `.bss`?,
`.symtab`, `.strtab`, `.shstrtab`, with `e_shstrndx` pointing at the last. The
symbol order is pinned: null, `_start`, `__aster_init`?, functions in emission
order (`main` first, then source order), then globals in symbol-row order. A
function symbol's value is `0x401000 + word_offset*4` and its size is
`word_count*4`.

## 6. The error catalog `C1`–`C15`

| | Message | Anchor |
| --- | --- | --- |
| C1 | `break used outside a loop` | host |
| C2 | `continue used outside a loop` | host |
| C3 | `<fn> may fall through without returning i32; …` | host `:4903` |
| C4 | `expression too complex: temporary register limit exceeded` | host `:2429` |
| C5 | `invalid pointer arithmetic: expected ptr +/- i32 or i32 + ptr` | host `:3649` |
| C6 | `only == and != are defined for a ptr` | host `:4387` |
| C7 | `the arguments of this call need more scratch space than the frame provides` | host `:4162` |
| C8 | `nested function-call arguments exceed compiler limit (100 scratch slots)` | host `:4180` |
| C9 | `cannot call external function: <name>` / `cannot reference external global: <name>` | **new** (the host reports this at link time) |
| C10 | `no main function: this backend emits a standalone ELF and needs an entry point` | **new** |
| C11 | `too many local declarations (limit 500, including parameters)` | mirrors M3c S21 (defensive) |
| C12 | `internal compiler error: …` (temp leak / invalid frame slot / walk overflow) | host's own wording |
| C13 | capacity guards: `.text exceeds the 1 MiB instruction buffer`, `.rodata exceeds its 2 MiB window`, `.strtab exceeds its 1 MiB window`, `too many symbols`, `fixup table overflow`, `too many labels`, `loops nested too deeply (limit 64)`, `global data exceeds the address space` | **new** |
| C14 | `type mismatch initializing global '<name>': expected <T>, got <U>` | host `:6527` |
| C15 | intrinsic argument validation (the §8 message set) | host `:3170-3210,5980-6043` |

C1/C2/C3 are positioned before any instruction is emitted, so a rejection
leaves stdout empty — the two-phase rule M3b and M3c established, carried into
codegen.

## 7. The oracle is independent by construction

`tests/codegen-twin.c` re-implements `CODEGEN-SPEC.md` in C, and differs in
shape wherever the spec leaves room:

- its node graph is **0-based** (`-1` = none) where the bootstrap's handles are
  1-based (`0` = none), with `NK`/`NF`/`NN`/`NT`/`NTY`/`ETY`/`EAR` macros mapping
  `-1` to `0` so the ported logic stays readable;
- its temporary pool is a LIFO free list over `X0`–`X15`;
- its fixup table is explicit rather than folded into the text stream;
- it lowers expressions with an explicit work stack, as the bootstrap does, but
  written in C against a different AST.

It is built under `-std=c11 -O2 -Wall -Wextra -Werror -fwrapv -fno-builtin -I.`
— the same strict flags every twin in this project carries — and it does not
read `bootstrap/aster.ast`. The only knowledge the two share is the frozen spec
and the node numbering established by the earlier stages.

The clause is `CODEGEN-SPEC.md` §12: on any program **both** sides accept, the
two ELF outputs are byte-identical; on any program either side rejects, the exit
status and the diagnostic agree. Any divergence is a defect in one side, and the
referee rule is fixed in advance — a bootstrap-side defect is fixed in the
bootstrap, a twin-side defect in the twin, and an ambiguous spec is fixed in the
spec first and then in both.

## 8. What the differential proved

Bringing the twin up to byte-identical found defects on **both** sides, which is
what an independent oracle is for:

- **A real bootstrap bug** (fixed in this milestone's earlier work): `cg_globals`
  mis-counted the address cursor when one global in the file was `extern`,
  shifting the addresses of the globals behind it.
- **Three twin-side bugs**, each found because the differential disagreed: the
  `ic_sig` argument slots for the load family were written as the *element* type
  (`TY_U8`, `TY_I64`) where the bootstrap uses `TY_PTR` for all of them, which
  rejected `string_literal_exec`, `arena`, `narrow_mem` and
  `pixel_offset_selfcheck` with a bogus "expects a ptr argument"; the leaf
  branches used the *call-level* `want` width instead of the *per-node* `wt`, so
  a narrow immediate inside a wide expression was emitted at the wrong width and
  lost its `SXTW`; and the symbol-emission loops read `st_kind[c]` with a node
  index where a symbol row was meant, which silently dropped non-`main`
  functions from the text and the symbol table.

The final state: **115 programs — 48 byte-identical on accept, 67 rejected by
both, 0 divergence.** Every program the bootstrap accepts, the twin accepts and
matches to the byte; every program one rejects, the other rejects too.

## 9. Coverage: one resident suite, `tests/codegen-checks.sh` [6/6]

| Phase | What it asserts |
| --- | --- |
| [1/6] | a strict `-Werror` rebuild of the host compiler (the tool that builds the stage) |
| [2/6] | an AArch64 runner exists (`qemu-aarch64`, or a native AArch64 host) — otherwise a clean SKIP |
| [3/6] | the generated name tables are what `gen_parser_names.py` / `gen_lexer_names.py` produce |
| [4/6] | the delivery chain: `build-obj bootstrap/aster.ast` + `build-obj stdlib/aster_std.ast` + `link-obj` → `verifybin`; the twin's strict build; **zero dependency** (exactly one UND symbol, the ELF null) |
| [5/6] | the three-way differential over `examples/*.ast` + `tests/codegen-fixtures/*.ast` |
| [6/6] | 7 mutation probes against `bootstrap/aster.ast` |

The suite replaces the retired `tests/parser-checks.sh`. That suite's central
pin was the *AST self-parse* — the stage reading its own source and producing a
byte-identical dump. M3d removes the dump entirely (`main()` is now the codegen
chain), so the pin had to be replaced rather than dropped: **the ELF
differential is the replacement**. It is a strictly stronger pin, because it
compares emitted machine code rather than a textual rendering of a tree.

The corpus is 110 shipped examples plus 5 fixtures in
`tests/codegen-fixtures/`. The fixtures exist so the gate is self-contained —
they are the minimal accepted shapes that the shipped examples happen not to
cover in isolation: a bare `return`, an unused `extern` global (which pins the
`cg_globals` cursor bug), runtime-initialised globals with a rodata string,
arrays and `write`, and the `exit` intrinsic.

Measured on the current tree:

```
[4/6] PASS: emitted AArch64 ELF64 ET_REL object (35187 instructions, 204 functions, 627 globals)
      PASS: linked 2 object(s), applied 7171 relocation(s) (1731 CALL26) to ELF64 ET_EXEC
            (143408 text bytes, 10126 rodata bytes, 568 data bytes, 13440168 bss bytes)
      PASS: zero-dependency — verifybin imports nothing (1 UND = the null symbol)
[5/6] === codegen: 总计 115 : 接受一致=48 都拒绝=67 分歧=0 ===
[6/6] === mutation probes: 7 probes, 0 blind or failed ===
ALL CODEGEN CHECKS PASSED
```

## 10. The mutation probes — and the two that shipped blind

Each probe patches `bootstrap/aster.ast` itself into a scratch copy, rebuilds
the reference binary from it, and requires the mutant to **diverge** from the
twin on a targeted input. The suite asserts the edit applied before it even
builds, because a probe that still matches is blind, and blind is a failure.

| Probe | Patch | Target |
| --- | --- | --- |
| `syscall_write` | `write`'s number 64 → 65 | `globals_and_write.ast` |
| `exit_main_ret` | `emit_movz(8, 93, 0, 1)` → 94 | `return_42.ast` |
| `exit_intrinsic` | `ic_sig`'s `(93 << 21)` → `(94 << 21)` | `exit_intrinsic.ast` |
| `enc_bl` | the `BL` opcode | `globals_and_write.ast` |
| `enc_bcond` | bit 4 of the `B.cond` encoding | `if_less.ast` |
| `addr_entry` | `e_entry` `0x401000` → `0x401004` | `return_42.ast` |
| `addr_rodata` | the `.rodata` string base `0x600000` → `0x610000` | `globals_and_write.ast` |

Two first drafts shipped blind, and both are worth recording because the reason
is not obvious and the same trap will catch the next probe written here:

1. **`exit`'s number is not read from `ic_sig` on the main-return path.** The
   obvious patch — `ic_sig`'s `(93 << 21)` → `(94 << 21)` — changes nothing about
   a program whose only exit is `main`'s `return`, because that path emits
   `emit_movz(8, 93, 0, 1)` directly. The probe was re-aimed at the emission
   *and* a second probe was added for the intrinsic path, with a new fixture
   (`exit_intrinsic.ast`) so the intrinsic has an in-tree target that reaches it.
2. **A low `imm26` bit of `B` is overwritten by the branch fixup.** Patching
   `emit_word(0x14000000)` → `emit_word(0x14000001)` looks like an encoding
   mutation, but bit 0 belongs to `imm26`, which the fixup recomputes when the
   label is resolved — so the emitted word is identical and the probe is blind.
   `B.cond` bit 4 sits outside `imm19` and survives backfill, so that is where
   the branch-encoding probe went.

Both were found by the suite's own "a probe that does not diverge is a failure"
rule, which is the point of the rule: a mutation layer is only as good as its
last miss.

## 11. Deliberately not included

The ten divergences from the host's `build-elf` are recorded in
`CODEGEN-SPEC.md` §11 and are intentional, not gaps:

| # | Host | Bootstrap |
| --- | --- | --- |
| 1 | global/string addresses via `X16 = SP+8192` | four-word absolute `emit_addr64` (no ADRP; base is fixed) |
| 2 | comparison conditions reuse flags | always materialise then `CMP` |
| 3 | live temporaries parked with `STR W` | `STR X`/`LDR X`, full width |
| 4 | call result straight into `MOV d, X0` | through frame slot 1022 |
| 5 | string globals are `.data` constants | string globals go through runtime-init |
| 6 | `.eh_frame`/DWARF/`--bounds-check` | not emitted (minimal runnable image) |
| 7 | rodata collects only referenced strings | collects every `E_String` node |
| 8 | PIC / `build-so` / multi-object linking | none (single-image `ET_EXEC`) |
| 9 | no `exit` builtin | `exit` = 93 added |
| 10 | symtab carries the linker's view | `_start` + `main` + `__aster_init` + function/global symbols |

Item 8 is the one that matters for what comes next: a single-image `ET_EXEC`
cannot reference an external symbol, which is exactly why `bootstrap/aster.ast`
compiling *itself* is not in this round. Its own source declares four
`extern fn` (`strlen`, `utoa`, `itoa`, `memcmp`), and `CODEGEN-SPEC.md` §10 C9
refuses them — both sides refuse, consistently. Closing that is **M4**.

## 12. What this closes, and what it opens

M3d closes M3: the bootstrap compiler now reads an Aster source on stdin and
writes a runnable AArch64 ELF on stdout, with an independent oracle that agrees
with it to the byte on every accepted program, under a contract that was frozen
before the first encoder was written and with seven probes that can each still
fail. The stage is built and linked the way every M3 stage was — `build-obj` +
`build-obj stdlib` + `link-obj` — and it imports nothing.

What it opens is M4: `bootstrap/aster.ast` compiling itself. That needs the four
`extern fn` resolved, by multi-object linking or by lowering them as builtins,
and it is the one thing this round deliberately does not do.

## 13. Reproducibility — how to re-run this round

```
# 1. Strict-build the host compiler (the gate the bootstrap is compiled by).
g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o aster

# 2. Run the resident suite (6 phases, the differential over 115 programs,
#    7 mutation probes).
sh tests/codegen-checks.sh
#    OUT=tmp-codegen-checks selects the scratch dir; it is removed on exit.
#    A host without qemu-aarch64 degrades to a clean SKIP, as every e2e suite
#    in this project does.
#    => "ALL CODEGEN CHECKS PASSED"

# 3. Build the stage by hand and use it (stdin in, ELF out).
./aster build-obj bootstrap/aster.ast -o boot.o
./aster build-obj stdlib/aster_std.ast -o std.o
./aster link-obj boot.o std.o -o verifybin
qemu-aarch64 ./verifybin < examples/write_hello.ast > hello.elf
chmod +x hello.elf && qemu-aarch64 ./hello.elf     # => Hello, World!

# 4. The whole gate (101 suites, this one included).
sh tests/ci.sh
```

## 14. Appendix — the frozen self-hosting criteria (`CODEGEN-SPEC.md` §13)

1. **Minimal chain** — `arithmetic.ast`, `write_hello.ast` and a composite
   sample (multi-function `BL`, global arrays, pointer walk, `while`,
   `break`/`continue`) run correctly under `qemu-aarch64`.
2. **Byte-level differential (the frozen criterion)** — over
   `examples/*.ast` + `tests/codegen-fixtures/*.ast`, the two sides agree on
   accept/reject for *every* program, and for every program both accept the ELFs
   are `cmp -s` identical. **Met: 115 programs, 48/67/0.**
3. **Functional equivalence** — the bootstrap's ELF and the host `build-elf`'s
   ELF agree on observable behaviour (exit status, stdout); byte equality is not
   required (see §11).
4. **Zero dependency** — no dynamic section, no UND symbols; the suite also
   asserts `verifybin` itself carries exactly one UND, the ELF null.
5. **Mutation probes** — patch `bootstrap/aster.ast`, rebuild, assert divergence
   from the twin (≥3–5 probes over instruction encoding, syscall number, branch
   backfill, symbol address, width propagation). **Met: 7 probes, 0 blind.**
6. **Capacity and edges** — large functions, deep left-associative expressions
   (30k+ terms), >8 arguments on the stack, long strings, arrays up to 1 MiB,
   the 32-argument ceiling, nested-call grid budget.
7. **Intrinsic cross-check** — all 15 against the host's `build-elf`, with the
   exit-status and stdout comparisons recorded in the plan (#259).
8. **ELF structure** — `readelf` assertions on the section, segment and symbol
   tables (#260).
