#!/bin/sh
# tests/heap-checks.sh — the memory side of a self-hosting compiler,
# differentially.
#
# v0.23.41-dev added mmap(2) at 222 and brk(2) at 214: the two system calls
# that give a no-libc program a heap. They are the first intrinsics whose
# *result* is an address, so the shared syscallInsn staging learned to read a
# 64-bit answer (MOV Xd, X0) and to carry an i64 argument at full width —
# mmap's length and offset are the first i64 arguments any intrinsic has
# taken, and staging them through W would silently truncate a length above
# 4 GiB. Both halves of that are pinned here: mmap_huge maps exactly
# 0x1_0000_0000 bytes, which truncates to 0 and fails with EINVAL.
#
# Discipline (carried over from syscall-io-checks.sh): every positive case has
# an Aster source AND a C source that performs the same system calls, and the
# oracle is aarch64-linux-gnu-gcc, not a hand-computed expectation. stdout
# bytes and the exit status are compared per case, so a wrong syscall number,
# a truncated result, a mis-staged argument or a cursor that fails to move
# each fail a case. A wrong expectation cannot make a case pass.
#
# The mutation probes at the bottom are load-bearing, not decoration: they
# renumber the syscalls, narrow the result back to 32 bits, revert the i64
# argument width and delete the dispatch, and assert the suite notices each
# one. m_mmap_result is the bug class this round actually risked — the answer
# is an address, and reading it through W hands back 0x00000000_7fxxxxxx.

set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-heap-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# [1/6] Strictly build the Aster compiler
printf '%s\n' '[1/6] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
# [2/6] Locate an AArch64 C compiler (the independent oracle) and a runner.
printf '%s\n' '[2/6] Locate an AArch64 C compiler and a runner'
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
if [ -z "$HOSTCC" ]; then
    echo "SKIP: heap coverage needs an AArch64 C compiler (none found)"
    exit 0
fi
printf 'int main(){return 0;}\n' > "$W/hostprobe.c"
if ! "$HOSTCC" -O2 -fwrapv "$W/hostprobe.c" -o "$W/hostprobe" 2>/dev/null \
   || ! readelf -h "$W/hostprobe" 2>/dev/null | grep -q 'AArch64'; then
    echo "SKIP: $HOSTCC does not emit AArch64 ELF (cross-compile toolchain missing)"
    exit 0
fi
if ! command -v qemu-aarch64 >/dev/null 2>&1 && [ "$(uname -m)" != "aarch64" ]; then
    echo "SKIP: heap coverage needs qemu-aarch64 (or an AArch64 host)"
    exit 0
fi
run(){ sh tests/run-aarch64.sh "$@"; }

# The file mmap_file maps: two 4096-byte pages of distinct content, so the
# page-aligned offset 4096 maps the second page and a wrong offset (or a
# mapping of the wrong length) shows up in the bytes.
ABS=$(cd "$W" && pwd)
python3 - "$W/big.txt" <<'PYEOF'
import sys
one = (b'FIRST-PAGE-' + bytes(range(65, 91)) * 8) * 200
two = (b'SECOND-PAGE-' + bytes(range(48, 58)) * 10) * 200
with open(sys.argv[1], 'wb') as f:
    f.write(one[:4096]); f.write(two[:4096])
PYEOF
# Stdin is unused by every case here; an empty file keeps the harness uniform.
: > "$W/input.bin"

# ---------------------------------------------------------------------------
# [3/6] Differential battery. Every case is compared against the C oracle on
# stdout and exit status.
CASES="mmap_anon mmap_huge mmap_file brk_grow arena_example"

emit_case(){
    n="$1"
    case "$n" in
    mmap_anon)
        # One anonymous page, poked at five offsets spanning the page (the
        # last byte of it included) through the byte intrinsics, read back
        # and printed. A truncated result address, a wrong length or a
        # mis-staged argument each fault or diverge.
        cat > "$W/$n.ast" <<AST
let res: u8[8] = 0;
fn main() -> i32 {
    let z: ptr = 0;
    let p: ptr = mmap(z, 4096, 3, 34, -1, 0);
    if (p == z) { write(1, "MAP-FAIL\n", 10); return 1; }
    store_u8(p + 0, 11);
    store_u8(p + 1, 22);
    store_u8(p + 7, 33);
    store_u8(p + 255, 44);
    store_u8(p + 4095, 55);
    res[0] = load_u8(p + 0);
    res[1] = load_u8(p + 1);
    res[2] = load_u8(p + 7);
    res[3] = load_u8(p + 255);
    res[4] = load_u8(p + 4095);
    write(1, &res, 5);
    return res[0] + res[1] + res[2] + res[3] + res[4];
}
AST
        cat > "$W/$n.c" <<CEOF
#include <sys/mman.h>
#include <unistd.h>
static unsigned char res[8];
int main(void){
    unsigned char *p = mmap(0, 4096, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (p == 0) { write(1, "MAP-FAIL\n", 10); return 1; }
    p[0]=11; p[1]=22; p[7]=33; p[255]=44; p[4095]=55;
    res[0]=p[0]; res[1]=p[1]; res[2]=p[7]; res[3]=p[255]; res[4]=p[4095];
    write(1, res, 5);
    return res[0]+res[1]+res[2]+res[3]+res[4];
}
CEOF
        ;;
    mmap_huge)
        # A length of exactly 0x1_0000_0000 (4 GiB): the i64 argument-width
        # tripwire. Staged through W it truncates to 0, and mmap rejects a
        # zero length with EINVAL — the intrinsic then answers -22 as a ptr
        # and the poke faults. Full width, the demand-zero mapping succeeds
        # and the first byte is writable. This case is the m_mmap_argwidth
        # probe's resident case.
        cat > "$W/$n.ast" <<AST
fn main() -> i32 {
    let z: ptr = 0;
    let maplen: i64 = 4294967296;
    let p: ptr = mmap(z, maplen, 3, 34, -1, 0);
    if (p == z) { write(1, "MAP-FAIL\n", 10); return 1; }
    store_u8(p, 65);
    let v: i32 = load_u8(p);
    write(1, p, 1);
    return v;
}
AST
        cat > "$W/$n.c" <<CEOF
#include <sys/mman.h>
#include <unistd.h>
int main(void){
    unsigned char *p = mmap(0, (size_t)4294967296ULL, PROT_READ|PROT_WRITE,
                            MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (p == 0) { write(1, "MAP-FAIL\n", 10); return 1; }
    p[0] = 65;
    unsigned char v = p[0];
    write(1, &v, 1);
    return v;
}
CEOF
        ;;
    mmap_file)
        # The bootstrap's read-source pattern: openat -> fstat -> mmap the
        # file (MAP_PRIVATE, page-aligned offset 4096, so the second page is
        # what lands in the mapping) -> close -> read it back one byte at a
        # time through load_u8 -> write it out. A wrong offset, a wrong
        # length, a mapping of the wrong page or a closed-too-early fd each
        # diverge from the oracle.
        cat > "$W/$n.ast" <<AST
let st: u8[144] = 0;
let out: u8[64] = 0;
fn main() -> i32 {
    let z: ptr = 0;
    let fd: i32 = openat(-100, "$ABS/big.txt", 0, 0);
    if (fd < 0) { write(1, "OPEN-ERR\n", 9); return 1; }
    let r: i32 = fstat(fd, &st);
    if (r != 0) { write(1, "FSTAT-ERR\n", 10); return 1; }
    let map: ptr = mmap(z, 4096, 3, 2, fd, 4096);
    close(fd);
    if (map == z) { write(1, "MAP-FAIL\n", 10); return 1; }
    let i: i32 = 0;
    while (i < 32) {
        out[i] = load_u8(map + i);
        i = i + 1;
    }
    write(1, &out, 32);
    return 0;
}
AST
        cat > "$W/$n.c" <<CEOF
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
static unsigned char out[64];
int main(void){
    int fd = openat(AT_FDCWD, "$ABS/big.txt", O_RDONLY, 0);
    if (fd < 0) { write(1, "OPEN-ERR\n", 9); return 1; }
    struct stat st;
    int r = fstat(fd, &st);
    if (r != 0) { write(1, "FSTAT-ERR\n", 10); return 1; }
    unsigned char *map = mmap(0, 4096, PROT_READ|PROT_WRITE, MAP_PRIVATE, fd, 4096);
    close(fd);
    if (map == 0) { write(1, "MAP-FAIL\n", 10); return 1; }
    for (int i = 0; i < 32; i++) out[i] = map[i];
    write(1, out, 32);
    return 0;
}
CEOF
        ;;
    brk_grow)
        # The classic sbrk shape: query the break, grow it by a page, use the
        # fresh memory, read it back. The oracle is the same raw SVC pair in
        # inline asm (x8 = 214), because glibc's brk() answers an int — 0 on
        # success — where the system call answers the new break, and a libc
        # oracle would diverge for a reason that is not a bug.
        cat > "$W/$n.ast" <<AST
let res: u8[8] = 0;
fn main() -> i32 {
    let z: ptr = 0;
    let base: ptr = brk(z);
    let grown: ptr = brk(base + 4096);
    let same: i32 = 0;
    if (grown == base + 4096) { same = 1; }
    store_u8(grown - 4096, 101);
    store_u8(grown - 2048, 102);
    store_u8(grown - 1, 103);
    res[0] = load_u8(grown - 4096);
    res[1] = load_u8(grown - 2048);
    res[2] = load_u8(grown - 1);
    write(1, &res, 3);
    return same * 100 + res[0] + res[1] + res[2];
}
AST
        cat > "$W/$n.c" <<CEOF
#include <unistd.h>
int main(void){
    register long x8 __asm__("x8") = 214;   /* SYS_brk on AArch64 */
    register long x0 __asm__("x0") = 0;     /* brk(0): the current break */
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8) : "memory");
    long base = x0;
    x0 = base + 4096;                        /* grow by one page */
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8) : "memory");
    long grown = x0;
    int same = (grown == base + 4096);
    unsigned char *m = (unsigned char *)grown;
    m[-4096] = 101; m[-2048] = 102; m[-1] = 103;
    unsigned char res[3] = { m[-4096], m[-2048], m[-1] };
    write(1, res, 3);
    return same * 100 + res[0] + res[1] + res[2];
}
CEOF
        ;;
    arena_example)
        # The shipped example against its C twin: a bump allocator over one
        # mmap'd page — allocate three nodes, read a payload back byte by
        # byte, reclaim, allocate again at the same address.
        cp examples/arena.ast "$W/$n.ast"
        cp tests/arena-twin.c "$W/$n.c"
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

printf '%s\n' '[3/6] Differential battery: every case run against the C oracle'
for n in $CASES; do
    emit_case "$n"
    check_case "$n"
done

# ---------------------------------------------------------------------------
# [4/6] Rejections: the argument contract is enforced and names the argument.
printf '%s\n' '[4/6] Rejections: the argument contract is enforced'
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
reject "mmap with five arguments (no offset)" \
    'fn main() -> i32 { let z: ptr = 0; let p: ptr = mmap(z, 4096, 3, 34, -1); return 0; }' \
    "mmap expects (addr: ptr, length: i64, prot: i32, flags: i32, fd: i32, offset: i64)"
reject "mmap with seven arguments" \
    'fn main() -> i32 { let z: ptr = 0; let p: ptr = mmap(z, 4096, 3, 34, -1, 0, 0); return 0; }' \
    "mmap expects (addr: ptr, length: i64, prot: i32, flags: i32, fd: i32, offset: i64)"
reject "mmap with an integer address" \
    'fn main() -> i32 { let p: ptr = mmap(5, 4096, 3, 34, -1, 0); return 0; }' \
    "mmap first argument must be ptr"
reject "mmap with a pointer length" \
    'let gb: u8[8] = 0;
fn main() -> i32 { let p: ptr = mmap(&gb, &gb, 3, 34, -1, 0); return 0; }' \
    "mmap second argument must be i64"
reject "mmap with a bool length" \
    'let gb: u8[8] = 0;
fn main() -> i32 { let p: ptr = mmap(&gb, true, 3, 34, -1, 0); return 0; }' \
    "mmap second argument must be i64"
reject "mmap with a pointer prot" \
    'let gb: u8[8] = 0;
fn main() -> i32 { let p: ptr = mmap(&gb, 4096, &gb, 34, -1, 0); return 0; }' \
    "mmap third argument must be i32"
reject "mmap with a pointer offset" \
    'let gb: u8[8] = 0;
fn main() -> i32 { let p: ptr = mmap(&gb, 4096, 3, 34, -1, &gb); return 0; }' \
    "mmap sixth argument must be i64"
reject "brk with no arguments" \
    'fn main() -> i32 { let p: ptr = brk(); return 0; }' \
    "brk expects (addr: ptr)"
reject "brk with two arguments" \
    'let gb: u8[8] = 0;
fn main() -> i32 { let p: ptr = brk(&gb, &gb); return 0; }' \
    "brk expects (addr: ptr)"
reject "brk with an integer argument" \
    'fn main() -> i32 { let p: ptr = brk(5); return 0; }' \
    "brk argument must be ptr"

# ---------------------------------------------------------------------------
# [5/6] User code wins: a program that defines its own mmap/brk keeps
# compiling, and the intrinsic stands down — the same shadowing rule write and
# read have always had. A counter makes the win observable in the exit status.
printf '%s\n' '[5/6] Shadowing: a user-defined mmap/brk beats the intrinsic'
check_shadow(){ # $1 = name, $2 = source, $3 = expected exit status
    printf '%s\n' "$2" > "$W/$1.ast"
    if ! "$OUT/aster" build-elf "$W/$1.ast" -o "$W/$1.ab" >"$W/$1.log" 2>&1; then
        echo "FAIL: $1 — shadowed build failed:" >&2; cat "$W/$1.log" >&2; return 1
    fi
    src=0
    run "$W/$1.ab" </dev/null >"$W/$1.out" 2>/dev/null || src=$?
    if [ "$src" -ne "$3" ]; then
        echo "FAIL: $1 — exit status $src, expected $3 (the intrinsic fired instead of the user function?)" >&2
        return 1
    fi
    printf 'PASS: %-14s user function won (exit %s)\n' "$1" "$src"
}
check_shadow shadow_mmap \
    'fn mmap(a: ptr, b: i64, c: i32, d: i32, e: i32, f: i64) -> ptr {
    calls = calls + 1;
    return a;
}
let calls: i32 = 0;
let gb: u8[8] = 0;
let gp: ptr = 0;
fn main() -> i32 {
    gp = &gb;
    let p: ptr = mmap(gp, 4096, 3, 34, -1, 0);
    return calls;
}' \
    1
check_shadow shadow_brk \
    'fn brk(p: ptr) -> ptr {
    hits = hits + 1;
    return p;
}
let hits: i32 = 0;
let gb: u8[8] = 0;
let gp: ptr = 0;
fn main() -> i32 {
    gp = &gb;
    let r: ptr = brk(gp);
    return hits;
}' \
    1

# ---------------------------------------------------------------------------
# [6/6] Mutation probes — break the implementation on purpose and assert the
# suite notices. Each builds a mutated compiler from a patched copy of the
# source; the "before" and "after" facts are both asserted.
printf '%s\n' '[6/6] Mutation probes: the numbering, widths and dispatch stay load-bearing'

# m_mmap_num: renumber mmap from 222 to 223. The call then fails (-ENOSYS or
# worse), the intrinsic answers a negative as a ptr, and the poke faults —
# mmap_anon's stdout goes empty and its exit status moves.
cp src/aster.cpp "$W/m_mmap.cpp"
sed -i 's/syscallInsn(222,e\.args/syscallInsn(223,e.args/' "$W/m_mmap.cpp"
if ! grep -q 'syscallInsn(223,e.args' "$W/m_mmap.cpp"; then
    echo "FAIL: m_mmap_num — sed did not apply (the 222 renumber is gone?)" >&2; exit 1
fi
${CXX:-c++} -std=c++17 -O2 -w "$W/m_mmap.cpp" -o "$OUT/aster_m_mmap" 2>/dev/null
emit_case mmap_anon
if "$OUT/aster_m_mmap" build-elf "$W/mmap_anon.ast" -o "$W/mmap_anon.mab" >/dev/null 2>&1; then
    mrc=0
    run "$W/mmap_anon.mab" <"$W/input.bin" >"$W/mmap_anon.mout" 2>/dev/null || mrc=$?
    "$HOSTCC" -O2 -fwrapv -fno-builtin "$W/mmap_anon.c" -o "$W/mmap_anon.ccb" >/dev/null 2>&1
    crc=0; run "$W/mmap_anon.ccb" <"$W/input.bin" >"$W/mmap_anon.ccout" 2>/dev/null || crc=$?
    if cmp -s "$W/mmap_anon.mout" "$W/mmap_anon.ccout" && [ "$mrc" -eq "$crc" ]; then
        echo "FAIL: m_mmap_num — renumbering mmap 222->223 did NOT diverge (probe is blind)" >&2; exit 1
    fi
    printf 'PASS: m_mmap_num — mmap 222->223 diverges from the C oracle\n'
else
    printf 'PASS: m_mmap_num — mutated compiler no longer builds mmap_anon correctly\n'
fi

# m_brk_num: renumber brk from 214 to 215. The query then answers -ENOSYS as
# a ptr, the growth request is computed off it, and the poke faults.
cp src/aster.cpp "$W/m_brk.cpp"
sed -i 's/syscallInsn(214,e\.args/syscallInsn(215,e.args/' "$W/m_brk.cpp"
if ! grep -q 'syscallInsn(215,e.args' "$W/m_brk.cpp"; then
    echo "FAIL: m_brk_num — sed did not apply (the 214 renumber is gone?)" >&2; exit 1
fi
${CXX:-c++} -std=c++17 -O2 -w "$W/m_brk.cpp" -o "$OUT/aster_m_brk" 2>/dev/null
emit_case brk_grow
if "$OUT/aster_m_brk" build-elf "$W/brk_grow.ast" -o "$W/brk_grow.mab" >/dev/null 2>&1; then
    mrc=0
    run "$W/brk_grow.mab" <"$W/input.bin" >"$W/brk_grow.mout" 2>/dev/null || mrc=$?
    "$HOSTCC" -O2 -fwrapv -fno-builtin "$W/brk_grow.c" -o "$W/brk_grow.ccb" >/dev/null 2>&1
    crc=0; run "$W/brk_grow.ccb" <"$W/input.bin" >"$W/brk_grow.ccout" 2>/dev/null || crc=$?
    if cmp -s "$W/brk_grow.mout" "$W/brk_grow.ccout" && [ "$mrc" -eq "$crc" ]; then
        echo "FAIL: m_brk_num — renumbering brk 214->215 did NOT diverge (probe is blind)" >&2; exit 1
    fi
    printf 'PASS: m_brk_num — brk 214->215 diverges from the C oracle\n'
else
    printf 'PASS: m_brk_num — mutated compiler no longer builds brk_grow correctly\n'
fi

# m_mmap_result: read the syscall answer back through W instead of X. Every
# intrinsic still answers, but mmap/brk's address loses its upper 32 bits —
# the guest mapping lives far above 4 GiB, so the poke lands on an unmapped
# low address and faults. This is the bug class the 64-bit result read exists
# to prevent, pinned so it can never regress silently.
cp src/aster.cpp "$W/m_res.cpp"
sed -i 's/tyIs64(resultTy)?0xaa0003e0u:0x2a0003e0u/0x2a0003e0u/' "$W/m_res.cpp"
if grep -q 'tyIs64(resultTy)?0xaa0003e0u:0x2a0003e0u' "$W/m_res.cpp"; then
    echo "FAIL: m_mmap_result — sed did not apply (the result-width choice is gone?)" >&2; exit 1
fi
${CXX:-c++} -std=c++17 -O2 -w "$W/m_res.cpp" -o "$OUT/aster_m_res" 2>/dev/null
emit_case mmap_anon
if "$OUT/aster_m_res" build-elf "$W/mmap_anon.ast" -o "$W/mmap_anon.rab" >/dev/null 2>&1; then
    mrc=0
    run "$W/mmap_anon.rab" <"$W/input.bin" >"$W/mmap_anon.rout" 2>/dev/null || mrc=$?
    if cmp -s "$W/mmap_anon.rout" "$W/mmap_anon.ccout" && [ "$mrc" -eq "$crc" ]; then
        echo "FAIL: m_mmap_result — a 32-bit result read did NOT diverge (probe is blind)" >&2; exit 1
    fi
    printf 'PASS: m_mmap_result — narrowing the result to 32 bits diverges from the C oracle\n'
else
    printf 'PASS: m_mmap_result — mutated compiler no longer builds mmap_anon correctly\n'
fi

# m_mmap_argwidth: revert the i64 argument staging to the ptr-only test.
# mmap_huge's 4 GiB length truncates to 0, the kernel answers EINVAL, and the
# poke at the returned -22 faults — the length that matters is the one above
# 32 bits, which is exactly what the wider staging carries.
cp src/aster.cpp "$W/m_arg.cpp"
sed -i 's/tyIs64(tys\[i\])?0xaa0003e0u/(tys[i]==Ty::Ptr)?0xaa0003e0u/' "$W/m_arg.cpp"
if grep -q 'tyIs64(tys\[i\])?0xaa0003e0u' "$W/m_arg.cpp"; then
    echo "FAIL: m_mmap_argwidth — sed did not apply (the i64 argument width is gone?)" >&2; exit 1
fi
${CXX:-c++} -std=c++17 -O2 -w "$W/m_arg.cpp" -o "$OUT/aster_m_arg" 2>/dev/null
emit_case mmap_huge
if "$OUT/aster_m_arg" build-elf "$W/mmap_huge.ast" -o "$W/mmap_huge.gab" >/dev/null 2>&1; then
    mrc=0
    run "$W/mmap_huge.gab" <"$W/input.bin" >"$W/mmap_huge.gout" 2>/dev/null || mrc=$?
    "$HOSTCC" -O2 -fwrapv -fno-builtin "$W/mmap_huge.c" -o "$W/mmap_huge.gcb" >/dev/null 2>&1
    crc=0; run "$W/mmap_huge.gcb" <"$W/input.bin" >"$W/mmap_huge.gcout" 2>/dev/null || crc=$?
    if cmp -s "$W/mmap_huge.gout" "$W/mmap_huge.gcout" && [ "$mrc" -eq "$crc" ]; then
        echo "FAIL: m_mmap_argwidth — staging the i64 length through W did NOT diverge (probe is blind)" >&2; exit 1
    fi
    printf 'PASS: m_mmap_argwidth — a 32-bit length truncates 4 GiB to 0 and diverges\n'
else
    printf 'PASS: m_mmap_argwidth — mutated compiler no longer builds mmap_huge correctly\n'
fi

# m_mmap_dispatch: delete the mmap dispatch block from codegen. mmap(...) is
# then an undeclared function, so mmap_anon no longer compiles — the heap
# primitive is load-bearing, not accidentally satisfied some other way.
cp src/aster.cpp "$W/m_disp.cpp"
sed -i '/if(e.name=="mmap"&&!functionArities.count(e.name)){/,/^                }$/d' "$W/m_disp.cpp"
if grep -q 'if(e.name=="mmap"&&!functionArities.count(e.name)){' "$W/m_disp.cpp"; then
    echo "FAIL: m_mmap_dispatch — sed did not remove the mmap dispatch" >&2; exit 1
fi
${CXX:-c++} -std=c++17 -O2 -w "$W/m_disp.cpp" -o "$OUT/aster_m_disp" 2>/dev/null
emit_case mmap_anon
if "$OUT/aster_m_disp" build-elf "$W/mmap_anon.ast" -o "$W/mmap_anon.dab" >/dev/null 2>&1; then
    echo "FAIL: m_mmap_dispatch — mmap_anon still compiled without the mmap dispatch" >&2; exit 1
fi
printf 'PASS: m_mmap_dispatch — removing the mmap dispatch breaks the compiler\n'

printf '%s\n' 'ALL HEAP CHECKS PASSED'
