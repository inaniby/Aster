#!/bin/sh
# tests/frame-slot-contract-checks.sh — resident gate for the three audit
# repairs that landed on main at v0.23.77-dev (D-01 / D-02 / D-09 of
# AUDIT-v0.23.77-dev.md), promoted to v0.23.78-dev by this round.
#
# v0.23.78-dev changes NO compiler behaviour: the repairs arrived in three
# upstream commits (bootstrap char, the three externally reproduced defects,
# and the touch-example comment). What was thin about them is the gate: six
# lines in frame-size-checks.sh, five in float-literal-checks.sh, and nothing
# at all for the high-slot f64 store that wrote into the caller's stack.
# This suite is the resident nail.
#
#   D-01  incomingBaseWords patched a single `ADD X16, SP, #frameBytes`;
#         imm12 is 12 bits, so a compact frame over 4095 bytes corrupted the
#         instruction. The upstream fix keeps the default 8192 frame when the
#         wanted size does not fit, which the unpatched word already says.
#   D-02  loadVarT/storeVarT wrote the F64 immediate as slot*8, but LDR/STR D
#         already scale imm12 by 8. A double landed eight slots away; at
#         slot >= 128 it landed at [sp,#8192] and wrote into the caller's
#         stack. The fix uses the unscaled slot.
#   D-09  the number loop accepted a fractional part and an exponent any
#         number of times, so `1.5.2` and `1e2e3` glued into one token. The
#         fix tracks seenDot / seenExp.
#
# Layers (the 9-layer shape): strict build; source guards; a static binary
# oracle that decodes .text words with no binutils; the behavioural matrix;
# a C oracle; every writer and link; a coverage census; six mutations; the
# byte baseline (zero drift, all 393 rows reproduced).
#
# Cross-host note (v0.23.77-dev's lesson): AArch64 binaries go through
# $RUNNER, C oracles through $HOSTCC, and the primary instruction-word oracle
# is pure Python, so x86_64+qemu and native AArch64/Termux assert the same
# things. GNU objdump is a second witness, never the only one.
set -eu
cd "$(dirname "$0")/.."
. tests/lib/baseline.sh
. tests/lib/verdict.sh
. tests/lib/tools.sh
CXX=${CXX:-c++}
HOSTCC=${HOSTCC:-cc}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-frame-slot-contract-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
run(){ sh "$RUNNER" "$@"; }
COVER=0
bump(){ COVER=$((COVER + 1)); }
fail(){ echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
A=$OUT/aster
grep -qF '#define ASTER_VERSION_STRING "0.23.79-dev"' src/aster.cpp \
    || fail 'the version constant is not 0.23.78-dev'
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: the three upstream repairs are present and pinned'
python3 - <<'PY' || exit 1
import pathlib
s = pathlib.Path('src/aster.cpp').read_text(encoding='utf-8')

def body(name):
    start = s.index('static uint32_t %s(' % name)
    end = s.index('static uint32_t ', start + 10)
    return s[start:end]

ld, st = body('loadVarT'), body('storeVarT')
for label, b in (('loadVarT', ld), ('storeVarT', st)):
    # Comments legitimately say "slot*8" when describing the byte offset;
    # only the *encoding expression* (slot*8) is forbidden.
    assert '(slot*8)' not in b, (label, 'eightfold scale is back')
    print('  OK %s: no eightfold F64 encoding' % label)
assert '0xfd4003e0u|(uint32_t(slot)<<10)' in ld, 'LDR D immediate is not the slot'
assert '0xbd4003e0u|(uint32_t(slot*2)<<10)' in ld, 'LDR S scale changed'
assert '0xfd0003e0u|(uint32_t(slot)<<10)' in st, 'STR D immediate is not the slot'
assert '0xbd0003e0u|(uint32_t(slot*2)<<10)' in st, 'STR S scale changed'
print('  OK F64 immediates are unscaled; F32 keeps its factor of two')

assert s.count('if(want<=4095u){') == 2, 'both compact-frame bounds are gone'
assert 'if(compact&&frameBytes!=8192u)' in s, 'the incoming-base patch lost its guard'
assert '0x910003f0u|(frameBytes<<10)' in s, 'the legal small-frame patch is gone'
assert 'if(frameBytes>8192u)frameBytes=8192u;' in s, 'frameBytes lost its 8192 clamp'
print('  OK a compact frame above 4095 falls back to the default 8192 frame')

assert 'bool seenDot=false, seenExp=false;' in s, 'lexer lost its one-dot/one-exp state'
assert "!seenDot&&!seenExp&&q=='.'" in s, 'the fractional-part guard is gone'
assert "!seenExp&&(q=='e'||q=='E')" in s, 'the exponent guard is gone'
print('  OK lexer accepts at most one fractional part and one exponent')
PY
bump; bump

# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] Static binary oracle: decode .text words with no binutils'
cat > "$W/insn.py" <<'PY'
#!/usr/bin/env python3
"""Independent AArch64 instruction-word reader for Aster ELF64 images.

No binutils: parse the section table, read .text, decode only the encodings
this suite pins. Little-endian ELF64 throughout.
"""
import pathlib, struct, sys

def words(path):
    b = pathlib.Path(path).read_bytes()
    assert b[:6] == b'\x7fELF\x02\x01', ('not ELF64 little-endian', path)
    shoff = struct.unpack_from('<Q', b, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 0x3a)
    sh = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i*shentsize)
          for i in range(shnum)]
    st = sh[shstrndx]
    names = b[st[4]:st[4]+st[5]]
    def nm(x):
        return names[x[0]:names.index(b'\0', x[0])].decode()
    for x in sh:
        if nm(x) == '.text':
            off, size = x[4], x[5]
            assert size % 4 == 0, ('odd .text size', path)
            return list(struct.unpack_from('<' + 'I'*(size//4), b, off))
    raise SystemExit('FAIL: no .text section in %s' % path)

# ADD X16, SP, #imm12{,LSL #12}: shift is bit 22; the only legal shifted
# form in an Aster image is the default 8192 frame, 0x91400bf0.
# STR/LDR D/S with Rn = SP; Rt varies, so mask bits 4:0 out of the tag.
def add16_sp(w):  return ((w & 0xff000000) == 0x91000000
                          and ((w >> 5) & 0x1f) == 31 and (w & 0x1f) == 16)
def fp(w, tag):   return (w & 0xffc003e0) == tag
def imm12(w):     return (w >> 10) & 0xfff

def main():
    cmd, path = sys.argv[1], sys.argv[2]
    ws = words(path)
    if cmd == 'words':
        for w in ws: print('%08x' % w)
    elif cmd == 'has':
        sys.exit(0 if int(sys.argv[3], 16) in ws else 1)
    elif cmd == 'hasnt':
        sys.exit(0 if int(sys.argv[3], 16) not in ws else 1)
    elif cmd == 'spadd':
        # Every legal small-frame ADD X16, SP, #imm has shift=0; list its imm12.
        for w in ws:
            if add16_sp(w) and not (w & 0x00400000):
                print(imm12(w))
    elif cmd == 'badspadd':
        # The old defect wrote frameBytes (>=4096) into an unscaled imm12, so
        # the shift field lit up and Rd/Rn were corrupted. 0x91400bf0 is the
        # one legal shifted ADD X16,SP word (ADD X16, SP, #2, LSL #12).
        bad = [w for w in ws
               if add16_sp(w) and (w & 0x00400000) and w != 0x91400bf0]
        if bad:
            print('BAD ' + ' '.join('%08x' % w for w in bad), path)
            sys.exit(1)
        print('  OK no overflowing ADD X16,SP immediate', path)
    elif cmd == 'etype':
        b = pathlib.Path(path).read_bytes()
        e = struct.unpack_from('<H', b, 0x10)[0]
        print({1: 'REL', 2: 'EXEC', 3: 'DYN'}.get(e, str(e)))
    elif cmd in ('strd', 'ldrd', 'strs', 'ldrs'):
        tag = {'strd': 0xfd0003e0, 'ldrd': 0xfd4003e0,
               'strs': 0xbd0003e0, 'ldrs': 0xbd4003e0}[cmd]
        for w in ws:
            if fp(w, tag): print(imm12(w))
    else:
        raise SystemExit('FAIL: unknown insn.py command %s' % cmd)

main()
PY
# Probes: a D-01 frame spectrum straddling 4096, and a D-02 slot matrix with
# a caller-stack guard plus f32/i32 controls.
python3 - <<'PY'
import os, pathlib
W = pathlib.Path(os.environ.get('OUT', 'tmp-frame-slot-contract-checks')) / 'work'
D01 = """fn g(n:i32)->i32 {{ return n; }}
fn f(a:i32,b:i32,c:i32,d:i32,e:i32,g:i32,h:i32,i:i32,j:i32)->i32 {{
    let pad: i64[{pad}] = 0;
    let t: i32 = g(g(0));
    return j - a + t;
}}
fn main()->i32 {{ return f(1,2,3,4,5,6,7,8,9); }}
"""
for pad in (100, 450, 465, 466, 467, 469, 480, 490):
    (W / ('d01_p%d.ast' % pad)).write_text(D01.format(pad=pad))

def decls(prefix, n):
    return '\n'.join('    let %s%d: i32 = 0;' % (prefix, i) for i in range(n))

(W/'d02_slot1.ast').write_text("""fn main() -> i32 {
    let lead: i32 = 1;
    let x: f64 = 2.5;
    let p1: i32=0; let p2: i32=0; let p3: i32=0; let p4: i32=0;
    let p5: i32=0; let p6: i32=0; let p7: i32=0;
    p7 = 99;
    if (x == 2.5) { return 0; }
    return 1;
}
""")
(W/'d02_slot0.ast').write_text("""fn main() -> i32 {
    let x: f64 = 2.5;
    if (x == 2.5) { return 0; }
    return 1;
}
""")
# slot 7: the old eightfold store landed at slot 56 == t48.
(W/'d02_slot7.ast').write_text("""fn main() -> i32 {
%s
    let x: f64 = 2.5;
%s
    t48 = 99;
    if (x == 2.5) { return 0; }
    return 1;
}
""" % (decls('l', 7), decls('t', 56)))
(W/'d02_guard128.ast').write_text("""fn probe() -> i32 {
%s
    let x: f64 = 2.5;
    return 0;
}
fn main() -> i32 {
    let guard: i32 = 12345;
    let r: i32 = probe();
    if (guard == 12345) { return 0; }
    return 20;
}
""" % decls('v', 128))
(W/'d02_nine.ast').write_text("""fn f(a:f64,b:f64,c:f64,d:f64,e:f64,g:f64,h:f64,i:f64,j:f64)->f64 {
    let pad: i64[480] = 0;
    return j - a;
}
fn main()->i32 { return i32(f(1.0,2.0,3.0,4.0,5.0,6.0,7.0,8.0,9.0)); }
""")
(W/'d02_f32_ctl.ast').write_text("""fn main() -> i32 {
    let lead: i32 = 1;
    let x: f32 = f32(2.5);
    let p1: i32=0; let p2: i32=0; let p3: i32=0; let p4: i32=0;
    let p5: i32=0; let p6: i32=0; let p7: i32=0;
    p7 = 99;
    if (x == f32(2.5)) { return 0; }
    return 1;
}
""")
(W/'d02_i32_ctl.ast').write_text("""fn main() -> i32 {
    let lead: i32 = 1;
    let x: i32 = 7;
    let p1: i32=0; let p2: i32=0; let p3: i32=0; let p4: i32=0;
    let p5: i32=0; let p6: i32=0; let p7: i32=0;
    p7 = 99;
    if (x == 7) { return 0; }
    return 1;
}
""")
PY
insn(){ python3 "$W/insn.py" "$@"; }
# D-09: two malformed literals and four legal controls.
for spec in 'twodot 1.5.2' 'twoexp 1e2e3' 'frac 1.5' 'exp 1e2' 'fracexp 1.5e2' 'expneg 1.5e-2'; do
    set -- $spec; n=$1; lit=$2
    printf 'fn main() -> i32 { let x: f64 = %s; return 0; }\n' "$lit" > "$W/d09_$n.ast"
done
for pad in 100 450 465 466 467 469 480 490; do
    "$A" build-elf --compact-frames "$W/d01_p$pad.ast" -o "$W/c_p$pad" >/dev/null
    "$A" build-elf "$W/d01_p$pad.ast" -o "$W/n_p$pad" >/dev/null
done
for name in slot0 slot1 slot7 guard128 nine f32_ctl i32_ctl; do
    "$A" build-elf "$W/d02_$name.ast" -o "$W/d02_$name" >/dev/null
done

# D-01: no ADD X16,SP immediate may overflow. Small compact frames keep a
# legal unshifted ADD and lose the 8192 default; large ones keep 8192 (the
# upstream fallback) and get no patch at all. Non-compact always keeps 8192.
for pad in 100 450 465 466; do
    insn badspadd "$W/c_p$pad" >/dev/null || fail "compact pad=$pad has an overflowing ADD X16,SP immediate"
    insn hasnt "$W/c_p$pad" 91400bf0 >/dev/null || fail "compact pad=$pad did not compact"
    n=$(insn spadd "$W/c_p$pad" | wc -l)
    [ "$n" -ge 1 ] || fail "compact pad=$pad has no legal ADD X16,SP,#imm"
    insn spadd "$W/c_p$pad" | awk '$1>4095{exit 1}' \
        || fail "compact pad=$pad immediate exceeds the 12-bit field"
    insn has "$W/n_p$pad" 91400bf0 >/dev/null || fail "normal pad=$pad lost ADD X16,SP,#8192"
    bump; bump
done
for pad in 467 469 480 490; do
    insn badspadd "$W/c_p$pad" >/dev/null || fail "compact pad=$pad has an overflowing ADD X16,SP immediate"
    insn has "$W/c_p$pad" 91400bf0 >/dev/null \
        || fail "compact pad=$pad did not fall back to the default 8192 frame"
    [ -z "$(insn spadd "$W/c_p$pad")" ] \
        || fail "compact pad=$pad still patched a frame above 4095"
    insn has "$W/n_p$pad" 91400bf0 >/dev/null || fail "normal pad=$pad lost ADD X16,SP,#8192"
    bump; bump
done
# D-02: STR D uses the slot itself, never slot*8. slot 0 is the control.
for spec in 'slot0 0' 'slot1 1' 'slot7 7' 'guard128 128'; do
    set -- $spec; name=$1; slot=$2
    insn strd "$W/d02_$name" | grep -qx "$slot" \
        || fail "d02_$name has no STR D with imm12=$slot"
    if [ "$slot" -ne 0 ]; then
        old=$((slot * 8))
        if insn strd "$W/d02_$name" | grep -qx "$old"; then
            fail "d02_$name still has the eightfold STR D (imm12=$old)"
        fi
    fi
    bump
done
insn strs "$W/d02_f32_ctl" | grep -qx 2 || fail 'the f32 scale regressed'
bump
printf '  %-40s %s\n' 'instruction words decoded' 'Python only, zero binutils'; bump
if [ -n "$AST_OBJDUMP" ]; then
    "$AST_OBJDUMP" -d "$W/d02_guard128" | grep -qE 'str[[:space:]]+d0, \[sp, #1024\]' \
        || fail 'objdump disagrees: slot 128 is not [sp,#1024]'
    printf '  %-40s %s\n' 'GNU objdump cross-check' 'slot 128 = [sp,#1024]'; bump
else
    printf '  %-40s %s\n' 'GNU objdump cross-check' 'SKIP: no objdump (Python oracle still ran)'
fi

# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] Behavioural matrix: frame spectrum and f64 slot matrix'
for pad in 100 450 465 466 467 469 480 490; do
    rc_c=0; run "$W/c_p$pad" >/dev/null 2>&1 || rc_c=$?
    rc_n=0; run "$W/n_p$pad" >/dev/null 2>&1 || rc_n=$?
    [ "$rc_c" = 8 ] || fail "compact pad=$pad returned $rc_c, expected 8"
    [ "$rc_n" = 8 ] || fail "normal pad=$pad returned $rc_n, expected 8"
    printf '  %-40s %s\n' "D-01 pad=$pad compact/normal" 'both returned 8'; bump
done
for spec in 'slot0 0' 'slot1 0' 'slot7 0' 'guard128 0' 'nine 8' 'f32_ctl 0' 'i32_ctl 0'; do
    set -- $spec; name=$1; want=$2
    rc=0; run "$W/d02_$name" >/dev/null 2>&1 || rc=$?
    [ "$rc" = "$want" ] || fail "d02_$name returned $rc, expected $want"
    printf '  %-40s %s\n' "D-02 d02_$name" "returned $want"; bump
done

# D-09: the malformed literals must be refused; the legal ones must still build.
for n in twodot twoexp; do
    if "$A" build-elf "$W/d09_$n.ast" -o "$W/d09_$n" >/dev/null 2>&1; then
        fail "malformed literal d09_$n was accepted"
    fi
    printf '  %-40s %s\n' "D-09 d09_$n" 'refused'; bump
done
for n in frac exp fracexp expneg; do
    "$A" build-elf "$W/d09_$n.ast" -o "$W/d09_$n" >/dev/null \
        || fail "valid literal d09_$n was refused"
    rc=0; run "$W/d09_$n" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || fail "valid literal d09_$n returned $rc"
    printf '  %-40s %s\n' "D-09 d09_$n" 'accepted'; bump
done

# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] C oracle: the language-level answers an independent compiler gives'
cat > "$W/oracle.c" <<'C'
#include <stdint.h>
/* The same two programs in C, built by $HOSTCC and run through $RUNNER. This
   pins the semantic answer (a double nothing overwrote, a difference of two
   doubles) independently of Aster's slot layout. */
static int slot1(void) {
    volatile int lead = 1; double x = 2.5; volatile int p[7] = {0};
    p[6] = 99; (void)lead; (void)p;
    return x == 2.5 ? 0 : 1;
}
static int nine(double a, double b, double c, double d, double e,
                double g, double h, double i, double j) {
    volatile long pad[480] = {0};
    (void)pad; (void)b; (void)c; (void)d; (void)e; (void)g; (void)h; (void)i;
    return (int)(j - a);
}
int main(int argc, char **argv) {
    if (argc > 1 && argv[1][0] == 's') return slot1();
    return nine(1, 2, 3, 4, 5, 6, 7, 8, 9);
}
C
if ! aster_hostcc_link "$W/oracle" "$W/oracle.c"; then
    fail 'the C oracle could not be built by $HOSTCC'
fi
rc_s=0; run "$W/oracle" s >/dev/null 2>&1 || rc_s=$?
rc_n=0; run "$W/oracle" n >/dev/null 2>&1 || rc_n=$?
[ "$rc_s" = 0 ] || fail "C oracle slot1 returned $rc_s, expected 0"
[ "$rc_n" = 8 ] || fail "C oracle nine returned $rc_n, expected 8"
printf '  %-40s %s\n' 'C oracle slot1 / nine' '0 / 8, matching Aster'; bump; bump

# The C oracle agrees that neither malformed literal is a number at all.
for lit in 1.5.2 1e2e3; do
    printf 'double v = %s;\n' "$lit" > "$W/d09_c_probe.c"
    if "$HOSTCC" -fsyntax-only "$W/d09_c_probe.c" >/dev/null 2>&1; then
        fail "the C oracle accepted the malformed literal $lit"
    fi
done
printf '  %-40s %s\n' 'C oracle rejects 1.5.2 / 1e2e3' 'agrees with Aster'; bump

# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Every writer and link: EXEC, PIE, DYN, ET_REL'
"$A" build-pie "$W/d02_slot1.ast" -o "$W/w_pie" >/dev/null
[ "$(insn etype "$W/w_pie")" = DYN ] || fail 'build-pie is not ET_DYN'
rc=0; run "$W/w_pie" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "build-pie returned $rc, expected 0"; bump
"$A" build-obj "$W/d02_slot1.ast" -o "$W/w_obj.o" >/dev/null
"$A" link-obj "$W/w_obj.o" -o "$W/w_linkobj" >/dev/null
[ "$(insn etype "$W/w_linkobj")" = EXEC ] || fail 'link-obj is not ET_EXEC'
rc=0; run "$W/w_linkobj" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "link-obj returned $rc, expected 0"; bump
# A PIC object keeps its source-level `main` (no main -> _start aliasing), so
# link-pie takes the non-PIC object; the PIC object is checked on its own and
# is the right input for link-so (which must not define _start).
"$A" build-obj --pic "$W/d02_slot1.ast" -o "$W/w_pic.o" >/dev/null
[ "$(insn etype "$W/w_pic.o")" = REL ] || fail 'build-obj --pic is not ET_REL'
insn strd "$W/w_pic.o" | grep -qx 1 || fail 'the PIC object lost the slot-1 STR D'; bump
"$A" link-pie "$W/w_obj.o" -o "$W/w_linkpie" >/dev/null
[ "$(insn etype "$W/w_linkpie")" = DYN ] || fail 'link-pie is not ET_DYN'
rc=0; run "$W/w_linkpie" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "link-pie returned $rc, expected 0"; bump
"$A" build-so "$W/d02_slot1.ast" -o "$W/w_so" >/dev/null
[ "$(insn etype "$W/w_so")" = DYN ] || fail 'build-so is not ET_DYN'
insn strd "$W/w_so" | grep -qx 1 || fail 'build-so lost the slot-1 STR D'; bump
"$A" link-so --soname libslot.so "$W/w_pic.o" -o "$W/w_linkso.so" >/dev/null
[ "$(insn etype "$W/w_linkso.so")" = DYN ] || fail 'link-so is not ET_DYN'; bump
# -g and --bounds-check must not perturb the compact two-word patch.
"$A" build-elf -g --compact-frames "$W/d01_p490.ast" -o "$W/w_dbg" >/dev/null
rc=0; run "$W/w_dbg" >/dev/null 2>&1 || rc=$?
[ "$rc" = 8 ] || fail "-g compact pad=490 returned $rc, expected 8"; bump
"$A" build-elf --bounds-check --compact-frames "$W/d01_p490.ast" -o "$W/w_bnd" >/dev/null
rc=0; run "$W/w_bnd" >/dev/null 2>&1 || rc=$?
[ "$rc" = 8 ] || fail "--bounds-check compact pad=490 returned $rc, expected 8"; bump
printf '  %-40s %s\n' 'four writers + two links + two flags' 'slot and frame encodings hold'; bump

# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Coverage census'
# Measured 59 invariants on the a235ed2 baseline; the floor sits below it so
# a reviewed addition can raise the ratchet while a silent shrink still fails.
[ "$COVER" -ge 55 ] || fail "only $COVER invariants exercised"
printf '  %-40s %s\n' 'invariants exercised' "$COVER"; bump

# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Mutations: every edit must be tested'
mut_check(){
    m="$1"
    # A surviving mutant must fail one of: the compact frame spectrum (both
    # sides of the 4096 boundary), its exact instruction words, the f64 slot
    # matrix, the caller-stack guard, the nine-FP-argument path, the two
    # controls, or the D-09 literal refusals. Checking words as well as
    # answers catches a scale typo whose store and load would otherwise be
    # self-consistent.
    for pad in 465 467 490; do
        "$m" build-elf --compact-frames "$W/d01_p$pad.ast" -o "$W/m_c$pad" >/dev/null 2>&1 || return 1
        rc=0; run "$W/m_c$pad" >/dev/null 2>&1 || rc=$?
        [ "$rc" = 8 ] || return 1
        insn badspadd "$W/m_c$pad" >/dev/null 2>&1 || return 1
    done
    insn has "$W/m_c467" 91400bf0 >/dev/null 2>&1 || return 1
    insn has "$W/m_c490" 91400bf0 >/dev/null 2>&1 || return 1
    insn hasnt "$W/m_c465" 91400bf0 >/dev/null 2>&1 || return 1
    for spec in 'slot1 0' 'guard128 0' 'nine 8' 'f32_ctl 0' 'i32_ctl 0'; do
        set -- $spec; name=$1; want=$2
        "$m" build-elf "$W/d02_$name.ast" -o "$W/m_$name" >/dev/null 2>&1 || return 1
        rc=0; run "$W/m_$name" >/dev/null 2>&1 || rc=$?
        [ "$rc" = "$want" ] || return 1
    done
    "$m" build-elf "$W/d02_slot1.ast" -o "$W/m_slot1x" >/dev/null 2>&1 || return 1
    insn strd "$W/m_slot1x" | grep -qx 1 || return 1
    if insn strd "$W/m_slot1x" | grep -qx 8; then return 1; fi
    for n in twodot twoexp; do
        if "$m" build-elf "$W/d09_$n.ast" -o "$W/m_d09_$n" >/dev/null 2>&1; then return 1; fi
    done
    for n in frac exp fracexp expneg; do
        "$m" build-elf "$W/d09_$n.ast" -o "$W/m_d09_$n" >/dev/null 2>&1 || return 1
    done
    return 0
}
mutate(){ # <label> <old> <new> [expected occurrences]
    python3 - "$2" "$3" "${4:-1}" <<'PY'
import pathlib, sys
s = pathlib.Path('src/aster.cpp').read_text(encoding='utf-8')
old, new, want = sys.argv[1], sys.argv[2], int(sys.argv[3])
got = s.count(old)
assert got == want, (got, want, old[:70])
pathlib.Path('tmp-mut.cpp').write_text(s.replace(old, new), encoding='utf-8')
PY
    mv tmp-mut.cpp "$W/mut.cpp"
    $CXX -std=c++17 -O2 -w "$W/mut.cpp" -o "$W/mut.aster" >/dev/null 2>&1 \
        || fail "$1 mutant does not compile"
    if mut_check "$W/mut.aster"; then
        # "went unnoticed" is the survivor-assertion wording the aggregate
        # mutation-score census greps for; keep this failing path visible.
        echo "FAIL: mutation '$1' went unnoticed" >&2; exit 1
    fi
    printf '  %-52s %s\n' "$1" 'caught'; bump
}
mutate 'm1: storeVarT F64 immediate reverts to slot*8' \
    '0xfd0003e0u|(uint32_t(slot)<<10)' \
    '0xfd0003e0u|(uint32_t(slot*8)<<10)'
mutate 'm2: loadVarT F64 immediate reverts to slot*8' \
    '0xfd4003e0u|(uint32_t(slot)<<10)' \
    '0xfd4003e0u|(uint32_t(slot*8)<<10)'
mutate 'm3: storeVarT F64 immediate takes the f32 scale' \
    '0xfd0003e0u|(uint32_t(slot)<<10)' \
    '0xfd0003e0u|(uint32_t(slot*2)<<10)'
mutate 'm4: compact frames stop checking the 4095 ADD immediate bound' \
    'if(want<=4095u){' \
    'if(true){' 2
mutate 'm5: lexer takes a second fractional part again' \
    "if(!isHex&&!isBin&&!seenDot&&!seenExp&&q=='.'&&std::isdigit((unsigned char)peek(1))){" \
    "if(!isHex&&!isBin&&q=='.'&&std::isdigit((unsigned char)peek(1))){"
mutate 'm6: lexer takes a second exponent again' \
    "if(!isHex&&!isBin&&!seenExp&&(q=='e'||q=='E')){" \
    "if(!isHex&&!isBin&&(q=='e'||q=='E')){"

# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] Byte baseline: zero drift, all 393 rows reproduced'
BASE=$(aster_baseline_file)
rows=$(wc -l < "$BASE")
[ "$rows" = 393 ] || fail "the current baseline has $rows rows, expected 393"
_cur_v=$(aster_baseline_version)
_prev_v=$(ls tests/baseline/ | grep -v "^v${_cur_v}\$" | sort -V | tail -1)
PREV="tests/baseline/${_prev_v}/example-hashes.txt"
prev_rows=$(wc -l < "$PREV")
[ "$prev_rows" = 393 ] || fail "the previous baseline has $prev_rows rows, expected 393"
# v0.23.78-dev changes no compiler behaviour relative to a235ed2 (the
# three repairs are already in that tree); it only bumps the version and
# adds this resident gate. The frozen snapshot covers build-elf /
# build-obj --pic / build-so over the shipped examples, none of which use
# --compact-frames or f64/f32, so every inherited row is byte-identical.
cmp -s "$PREV" "$BASE" || fail "a frozen byte moved against ${_prev_v}"
printf '  %-40s %s\n' 'zero drift vs previous snapshot' "$prev_rows rows"; bump
# Reproduce every frozen row with this build's compiler. build-so derives
# DT_SONAME from the output basename, so the reproduction uses the exact key.
reproduced=0
while read -r key val; do
    base=${key%.*}; mode=${key#*.}
    case "$mode" in
        build-so) m='build-so' ;;
        build-elf) m='build-elf' ;;
        build-obj_--pic) m='build-obj --pic' ;;
        *) continue ;;
    esac
    # shellcheck disable=SC2086
    if "$A" $m "examples/$base.ast" -o "$W/$key" >/dev/null 2>&1; then
        got=$(sha256sum "$W/$key" | cut -d' ' -f1)
    else
        got=FAILED
    fi
    [ "$got" = "$val" ] || fail "$key baseline moved: expected $val, got $got"
    reproduced=$((reproduced+1))
done < "$BASE"
[ "$reproduced" = 393 ] || fail "only $reproduced of 393 frozen rows were reproduced"
printf '  %-40s %s\n' 'baseline rows reproduced' "$reproduced"; bump

printf '%s\n' 'PASS: all v0.23.78-dev audit-fix contract checks (D-01/D-02/D-09)'
