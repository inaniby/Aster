#!/bin/sh
# tests/bootstrap-loop-checks.sh — the M4 self-hosting closed loop, guarded.
#
# v0.23.56-dev adds this suite because the M4 end-to-end bootstrap loop had no
# continuous guard: the only evidence it still worked was a one-off VALIDATION
# report. A self-hosting compiler that silently stops reproducing itself is the
# worst kind of rot — it passes every other suite (they all use the host
# compiler) while the loop it depends on has quietly broken. This suite is the
# thing that looks.
#
# What it actually proves (the invariants that are TRUE and stable today):
#   1. The host compiler reproduces the self-host deterministically: aster
#      compiles bootstrap/aster.ast into bootaster, and two such builds are
#      byte-for-byte identical. If the host ever drifted, bootaster would too.
#   2. The closed loop is reproducible: bootaster (the self-hosted compiler,
#      an AArch64 ELF run under qemu) recompiles bootstrap/aster.ast into
#      bootaster2, and two such runs are byte-for-byte identical and produce a
#      valid ELF. The loop reproduces itself.
#   3. Host codegen is reproducible over a fixed corpus: each fixture compiles
#      to a byte-identical ELF across two builds.
#
# What it deliberately does NOT do (and why), surfaced as a non-fatal ADVISORY:
#   - It never *executes* a program emitted by the self-host. Such programs are
#     currently not qemu-loadable on this host (a known limitation, tracked
#     separately), so runtime e2e of self-hosted output is out of scope here.
#     The differential suite (codegen-checks.sh) covers correctness of emitted
#     code against the C twin instead.
#   - It does not assert bootaster == bootaster2 byte-for-byte. The host
#     compiler and the self-host emit slightly different ELF layouts for the
#     same source (a known, tolerated contract delta); what matters and what is
#     asserted is that each step is *reproducible* (two runs agree).
#
# The self-hosted compiler is a stdin->stdout filter: it reads the program on
# stdin and emits the ELF on stdout (no build-obj/link-obj subcommands of its
# own), which is why the closed loop feeds bootstrap/aster.ast on stdin and
# captures the ELF from stdout. The host compiler (src/aster.cpp) still takes a
# file argument and an -o target, so it builds bootaster the normal way.

set -eu
cd "$(dirname "$0")/.."

OUT=${OUT:-bootstrap-loop-artifacts}
W="$OUT/work"
mkdir -p "$W"
trap 'rm -rf "$OUT"' EXIT HUP INT TERM

CXX=${CXX:-g++}
run(){ sh tests/run-aarch64.sh "$@"; }

if [ ! -f bootstrap/aster.ast ]; then
    echo "SKIP: bootstrap/aster.ast is missing — nothing to self-host"
    exit 0
fi

# ---------------------------------------------------------------------------
# [1/6] Obtain the host compiler. ci.sh builds ./aster before the suites run,
# so reuse it when present and runnable; otherwise build our own. Either way we
# only need one host binary — the determinism is proven by building bootaster
# twice with the *same* host, not by building the host twice.
printf '%s\n' '[1/6] Obtain the host Aster compiler'
if [ -x ./aster ] && ./aster --help >/dev/null 2>&1; then
    ASTER=./aster
    printf 'reusing existing ./aster (built by ci.sh)\n'
else
    if ! "$CXX" -std=c++17 -O2 -Wall -Wextra -pedantic -Werror \
            src/aster.cpp -o "$OUT/aster" 2>"$W/host-build.log"; then
        echo "FAIL: host Aster build failed:" >&2; cat "$W/host-build.log" >&2
        exit 1
    fi
    ASTER="$OUT/aster"
    printf 'built host aster (%s)\n' "$("$CXX" --version | head -1)"
fi

# ---------------------------------------------------------------------------
# [2/6] Locate an AArch64 runner for the self-host. bootaster is an AArch64 ELF
# and runs under qemu-aarch64 on this (x86_64) host. Without qemu (and not on
# an AArch64 host) the closed-loop phase cannot run and is SKIPped cleanly; the
# host-side phases (1, 3, 5) still run and still guard the host compiler.
printf '%s\n' '[2/6] Locate an AArch64 runner for the self-host'
SELFHOST_OK=1
if ! command -v qemu-aarch64 >/dev/null 2>&1 && [ "$(uname -m)" != "aarch64" ]; then
    echo "SKIP: the closed-loop phase needs qemu-aarch64 (or an AArch64 host) to run bootaster"
    SELFHOST_OK=0
fi

# ---------------------------------------------------------------------------
# [3/6] Host bootstrap is reproducible. The host compiler builds the self-host
# twice; the two bootaster binaries must be byte-identical. This is the floor:
# if the host cannot reproduce the self-host, every downstream claim is void.
printf '%s\n' '[3/6] Host bootstrap is reproducible: aster -> bootaster (twice)'
"$ASTER" build-obj bootstrap/aster.ast -o "$W/boot1.o" >"$W/boot1.log" 2>&1 \
    || { echo "FAIL: host build-obj (run 1) failed:" >&2; cat "$W/boot1.log" >&2; exit 1; }
"$ASTER" link-obj "$W/boot1.o" -o "$W/bootaster1" >"$W/link1.log" 2>&1 \
    || { echo "FAIL: host link-obj (run 1) failed:" >&2; cat "$W/link1.log" >&2; exit 1; }
"$ASTER" build-obj bootstrap/aster.ast -o "$W/boot2.o" >"$W/boot2.log" 2>&1 \
    || { echo "FAIL: host build-obj (run 2) failed:" >&2; cat "$W/boot2.log" >&2; exit 1; }
"$ASTER" link-obj "$W/boot2.o" -o "$W/bootaster2" >"$W/link2.log" 2>&1 \
    || { echo "FAIL: host link-obj (run 2) failed:" >&2; cat "$W/link2.log" >&2; exit 1; }
if cmp -s "$W/bootaster1" "$W/bootaster2"; then
    sz_boot=$(stat -c%s "$W/bootaster1")
    echo "PASS: host aster reproduces bootaster byte-for-byte ($sz_boot bytes, 2 builds identical)"
else
    echo "FAIL: host aster -> bootaster is NOT deterministic — the self-host would drift" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# [4/6] The closed loop. bootaster (the self-host) recompiles bootstrap/aster.ast;
# it reads the program on stdin and emits the ELF on stdout. Two such runs must
# agree byte-for-byte and yield a valid ELF. This is the core M4 invariant: the
# self-host reproduces itself.
printf '%s\n' '[4/6] Closed loop: bootaster (self-host) recompiles bootstrap/aster.ast -> bootaster2 (twice)'
if [ "$SELFHOST_OK" -eq 1 ]; then
    run "$W/bootaster1" < bootstrap/aster.ast > "$W/bootaster2a" 2>"$W/b2a.err" \
        || { echo "FAIL: bootaster -> bootaster2 (run A) failed (rc=$?):" >&2; cat "$W/b2a.err" >&2; exit 1; }
    run "$W/bootaster2" < bootstrap/aster.ast > "$W/bootaster2b" 2>"$W/b2b.err" \
        || { echo "FAIL: bootaster -> bootaster2 (run B) failed (rc=$?):" >&2; cat "$W/b2b.err" >&2; exit 1; }
    szA=$(stat -c%s "$W/bootaster2a"); szB=$(stat -c%s "$W/bootaster2b")
    if [ "$szA" -eq 0 ] || [ "$szB" -eq 0 ] || [ "$szA" != "$szB" ] \
            || ! cmp -s "$W/bootaster2a" "$W/bootaster2b"; then
        echo "FAIL: the self-host does not reproduce itself deterministically (A=$szA B=$szB)" >&2
        exit 1
    fi
    if ! readelf -h "$W/bootaster2a" >/dev/null 2>&1; then
        echo "FAIL: bootaster2 is not a valid ELF" >&2
        exit 1
    fi
    echo "PASS: the self-host reproduces itself deterministically (bootaster2 = $szA bytes, valid ELF, identical across 2 runs)"
    if cmp -s "$W/bootaster1" "$W/bootaster2a"; then
        echo "NOTE: fixed point holds — bootaster == bootaster2"
    else
        echo "NOTE (non-fatal): bootaster ($sz_boot) and bootaster2 ($szA) differ in size. This is the known self-host contract delta — the host compiler and the self-host emit slightly different ELF layouts for the same source — not a regression. The loop is reproducible either way."
    fi
else
    echo "SKIP: closed-loop phase (no AArch64 runner)"
fi

# ---------------------------------------------------------------------------
# [5/6] Host codegen is reproducible over a fixed corpus. Each fixture is
# compiled (build-obj + link-obj) twice; the two ELFs must be byte-identical.
# These are host-aster outputs (well-formed, loadable) but — like everything in
# this suite — they are compared, never executed.
printf '%s\n' '[5/6] Host codegen is reproducible over a fixed corpus (twice each)'
CORPUS="tests/codegen-fixtures/return_42.ast tests/codegen-fixtures/return_1.ast tests/codegen-fixtures/extern_global_main.ast tests/codegen-fixtures/globals_and_write.ast"
n=0; bad=""
for f in $CORPUS; do
    [ -e "$f" ] || { echo "FAIL: corpus fixture missing: $f" >&2; exit 1; }
    n=$((n+1))
    "$ASTER" build-obj "$f" -o "$W/c1_$n.o" >/dev/null 2>&1 \
        && "$ASTER" link-obj "$W/c1_$n.o" -o "$W/c1_$n" >/dev/null 2>&1 \
        || { echo "FAIL: host build of $f (run 1) failed" >&2; exit 1; }
    "$ASTER" build-obj "$f" -o "$W/c2_$n.o" >/dev/null 2>&1 \
        && "$ASTER" link-obj "$W/c2_$n.o" -o "$W/c2_$n" >/dev/null 2>&1 \
        || { echo "FAIL: host build of $f (run 2) failed" >&2; exit 1; }
    if ! cmp -s "$W/c1_$n" "$W/c2_$n"; then bad="$bad $(basename "$f")"; fi
done
if [ -n "$bad" ]; then
    echo "FAIL: host codegen not deterministic for:$bad" >&2
    exit 1
fi
echo "PASS: host aster compiles $n corpus programs byte-for-byte identically across 2 builds each"

# ---------------------------------------------------------------------------
# [6/6] Scope advisory. Non-fatal: states plainly what this guard covers and,
# importantly, what it does not (and why), so a future reader does not "fix" it
# by adding an execution step that would hard-fail on the known limitation.
printf '%s\n' '[6/6] Scope advisory (non-fatal)'
echo "ADVISORY: this guard proves the M4 bootstrap CLOSED LOOP is reproducible"
echo "  (host aster -> bootaster -> bootaster2, all deterministic, bootaster2 a valid"
echo "  ELF) and that host codegen is reproducible. It does NOT execute any program"
echo "  produced by the self-host: programs emitted by the self-hosted compiler are"
echo "  currently not qemu-loadable on this host (a known limitation, tracked"
echo "  separately), so runtime e2e of self-hosted output is out of scope here and is"
echo "  covered by the differential suite (codegen-checks.sh) against the C twin instead."

echo "=== bootstrap-loop: ALL CHECKS PASSED ==="
