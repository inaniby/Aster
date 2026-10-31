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
# stage, link-obj it into the reference compiler binary (verifybin), build the
# C twin, and diff the two over the same corpus. What is new is that the
# subject is a code generator: both sides take one Aster program on stdin and
# emit one AArch64 ELF on stdout, and the suite requires byte-identical ELF on
# every accepted program and matching accept/reject on every program.
#
# M4 (#216) delivery shape: the stage is self-contained. It used to declare
# four `extern fn` (strlen/utoa/itoa/memcmp) and take them from std.o — but a
# standalone ET_EXEC cannot reference an external symbol (§10 C9), so the
# stage could never compile its own source. The routines are inlined into
# bootstrap/aster.ast now, and verifybin links against nothing: the library is
# covered by its own suite (tests/stdlib-checks.sh), not this one.
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
# [1/6] Strictly build the Aster compiler. The host is the tool that compiles
# the bootstrap stage into the reference binary, so it must build clean under
# -Werror exactly as CI enforces.
printf '%s\n' '[1/6] Strictly build Aster compiler'
${CXX:-g++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
# [2/6] Locate a runner. verifybin is AArch64; on any other host it runs under
# qemu-aarch64 user-mode emulation (tests/run-aarch64.sh hides the difference).
# The twin is a host C program and runs natively everywhere.
printf '%s\n' '[2/6] Locate an AArch64 runner'
if ! command -v qemu-aarch64 >/dev/null 2>&1 && [ "$(uname -m)" != "aarch64" ]; then
    echo "SKIP: codegen coverage needs qemu-aarch64 (or an AArch64 host)"
    exit 0
fi
run(){ sh tests/run-aarch64.sh "$@"; }

# ---------------------------------------------------------------------------
# [3/6] Generator freshness. bootstrap/gen_parser_names.py is the single source
# of truth for the node-kind names and numbers that both the bootstrap stage and
# the C twin consume (via tests/parser_names.h); gen_lexer_names.py feeds the
# token codes. A table that drifted from the Python fails CI here rather than
# the differential.
printf '%s\n' '[3/6] The generated tables are what the Python produces'
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
# [4/6] The delivery shape. build-obj the bootstrap stage (the reference
# compiler, now on the codegen path) and link-obj it — the stage is
# self-contained since M4 (#216), so there is exactly one input object and the
# chain bootstrap/aster.ast's header documents is a single build-elf/link-obj.
# The twin is built with the host C compiler (it is a host program, not a
# guest) under -Werror: the oracle is a shipped artifact and a warning there is
# future drift.
printf '%s\n' '[4/6] Delivery shape: verifybin (boot.o alone) linked; the twin is built'
if ! "$OUT/aster" build-obj bootstrap/aster.ast -o "$W/verify_boot.o" >"$W/boot.log" 2>&1; then
    echo "FAIL: bootstrap build-obj failed:" >&2; cat "$W/boot.log" >&2; exit 1
fi
if ! "$OUT/aster" link-obj "$W/verify_boot.o" -o "$W/verifybin" >"$W/link.log" 2>&1; then
    echo "FAIL: link-obj verify_boot.o failed:" >&2; cat "$W/link.log" >&2; exit 1
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
# Zero-dependency, made checkable: the stage is self-contained since M4
# (#216) — it imports nothing at all, so the linked reference binary has
# exactly one UND entry, the ELF null symbol at index 0: no libc, no external
# anything, not even the library it used to lean on.
und=$(readelf -sW "$W/verifybin" | awk '$7=="UND"' | wc -l)
if [ "$und" -ne 1 ]; then
    echo "FAIL: verifybin has $und UND symbols, expected exactly 1 (the ELF null symbol)" >&2
    readelf -sW "$W/verifybin" | awk '$7=="UND"' >&2
    exit 1
fi
printf 'PASS: zero-dependency — verifybin imports nothing (1 UND = the null symbol)\n'

# ---------------------------------------------------------------------------
# [5/6] The differential. Both sides take one Aster program on stdin and emit
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
printf '%s\n' '[5/6] Differential: twin vs verifybin over the corpus'
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

# The floor. Byte equality is only evidence if the corpus actually exercises
# both outcomes: a corpus that lost its accepted programs (or degenerated to
# "both reject everything") would pass the divergence check vacuously. The
# floors sit below the current 48 accepted / 67 rejected so adding or retiring
# a handful of examples does not need a test edit, while a lost layer does.
# They are deliberately not environment-overridable: lowering them is a source
# change with a review, not a CI knob.
MIN_ACCEPT=40
MIN_REJECT=55
if [ "$PASS" -lt "$MIN_ACCEPT" ] || [ "$REJ_BOTH" -lt "$MIN_REJECT" ]; then
    echo "FAIL: differential corpus too thin: accepted=$PASS (floor $MIN_ACCEPT), rejected=$REJ_BOTH (floor $MIN_REJECT), total=$cnt" >&2
    echo "      the corpus must keep enough accepted and rejected programs for byte equality to mean anything;" >&2
    echo "      restore the corpus, or lower the floor deliberately in tests/codegen-checks.sh." >&2
    exit 1
fi
printf 'PASS: codegen-twin.c matches bootstrap/aster.ast byte-for-byte on every accepted program (%s/%s; floors %s accepted, %s rejected)\n' \
    "$PASS" "$cnt" "$MIN_ACCEPT" "$MIN_REJECT"

# ---------------------------------------------------------------------------
# [6/6] Mutation probes. Each one patches bootstrap/aster.ast — the reference
# compiler's own source — into a scratch copy, rebuilds the reference binary
# from it, and requires the mutant to DIVERGE from the twin on a targeted
# input. A probe whose mutant still matches is blind, and blind is a failure,
# so the suite asserts the edit applied before it even builds. This is
# CODEGEN-SPEC.md §13 crusher 5: probes across instruction encoding, syscall
# number, branch backfill and symbol address.
printf '%s\n' '[6/6] Mutation probes against bootstrap/aster.ast'
MPROBE=0; MFAIL=0
mutate(){ # $1 name, $2 sed-from, $3 sed-to, $4 targeted input
    mname="$1"; mfrom="$2"; mto="$3"; mtgt="$4"
    MPROBE=$((MPROBE+1))
    # '#' is the sed delimiter because several probes patch source text that
    # itself contains '|' (e.g. `emit_word(0x54000000 | cond)`).
    sed "s#$mfrom#$mto#" bootstrap/aster.ast > "$W/mut_$mname.ast"
    if ! grep -qF -- "$mto" "$W/mut_$mname.ast"; then
        echo "FAIL: probe $mname did not apply — blind" >&2
        MFAIL=$((MFAIL+1)); return 0
    fi
    if ! "$OUT/aster" build-obj "$W/mut_$mname.ast" -o "$W/mut_$mname.o" >"$W/mut_$mname.blog" 2>&1; then
        echo "FAIL: probe $mname — mutant build-obj failed:" >&2
        cat "$W/mut_$mname.blog" >&2; MFAIL=$((MFAIL+1)); return 0
    fi
    if ! "$OUT/aster" link-obj "$W/mut_$mname.o" -o "$W/mut_$mname.bin" >"$W/mut_$mname.llog" 2>&1; then
        echo "FAIL: probe $mname — mutant link-obj failed:" >&2
        cat "$W/mut_$mname.llog" >&2; MFAIL=$((MFAIL+1)); return 0
    fi
    "$W/twin" <"$mtgt" > "$W/mut_$mname.twin" 2>/dev/null; mrc_t=$?
    run "$W/mut_$mname.bin" <"$mtgt" > "$W/mut_$mname.mut" 2>/dev/null; mrc_m=$?
    if [ "$mrc_t" -eq "$mrc_m" ] && cmp -s "$W/mut_$mname.twin" "$W/mut_$mname.mut"; then
        echo "FAIL: probe $mname is blind — the mutant matches the twin on $(basename "$mtgt")" >&2
        MFAIL=$((MFAIL+1)); return 0
    fi
    printf 'PASS: probe %s diverges on %s\n' "$mname" "$(basename "$mtgt")"
    return 0
}
# syscall number: write 64 -> 65 (the MOV X8 immediate in a write program)
mutate syscall_write '(64 << 21)' '(65 << 21)' tests/codegen-fixtures/globals_and_write.ast
# syscall number: every main return path lowers to MOV X8,#93. Patched at the
# emission itself rather than at ic_sig, because the return path does not read
# the intrinsic signature table — a probe on ic_sig alone is blind here.
mutate exit_main_ret 'emit_movz(8, 93, 0, 1)' 'emit_movz(8, 94, 0, 1)' tests/codegen-fixtures/return_42.ast
# syscall number: the exit() intrinsic, which does come out of ic_sig
mutate exit_intrinsic '(93 << 21)' '(94 << 21)' tests/codegen-fixtures/exit_intrinsic.ast
# instruction encoding: the BL opcode
mutate enc_bl 'emit_word(0x94000000)' 'emit_word(0x94000001)' tests/codegen-fixtures/globals_and_write.ast
# branch encoding: bit 4 of B.cond, which sits outside imm19 and so survives
# the branch fixup that rewrites the offset — unlike a low imm26 bit of B.
mutate enc_bcond 'emit_word(0x54000000 | cond)' 'emit_word(0x54000010 | cond)' examples/if_less.ast
# symbol address: the ELF entry point
mutate addr_entry 'elf_put64(0x401000);  // e_entry' 'elf_put64(0x401004);  // e_entry' tests/codegen-fixtures/return_42.ast
# symbol address: the .rodata base every string literal is placed at
mutate addr_rodata '0x600000 + rodata_size' '0x610000 + rodata_size' tests/codegen-fixtures/globals_and_write.ast

printf '=== mutation probes: %s probes, %s blind or failed ===\n' "$MPROBE" "$MFAIL"
if [ "$MFAIL" -ne 0 ]; then
    echo "FAIL: $MFAIL mutation probe(s) did not diverge from the twin" >&2
    exit 1
fi
# The score is 100% killed, but a score over a shrunken probe set is not
# evidence. Keep at least the seven probes that cover instruction encoding,
# both syscall paths, branch backfill, the entry point and the rodata base.
MIN_MPROBE=7
if [ "$MPROBE" -lt "$MIN_MPROBE" ]; then
    echo "FAIL: mutation probe set too small: $MPROBE probe(s), floor $MIN_MPROBE" >&2
    exit 1
fi
printf 'PASS: all %s mutation probes against bootstrap/aster.ast diverge from the twin (floor %s)\n' \
    "$MPROBE" "$MIN_MPROBE"

printf '%s\n' 'ALL CODEGEN CHECKS PASSED'
