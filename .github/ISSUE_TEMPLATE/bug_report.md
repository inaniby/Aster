---
name: Bug report
about: A wrong binary, a wrong diagnostic, or a crash — with a reproducer
title: "[bug] "
labels: bug
---

## Reproducer

A minimal `.ast` program (or ELF/APK input) and the exact command line:

```aster
fn main() : i32 { return 42; }
```

```sh
aster build-elf repro.ast -o repro.elf
```

## Expected vs. actual

- Expected: (exit code / output / diagnostic)
- Actual: (exit code / output / diagnostic)

## Control case

The same program with the suspect feature removed, or the gcc C oracle's
answer — so the report shows the defect, not just a surprise:

## Environment

- `aster --version`:
- `aster doctor` summary:
- Host: (x86_64+qemu / native AArch64 / Termux)
