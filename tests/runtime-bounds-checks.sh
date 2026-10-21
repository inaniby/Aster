#!/bin/sh
# v0.23.1-dev structural + behavioral checks for --bounds-check (P1.5).
#
# Constant out-of-bounds indexes have always been a compile-time error. The
# other half of the array-safety story -- an index whose value is only known at
# run time -- used to read or write neighbouring memory in silence. `--bounds-check`
# closes that hole: every dynamic index into a fixed-size array is compared
# against the array's length and traps with BRK #1 (SIGTRAP) when it is out of
# range. One unsigned comparison covers both halves of the range, because a
# negative index is a huge unsigned value.
#
# The flag is OFF by default, so an ordinary build emits the bytes it always
# did; this suite proves that as well. Layers: strict compiler build, source
# guards, flag routing (the link commands must reject it), compile-time
# rejection still wins with the flag on, structural BRK counts, qemu runs of
# the in-range and out-of-range paths, and a bit-level check of the trap
# encoding.
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-runtime-bounds-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# Run an Aster-built AArch64 binary and report its status without tripping
# `set -e`: the whole point of several checks below is that the guest dies.
run_status(){ st=0; "$PWD/tests/run-aarch64.sh" "$1" >/dev/null 2>&1 || st=$?; echo "$st"; }

printf '%s\n' '[1/8] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

printf '%s\n' '[2/8] Source guard: --bounds-check plumbing and the trap sequence'
# A regression that drops the flag, the Codegen member, the range test, the BRK
# encoding, or the skip-over-the-trap branch must fail here first.
grep -qF 'else if(a=="--bounds-check")boundsCheck=true;' src/aster.cpp \
    || { echo 'FAIL: --bounds-check missing from the command line' >&2; exit 1; }
grep -qF 'bool boundsCheck=false;' src/aster.cpp \
    || { echo 'FAIL: boundsCheck member missing from Codegen' >&2; exit 1; }
# Matched on the member init rather than on the whole constructor signature:
# the signature gains a parameter whenever Codegen grows an option (v0.23.12-dev
# added -g), and re-spelling it here every time is churn that hides the real
# intent — the flag has to reach the member.
grep -qF 'boundsCheck(runtimeBoundsCheck)' src/aster.cpp \
    || { echo 'FAIL: boundsCheck is not threaded into Codegen' >&2; exit 1; }
grep -qF 'void emitBoundsCheck(const std::string& name,const Expr& index,int idxReg){' src/aster.cpp \
    || { echo 'FAIL: emitBoundsCheck missing from codegen' >&2; exit 1; }
grep -qF 'static uint32_t brk(uint32_t imm){return 0xd4200000u|((imm&0xffffu)<<5);}' src/aster.cpp \
    || { echo 'FAIL: BRK encoding helper missing' >&2; exit 1; }
# The trap sits on the fall-through path, so the branch must jump *over* it
# (B.LO = cond 3) — branching *to* it would trap on every index.
grep -qF 'patchCond(at,3,(int)code.size());' src/aster.cpp \
    || { echo 'FAIL: bounds check must branch over the BRK, not to it' >&2; exit 1; }
# v0.23.28-dev: both read paths (a local array and a global one) compute their
# element address in emitElemAddr, so the two calls there are the read side's
# bounds check; the write path's own call is pinned separately below.
test "$(grep -cF 'emitBoundsCheck(name,index,r);' src/aster.cpp)" -eq 2 \
    || { echo 'FAIL: array reads are not bounds-checked' >&2; exit 1; }
grep -qF 'emitBoundsCheck(s.name,*s.idx,r);' src/aster.cpp \
    || { echo 'FAIL: array writes are not bounds-checked' >&2; exit 1; }
# Constant indexes are already proved in range by checkArrayBounds, so the
# run-time test must skip them: turning the flag on cannot change such a build.
grep -qF 'if(constantInteger(index,folded))return; // compile-time check already covers it' src/aster.cpp \
    || { echo 'FAIL: bounds check must skip constant indexes' >&2; exit 1; }
printf '%s\n' 'PASS: --bounds-check flag, Codegen plumbing, range test and BRK encoding present'

printf '%s\n' '[3/8] Flag routing: --bounds-check is a compile-time option only'
# The link commands consume objects, not sources: accepting the flag there would
# silently do nothing, so it is rejected with the usage banner (exit 2).
"$OUT/aster" build-elf /dev/null -o "$OUT/dummy.elf" >/dev/null 2>&1 || true
"$OUT/aster" build-obj "$OUT/nonexistent.ast" -o "$OUT/x.o" --bounds-check >/dev/null 2>&1 && \
    { echo 'FAIL: build-obj accepted a missing input' >&2; exit 1; }
for lcmd in link-obj link-pie link-so; do
    st=0; "$OUT/aster" "$lcmd" "$OUT/x.o" -o "$OUT/x.out" --bounds-check >/dev/null 2>&1 || st=$?
    [ "$st" = 2 ] || { echo "FAIL: $lcmd must reject --bounds-check (exit 2, got $st)" >&2; exit 1; }
done
# An unrecognized option is still an error, so the flag did not loosen parsing.
st=0; "$OUT/aster" build-elf "$OUT/x.o" -o "$OUT/x.out" --nope >/dev/null 2>&1 || st=$?
[ "$st" = 2 ] || { echo "FAIL: unknown option must still be rejected (exit 2, got $st)" >&2; exit 1; }
printf '%s\n' 'PASS: link-obj/link-pie/link-so reject --bounds-check; unknown options still fail'

printf '%s\n' '[4/8] Compile-time bounds checking still wins with the flag on'
cat > "$OUT/const-global.ast" <<'AST'
let b: i32[4] = 0;
fn main() -> i32 { return b[5]; }
AST
cat > "$OUT/const-local.ast" <<'AST'
fn main() -> i32 { let a: i32[4] = 0; return a[4]; }
AST
cat > "$OUT/const-neg.ast" <<'AST'
let b: i32[4] = 0;
fn main() -> i32 { let r: i32 = b[-1]; return r; }
AST
for f in const-global const-local const-neg; do
    "$OUT/aster" build-elf "$OUT/$f.ast" -o "$OUT/x" --bounds-check 2>&1 | grep -qF 'array index out of bounds' \
        || { echo "FAIL: constant out-of-bounds index not rejected at compile time ($f)" >&2; exit 1; }
done
printf '%s\n' 'PASS: constant indexes are still rejected by the compiler, flag or no flag'

printf '%s\n' '[5/8] Structure: default emits no trap, --bounds-check emits one per dynamic index'
cat > "$OUT/dyn.ast" <<'AST'
let buf: i32[8] = 0;
fn read(i: i32) -> i32 { return buf[i]; }
fn write(i: i32, v: i32) -> i32 { buf[i] = v; return 0; }
fn main() -> i32 {
    let a: i32[4] = 0;
    let k: i32 = 2;
    a[k] = 7;
    let z: i32 = write(3, 9);
    return a[k] + read(3) + z;
}
AST
cat > "$OUT/const.ast" <<'AST'
let buf: i32[8] = 0;
fn main() -> i32 { buf[0] = 5; return buf[0]; }
AST
"$OUT/aster" build-elf "$OUT/dyn.ast" -o "$OUT/dyn-off" >/dev/null
"$OUT/aster" build-elf "$OUT/dyn.ast" -o "$OUT/dyn-on" --bounds-check >/dev/null
"$OUT/aster" build-elf "$OUT/const.ast" -o "$OUT/const-off" >/dev/null
"$OUT/aster" build-elf "$OUT/const.ast" -o "$OUT/const-on" --bounds-check >/dev/null
# Four dynamic indexes: a[k] write, a[k] read, buf[i] in read(), buf[i] in write().
python3 - "$OUT/dyn-off" "$OUT/dyn-on" <<'PY'
import struct, sys
def words(path):
    b = open(path, 'rb').read()
    assert b[:4] == b'\x7fELF'
    shoff, = struct.unpack_from('<Q', b, 40)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
    def sh(i):
        o = shoff + i * shentsize
        name, _t, _f, addr, off, size = struct.unpack_from('<IIQQQQ', b, o)
        return name, addr, off, size
    strbase = sh(shstrndx)[2]
    for i in range(shnum):
        name, addr, off, size = sh(i)
        n = b[strbase + name:b.index(b'\0', strbase + name)].decode()
        if n == '.text':
            return list(struct.unpack_from('<%dI' % (size // 4), b, off))
    raise AssertionError('no .text')
BRK1 = 0xd4200020
off_w, on_w = words(sys.argv[1]), words(sys.argv[2])
assert not [w for w in off_w if w == BRK1], 'default build contains a bounds trap'
traps = [w for w in on_w if w == BRK1]
assert len(traps) == 4, 'expected 4 traps (a[k] write, a[k] read, buf[i] read, buf[i] write), got %d' % len(traps)
print('PASS: default build has 0 traps; --bounds-check adds exactly 4 (one per dynamic index)')
PY
cmp "$OUT/const-off" "$OUT/const-on" \
    || { echo 'FAIL: --bounds-check changed a program that only indexes with constants' >&2; exit 1; }
printf '%s\n' 'PASS: a constant-index program is byte-identical with the flag on'

printf '%s\n' '[6/8] Acceptance: in-range dynamic indexes behave identically (qemu self-check)'
st=$(run_status "$OUT/dyn-off"); [ "$st" = 16 ] || { echo "FAIL: dyn-off exit $st, want 16" >&2; exit 1; }
st=$(run_status "$OUT/dyn-on");  [ "$st" = 16 ] || { echo "FAIL: dyn-on exit $st, want 16" >&2; exit 1; }
cat > "$OUT/edge.ast" <<'AST'
let buf: i32[8] = 0;
fn main() -> i32 {
    let lo: i32 = 0;
    let hi: i32 = 7;
    buf[lo] = 3;
    buf[hi] = 4;
    return buf[lo] * 10 + buf[hi] - 34;
}
AST
"$OUT/aster" build-elf "$OUT/edge.ast" -o "$OUT/edge" --bounds-check >/dev/null
"$PWD/tests/run-aarch64.sh" "$OUT/edge"
printf '%s\n' 'PASS: index 0 and index len-1 are accepted (3*10+4 == 34, exit 0)'

printf '%s\n' '[7/8] Acceptance: out-of-range indexes trap instead of corrupting memory (qemu self-check)'
cat > "$OUT/oob-high.ast" <<'AST'
let buf: i32[8] = 0;
fn main() -> i32 { let i: i32 = 8; return buf[i]; }
AST
cat > "$OUT/oob-neg.ast" <<'AST'
let buf: i32[8] = 0;
fn main() -> i32 { let i: i32 = 0 - 1; return buf[i]; }
AST
cat > "$OUT/oob-local.ast" <<'AST'
fn main() -> i32 { let a: i32[4] = 0; let i: i32 = 4; a[i] = 9; return a[0]; }
AST
cat > "$OUT/oob-global-write.ast" <<'AST'
let buf: i32[8] = 0;
fn main() -> i32 { let i: i32 = 9; buf[i] = 1; return buf[0]; }
AST
for f in oob-high oob-neg oob-local oob-global-write; do
    "$OUT/aster" build-elf "$OUT/$f.ast" -o "$OUT/$f-on" --bounds-check >/dev/null
    st=$(run_status "$OUT/$f-on")
    [ "$st" = 133 ] || { echo "FAIL: $f with --bounds-check exit $st, want 133 (SIGTRAP)" >&2; exit 1; }
done
# The default build does not trap: that is exactly the hole being closed, and
# it must stay reachable so the flag remains opt-in.
"$OUT/aster" build-elf "$OUT/oob-high.ast" -o "$OUT/oob-high-off" >/dev/null
st=$(run_status "$OUT/oob-high-off")
[ "$st" != 133 ] || { echo 'FAIL: the default build traps: --bounds-check is no longer opt-in' >&2; exit 1; }
printf '%s\n' 'PASS: index == len, a negative index, and out-of-range local/global writes all raise SIGTRAP (133); the default build still does not'

printf '%s\n' '[8/8] Bit-level: the trap is BRK #1, and the range test is one CMP + B.LO'
python3 - "$OUT/dyn-on" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
assert b[:4] == b'\x7fELF'
shoff, = struct.unpack_from('<Q', b, 40)
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
def sh(i):
    o = shoff + i * shentsize
    name, _t, _f, addr, off, size = struct.unpack_from('<IIQQQQ', b, o)
    return name, addr, off, size
strbase = sh(shstrndx)[2]
text = None
for i in range(shnum):
    name, addr, off, size = sh(i)
    if b[strbase + name:b.index(b'\0', strbase + name)].decode() == '.text':
        text = (addr, off, size)
w = list(struct.unpack_from('<%dI' % (text[2] // 4), b, text[1]))
BRK1 = 0xd4200020
# The original bug: the branch targeted the BRK itself, which is also the
# fall-through address, so every index trapped. B.LO with a +2 instruction
# delta (0x54000083) is the only correct skip.
skip = 0x54000043          # B.LO with imm19 = 2: 0x54000000 | (2 << 5) | cond 3
zo = 0x7100201f   # cmp w0, #8
fo = 0x7100101f   # cmp w0, #4
assert w.count(BRK1) == 4, 'expected 4 BRK #1, got %d' % w.count(BRK1)
assert w.count(skip) >= 2, 'B.LO +2 (skip over BRK) missing'
assert w.count(zo) == 2 and w.count(fo) == 2, 'expected CMP w0, #8 twice and CMP w0, #4 twice'
print('PASS: 4x BRK #1 with B.LO +2 skips; CMP w0, #8 (global) x2 and CMP w0, #4 (local) x2')
PY
