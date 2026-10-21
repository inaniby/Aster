#!/bin/sh
# tests/write-output-checks.sh — the output primitive, differentially.
#
# v0.23.21-dev added `write(fd, buf, len)` — one write(2) system call
# (x8 = 64) — so an ELF program can print without libc. `main`'s return was
# already a system call (x8 = 93, exit); this is the same idea on the output
# side, and it is what keeps build-elf static and self-contained. The .so
# path still uses libc for the Android host.
#
# The discipline that matters (carried over from narrow-value-coverage.sh):
# every case below has an Aster source AND a C source that performs the same
# writes, and the oracle is aarch64-linux-gnu-gcc, not a hand-computed
# expectation. Three channels are compared per case — stdout bytes, stderr
# bytes and the exit status — so a wrong fd, a wrong length, a wrong buffer
# or a wrong byte count each fail a case. A wrong expectation cannot make a
# case pass.
#
# The cases named in COVERAGE_MAP at the bottom are not decoration. Each one
# reproduces a register-clobber failure the implementation actually hit while
# this intrinsic was being written, because x0/x1/x2 are simultaneously the
# syscall argument registers and the first three temporaries of the w0–w15
# pool:
#
#   accumulate — `total = total + write(...)`: the argument load clobbered
#       the surrounding expression's own w0 (gen(total)), and the byte count
#       was summed with itself (4 instead of 6).
#   loop_multi — the same shape inside a loop, where the clobbered value is
#       carried across iterations.
#   nested_expr — two writes inside one expression, where the second write's
#       argument load runs while the first write's result is live.
#
# The fix parks every live temporary before loading the syscall registers and
# restores it afterwards, exactly as emitCallSeq does around a call.

set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-write-output-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# [1/4] Strictly build the Aster compiler
printf '%s\n' '[1/4] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
# [2/4] Locate the tools: an AArch64 C compiler (the independent oracle) and
# something to run AArch64 ELFs with. Without them this suite SKIPs cleanly —
# every remaining layer is a consumer of both.
printf '%s\n' '[2/4] Locate an AArch64 C compiler and a runner'
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
if [ -z "$HOSTCC" ]; then
    echo "SKIP: write-output coverage needs an AArch64 C compiler (none found)"
    exit 0
fi
# Confirm $HOSTCC actually emits AArch64; a native cc on an x86 box would pass
# the compile but produce binaries qemu-aarch64 cannot run.
printf 'int main(){return 0;}\n' > "$W/hostprobe.c"
if ! "$HOSTCC" -O2 -fwrapv "$W/hostprobe.c" -o "$W/hostprobe" 2>/dev/null \
   || ! readelf -h "$W/hostprobe" 2>/dev/null | grep -q 'AArch64'; then
    echo "SKIP: $HOSTCC does not emit AArch64 ELF (cross-compile toolchain missing)"
    exit 0
fi
if ! command -v qemu-aarch64 >/dev/null 2>&1 && [ "$(uname -m)" != "aarch64" ]; then
    echo "SKIP: write-output coverage needs qemu-aarch64 (or an AArch64 host)"
    exit 0
fi
# run <elf> — execute an AArch64 ELF transparently. The suite's own harness
# (tests/run-aarch64.sh) handles both native and qemu; stdout/stderr redirection
# happens here, outside it, so both channels are captured separately.
run(){ sh tests/run-aarch64.sh "$@"; }

# ---------------------------------------------------------------------------
# [3/4] Differential battery. Each case writes $W/<name>.ast and
# $W/<name>.c, compiles both, runs both, and compares three channels.
#
#   emit_case <name>   — writes the two sources
#   check_case <name>  — build, run, compare; returns non-zero on any mismatch
CASES="hello_stdout hello_stderr zero_len bss_bytes offset_write rodata_two \
i64_count accumulate loop_multi nested_expr helper_call \
shadow_write shadow_write_same_sig shadow_load_u8 shadow_load_ptr shadow_store_u8"

emit_case(){
    n="$1"
    case "$n" in
    hello_stdout)
        cat > "$W/$n.ast" <<'AST'
fn main() -> i32 {
    let n: i32 = write(1, "Hello, World!", 14);
    return 0;
}
AST
        cat > "$W/$n.c" <<'CEOF'
#include <unistd.h>
int main(void){ write(1, "Hello, World!", 14); return 0; }
CEOF
        ;;
    hello_stderr)
        cat > "$W/$n.ast" <<'AST'
fn main() -> i32 {
    let n: i32 = write(2, "to stderr", 10);
    return 0;
}
AST
        cat > "$W/$n.c" <<'CEOF'
#include <unistd.h>
int main(void){ write(2, "to stderr", 10); return 0; }
CEOF
        ;;
    zero_len)
        cat > "$W/$n.ast" <<'AST'
fn main() -> i32 {
    let n: i32 = write(1, "abc", 0);
    return n;
}
AST
        cat > "$W/$n.c" <<'CEOF'
#include <unistd.h>
int main(void){ return write(1, "abc", 0); }
CEOF
        ;;
    bss_bytes)
        # The buffer is not a string literal: it is a global array in .bss
        # whose bytes are filled at run time, so the ptr argument travels
        # from a mutable global rather than from .rodata.
        cat > "$W/$n.ast" <<'AST'
let buf: u8[5] = 0;
fn main() -> i32 {
    buf[0] = 72; buf[1] = 105; buf[2] = 33; buf[3] = 10; buf[4] = 0;
    let n: i32 = write(1, buf, 4);
    return n;
}
AST
        cat > "$W/$n.c" <<'CEOF'
#include <unistd.h>
static unsigned char buf[5] = {0};
int main(void){
    buf[0] = 72; buf[1] = 105; buf[2] = 33; buf[3] = 10; buf[4] = 0;
    return write(1, buf, 4);
}
CEOF
        ;;
    offset_write)
        # A pointer plus an integer is a byte offset in Aster (no scaling on
        # ptr + i32), so p + 2 addresses the third byte of the literal.
        cat > "$W/$n.ast" <<'AST'
fn main() -> i32 {
    let p: ptr = "abcdef";
    let n: i32 = write(1, p + 2, 3);
    return n;
}
AST
        cat > "$W/$n.c" <<'CEOF'
#include <unistd.h>
int main(void){
    const char *p = "abcdef";
    return write(1, p + 2, 3);
}
CEOF
        ;;
    rodata_two)
        # Two distinct literals in one program: each write must reach its own
        # .rodata bytes, which is what a wrong base or a wrong relocation
        # would break.
        cat > "$W/$n.ast" <<'AST'
fn main() -> i32 {
    let a: i32 = write(1, "one-", 4);
    let b: i32 = write(1, "two!", 4);
    return a + b;
}
AST
        cat > "$W/$n.c" <<'CEOF'
#include <unistd.h>
int main(void){
    int a = write(1, "one-", 4);
    int b = write(1, "two!", 4);
    return a + b;
}
CEOF
        ;;
    i64_count)
        # The count consumed at 64-bit width: MOV Wd, W0 leaves the upper
        # half zero, and the count is never negative, so widening cannot
        # diverge. This case pins that.
        cat > "$W/$n.ast" <<'AST'
fn main() -> i32 {
    let n: i64 = write(1, "wide", 4);
    return n % 100;
}
AST
        cat > "$W/$n.c" <<'CEOF'
#include <unistd.h>
int main(void){
    long long n = write(1, "wide", 4);
    return n % 100;
}
CEOF
        ;;
    accumulate)
        # COVERAGE_MAP: the byte count must add to the running total, not to
        # itself — the first failure of the intrinsic (EBADF was the second).
        cat > "$W/$n.ast" <<'AST'
fn main() -> i32 {
    let total: i32 = 0;
    total = total + write(1, "ab", 2);
    total = total + write(1, "cd", 2);
    total = total + write(1, "ef", 2);
    return total;
}
AST
        cat > "$W/$n.c" <<'CEOF'
#include <unistd.h>
int main(void){
    int total = 0;
    total += write(1, "ab", 2);
    total += write(1, "cd", 2);
    total += write(1, "ef", 2);
    return total;
}
CEOF
        ;;
    loop_multi)
        # COVERAGE_MAP: the same accumulation, but the value carried across
        # loop iterations is the one a clobbered w0 would corrupt silently.
        cat > "$W/$n.ast" <<'AST'
fn main() -> i32 {
    let total: i32 = 0;
    let i: i32 = 0;
    while (i < 3) {
        total = total + write(1, "ab", 2);
        i = i + 1;
    }
    return total;
}
AST
        cat > "$W/$n.c" <<'CEOF'
#include <unistd.h>
int main(void){
    int total = 0;
    for (int i = 0; i < 3; i++) total += write(1, "ab", 2);
    return total;
}
CEOF
        ;;
    nested_expr)
        # COVERAGE_MAP: two writes in one expression — the second write's
        # argument load runs while the first write's result is still live.
        cat > "$W/$n.ast" <<'AST'
fn main() -> i32 {
    let a: i32 = write(1, "A", 1);
    let b: i32 = write(1, "B", 1);
    return (a + b) + (write(1, "C", 1) + write(1, "D", 1));
}
AST
        cat > "$W/$n.c" <<'CEOF'
#include <unistd.h>
int main(void){
    int a = write(1, "A", 1);
    int b = write(1, "B", 1);
    return (a + b) + (write(1, "C", 1) + write(1, "D", 1));
}
CEOF
        ;;
    helper_call)
        # write inside a non-main function, with a function call among the
        # arguments: the argument staging must nest (callDepth) without
        # colliding with the helper's own frame.
        cat > "$W/$n.ast" <<'AST'
fn twice(x: i32) -> i32 { return x + x; }
fn emit(s: ptr, n: i32) -> i32 { return write(1, s, n); }
fn main() -> i32 { return emit("ZZZZ", twice(2)); }
AST
        cat > "$W/$n.c" <<'CEOF'
#include <unistd.h>
static int twice(int x){ return x + x; }
static int emit(const char *s, int n){ return write(1, s, n); }
int main(void){ return emit("ZZZZ", twice(2)); }
CEOF
        ;;
    shadow_write|shadow_write_same_sig|shadow_load_u8|shadow_load_ptr|shadow_store_u8)
        # The intrinsic-shadow regressions. v0.23.21-dev's first CI run failed
        # tests/runtime-bounds-checks.sh because it defines its own helper
        # named `write`: the intrinsic dispatch ran before the function lookup
        # and swallowed the user's definition. The rule since: a program's own
        # definition always wins, for every intrinsic name — including a
        # `write` whose signature matches the intrinsic's exactly, where the
        # program must get its own function and print nothing.
        case "$n" in
        shadow_write)
            cat > "$W/$n.ast" <<'AST'
fn write(fd: i32, n: i32) -> i32 { return n * 10; }
fn main() -> i32 { return write(3, 9); }
AST
            cat > "$W/$n.c" <<'CEOF'
static int write(int fd, int n){ (void)fd; return n * 10; }
int main(void){ return write(3, 9); }
CEOF
            ;;
        shadow_write_same_sig)
            # The signature matches the intrinsic's exactly — the user's
            # function must still win, and nothing may be printed.
            cat > "$W/$n.ast" <<'AST'
fn write(fd: i32, buf: ptr, len: i32) -> i32 { return 99; }
fn main() -> i32 { return write(1, "abc", 3); }
AST
            cat > "$W/$n.c" <<'CEOF'
static int write(int fd, const char *buf, int len){ (void)fd; (void)buf; (void)len; return 99; }
int main(void){ return write(1, "abc", 3); }
CEOF
            ;;
        shadow_load_u8)
            cat > "$W/$n.ast" <<'AST'
fn load_u8(p: ptr) -> i32 { return 7; }
fn main() -> i32 { return load_u8("x"); }
AST
            cat > "$W/$n.c" <<'CEOF'
static int load_u8(const char *p){ (void)p; return 7; }
int main(void){ return load_u8("x"); }
CEOF
            ;;
        shadow_load_ptr)
            # The shadowing function returns a ptr, so the *intrinsic* load_u8
            # (unshadowed) still reads through what it returned.
            cat > "$W/$n.ast" <<'AST'
fn load_ptr(p: ptr) -> ptr { return p; }
fn main() -> i32 { let q: ptr = load_ptr("ab"); return load_u8(q); }
AST
            cat > "$W/$n.c" <<'CEOF'
static const char *load_ptr(const char *p){ return p; }
static int load_u8(const char *p){ return *(const unsigned char *)p; }
int main(void){ const char *q = load_ptr("ab"); return load_u8(q); }
CEOF
            ;;
        shadow_store_u8)
            cat > "$W/$n.ast" <<'AST'
fn store_u8(p: ptr, v: i32) -> i32 { return v + 1; }
let g: u8[4] = 0;
fn main() -> i32 { return store_u8(g, 41); }
AST
            cat > "$W/$n.c" <<'CEOF'
static int store_u8(void *p, int v){ (void)p; return v + 1; }
static unsigned char g[4] = {0};
int main(void){ return store_u8(g, 41); }
CEOF
            ;;
        esac
        ;;
    *)
        echo "internal error: no such case '$n'" >&2
        return 1
        ;;
    esac
}

check_case(){
    n="$1"
    if ! "$OUT/aster" build-elf "$W/$n.ast" -o "$W/$n.ab" >"$W/$n.ab.log" 2>&1; then
        echo "FAIL: $n — Aster build failed:" >&2; cat "$W/$n.ab.log" >&2; return 1
    fi
    # -fno-builtin: the shadow cases define their own `write`, and gcc would
    # otherwise reject it as a conflicting declaration of a builtin.
    if ! "$HOSTCC" -O2 -fwrapv -fno-builtin "$W/$n.c" -o "$W/$n.cb" >"$W/$n.cb.log" 2>&1; then
        echo "FAIL: $n — C oracle build failed:" >&2; cat "$W/$n.cb.log" >&2; return 1
    fi
    arc=0; crc=0
    run "$W/$n.ab" >"$W/$n.aout" 2>"$W/$n.aerr" || arc=$?
    run "$W/$n.cb" >"$W/$n.cout" 2>"$W/$n.cerr" || crc=$?
    if ! cmp -s "$W/$n.aout" "$W/$n.cout"; then
        echo "FAIL: $n — stdout differs from the C oracle:" >&2
        echo "----- Aster (od -c):" >&2; od -c "$W/$n.aout" >&2
        echo "----- C    (od -c):" >&2; od -c "$W/$n.cout" >&2
        return 1
    fi
    if ! cmp -s "$W/$n.aerr" "$W/$n.cerr"; then
        echo "FAIL: $n — stderr differs from the C oracle:" >&2
        echo "----- Aster (od -c):" >&2; od -c "$W/$n.aerr" >&2
        echo "----- C    (od -c):" >&2; od -c "$W/$n.cerr" >&2
        return 1
    fi
    if [ "$arc" -ne "$crc" ]; then
        echo "FAIL: $n — exit status $arc, C oracle says $crc" >&2
        return 1
    fi
    printf 'PASS: %-14s stdout %s, stderr %s, exit %s\n' "$n" \
        "$(wc -c <"$W/$n.aout") bytes" "$(wc -c <"$W/$n.aerr") bytes" "$arc"
}

printf '%s\n' '[3/4] Differential battery: every case run against the C oracle'
for n in $CASES; do
    emit_case "$n"
    check_case "$n"
done

# The rejections: the same four mistakes a caller can make, each with the
# diagnostic that names the offending argument. These are the intrinsic's
# type contract, and they are checked here rather than assumed.
printf '%s\n' '[3/4b] Rejections: the argument contract is enforced'
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
reject "a string length" \
    'fn main() -> i32 { let n: i32 = write(1, "x", "y"); return n; }' \
    "write third argument must be i32"
reject "a string fd" \
    'fn main() -> i32 { let n: i32 = write("a", "x", 1); return n; }' \
    "write first argument must be i32"
reject "an integer buffer" \
    'fn main() -> i32 { let n: i32 = write(1, 5, 1); return n; }' \
    "write second argument must be ptr"
reject "two arguments" \
    'fn main() -> i32 { let n: i32 = write(1, "x"); return n; }' \
    "write expects (fd: i32, buf: ptr, len: i32)"

# ---------------------------------------------------------------------------
# [4/4] Coverage map. Every register-clobber failure the implementation
# actually hit must have a resident case; if a case is deleted without the
# map being updated, the map itself fails — that is the point of naming them.
printf '%s\n' '[4/4] Coverage map: the register-conflict regressions stay resident'
for c in accumulate loop_multi nested_expr; do
    case " $CASES " in
        *" $c "*) printf 'PASS: coverage map holds — %s\n' "$c" ;;
        *) echo "FAIL: coverage map lost $c (it reproduces a real clobber failure)" >&2; exit 1 ;;
    esac
done

printf '%s\n' 'ALL WRITE-OUTPUT CHECKS PASSED'
