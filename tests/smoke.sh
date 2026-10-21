#!/bin/sh
set -eu
CXX=${CXX:-g++}
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic src/aster.cpp -o aster
for name in hello arithmetic negative_division if_less if_greater_equal if_equal if_not_equal_false if_less_equal if_greater_false assignment while_count nested_while scope_shadow nested_if many_locals long_expression if_return while_break while_continue nested_loop_break; do
  ./aster build-elf "examples/$name.ast" -o "tmp-$name"
done
python3 - <<'PY'
import os, struct
names = ['hello', 'arithmetic', 'negative_division', 'if_less', 'if_greater_equal', 'if_equal', 'if_not_equal_false', 'if_less_equal', 'if_greater_false', 'assignment', 'while_count', 'nested_while', 'scope_shadow', 'nested_if', 'many_locals', 'long_expression', 'if_return', 'while_break', 'while_continue', 'nested_loop_break']
for name in names:
    p = 'tmp-' + name
    b = open(p, 'rb').read()
    assert b[:4] == b'\x7fELF', p
    assert b[4] == 2 and b[5] == 1, p
    assert struct.unpack_from('<H', b, 16)[0] == 2, p
    assert struct.unpack_from('<H', b, 18)[0] == 183, p
    entry = struct.unpack_from('<Q', b, 24)[0]
    assert entry == 0x401000, (p, hex(entry))
    assert struct.unpack_from('<H', b, 56)[0] == 1, p
    print(f'{p}: ELF64 AArch64 ET_EXEC, entry=0x{entry:x}, bytes={len(b)}')
    os.remove(p)
PY

./tests/error-checks.sh

./tests/object-checks.sh

./tests/linker-checks.sh

./tests/global-checks.sh

# v0.18.0: link-so, cross-.so imports, SONAME/NEEDED and PLT/GOT.
./tests/pie-so-checks.sh

./tests/so-dyn-checks.sh
./tests/so-negative-checks.sh
./tests/gnu-hash-checks.sh
./tests/relro-checks.sh

./tests/e2e-so-import.sh
./tests/e2e-so-negative.sh

# v0.22.43-dev: comment syntax (// and /* */) + non-ASCII diagnostics.
./tests/comment-checks.sh

# v0.22.46-dev: pixel byte offsets must scale the row term by bytes-per-pixel
# (stride counts pixels); native_render.ast source guard + qemu self-check.
./tests/pixel-offset-checks.sh

# v0.22.48-dev: constant-folded bounds checks on fixed-size global arrays and
# the ptr-typed global-initializer rejection (merged from the v0.23.4-dev branch).
./tests/array-bounds-checks.sh

# v0.22.49-dev: local (function-scope) i32[N] arrays — frame allocation with
# packed 4-byte elements, constant initialization, both index paths, and the
# array-name-decays-to-frame-address rule (ptr arguments).
./tests/local-array-checks.sh

# v0.22.49-dev: pointer indexing p[i] (ptr base, 4-byte i32 element stride) on
# the read and write paths, plus the C ABI end-to-end (C array -> Aster p[i]).
./tests/pointer-index-checks.sh

# v0.22.49-dev: C ABI e2e for pointer indexing. The probe skips (exit 0) when no
# AArch64-capable $HOSTCC is on PATH; otherwise run with HOSTCC=aarch64-linux-gnu-gcc.
HOSTCC=${HOSTCC:-cc} ./tests/e2e-c-ptr-index.sh

# v0.22.50-dev: for loops — for (init; cond; step) { } with the step between the
# body and the back-edge and continue branching to the step; empty clauses,
# assignment-form initializers, nested/mixed loops, and for over a local array.
./tests/for-loop-checks.sh

# v0.22.51-dev: bool type + logical operators (&& || !) + else-if chains.
# Comparisons become ordinary bool expressions, && / || short-circuit, bool is
# not convertible to or from i32, and `else if` desugars to `else { if … }`.
./tests/bool-checks.sh

# v0.23.0-dev: standalone semantic pass (P3.1) — type checking runs over the
# AST before any code is emitted, with its own scope stack, instead of being
# decided inside codegen. Includes the proof that type errors now precede
# codegen diagnostics, and the type-rule matrix the pass owns.
./tests/sema-checks.sh

# v0.23.1-dev: --bounds-check (P1.5) — run-time range tests for dynamic indexes
# into fixed-size arrays (global and local, read and write), trapping with
# BRK #1 / SIGTRAP. Opt-in: a default build emits no trap at all, and a program
# that only indexes with constants is byte-identical with the flag on.
./tests/runtime-bounds-checks.sh

# v0.23.2-dev: wider integer types (i64, u8, u16, u32) — the unified Ty lattice,
# the MOVZ+MOVK wide-literal fix, narrow zero-extending load/store, unsigned
# condition codes + UDIV, the 8-byte AAPCS64 ABI, and wide/narrow globals/arrays.
./tests/wide-int-checks.sh

# v0.23.3-dev: APK v2 (APK Signing Block) signatures, with v1 retained for
# dual-signing (P2.1) — the Signing Block layout, the chunked CHUNKED_SHA256
# content digest (including the EOCD central-directory-offset rewrite), the
# anti-stripping X-Android-APK-Signed attribute, and mutation checks proving the
# v2 verifier actually rejects tampering v1 cannot see.
./tests/apk-checks.sh

# v0.23.4-dev: signing keys as input, not as constants (P2.5) — per-project debug
# keys via `aster keygen`, release signing with the developer's own key (fail
# closed when it is missing), PEM/DER key loading, `aster verify-apk`, and
# build-apk re-verifying every APK in memory before it reaches the disk.
./tests/signing-checks.sh

# v0.23.5-dev: structs (P3.3) — nominal struct types with AAPCS64 layout,
# ptr<S> and &, aggregate literals, whole-struct copy, nesting, struct globals,
# and the three composite size classes crossing a call (one register, a register
# pair, a caller-made copy with X8 carrying a >16-byte result).
./tests/struct-checks.sh

# v0.23.5-dev: the same three classes against a real C compiler, in both
# directions. Skips (exit 0) when no AArch64-capable $HOSTCC is on PATH;
# otherwise run with HOSTCC=aarch64-linux-gnu-gcc.
HOSTCC=${HOSTCC:-cc} ./tests/e2e-c-struct.sh

# v0.23.6-dev: launcher icon (P2.2) — a self-generated 192x192 palette PNG under
# res/drawable-nodpi, a from-scratch binary resources.arsc (android:icon is a
# resource id, and only the resource table maps it to a file), and the attribute
# written as TYPE_REFERENCE rather than the numerically identical TYPE_INT_HEX.
# Includes five compiler mutations, each one a way to ship an APK whose icon
# silently falls back to the system default.
./tests/icon-checks.sh

# v0.23.7-dev: @embed / @embed_len (P2.2 follow-up) — compile-time file inlining
# into .rodata, returning a ptr, plus @embed_len folding to a constant usable as
# an array bound or a global initializer. Path base is the source file's own
# directory (C #include rules) with --embed-dir overriding it; identical paths
# are interned once. Byte-level comparison against the source file, dedup
# evidence, and in-.so embedding.
./tests/embed-checks.sh

# v0.23.7-dev: resources.arsc as a real resource table (P2.2 follow-up) — more
# than one type and more than one entry, id assignment derived from the table
# rather than hardcoded, android:label as @string/app_name instead of a literal
# in the manifest, and --string NAME=VALUE for extra inline strings. The table
# is re-derived by an independent parser and cross-checked against androguard.
./tests/resource-table-checks.sh

# v0.23.7-dev: the icon+text demo (P2.2 showcase) — one program that draws a
# 48x48 RGBA icon and three lines of 8x8 bitmap text, all of it read from @embed
# data at run time. Asserts the assets are in the .so byte for byte, renders the
# frame under qemu with no Android present and checks the pixel census, and
# packages the result with the app name living only in resources.arsc.
# Skips (exit 0) when there is no AArch64-capable $HOSTCC (or qemu on a foreign
# host); otherwise run with HOSTCC=aarch64-linux-gnu-gcc.
HOSTCC=${HOSTCC:-cc} ./tests/icon-text-demo-checks.sh
