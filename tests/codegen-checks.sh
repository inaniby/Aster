#!/bin/sh
# tests/codegen-checks.sh — the M3d codegen, differentially against the spec.
#
# v0.23.45-dev (self-hosting M3d, #261) ships bootstrap/aster.ast with its full
# codegen chain wired into main(): read source, lex, parse, sema, then
# cg_collect (address/label allocation) -> cg_gen_program (linearise the text
# stream) -> elf_emit (fixup back-patch + section/segment emission) -> flush.
# The frozen contract is bootstrap/CODEGEN-SPEC.md (ELF layout §9, the three
# passes, the intrinsic signatures); the independent oracle is
# tests/codegen-twin.c, written from that spec in C — a from-scratch
# reimplementation of the backend (its own node graph, its own temp-register
# pool, its own fixup table) so the two share no code and can still be made to
# agree byte for byte; this suite holds both to the spec.
#
# The shape follows tests/parser-checks.sh (the M3b delivery chain), which this
# suite retires: strictly build the host compiler, build-obj the bootstrap
# stage, build-obj the library, link-obj them main-first into the reference
# compiler binary (verifybin), build the C twin, and diff the two over the same
# corpus. What is new is that the subject is a code generator: both sides take
# one Aster program on stdin and emit one AArch64 ELF on stdout, and the suite
# requires byte-identical ELF on every accepted program and matching
# accept/reject on every program.
#
# The lexer's and parser's own coverage (E1-E9, P1-P62, the C1-C3 caps, the
# semantic S5-S22 codes) is still exercised by the input corpus, but the oracle
# that pins the AST dump (tests/parser-twin.c) is retired with parser-checks.sh:
# bootstrap/aster.ast no longer dumps the AST, it emits ELF.

set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-codegen-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# [1/5] Strictly build the Aster compiler. The host is the tool that compiles
# the bootstrap stage into the reference binary, so it must build clean under
# -Werror exactly as CI enforces.
printf '%s\n' '[1/5] Strictly build Aster compiler'
${CXX:-g++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
# [2/5] Locate a runner. verifybin is AArch64; on any other host it runs under
# qemu-aarch64 user-mode emulation (tests/run-aarch64.sh hides the difference).
# The twin is a host C program and runs natively everywhere.
printf '%s\n' '[2/5] Locate an AArch64 runner'
if ! command -v qemu-aarch64 >/dev/null 2>&1 && [ "$(uname -m)" != "aarch64" ]; then
    echo "SKIP: codegen coverage needs qemu-aarch64 (or an AArch64 host)"
    exit 0
fi
run(){ sh tests/run-aarch64.sh "$@"; }

# ---------------------------------------------------------------------------
# [3/5] Generator freshness. bootstrap/gen_parser_names.py is the single source
# of truth for the node-kind names and numbers that both the bootstrap stage and
# the C twin consume (via tests/parser_names.h); gen_lexer_names.py feeds the
# token codes. A table that drifted from the Python fails CI here rather than
# the differential.
printf '%s\n' '[3/5] The generated tables are what the Python produces'
if ! python3 bootstrap/gen_parser_names.py --check; then
    echo "FAIL: stale parser tables — re-run: python3 bootstrap/gen_parser_names.py" >&2
    exit 1
fi
if ! python3 bootstrap/gen_lexer_names.py --check; then
    echo "FAIL: stale lexer tables — re-run: python3 bootstrap/gen_lexer_names.py" >&2
    exit 1
fi
printf 'PASS: aster.ast generated regions, tests/parser_names.h and tests/lexer_names.h are fresh\n'

# ---------------------------------------------------------------------------
# [4/5] The delivery shape. build-obj the bootstrap stage (the reference
# compiler, now on the codegen path), build-obj the library, link-obj
# main-first — the same chain bootstrap/aster.ast's header documents. The twin
# is built with the host C compiler (it is a host program, not a guest) under
# -Werror: the oracle is a shipped artifact and a warning there is future drift.
printf '%s\n' '[4/5] Delivery shape: verifybin (boot.o + std.o) linked; the twin is built'
if ! "$OUT/aster" build-obj bootstrap/aster.ast -o "$W/verify_boot.o" >"$W/boot.log" 2>&1; then
    echo "FAIL: bootstrap build-obj failed:" >&2; cat "$W/boot.log" >&2; exit 1
fi
if ! "$OUT/aster" build-obj stdlib/aster_std.ast -o "$W/std.o" >"$W/std.log" 2>&1; then
    echo "FAIL: stdlib build-obj failed:" >&2; cat "$W/std.log" >&2; exit 1
fi
if ! "$OUT/aster" link-obj "$W/verify_boot.o" "$W/std.o" -o "$W/verifybin" >"$W/link.log" 2>&1; then
    echo "FAIL: link-obj verify_boot.o std.o failed:" >&2; cat "$W/link.log" >&2; exit 1
fi
printf 'PASS: %s | %s\n' "$(cat "$W/boot.log")" "$(cat "$W/link.log")"
TWCC=${CC:-}
if [ -z "$TWCC" ]; then
    for c in cc gcc clang; do
        if command -v "$c" >/dev/null 2>&1; then TWCC="$c"; break; fi
    done
fi
if [ -z "$TWCC" ]; then
    echo "SKIP: codegen coverage needs a host C compiler for the twin (none found)"
    exit 0
fi
if ! "$TWCC" -std=c11 -O2 -Wall -Wextra -Werror -fwrapv -fno-builtin \
        -I. tests/codegen-twin.c -o "$W/twin" >"$W/twin.log" 2>&1; then
    echo "FAIL: C twin build failed:" >&2; cat "$W/twin.log" >&2; exit 1
fi
printf 'PASS: twin built with %s (-std=c11 -O2 -Wall -Wextra -Werror -fwrapv -fno-builtin)\n'
# Zero-dependency, made checkable: the linked reference binary imports nothing
# beyond what std.o supplies (the two extern fn the stage declares are satisfied
# by std.o, and __aster_init_next by the linker). The only UND entry is the ELF
# null symbol at index 0 — no libc, no external anything.
und=$(readelf -sW "$W/verifybin" | awk '$7=="UND"' | wc -l)
if [ "$und" -ne 1 ]; then
    echo "FAIL: verifybin has $und UND symbols, expected exactly 1 (the ELF null symbol)" >&2
    readelf -sW "$W/verifybin" | awk '$7=="UND"' >&2
    exit 1
fi
printf 'PASS: zero-dependency — verifybin imports nothing (1 UND = the null symbol)\n'

# ---------------------------------------------------------------------------
# [5/5] The differential. Both sides take one Aster program on stdin and emit
# one AArch64 ELF on stdout. For every program in the corpus:
#   - both reject  -> consistent (the suite does not pin rejection text; it only
#                     requires the two sides agree on accept/reject);
#   - both accept  -> the two ELF outputs must be byte-identical;
#   - disagree     -> FAIL (ACCEPT_DIV: one accepts what the other rejects), or
#                     BYTE_DIFF: both accept but the ELF differs.
# Every accepted program must produce a byte-identical ELF; that is the frozen
# contract and the regression gate. The corpus is the project's program
# collection (examples/*.ast) plus the small, self-contained codegen fixtures
# (tests/codegen-fixtures/*.ast) that pin the minimal accepted shapes (a bare
# return, an unused extern global, runtime-initialised globals with a rodata
# string, arrays and a write) without depending on any out-of-tree file.
printf '%s\n' '[5/5] Differential: twin vs verifybin over the corpus'
PASS=0; FAIL=0; REJ_BOTH=0; cnt=0; fails=""
for f in examples/*.ast tests/codegen-fixtures/*.ast; do
    [ -e "$f" ] || continue
    cnt=$((cnt+1)); base=$(basename "$f")
    o="$W/d_${base}.twin"; v="$W/d_${base}.ver"; e="$W/d_${base}.ter"
    "$W/twin" <"$f" >"$o" 2>"$e" || rc_t=$?; rc_t=${rc_t:-0}
    run "$W/verifybin" <"$f" >"$v" 2>/dev/null || rc_v=$?; rc_v=${rc_v:-0}
    if [ "$rc_t" -ne 0 ] && [ "$rc_v" -ne 0 ]; then
        REJ_BOTH=$((REJ_BOTH+1))
    elif [ "$rc_t" -eq 0 ] && [ "$rc_v" -eq 0 ]; then
        if cmp -s "$o" "$v"; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1)); fails="$fails $base"
            echo "BYTE_DIFF $base (twin=$(stat -c%s "$o") ver=$(stat -c%s "$v"))" >&2
        fi
    else
        FAIL=$((FAIL+1)); fails="$fails $base"
        echo "ACCEPT_DIV $base (twin_rc=$rc_t ver_rc=$rc_v)" >&2
        if [ "$rc_t" -ne 0 ]; then echo "    twin stderr: $(head -1 "$e")" >&2; fi
    fi
    unset rc_t rc_v
done

printf '=== codegen: 总计 %s : 接受一致=%s 都拒绝=%s 分歧=%s ===\n' \
    "$cnt" "$PASS" "$REJ_BOTH" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: $FAIL divergence(s):$fails" >&2
    exit 1
fi
printf 'PASS: codegen-twin.c matches bootstrap/aster.ast byte-for-byte on every accepted program (%s/%s)\n' \
    "$PASS" "$cnt"
