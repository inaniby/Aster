# Validation Report — v0.23.33-dev

**Feature: `-g` grows a third section — DWARF v4 `.eh_frame` (and its
`.eh_frame_hdr`) beside the `.debug_line` and `.debug_info` Aster has emitted
since v0.23.12-dev and v0.23.32-dev — so a debugger can *walk* a stack, not
only print the frame it stopped in.**

```
$ ./aster build-elf examples/multi_dim_array.ast -g -o mda
$ readelf -S -W mda | grep -E 'eh_frame'
  [ 5] .eh_frame         PROGBITS   0000000000402000 002000 00005c 00   A
  [ 6] .eh_frame_hdr     PROGBITS   0000000000402060 002060 000024 00   A
$ readelf --debug-dump=frames mda
  00000000 0000001c 00000000 CIE
    Version:               1
    Augmentation:          "zR"
    Code alignment factor: 4
    Data alignment factor: -8
    Return address column: 30
  DW_CFA_def_cfa: r31 (sp) ofs 0
  00000028 00000018 0000001c FDE cie=00000000 pc=0000000000401000..0000000000401058
  DW_CFA_advance_loc: 4
  DW_CFA_def_cfa_offset: 8192
```

## 1. Why this round exists

It is the natural second half of the debug-information story. The roadmap had
already scheduled it as the line after `.debug_info`: *"The remaining
debug-info work is call-frame information (`.eh_frame`), so a debugger can walk
a stack rather than only print the frame it is in."* v0.23.32-dev made the
frame base free (`DW_AT_frame_base = DW_OP_breg31 + 0`), which is exactly why
this round is cheap: a debugger could already *read* every local, but it could
not *unwind* — there was no `.eh_frame`. As before, it is a **toolchain** round
(reuses the patch-site / relocation machinery v0.23.32-dev built) and **not** a
language change, so it is its own version.

## 2. The core observation: a whole function's unwind table is six bytes

Every Aster frame is a fixed **8192 bytes** (`SUB SP, SP, #8192`) and SP does
not move again inside a body. There is no frame pointer, no push/pop
bookkeeping and no variable frame size, so a single function's unwind table is
six bytes of CFI:

* **CFA** = `r31 (sp) + 8192`, from one instruction past the prologue.
* **Return address** = `r30` stored at `CFA − 8`, for every body that *returns*.
* The **entry**, which *exits*, never stores `x30`, so its FDE has no such rule.

The `preservesRa` flag — set opposite `Codegen::isMain`, and true for `main` in
a shared object, where `main` is an ordinary returning function — is the only
thing a function contributes to its FDE. The CIE and the per-function CFI are
constant; only the `initial_location` differs per function.

## 3. The CIE is copied from `aarch64-linux-gnu-gcc`'s real object

The format was fixed by reading `readelf -x .eh_frame` / `--debug-dump=frames`
on `aarch64-linux-gnu-gcc -O2 -c`, not from the spec: augmentation `zR`, code
alignment 4, data alignment −8 (`SLEB128 0x78`), return-address column 30,
augmentation data `0x1b` (`DW_EH_PE_pcrel | sdata4`), and the initial
instruction `DW_CFA_def_cfa: r31, 0`. An FDE is laid out as
`[length][cie_ptr][initial_location: pcrel sdata4][address_range: udata4][aug
byte][cfi…][nop pad to 4]`. `initial_location` is a displacement from its own
field, so a static image and a `.so` write it directly while an `ET_REL` object
carries it as `R_AARCH64_PREL32` (261) against the function — confirming
against gcc's own `.o` is what pins the layout. The suite checks the CIE
**byte for byte** against `aarch64-linux-gnu-gcc`.

## 4. The same patch-site idea serves the unwinder

`encodeEhFrame` writes each FDE's `initial_location` as a placeholder and
records `(offset, symbol, addend)`. `writeObject` emits `R_AARCH64_PREL32`
against the function; `writeElfBytes` and both `.so` writers resolve it from
the segment addresses they compute; `linkObjects` / `linkSharedObjects`
rebuild one FDE per function with a `cie_ptr` back to the single merged CIE and
an `initial_location` that points at the function's raised address. The
`.eh_frame_hdr` is one sorted row per FDE (`function − header_vaddr`,
`fde − header_vaddr`) under `PT_GNU_EH_FRAME`, and both sections sit in their
**own `PT_LOAD`** because an unwinder reads them out of the running image —
appending them to an existing load would move a boundary every other offset is
computed from.

## 5. Four write paths and two linkers, all carrying the table

| Path | Reached by | Resolution |
| --- | --- | --- |
| `writeObject` | `build-obj` | records `.rela.eh_frame` (`R_AARCH64_PREL32`) |
| `writeElfBytes` | `build-elf`, `build-pie`, `link-obj`, `link-pie` | merged symbol map |
| `writeSharedObjectDyn` | `build-so --soname`, `link-so` | its own segment addresses |
| `writeSharedObject` | `build-so` with no soname and no imports | its own segment addresses |

Both linkers merge one FDE per input object, each raised to that object's text
address. The unwind table is laid out **after** everything that existed before
(and is `SHF_ALLOC`, so the loader can find it), so no pre-existing byte moves.

## 6. Coverage: `tests/eh-frame-checks.sh` [9/9]

Written for this round, with `tests/ehframe-decode.py` — a decoder that reads
the CIE/FDE bytes straight out of the ELF (no pyelftools, no objdump) and runs
the CFI program:

1. a strict `-Werror` rebuild;
2. **off by default** — no `.eh_frame`, no `.eh_frame_hdr`, no `PT_GNU_EH_FRAME`
   in any product without `-g` (checked across the 101 shipped examples too);
3. **additive** — `.text` compared byte for byte with and without the flag, and
   `.rela.eh_frame` carrying `R_AARCH64_PREL32` against every function;
4. **the CIE equals gcc's** — byte-for-byte against `aarch64-linux-gnu-gcc -O2
   -c` for the same program;
5. **one FDE per function, agreeing with `.symtab`** — each `[begin, end)`
   equals its FUNC symbol's address and size (alias names like `main`/`_start`
   share one FDE);
6. **the CFI is tied to the code** — the CFA rule starts one instruction in
   (where `objdump` says `SUB SP, SP, #8192` ends) and `r30` is saved at
   `CFA − 8` by every returning body, never by the entry;
7. **the header is self-consistent and reachable** — `.eh_frame_hdr` names
   `.eh_frame`, carries one sorted row per FDE pointing at it, and both sections
   sit inside a `PT_LOAD` with a `PT_GNU_EH_FRAME` on the header;
8. **two independent readers agree** — `readelf --debug-dump=frames` and
   `llvm-dwarfdump --eh-frame` must describe the same functions and the same
   rules;
9. **it survives linking and running** — two objects produce one raised table, a
   shared object keeps every function's, and qemu says the images behave exactly
   as without `-g`; a final mutation layer halves the CFA offset and drops the
   return-address rule and requires the suite to notice.

Steps 4–6 are the ones that matter: they check the compiler against gcc, against
the symbol table and against `objdump`, not against a number it produced.

## 7. Nothing that exists moves

```
$ sh tests/rebuild-baseline-v0.23.33.sh
OK: 303 pre-existing lines byte-identical; 303 lines total (0 new)
```

The unwind table is numbered after every section that existed before and written
only when `-g` asked for it, so an ordinary build is unchanged byte for byte.
The suite asserts this twice: through the baseline script, and directly, by
comparing `readelf -x .text` of a `-g` build against the same build without the
flag (step 2). This round adds no example, which is why the row count does not
grow.

## 8. Deliberately not included

* **`DW_AT_call_frame_info`**, `DW_AT_call_file` / `DW_AT_call_line` on inlined
  work, location lists (an Aster local lives at one slot for its whole life) and
  a type DIE for a **function type**.
* **DWARF v5**, and the compact `.eh_frame_hdr`-less form some linkers prefer —
  Aster emits `SHF_ALLOC` `.eh_frame` plus a sorted header, which is what every
  unwinder expects to find in a `PT_GNU_EH_FRAME`.

## 9. Full CI

```
$ sh tests/ci.sh
=== ... ===
90 passed / 0 skipped / 0 failed
```

One suite is new (`eh-frame-checks.sh`); every pre-existing suite passes
unchanged, including `debug-info-checks.sh` and `debugline-checks.sh`, which
still prove the line table and the DIE tree on their own terms.
