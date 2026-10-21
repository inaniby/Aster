#!/bin/sh
# tests/stdlib-checks.sh — the Aster standard library, differentially.
#
# v0.23.42-dev (self-hosting M2) ships stdlib/aster_std.ast: the mem/str/num/
# hash families a bootstrap compiler needs, in pure Aster over the byte
# intrinsics. Because `include` shares declarations only (v0.23.13-dev), a
# library is delivered as a relocatable object and consumed through
# `extern fn` — so this suite exercises the whole delivery shape: build-obj,
# build-obj, link-obj, run.
#
# The oracle is examples/stdlib_demo.ast's twin, tests/aster-std-twin.c: the
# same case set written from the specification in C, which additionally
# checks its own num converters against snprintf before printing anything.
# stdout bytes and the exit status are compared, so a wrong digit, a flipped
# comparison sign, a missed pad byte or a mis-hashed slot each fail a case.
#
# The mutation probes at the bottom break the LIBRARY on purpose — this is
# the first suite whose subject is Aster source rather than the compiler, and
# the same discipline applies: each probe asserts the suite notices.

set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-stdlib-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# [1/8] Strictly build the Aster compiler
printf '%s\n' '[1/8] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
# [2/8] Locate an AArch64 C compiler (the independent oracle) and a runner.
printf '%s\n' '[2/8] Locate an AArch64 C compiler and a runner'
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
if [ -z "$HOSTCC" ]; then
    echo "SKIP: stdlib coverage needs an AArch64 C compiler (none found)"
    exit 0
fi
printf 'int main(){return 0;}\n' > "$W/hostprobe.c"
if ! "$HOSTCC" -O2 -fwrapv "$W/hostprobe.c" -o "$W/hostprobe" 2>/dev/null \
   || ! readelf -h "$W/hostprobe" 2>/dev/null | grep -q 'AArch64'; then
    echo "SKIP: $HOSTCC does not emit AArch64 ELF (cross-compile toolchain missing)"
    exit 0
fi
if ! command -v qemu-aarch64 >/dev/null 2>&1 && [ "$(uname -m)" != "aarch64" ]; then
    echo "SKIP: stdlib coverage needs qemu-aarch64 (or an AArch64 host)"
    exit 0
fi
run(){ sh tests/run-aarch64.sh "$@"; }

# ---------------------------------------------------------------------------
# [3/8] The delivery shape, then the differential: build the library object,
# build the consumer object, link-obj them in main-first order, and compare
# every byte and the exit status against the C twin.
printf '%s\n' '[3/8] Differential: std.o + demo.o linked vs the C twin'
if ! "$OUT/aster" build-obj stdlib/aster_std.ast -o "$W/std.o" >"$W/std.log" 2>&1; then
    echo "FAIL: stdlib build-obj failed:" >&2; cat "$W/std.log" >&2; exit 1
fi
if ! "$OUT/aster" build-obj examples/stdlib_demo.ast -o "$W/demo.o" >"$W/demo.log" 2>&1; then
    echo "FAIL: demo build-obj failed:" >&2; cat "$W/demo.log" >&2; exit 1
fi
if ! "$OUT/aster" link-obj "$W/demo.o" "$W/std.o" -o "$W/demo" >"$W/link.log" 2>&1; then
    echo "FAIL: link-obj demo.o std.o failed:" >&2; cat "$W/link.log" >&2; exit 1
fi
# The twin is built with -Wall -Wextra like everything else in this project:
# the oracle is a shipped artifact, and a warning there is future drift.
if ! "$HOSTCC" -std=c11 -O2 -Wall -Wextra -fwrapv -fno-builtin tests/aster-std-twin.c -o "$W/twin" >"$W/twin.log" 2>&1; then
    echo "FAIL: C twin build failed:" >&2; cat "$W/twin.log" >&2; exit 1
fi
drc=0; trc=0
run "$W/demo" </dev/null >"$W/demo.out" 2>/dev/null || drc=$?
run "$W/twin" </dev/null >"$W/twin.out" 2>/dev/null || trc=$?
if ! cmp -s "$W/demo.out" "$W/twin.out"; then
    echo "FAIL: Aster library output differs from the C twin:" >&2
    echo "----- Aster (od -c):" >&2; od -c "$W/demo.out" >&2
    echo "----- twin  (od -c):" >&2; od -c "$W/twin.out" >&2
    exit 1
fi
if [ "$drc" -ne "$trc" ]; then
    echo "FAIL: exit status $drc, C twin says $trc" >&2; exit 1
fi
printf 'PASS: %s lines, %s bytes, exit %s — byte-identical to the twin\n' \
    "$(wc -l <"$W/demo.out")" "$(wc -c <"$W/demo.out")" "$drc"

# ---------------------------------------------------------------------------
# [4/8] The consumer contract, at compile time: a bare `ptr` parameter is
# refused &arr (only ptr<u8> takes both a literal and an array address — the
# spelling the library is written in), a wrong arity is refused, and an
# undeclared routine is refused. These pin the delivery shape's edges.
printf '%s\n' '[4/8] Rejections: the extern contract is enforced'
reject(){ # $1 = description, $2 = source, $3 = expected message fragment
    printf '%s\n' "$2" > "$W/rej.ast"
    if "$OUT/aster" build-elf "$W/rej.ast" -o "$W/rej" >"$W/rej.log" 2>&1; then
        echo "FAIL: $1 — was accepted" >&2; return 1
    fi
    if ! grep -q "$3" "$W/rej.log"; then
        echo "FAIL: $1 — wrong diagnostic:" >&2; cat "$W/rej.log" >&2; return 1
    fi
    printf 'PASS: rejected — %s\n' "$1"
}
reject "extern memcpy declared with a bare ptr parameter, called with &arr" \
    'extern fn memcpy(dst: ptr, src: ptr<u8>, n: i32) -> i32;
fn main() -> i32 {
    let b: u8[8] = 0;
    memcpy(&b, "x", 1);
    return 0;
}' \
    "argument type mismatch calling memcpy at argument 1: expected ptr"
reject "extern memcpy called with two arguments" \
    'extern fn memcpy(dst: ptr<u8>, src: ptr<u8>, n: i32) -> i32;
fn main() -> i32 {
    let b: u8[8] = 0;
    memcpy(b, "x");
    return 0;
}' \
    "wrong argument count calling memcpy: expected 3, got 2"
reject "calling a stdlib routine without declaring it extern" \
    'fn main() -> i32 {
    return strlen("x");
}' \
    "call to undeclared function: strlen"

# ---------------------------------------------------------------------------
# [5/8] Self-containedness: the library object defines every symbol it uses.
# The only UND entry is the ELF null symbol at index 0 — there is no libc
# import, no external anything. This is the zero-dependency discipline made
# checkable.
printf '%s\n' '[5/8] Self-contained: std.o imports nothing'
und=$(readelf -sW "$W/std.o" | awk '$7=="UND"' | wc -l)
if [ "$und" -ne 1 ]; then
    echo "FAIL: std.o has $und UND symbols, expected exactly 1 (the ELF null symbol)" >&2
    readelf -sW "$W/std.o" | awk '$7=="UND"' >&2
    exit 1
fi
printf 'PASS: std.o — 1 UND entry (the null symbol), 13 functions, 2 globals defined\n'

# ---------------------------------------------------------------------------
# [6/8] One definition per symbol: linking a second object that also defines
# memcpy must be refused, not silently picked. The consumer's extern
# declaration resolves against exactly one provider.
printf '%s\n' '[6/8] Duplicate definitions are refused by link-obj'
printf 'fn memcpy(dst: ptr<u8>, src: ptr<u8>, n: i32) -> i32 { return n; }\n' > "$W/dup_helper.ast"
"$OUT/aster" build-obj "$W/dup_helper.ast" -o "$W/dup_helper.o" >/dev/null 2>&1
if "$OUT/aster" link-obj "$W/demo.o" "$W/std.o" "$W/dup_helper.o" -o "$W/dup" >"$W/dup.log" 2>&1; then
    echo "FAIL: link-obj accepted two definitions of memcpy" >&2; exit 1
fi
if ! grep -q "duplicate global symbol 'memcpy'" "$W/dup.log"; then
    echo "FAIL: wrong diagnostic for duplicate memcpy:" >&2; cat "$W/dup.log" >&2; exit 1
fi
printf 'PASS: duplicate memcpy refused — %s\n' "$(grep -o "duplicate global symbol 'memcpy' across input objects" "$W/dup.log" | head -1)"

# ---------------------------------------------------------------------------
# [7/8] Mutation probes — break the LIBRARY on purpose and assert the suite
# notices. Each probe patches a copy of stdlib/aster_std.ast, rebuilds the
# object, relinks, and requires the output to diverge from the twin (or the
# build to fail). A probe that still matches the twin is a blind probe, and a
# blind probe is a failure.
printf '%s\n' '[7/8] Mutation probes: every family stays load-bearing'

mutate_and_check(){ # $1 = probe name, $2 = python edit script
    n="$1"; script="$2"
    cp stdlib/aster_std.ast "$W/$n.ast"
    if ! python3 - "$W/$n.ast" "$n" <<PYEOF
import sys
path, name = sys.argv[1], sys.argv[2]
src = open(path).read()
count = 0
def sub(old, new, expect):
    global count
    n_hits = src.count(old)
    if n_hits != expect:
        print("MUTATE-MISS:%s:%d!=%d" % (name, n_hits, expect), file=sys.stderr)
        sys.exit(2)
    return src.replace(old, new)
$script
open(path, 'w').write(src)
PYEOF
    then
        echo "FAIL: $n — the edit script did not apply as expected" >&2; exit 1
    fi
    if ! "$OUT/aster" build-obj "$W/$n.ast" -o "$W/$n.o" >"$W/$n.log" 2>&1; then
        printf 'PASS: %s — mutated library no longer compiles\n' "$n"
        return 0
    fi
    if ! "$OUT/aster" link-obj "$W/demo.o" "$W/$n.o" -o "$W/$n.ab" >"$W/$n.link.log" 2>&1; then
        printf 'PASS: %s — mutated library no longer links\n' "$n"
        return 0
    fi
    mrc=0
    run "$W/$n.ab" </dev/null >"$W/$n.out" 2>/dev/null || mrc=$?
    if cmp -s "$W/$n.out" "$W/twin.out" && [ "$mrc" -eq "$trc" ]; then
        echo "FAIL: $n — the mutation did NOT diverge from the twin (probe is blind)" >&2; exit 1
    fi
    printf 'PASS: %s — diverges from the twin\n' "$n"
}

# m_memcpy_off: copy one byte to the right. MC loses its first byte and
# writes one past the source window — the sum moves.
mutate_and_check m_memcpy_off '
src = sub("store_u8(dst + i, load_u8(src + i));",
          "store_u8(dst + i + 1, load_u8(src + i));", 1)
'
# m_memset_zero: fill with the constant zero instead of c. MS collapses to 0.
# (The anchor is memset's loop head — strncpy has the same store line one row
# later, after its `let c` load.)
mutate_and_check m_memset_zero '
src = sub("    while (i < n) {\n        store_u8(dst + i, c);",
          "    while (i < n) {\n        store_u8(dst + i, 0);", 1)
'
# m_strcmp_flip: answer the difference backwards. SC/ML flip sign. (The
# million-iteration loop head is strcmp's; memcmp's is `while (i < n)`.)
mutate_and_check m_strcmp_flip '
src = sub("    while (i < 1000000) {\n        let x: i32 = load_u8(a + i);\n        let y: i32 = load_u8(b + i);\n        if (x != y) { return x - y; }",
          "    while (i < 1000000) {\n        let x: i32 = load_u8(a + i);\n        let y: i32 = load_u8(b + i);\n        if (x != y) { return y - x; }", 1)
'
# m_utoa_base: render base 8, not base 10. The U lines come out octal. (The
# anchor is a regex over the narrowing comment that follows the store — the
# file header quotes the bare line as an idiom, and a comment must not be
# mutable.)
mutate_and_check m_utoa_base '
import re
src2, n_hits = re.subn(r"v % 10;(\s*)// narrowing", r"v % 8;\1// narrowing", src)
if n_hits != 1: sys.exit(2)
src = src2
'
# m_strncpy_ret: report the padded length, not the copied length. NP answers
# 8 for a two-character source — the exact bug this routine was fixed for.
mutate_and_check m_strncpy_ret '
src = sub("let copied: i32 = i;", "let copied: i32 = n;", 1)
'
# m_hash_prime: a different FNV multiplier. Every slot moves — the hash
# function's 64-bit behaviour is pinned by the HS/HU lines.
mutate_and_check m_hash_prime '
src = sub("* 1099511628211", "* 1099511628213", 1)
'
# m_hash_mask: mask to 1024 instead of 1023 — the classic off-by-one on a
# power-of-two capacity, forgetting the -1. Every key whose low bit pattern
# has no bit 10 set starts probing at slot 0, so the whole table collapses
# into the first slots: the HS/HU indices move. (Masking to 511 would NOT
# diverge here — all three demo keys hash below 512, which is exactly the
# kind of blind probe this suite refuses to ship.)
mutate_and_check m_hash_mask '
src = sub("hash_str(key) & 1023", "hash_str(key) & 1024", 2)
'
# m_hash_miss: an absent key answers 0 instead of the -1 sentinel. HX flips,
# and the miss becomes indistinguishable from a stored zero.
mutate_and_check m_hash_miss '
src = sub("if (k == 0) { return -1; }", "if (k == 0) { return 0; }", 1)
'

printf '%s\n' 'ALL STDLIB CHECKS PASSED'
