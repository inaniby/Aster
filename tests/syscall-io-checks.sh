#!/bin/sh
# tests/syscall-io-checks.sh — the input side of a self-hosting compiler,
# differentially.
#
# v0.23.40-dev added raw Linux system-call intrinsics so a program can pull
# source bytes in and push an ELF out without libc: read(2)/openat(2)/close(2)/
# fstat(2), alongside the write(2)/exit(2) that already existed. These are the
# AArch64 syscall numbers (asm-generic) — there is no plain `open` on aarch64,
# 56 is openat(dirfd, path, flags, mode), and fstat is 80 (79 is newfstatat).
# The exit(93)/write(64) intrinsics already pinned this numbering; getting 56/80
# wrong is exactly the kind of silent breakage this suite exists to catch.
#
# Discipline (carried over from write-output-checks.sh): every positive case has
# an Aster source AND a C source that performs the same system calls, and the
# oracle is aarch64-linux-gnu-gcc, not a hand-computed expectation. stdout bytes
# and the exit status are compared per case, so a wrong fd, a wrong syscall
# number, a wrong buffer, a wrong byte count or a wrong struct offset each fail a
# case. A wrong expectation cannot make a case pass.
#
# The mutation probes at the bottom are load-bearing, not decoration: they break
# the implementation on purpose (renumber fstat to 79, delete the read dispatch)
# and assert the suite notices. m_fstat is the real bug this feature shipped with
# — 79 is newfstatat, not fstat — pinned so it can never regress silently.

set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-syscall-io-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# [1/5] Strictly build the Aster compiler
printf '%s\n' '[1/5] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
# [2/5] Locate an AArch64 C compiler (the independent oracle) and a runner.
printf '%s\n' '[2/5] Locate an AArch64 C compiler and a runner'
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
if [ -z "$HOSTCC" ]; then
    echo "SKIP: syscall-io coverage needs an AArch64 C compiler (none found)"
    exit 0
fi
printf 'int main(){return 0;}\n' > "$W/hostprobe.c"
if ! "$HOSTCC" -O2 -fwrapv "$W/hostprobe.c" -o "$W/hostprobe" 2>/dev/null \
   || ! readelf -h "$W/hostprobe" 2>/dev/null | grep -q 'AArch64'; then
    echo "SKIP: $HOSTCC does not emit AArch64 ELF (cross-compile toolchain missing)"
    exit 0
fi
if ! command -v qemu-aarch64 >/dev/null 2>&1 && [ "$(uname -m)" != "aarch64" ]; then
    echo "SKIP: syscall-io coverage needs qemu-aarch64 (or an AArch64 host)"
    exit 0
fi
run(){ sh tests/run-aarch64.sh "$@"; }

# Shared stdin for the read cases: 700 bytes of a pattern, big enough to force
# several 256-byte reads and prove the read loop crosses the buffer boundary.
ABS=$(cd "$W" && pwd)
i=0
: > "$W/input.bin"
while [ "$i" -lt 100 ]; do
    printf '0123456789' >> "$W/input.bin"; printf 'ABCDEFG' >> "$W/input.bin"
    i=$((i+1))
done
# The file the openat/fstat cases read. 20 bytes.
printf 'TWENTY-BYTES-EXACT!' > "$W/data.txt"

# ---------------------------------------------------------------------------
# [3/5] Differential battery. Every case is fed $W/input.bin on stdin (ignored
# by the cases that do not read it) and compared against the C oracle on stdout
# and exit status.
CASES="cat_stdin chunked7 openat_read fstat_size close_badfd"

emit_case(){
    n="$1"
    case "$n" in
    cat_stdin)
        # read(0) in 256-byte chunks -> write(1), until read returns 0 at EOF.
        cat > "$W/$n.ast" <<AST
let buf: u8[256] = 0;
fn main() -> i32 {
    let n: i32 = read(0, &buf, 256);
    while (n > 0) {
        write(1, &buf, n);
        n = read(0, &buf, 256);
    }
    close(0);
    close(1);
    return 0;
}
AST
        cat > "$W/$n.c" <<CEOF
#include <unistd.h>
static unsigned char buf[256];
int main(void){
    long n = read(0, buf, 256);
    while (n > 0) { write(1, buf, n); n = read(0, buf, 256); }
    close(0); close(1);
    return 0;
}
CEOF
        ;;
    chunked7)
        # 7-byte reads: many iterations, each write riding the previous read's
        # count — a clobbered x0 (the count's home) would corrupt the loop.
        cat > "$W/$n.ast" <<AST
let buf: u8[7] = 0;
fn main() -> i32 {
    let n: i32 = read(0, &buf, 7);
    while (n > 0) {
        write(1, &buf, n);
        n = read(0, &buf, 7);
    }
    close(0);
    return 0;
}
AST
        cat > "$W/$n.c" <<CEOF
#include <unistd.h>
static unsigned char buf[7];
int main(void){
    long n = read(0, buf, 7);
    while (n > 0) { write(1, buf, n); n = read(0, buf, 7); }
    close(0);
    return 0;
}
CEOF
        ;;
    openat_read)
        # openat(AT_FDCWD, path, O_RDONLY, 0) -> read -> write -> close. The
        # path is baked in at emit time; the file exists at run time.
        cat > "$W/$n.ast" <<AST
let buf: u8[256] = 0;
fn main() -> i32 {
    let fd: i32 = openat(-100, "$ABS/data.txt", 0, 0);
    if (fd < 0) { write(1, "OPEN-ERR\n", 9); return 1; }
    let n: i32 = read(fd, &buf, 256);
    write(1, &buf, n);
    close(fd);
    return 0;
}
AST
        cat > "$W/$n.c" <<CEOF
#include <fcntl.h>
#include <unistd.h>
static unsigned char buf[256];
int main(void){
    int fd = openat(AT_FDCWD, "$ABS/data.txt", O_RDONLY, 0);
    if (fd < 0) { write(1, "OPEN-ERR\n", 9); return 1; }
    long n = read(fd, buf, 256);
    write(1, buf, n);
    close(fd);
    return 0;
}
CEOF
        ;;
    fstat_size)
        # openat -> fstat(fd, buf) -> write the 8 raw bytes of st_size, which on
        # AArch64 struct stat lives at offset 48. Both sides dump the same field,
        # so a renumbered fstat (79 = newfstatat) that fails to fill the buffer
        # diverges immediately. This is the m_fstat probe's resident case.
        cat > "$W/$n.ast" <<AST
let st: u8[144] = 0;
fn main() -> i32 {
    let fd: i32 = openat(-100, "$ABS/data.txt", 0, 0);
    if (fd < 0) { write(1, "OPEN-ERR\n", 9); return 1; }
    let r: i32 = fstat(fd, &st);
    close(fd);
    if (r != 0) { write(1, "FSTAT-ERR\n", 10); return 1; }
    write(1, &st + 48, 8);
    return 0;
}
AST
        cat > "$W/$n.c" <<CEOF
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
int main(void){
    int fd = openat(AT_FDCWD, "$ABS/data.txt", O_RDONLY, 0);
    if (fd < 0) { write(1, "OPEN-ERR\n", 9); return 1; }
    struct stat st;
    int r = fstat(fd, &st);
    close(fd);
    if (r != 0) { write(1, "FSTAT-ERR\n", 10); return 1; }
    long long sz = (long long)st.st_size;
    write(1, &sz, 8);
    return 0;
}
CEOF
        ;;
    close_badfd)
        # close() of a descriptor that was never open. The raw kernel syscall
        # answers -EBADF = -9 (not libc's -1): Aster's intrinsic IS the syscall,
        # so it returns -errno and lands 247 in the exit status. Every glibc
        # entry point — close() and even syscall() — normalises that to -1, so
        # the only fair oracle is the same raw SVC in C inline asm, mirroring
        # exactly what Aster's codegen emits (x8 = 57, SVC #0, result in x0).
        cat > "$W/$n.ast" <<AST
fn main() -> i32 {
    let r: i32 = close(9999);
    return r;
}
AST
        cat > "$W/$n.c" <<CEOF
int main(void){
    register long x8 __asm__("x8") = 57;   /* SYS_close on AArch64 */
    register long x0 __asm__("x0") = 9999;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8) : "memory");
    return (int)x0;                          /* raw -EBADF = -9 */
}
CEOF
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
    if ! "$HOSTCC" -O2 -fwrapv -fno-builtin "$W/$n.c" -o "$W/$n.cb" >"$W/$n.cb.log" 2>&1; then
        echo "FAIL: $n — C oracle build failed:" >&2; cat "$W/$n.cb.log" >&2; return 1
    fi
    arc=0; crc=0
    run "$W/$n.ab" <"$W/input.bin" >"$W/$n.aout" 2>"$W/$n.aerr" || arc=$?
    run "$W/$n.cb" <"$W/input.bin" >"$W/$n.cout" 2>"$W/$n.cerr" || crc=$?
    if ! cmp -s "$W/$n.aout" "$W/$n.cout"; then
        echo "FAIL: $n — stdout differs from the C oracle:" >&2
        echo "----- Aster (od -c):" >&2; od -c "$W/$n.aout" >&2
        echo "----- C    (od -c):" >&2; od -c "$W/$n.cout" >&2
        return 1
    fi
    if [ "$arc" -ne "$crc" ]; then
        echo "FAIL: $n — exit status $arc, C oracle says $crc" >&2; return 1
    fi
    printf 'PASS: %-14s stdout %s bytes, exit %s\n' "$n" \
        "$(wc -c <"$W/$n.aout")" "$arc"
}

printf '%s\n' '[3/5] Differential battery: every case run against the C oracle'
for n in $CASES; do
    emit_case "$n"
    check_case "$n"
done

# ---------------------------------------------------------------------------
# [4/5] Rejections: the argument contract is enforced and names the argument.
printf '%s\n' '[4/5] Rejections: the argument contract is enforced'
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
reject "read with a string fd" \
    'fn main() -> i32 { let n: i32 = read("a", &buf, 1); return n; } let buf: u8[1] = 0;' \
    "read first argument must be i32"
reject "read with an integer buffer" \
    'fn main() -> i32 { let n: i32 = read(0, 5, 1); return n; }' \
    "read second argument must be ptr"
reject "read with two arguments" \
    'fn main() -> i32 { let n: i32 = read(0, &buf); return n; } let buf: u8[1] = 0;' \
    "read expects (fd: i32, buf: ptr, len: i32)"
reject "openat with three arguments (no mode)" \
    'fn main() -> i32 { let n: i32 = openat(-100, "x", 0); return n; }' \
    "openat expects (fd: i32, path: ptr, flags: i32, mode: i32)"
reject "openat with an integer path" \
    'fn main() -> i32 { let n: i32 = openat(-100, 7, 0, 0); return n; }' \
    "openat second argument must be ptr"
reject "close with a pointer argument" \
    'fn main() -> i32 { let n: i32 = close("x"); return n; }' \
    "close argument must be i32"
reject "fstat with an integer buffer" \
    'fn main() -> i32 { let n: i32 = fstat(3, 5); return n; }' \
    "fstat second argument must be ptr"

# ---------------------------------------------------------------------------
# [5/5] Mutation probes — break the implementation on purpose and assert the
# suite notices. Each builds a mutated compiler from a patched copy of the
# source; the "before" and "after" facts are both asserted.
printf '%s\n' '[5/5] Mutation probes: the aarch64 numbering and dispatch stay load-bearing'

# m_fstat: renumber fstat from 80 to 79 (newfstatat). The syscall then takes
# (dirfd, path, flags) and never fills the stat buffer, so fstat_size's st_size
# dump diverges from the C oracle (or errors). This is the exact bug that
# shipped with the first cut of this feature.
cp src/aster.cpp "$W/m_fstat.cpp"
sed -i 's/syscallInsn(80,e\.args/syscallInsn(79,e.args/' "$W/m_fstat.cpp"
if ! grep -q 'syscallInsn(79,e.args' "$W/m_fstat.cpp"; then
    echo "FAIL: m_fstat — sed did not apply (the 80->79 renumber is gone?)" >&2; exit 1
fi
${CXX:-c++} -std=c++17 -O2 -w "$W/m_fstat.cpp" -o "$OUT/aster_m_fstat" 2>/dev/null
emit_case fstat_size
if "$OUT/aster_m_fstat" build-elf "$W/fstat_size.ast" -o "$W/fstat_size.mab" >/dev/null 2>&1; then
    mrc=0
    run "$W/fstat_size.mab" <"$W/input.bin" >"$W/fstat_size.mout" 2>/dev/null || mrc=$?
    "$HOSTCC" -O2 -fwrapv -fno-builtin "$W/fstat_size.c" -o "$W/fstat_size.ccb" >/dev/null 2>&1
    crc=0; run "$W/fstat_size.ccb" <"$W/input.bin" >"$W/fstat_size.ccout" 2>/dev/null || crc=$?
    if cmp -s "$W/fstat_size.mout" "$W/fstat_size.ccout" && [ "$mrc" -eq "$crc" ]; then
        echo "FAIL: m_fstat — renumbering fstat 80->79 did NOT diverge (probe is blind)" >&2; exit 1
    fi
    printf 'PASS: m_fstat — fstat 80->79 diverges from the C oracle\n'
else
    printf 'PASS: m_fstat — mutated compiler no longer builds fstat_size correctly\n'
fi

# m_read_dispatch: delete the read() dispatch block. read(...) is then an
# undeclared function, so cat_stdin no longer compiles — the input primitive is
# load-bearing, not accidentally satisfied some other way.
cp src/aster.cpp "$W/m_read.cpp"
sed -i '/if(e.name=="read"&&!functionArities.count(e.name)){/,/^                }$/d' "$W/m_read.cpp"
if grep -q 'if(e.name=="read"&&!functionArities.count(e.name)){' "$W/m_read.cpp"; then
    echo "FAIL: m_read_dispatch — sed did not remove the read dispatch" >&2; exit 1
fi
${CXX:-c++} -std=c++17 -O2 -w "$W/m_read.cpp" -o "$OUT/aster_m_read" 2>/dev/null
emit_case cat_stdin
if "$OUT/aster_m_read" build-elf "$W/cat_stdin.ast" -o "$W/cat_stdin.mab" >/dev/null 2>&1; then
    echo "FAIL: m_read_dispatch — cat_stdin still compiled without the read dispatch" >&2; exit 1
fi
printf 'PASS: m_read_dispatch — removing the read dispatch breaks the compiler\n'

printf '%s\n' 'ALL SYSCALL-IO CHECKS PASSED'
