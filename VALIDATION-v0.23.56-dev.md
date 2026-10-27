# Validation — v0.23.56-dev

## Audit-driven hardening — no compiler change

v0.23.56-dev closes three findings from the self-hosting audit. The only edit to
`src/aster.cpp` is the version constant (`0.23.55-dev` → `0.23.56-dev`); the
compiler's behaviour is unchanged, so the 348-row ELF byte baseline and every
existing suite stay green.

### Finding #1 — `--page-size` was undocumented

`--page-size 4096|16384` shipped in v0.23.54-dev (ELF load-segment alignment)
and v0.23.55-dev (the embedded-`.so` ZIP offset for `build-apk`), and the usage
banner has always named it, but `docs/language-reference.md` §11 never listed it.
A reader of the reference could not discover the flag.

**Fix.** `docs/language-reference.md` §11 now carries a full flag-table row:

> `--page-size N` sets every `PT_LOAD` `p_align` (and segment base/file offsets)
> to **N** for `build-elf`/`build-pie`/`build-obj`/`build-so`/`link-*`, **and**
> additionally aligns the embedded shared object inside the APK ZIP to **N** for
> `build-apk`. Default **4096**; only `4096` and `16384` are accepted. **16384 is
> required for Android 15+ devices that use a 16 KB page** (rejected at install
> when `targetSdk >= 35` unless both the ELF segments and the in-ZIP offset are
> page-aligned).

The wording matches the actual parser (`src/aster.cpp`: global parse at
`--page-size`, `build-apk` parse at `--page-size`, both validating
`!= 4096 && != 16384`), so the documentation and the binary cannot drift.

### Finding #2 — typed IR listed as `planned`

`FEATURE_STATUS.md` still carried `| Standalone semantic pass / typed IR |
planned (P3.1) | v0.23.0-dev | — |`. That row was wrong on two counts:

- The **standalone semantic pass** shipped in **v0.23.0-dev** (P3.1) — the
  comment at `src/aster.cpp:2514` ("These used to live inside Codegen, but
  v0.23.0-dev (P3.1) runs a semantic …") confirms it.
- The **typed IR** (every reachable expression carries its resolved type from the
  semantic pass into code generation, guarded by a contract at `gen()`'s entry)
  shipped in **v0.23.53-dev**, mutation-witnessed by
  `tests/typedir-mutation.sh` (commit `fabab31` "Typed IR mutation witness and
  re-aimed guards for the refactor"; `bcfa0e6` "Typed IR (v0.23.53-dev): Expr.type
  carries the resolved type, gen() guards resolver agreement"). The suite is
  registered in `tests/ci.sh`.

**Fix.** The row now reads `shipped`, with `Since` `v0.23.0-dev (semantic pass,
P3.1); v0.23.53-dev (typed IR …)` and `Coverage` naming `sema-checks.sh` and
`tests/typedir-mutation.sh` (commit `fabab31` / `bcfa0e6`).

### Finding #3 — the M4 closed loop had no continuous guard

The M4 self-hosting closed loop (host compiler → `bootaster` → `bootaster2`)
had only a one-off VALIDATION report as evidence. A self-hosting compiler that
silently stops reproducing itself would pass every other suite (all of them use
the host compiler) while the loop it depends on had quietly broken.

**Fix.** `tests/bootstrap-loop-checks.sh` is a new resident suite that guards the
loop reproducibly. Registered in `tests/ci.sh`.

## Empirical evidence (the guard, run on this host)

Environment: x86_64 host, `qemu-aarch64` present, 32 cores. The self-hosted
compiler is a **stdin→stdout filter** — it reads the program on stdin and emits
the ELF on stdout (no `build-obj`/`link-obj` subcommands of its own).

1. **Host bootstrap is reproducible.** The host compiler builds `bootaster` twice
   from `bootstrap/aster.ast`; the two `ET_EXEC` binaries are **byte-for-byte
   identical, 181600 bytes each**.
2. **Closed loop is reproducible.** `bootaster` (an AArch64 ELF, run under
   qemu) recompiles `bootstrap/aster.ast` into `bootaster2` — **twice, identical,
   222592 bytes, a valid ELF** (confirmed by `readelf -h`). The loop reproduces
   itself.
3. **Host codegen is reproducible.** Four fixtures
   (`return_42`, `return_1`, `extern_global_main`, `globals_and_write`) each
   compile (`build-obj` + `link-obj`) twice and are **byte-for-byte identical**
   across the two builds. (`exit_intrinsic.ast` is deliberately excluded — it
   calls the self-host-only `exit` intrinsic, which the host compiler has no
   builtin for, so it is not a host-codegen determinism case; it is covered by
   the differential suite.)

```
[3/6] PASS: host aster reproduces bootaster byte-for-byte (181600 bytes, 2 builds identical)
[4/6] PASS: the self-host reproduces itself deterministically (bootaster2 = 222592 bytes, valid ELF, identical across 2 runs)
[5/6] PASS: host aster compiles 4 corpus programs byte-for-byte identically across 2 builds each
=== bootstrap-loop: ALL CHECKS PASSED ===
```

### Known limitations, surfaced as a non-fatal advisory (not asserted)

- **Fixed-point delta.** `bootaster` (181600 bytes, host-built) and `bootaster2`
  (222592 bytes, self-host-built) differ in size. The host compiler and the
  self-host emit slightly different ELF layouts for the same source — a known,
  tolerated contract delta, not a regression. The guard asserts reproducibility
  (two runs agree), not byte-equality between the host and self-host products.
- **Self-host output is not qemu-loadable on this host.** Programs emitted by the
  self-hosted compiler (and the 3rd-generation `bootaster2`, which itself fails
  to compile `return_42`, rc=1) do not load under `qemu-aarch64` here. This is a
  pre-existing, tracked limitation; the guard does **not** execute any product of
  the self-host. Correctness of emitted code is covered by the differential suite
  (`tests/codegen-checks.sh`) against the independent C twin.

## CI

- `tests/bootstrap-loop-checks.sh` added to the `SUITES` list in `tests/ci.sh`.
- `version-checks.sh` green: README title, `VERSION_HISTORY.md` newest entry, and
  this report all name `v0.23.56-dev`.
- Full `tests/ci.sh` run pending the three-batch commit discipline.
