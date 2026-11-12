#!/bin/sh
# tests/link-project-contract-checks.sh — resident 9-layer gate for the three
# v0.23.79-dev "link & project-config contract" repairs (D-03 / D-04 / D-05 of
# AUDIT-v0.23.77-dev.md §3, queued together in §7).
#
#   D-03  checkInitOrder treated every relocation inside __aster_init as a read
#         of another object's global state, and every defined symbol (including
#         STT_FUNC) as that state. A plain CALL26 to a helper function defined
#         in a later object was therefore refused in one link order and
#         accepted in the other, although both mean the same thing. The repair
#         keeps only data symbols in ownerOf and drops CALL26 from initRefs;
#         the legitimate A-21 refusal for a real data dependency still fires.
#
#   D-04  `page-size` in aster.proj was parsed, range-checked and then thrown
#         away: filePage was unconditionally the CLI value. On an Android 15+
#         16 KB-page device the result would not load, with no warning. The
#         repair makes the project setting the default and lets an explicitly
#         supplied --page-size win, in build|run and test alike.
#
#   D-05  the SysV (single-source, no soname/needed) .so writer gave .tbss a
#         sh_offset that was not its sh_addr, and hardcoded kTlsBlockAlign for
#         its addresses, section headers and PT_TLS p_align. The Dyn writer had
#         none of those defects. The repair carries the TLS block's real
#         alignment (the widest @align of its members) into both writers, so
#         .tbss off == addr and p_align/sh_addralign agree with the address.
#
# Layers: strict build; source guards; a pure-Python ELF section/program-header
# oracle (no binutils as the primary judge); the behavioural matrix; a GNU ld C
# oracle as third-party witness; every writer and link; a coverage census; six
# mutations; the byte baseline (zero drift, all 393 rows reproduced).
#
# Cross-host discipline from v0.23.77-dev: AArch64 images go through $RUNNER,
# C oracles through $HOSTCC, and the primary oracle is pure Python, so the
# x86_64+qemu box and a native AArch64/Termux host assert the same invariants.
set -eu
cd "$(dirname "$0")/.."
. tests/lib/baseline.sh
. tests/lib/verdict.sh
. tests/lib/tools.sh
CXX=${CXX:-c++}
HOSTCC=${HOSTCC:-cc}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-link-project-contract-checks}
# Absolute: project builds cd into a subdirectory, so every redirect, cache
# path and ASTER_KEY_DIR must keep pointing at the same place.
W="$(pwd)/$OUT/work"
mkdir -p "$W" "$W/keys"
trap 'rm -rf "$OUT"' EXIT HUP INT TERM
export ASTER_KEY_DIR="$W/keys"
run(){ sh "$RUNNER" "$@"; }
COVER=0
bump(){ COVER=$((COVER + 1)); }
fail(){ echo "FAIL: $*" >&2; exit 1; }
PY=python3

# ---------------------------------------------------------------------------
printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
A="$(pwd)/$OUT/aster"
grep -qF '#define ASTER_VERSION_STRING "0.23.79-dev"' src/aster.cpp \
    || fail 'the version constant is not 0.23.79-dev'
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: the three contracts are pinned in source'
$PY - <<'PY' || exit 1
import pathlib
s = pathlib.Path('src/aster.cpp').read_text(encoding='utf-8')

# D-03 — both linkers carry the same analysis.
assert s.count('(s.info&0xfu)!=2') == 2, 'a linker still puts STT_FUNC in ownerOf'
assert s.count('r.type!=283') == 2, 'a linker still counts CALL26 as a global read'
assert s.count('checkInitOrder(inputs,ownerOf,initRefs,initNameByInput);') == 2
print('  OK D-03: function symbols excluded from ownerOf, CALL26 from initRefs, both linkers')

# D-04 — the project setting must be the default, with an explicit CLI override.
assert s.count('bool cliPageSet=false;') == 2, 'a build path lost its CLI flag tracking'
assert s.count('cliPageSet=true;') == 2, 'a --page-size branch no longer records the flag'
expr = 'const uint64_t filePage = cliPageSet ? ps : (spec.pageSize?spec.pageSize:ps);'
assert s.count(expr) == 2, 'a build path still discards spec.pageSize'
assert s.count('const uint64_t filePage = ps;') == 0, 'the dead assignment came back'
assert s.count('cachedProjectObject(sp,false,dbg,bc2,filePage,cacheDir') == 1
assert s.count('linkObjects(objs,exe,0x400000,2,filePage);') == 1
print('  OK D-04: project page-size is the default and an explicit CLI flag wins')

# D-05 — the SysV writer receives the block alignment and reports .tbss twice alike.
assert s.count('uint64_t tlsAlign=kTlsBlockAlign;') == 2, 'a TLS-align default went missing'
assert 'uint64_t tlsAlign=kTlsBlockAlign){' in s, 'the SysV writer lost its tlsAlign parameter'
assert s.count('for(const Global* g:tlsInit)L.tlsAlign=std::max(') == 1
assert s.count('for(const Global* g:tlsZero)L.tlsAlign=std::max(') == 1
assert 'cur=alignUp(cur,L.tlsAlign);' in s
assert 'const uint64_t tdataVaddr=hasTls?alignUp(relroEnd,tlsAlign):0,tdataSize=tls.size();' in s
assert 'const uint64_t tbssVaddr=hasTls?alignUp(tdataVaddr+tdataSize,tlsAlign):0;' in s
assert 'setSh(kTbssIdx,nTbss,8,0x1|0x2|0x400,tbssVaddr,tbssVaddr,tbssSize,0,0,tlsAlign,0);' in s, \
    '.tbss sh_offset no longer equals sh_addr'
assert 'ptls.align=tlsAlign;}' in s, 'PT_TLS p_align is hardcoded again'
assert 'spec.tlsAlign=L.tlsAlign;' in s, 'the Dyn writer lost the single-source alignment'
assert 'L.tls,L.tbssSize,pageSize,L.tlsAlign);' in s, 'the SysV writer is not given tlsAlign'
print('  OK D-05: tlsAlign flows from the layout into both .so writers; .tbss off == addr')
PY
bump; bump; bump

# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] Static ELF oracle: sections and program headers, no binutils'
cat > "$W/elfkit.py" <<'PY'
#!/usr/bin/env python3
"""Independent ELF64 little-endian section/program-header reader.

The primary oracle for this suite: it never shells out to readelf/objdump, so
it behaves identically on x86_64+qemu and native AArch64/Termux.
"""
import pathlib, struct, sys


def load(path):
    b = pathlib.Path(path).read_bytes()
    assert b[:6] == b'\x7fELF\x02\x01', ('not ELF64 little-endian', path)
    shoff = struct.unpack_from('<Q', b, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 0x3a)
    sh = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i * shentsize)
          for i in range(shnum)]
    st = sh[shstrndx]
    names = b[st[4]:st[4] + st[5]]

    def nm(x):
        return names[x[0]:names.index(b'\0', x[0])].decode()

    phoff = struct.unpack_from('<Q', b, 0x20)[0]
    phentsize, phnum = struct.unpack_from('<HH', b, 0x36)
    ph = [struct.unpack_from('<IIQQQQQQ', b, phoff + i * phentsize)
          for i in range(phnum)]
    return b, {nm(x): x for x in sh}, ph


def sect(d, name):
    # sh tuple: name,type,flags,addr,offset,size,link,info,addralign,entsize
    x = d.get(name)
    return None if x is None else (x[3], x[4], x[8], x[5])


def tlsalign(ph):
    v = [p[7] for p in ph if p[0] == 7]
    assert len(v) == 1, ('expected exactly one PT_TLS', v)
    return v[0]


def loads(ph):
    return [p[7] for p in ph if p[0] == 1]


def num(x):
    return int(x, 0)


def main():
    cmd, path = sys.argv[1], sys.argv[2]
    _, d, ph = load(path)
    if cmd == 'tls':
        for n in ('.tdata', '.tbss'):
            v = sect(d, n)
            print('%s addr=%#x off=%#x align=%d size=%d' % ((n,) + v) if v else '%s ABSENT' % n)
        print('PT_TLS align=%#x' % tlsalign(ph))
        print('PT_LOAD aligns=' + ','.join('%#x' % a for a in loads(ph)))
    elif cmd == 'checkalign':
        # Static EXEC images carry a 0x400000 base, so addr != off there; only
        # the declared alignments are comparable. .so images use `check`.
        want = num(sys.argv[3])
        td, tb = sect(d, '.tdata'), sect(d, '.tbss')
        assert td and tb, ('.tdata/.tbss missing', path)
        assert td[2] == want and tb[2] == want, ('TLS sh_addralign', path, td[2], tb[2], want)
        assert tlsalign(ph) == want, ('PT_TLS p_align', path, tlsalign(ph), want)
        print('  OK TLS sh_addralign/PT_TLS=%d %s' % (want, path))
    elif cmd == 'check':
        want = num(sys.argv[3])
        td, tb = sect(d, '.tdata'), sect(d, '.tbss')
        assert td and tb, ('.tdata/.tbss missing', path)
        assert td[0] == td[1], ('.tdata addr != off', path, td)
        assert tb[0] == tb[1], ('.tbss addr != off', path, tb)
        assert td[2] == want, ('.tdata sh_addralign', path, td[2], want)
        assert tb[2] == want, ('.tbss sh_addralign', path, tb[2], want)
        assert tlsalign(ph) == want, ('PT_TLS p_align', path, tlsalign(ph), want)
        print('  OK .tbss off==addr, sh_addralign/PT_TLS=%d %s' % (want, path))
    elif cmd == 'checkload':
        want = num(sys.argv[3])
        a = loads(ph)
        assert a, ('no PT_LOAD', path)
        assert all(x == want for x in a), ('PT_LOAD aligns', path,
                                           ['%#x' % x for x in a], want)
        print('  OK all %d PT_LOAD(s) align=%#x %s' % (len(a), want, path))
    elif cmd == 'checkloadany':
        want = num(sys.argv[3])
        assert want in loads(ph), ('no PT_LOAD with that align', path, loads(ph))
        print('  OK a PT_LOAD carries align=%#x %s' % (want, path))
    else:
        raise SystemExit('FAIL: unknown elfkit command ' + cmd)


main()
PY
# A default-alignment probe (4-byte .tdata + 16-byte .tbss) and a high-align
# family are shared by layers 4, 6 and 8.
cat > "$W/d05.ast" <<'AST'
tls let a: i32 = 10;
tls let b: u64 = 0;
tls let c: u64 = 0;
fn touch() -> i32 { b = 5; a = a + 1; return i32(a); }
AST
$PY - "$W" <<'PY'
import pathlib, sys
W = pathlib.Path(sys.argv[1])
for n in (16, 32, 64, 128, 256, 512, 1024, 2048, 4096):
    (W / ('tls%d.ast' % n)).write_text(
        'tls let a: i32 @align(%d) = 10;\n'
        'tls let b: u64 @align(%d) = 0;\n'
        'fn touch() -> i32 { b = 5; a = a + 1; return i32(a); }\n' % (n, n))
PY
"$A" build-so "$W/d05.ast" -o "$W/s_default.so" >/dev/null
"$A" build-so --soname libdyn.so "$W/d05.ast" -o "$W/d_default.so" >/dev/null
"$PY" "$W/elfkit.py" check "$W/s_default.so" 16
"$PY" "$W/elfkit.py" check "$W/d_default.so" 16
bump; bump
# The two writers must agree byte-for-byte on the TLS section contract.
for n in 16 32 64 128 256 512 1024 2048 4096; do
    "$A" build-so "$W/tls$n.ast" -o "$W/s_$n.so" >/dev/null
    "$A" build-so --soname libdyn.so "$W/tls$n.ast" -o "$W/d_$n.so" >/dev/null
    "$PY" "$W/elfkit.py" check "$W/s_$n.so" "$n" >/dev/null
    "$PY" "$W/elfkit.py" check "$W/d_$n.so" "$n" >/dev/null
done
printf '  %-40s %s\n' '9 alignment steps x 2 writers' 'section/PT_TLS contract holds'
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] Behavioural matrix: D-03 order, D-04 projects, D-05 writers'
# --- D-03: a pure function call is not a cross-object global read ------------
cat > "$W/call_a.ast" <<'AST'
extern fn helper() -> i32;
let x: i32 = helper();
AST
cat > "$W/call_b.ast" <<'AST'
fn helper() -> i32 { return 7; }
fn seed() -> i32 { return 3; }
let y: i32 = seed();
AST
cat > "$W/call_b2.ast" <<'AST'
fn helper() -> i32 { return 7; }
let y: i32 = 3;
AST
# --- D-03: a real data dependency must still be refused when inverted --------
cat > "$W/data_a.ast" <<'AST'
fn fz() -> i32 { return 1; }
let ga: i32 = 22;
let pa: ptr = &ga;
AST
cat > "$W/data_b.ast" <<'AST'
extern let ga: i32;
extern let pa: ptr;
let pb: ptr = pa;
fn main() -> i32 { if (pb == 0) { return 9; } return *pb; }
AST
for n in call_a call_b call_b2; do
    "$A" build-obj --pic "$W/$n.ast" -o "$W/$n.o" >/dev/null
done
# link-so: both orders and the no-initializer control must all succeed.
for spec in 'call_a.o:call_b.o:ab' 'call_b.o:call_a.o:ba' 'call_a.o:call_b2.o:ab2'; do
    $PY - "$W" "$A" "$spec" <<'PY' || exit 1
import subprocess, sys
W, A, spec = sys.argv[1], sys.argv[2], sys.argv[3]
x, y, z = spec.split(':')
r = subprocess.run([A, 'link-so', W + '/' + x, W + '/' + y, '-o', W + '/' + z + '.so'],
                   capture_output=True, text=True)
assert r.returncode == 0, ('D-03: a plain function call was refused', spec, r.stderr or r.stdout)
print('  OK link-so %s %s succeeds (D-03)' % (x, y))
PY
    bump
done
# link-obj carries the same checkInitOrder mirror. Unlike link-so it needs an
# object with _start (A-22), so the caller supplies main; the reversed order
# must succeed too.
cat > "$W/lobj_a.ast" <<'AST'
extern fn helper() -> i32;
let x: i32 = helper();
fn main() -> i32 { return 0; }
AST
cat > "$W/lobj_b.ast" <<'AST'
fn helper() -> i32 { return 7; }
fn seed() -> i32 { return 3; }
let y: i32 = seed();
AST
"$A" build-obj "$W/lobj_a.ast" -o "$W/la.o" >/dev/null
"$A" build-obj "$W/lobj_b.ast" -o "$W/lb.o" >/dev/null
"$A" link-obj "$W/la.o" "$W/lb.o" -o "$W/la_lb" >/dev/null \
    || fail 'D-03: link-obj refuses a plain function call'
"$A" link-obj "$W/lb.o" "$W/la.o" -o "$W/lb_la" >/dev/null \
    || fail 'D-03: link-obj refuses the reversed order'
bump
# Legitimate A-21 refusal survives: a data global read backwards is rejected.
"$A" build-obj "$W/data_a.ast" -o "$W/da.o" >/dev/null
"$A" build-obj "$W/data_b.ast" -o "$W/db.o" >/dev/null
"$A" link-obj "$W/da.o" "$W/db.o" -o "$W/data_ok" >/dev/null \
    || fail 'the well-ordered A-21 data dependency was refused'
if "$A" link-obj "$W/db.o" "$W/da.o" -o "$W/data_bad" >"$W/data_bad.log" 2>&1; then
    fail 'D-03 repair removed the legitimate A-21 refusal'
fi
grep -qF 'must be listed before' "$W/data_bad.log" \
    || fail 'the inverted data dependency was refused without its message'
bump

# --- D-04: project page-size matrix ------------------------------------------
mkproj(){ # <dir> <kind> <page-size>
    mkdir -p "$W/$1/src"
    cat > "$W/$1/src/main.ast" <<'AST'
fn main() -> i32 { return 7; }
AST
    if [ "$2" = apk ]; then
        cat > "$W/$1/src/main.ast" <<'AST'
fn aster_main() -> i32 { return 0; }
AST
    fi
    {
        echo "kind $2"
        [ "$2" = apk ] && echo 'package com.example.aster'
        echo 'src/main.ast'
        [ -n "$3" ] && echo "page-size $3"
    } > "$W/$1/aster.proj"
}
proj_build(){ # <dir> [extra cli args...]
    d=$1; shift
    (cd "$W/$d" && rm -rf build && "$A" build "$@" >"$W/$d.log" 2>&1)
}
proj_flags(){ grep -rh '^flags' "$W/$1/build/.cache/"*.meta | head -1; }
mkproj p16 apk 16384
mkproj p4 apk 4096
mkproj pcli apk 16384
mkproj pcli2 apk 4096
mkproj pexe exe 16384
mkproj pbad apk 8192
proj_build p16
proj_build p4
proj_build pcli --page-size 4096
proj_build pcli2 --page-size 16384
proj_build pexe
# apk: the intermediate .so is the page-aligned artefact.
"$PY" "$W/elfkit.py" checkload "$W/p16/build/.cache/p16.so" 16384
"$PY" "$W/elfkit.py" checkload "$W/p4/build/.cache/p4.so" 4096
"$PY" "$W/elfkit.py" checkload "$W/pcli/build/.cache/pcli.so" 4096
"$PY" "$W/elfkit.py" checkload "$W/pcli2/build/.cache/pcli2.so" 16384
"$PY" "$W/elfkit.py" checkload "$W/pexe/build/pexe" 16384
bump; bump; bump; bump; bump
case "$(proj_flags p16)" in *'|16384') ;; *) fail 'p16 cache flags lost 16384' ;; esac
case "$(proj_flags p4)" in *'|4096') ;; *) fail 'p4 cache flags lost 4096' ;; esac
case "$(proj_flags pcli)" in *'|4096') ;; *) fail 'CLI 4096 did not override project 16384' ;; esac
case "$(proj_flags pcli2)" in *'|16384') ;; *) fail 'CLI 16384 did not override project 4096' ;; esac
case "$(proj_flags pexe)" in *'|16384') ;; *) fail 'exe project lost 16384' ;; esac
bump
if proj_build pbad; then fail 'an invalid project page-size was accepted'; fi
grep -qE 'page-size' "$W/pbad.log" || fail 'the invalid page-size was rejected without a message'
bump
# aster test honours the same project default: compile flags, linked image,
# and the test run itself.
mkdir -p "$W/ptest/src" "$W/ptest/tests"
cat > "$W/ptest/src/main.ast" <<'AST'
fn main() -> i32 { return 0; }
AST
cat > "$W/ptest/tests/t.ast" <<'AST'
fn main() -> i32 { return 0; }
AST
cat > "$W/ptest/aster.proj" <<'PROJ'
kind exe
src/main.ast
test tests/t.ast
page-size 16384
PROJ
(cd "$W/ptest" && "$A" test >"$W/ptest.log" 2>&1) \
    || { cat "$W/ptest.log"; fail 'aster test failed on a 16 KB project'; }
grep -qF 'PASS tests/t.ast' "$W/ptest.log" || fail 'aster test did not run the test'
case "$(proj_flags ptest)" in *'|16384') ;; *) fail 'aster test cache flags lost 16384' ;; esac
"$PY" "$W/elfkit.py" checkload "$W/ptest/build/tests/t" 16384
bump; bump
printf '  %-40s %s\n' 'D-04 project matrix (apk/exe/test)' 'page-size effective, CLI wins'

# --- D-05: two writers, default and high alignment ---------------------------
"$PY" "$W/elfkit.py" tls "$W/s_default.so" | grep -q 'PT_TLS align=0x10' \
    || fail 'SysV default PT_TLS align is not 16'
"$PY" "$W/elfkit.py" tls "$W/d_default.so" | grep -q 'PT_TLS align=0x10' \
    || fail 'Dyn default PT_TLS align is not 16'
"$PY" "$W/elfkit.py" tls "$W/s_16.so" | grep -q '\.tbss addr=0x.* off=0x' \
    || fail 'SysV .tbss header is unreadable'
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] C oracle: GNU ld is the third-party witness'
cat > "$W/oracle.c" <<'C'
__thread int a = 10;
__thread unsigned long b = 0;
__thread unsigned long c = 0;
int touch(void) { b = 5; a = a + 1; return a; }
C
if $HOSTCC -shared -fPIC -O2 "$W/oracle.c" -o "$W/oracle.so" >"$W/cc.log" 2>&1; then
    "$PY" "$W/elfkit.py" tls "$W/oracle.so" > "$W/oracle.tls"
    # GNU ld is deliberately NOT an `addr == off` witness: its .tbss sh_offset
    # is the end of .tdata while its sh_addr sits one segment base higher. The
    # portable invariant is that PT_TLS p_align and both TLS sh_addraligns
    # agree — exactly what the SysV writer used to violate with its hard 16.
    $PY - "$W/oracle.tls" <<'PY' || exit 1
import re, sys
t = open(sys.argv[1]).read()
sec = [int(x) for x in re.findall(r'\.(?:tdata|tbss) addr=\S+ off=\S+ align=(\d+)', t)]
pt = re.search(r'PT_TLS align=(0x[0-9a-f]+)', t)
assert len(sec) == 2 and pt, ('GNU ld TLS headers unreadable', t)
assert int(pt.group(1), 16) in sec, ('PT_TLS p_align disagrees with TLS sections', t)
print('  OK GNU ld: PT_TLS p_align agrees with both TLS section alignments')
PY
    bump
else
    echo '  SKIP optional C oracle (host C compiler unavailable for -shared)' >&2
fi
if $HOSTCC -shared -fPIC -O2 -Wl,-z,max-page-size=16384 "$W/oracle.c" \
        -o "$W/oracle16k.so" >"$W/cc16.log" 2>&1; then
    "$PY" "$W/elfkit.py" checkloadany "$W/oracle16k.so" 16384
    bump
else
    echo '  SKIP optional 16 KB GNU ld witness' >&2
fi

# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Every writer and link'
cat > "$W/full.ast" <<'AST'
tls let a: i32 @align(64) = 10;
tls let b: u64 @align(64) = 0;
fn helper() -> i32 { return 7; }
let x: i32 = helper();
fn main() -> i32 { b = 5; return a + x - 17; }
AST
"$A" build-elf "$W/full.ast" -o "$W/w_elf" >/dev/null
rc=0; run "$W/w_elf" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "build-elf returned $rc, expected 0"
"$PY" "$W/elfkit.py" checkalign "$W/w_elf" 64 >/dev/null; bump
"$A" build-pie "$W/full.ast" -o "$W/w_pie" >/dev/null
rc=0; run "$W/w_pie" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "build-pie returned $rc, expected 0"; bump
"$A" build-obj "$W/full.ast" -o "$W/w_obj.o" >/dev/null
"$A" build-obj --pic "$W/full.ast" -o "$W/w_pic.o" >/dev/null
"$A" link-obj "$W/w_obj.o" -o "$W/w_linkobj" >/dev/null
rc=0; run "$W/w_linkobj" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "link-obj returned $rc, expected 0"; bump
"$A" link-pie "$W/w_obj.o" -o "$W/w_linkpie" >/dev/null
rc=0; run "$W/w_linkpie" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "link-pie returned $rc, expected 0"; bump
"$A" build-so "$W/d05.ast" -o "$W/w_so" >/dev/null
"$PY" "$W/elfkit.py" check "$W/w_so" 16 >/dev/null; bump
"$A" build-so --soname libw.so "$W/d05.ast" -o "$W/w_so_dyn" >/dev/null
"$PY" "$W/elfkit.py" check "$W/w_so_dyn" 16 >/dev/null; bump
"$A" build-obj --pic "$W/d05.ast" -o "$W/w_d05.o" >/dev/null
"$A" link-so --soname libl.so "$W/w_d05.o" -o "$W/w_linkso.so" >/dev/null
"$PY" "$W/elfkit.py" check "$W/w_linkso.so" 16 >/dev/null; bump
# -g and --bounds-check must not perturb the TLS contract.
"$A" build-elf -g "$W/full.ast" -o "$W/w_dbg" >/dev/null
rc=0; run "$W/w_dbg" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "-g returned $rc, expected 0"; bump
"$A" build-elf --bounds-check "$W/full.ast" -o "$W/w_bnd" >/dev/null
rc=0; run "$W/w_bnd" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "--bounds-check returned $rc, expected 0"; bump
printf '  %-40s %s\n' 'four writers + three links + two flags' 'contract holds'; bump

# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Coverage census'
[ "$COVER" -ge 32 ] || fail "only $COVER invariants exercised"
printf '  %-40s %s\n' 'invariants exercised' "$COVER"; bump

# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Mutations: every edit must be tested'
mut_check(){
    m="$1"
    # A surviving mutant must fail at least one of: the D-03 call link, the
    # legitimate A-21 refusal, the D-04 project page-size, or the D-05
    # .tbss/PT_TLS contract on either writer at high and default alignment.
    "$m" build-obj --pic "$W/call_a.ast" -o "$W/mu_a.o" >/dev/null 2>&1 || return 1
    "$m" build-obj --pic "$W/call_b.ast" -o "$W/mu_b.o" >/dev/null 2>&1 || return 1
    "$m" link-so "$W/mu_a.o" "$W/mu_b.o" -o "$W/mu_ab.so" >/dev/null 2>&1 || return 1
    "$m" build-obj "$W/lobj_a.ast" -o "$W/mu_la.o" >/dev/null 2>&1 || return 1
    "$m" build-obj "$W/lobj_b.ast" -o "$W/mu_lb.o" >/dev/null 2>&1 || return 1
    "$m" link-obj "$W/mu_la.o" "$W/mu_lb.o" -o "$W/mu_lab" >/dev/null 2>&1 || return 1
    "$m" build-obj "$W/data_a.ast" -o "$W/mu_da.o" >/dev/null 2>&1 || return 1
    "$m" build-obj "$W/data_b.ast" -o "$W/mu_db.o" >/dev/null 2>&1 || return 1
    if "$m" link-obj "$W/mu_db.o" "$W/mu_da.o" -o "$W/mu_bad" >/dev/null 2>&1; then return 1; fi
    (cd "$W/p16" && rm -rf build && "$m" build >/dev/null 2>&1) || return 1
    "$PY" "$W/elfkit.py" checkload "$W/p16/build/.cache/p16.so" 16384 >/dev/null 2>&1 || return 1
    # An explicit CLI flag must still beat the project setting.
    (cd "$W/pcli" && rm -rf build && "$m" build --page-size 4096 >/dev/null 2>&1) || return 1
    "$PY" "$W/elfkit.py" checkload "$W/pcli/build/.cache/pcli.so" 4096 >/dev/null 2>&1 || return 1
    "$m" build-so "$W/tls64.ast" -o "$W/mu_s64.so" >/dev/null 2>&1 || return 1
    "$PY" "$W/elfkit.py" check "$W/mu_s64.so" 64 >/dev/null 2>&1 || return 1
    "$m" build-so --soname libx.so "$W/tls64.ast" -o "$W/mu_d64.so" >/dev/null 2>&1 || return 1
    "$PY" "$W/elfkit.py" check "$W/mu_d64.so" 64 >/dev/null 2>&1 || return 1
    "$m" build-so "$W/d05.ast" -o "$W/mu_s.so" >/dev/null 2>&1 || return 1
    "$PY" "$W/elfkit.py" check "$W/mu_s.so" 16 >/dev/null 2>&1 || return 1
    return 0
}
mutate(){ # <label> [<old> <new> <expected count>]... (one or more triples)
    label=$1; shift
    $PY - "$@" <<'PY'
import pathlib, sys
args = sys.argv[1:]
assert len(args) % 3 == 0, args
s = pathlib.Path('src/aster.cpp').read_text(encoding='utf-8')
for i in range(0, len(args), 3):
    old, new, want = args[i], args[i+1], int(args[i+2])
    got = s.count(old)
    assert got == want, (got, want, old[:80])
    s = s.replace(old, new)
pathlib.Path('tmp-mut.cpp').write_text(s, encoding='utf-8')
PY
    mv tmp-mut.cpp "$W/mut.cpp"
    $CXX -std=c++17 -O2 -w "$W/mut.cpp" -o "$W/mut.aster" >/dev/null 2>&1 \
        || fail "$label mutant does not compile"
    if mut_check "$W/mut.aster"; then
        # The aggregate mutation-score census greps for this exact wording.
        echo "FAIL: mutation '$label' went unnoticed" >&2; exit 1
    fi
    printf '  %-52s %s\n' "$label" 'caught'; bump
}
# D-03's two filters are deliberately redundant: dropping either one alone is
# still caught by the other, so the mutant that restores the original defect
# removes both at once (in both linkers) and must be refused by link-so/link-obj.
mutate 'm1: both D-03 filters removed (original mis-refusal)' \
    '(s.info&0xfu)!=2' 'true' 2 'r.type!=283' 'true' 2
mutate 'm2: project page-size is discarded again' \
    'const uint64_t filePage = cliPageSet ? ps : (spec.pageSize?spec.pageSize:ps);' \
    'const uint64_t filePage = ps;' 2
mutate 'm3: explicit --page-size no longer recorded' \
    'cliPageSet=true;' '' 2
mutate 'm4: the TLS block alignment is no longer derived' \
    'for(const Global* g:tlsInit)L.tlsAlign=std::max(L.tlsAlign,std::max<uint64_t>(g->align,4));
        for(const Global* g:tlsZero)L.tlsAlign=std::max(L.tlsAlign,std::max<uint64_t>(g->align,4));' \
    '/* mutant: L.tlsAlign left at the default */' 1
mutate 'm5: .tbss sh_offset diverges from sh_addr again' \
    'setSh(kTbssIdx,nTbss,8,0x1|0x2|0x400,tbssVaddr,tbssVaddr,tbssSize,0,0,tlsAlign,0);' \
    'setSh(kTbssIdx,nTbss,8,0x1|0x2|0x400,tbssVaddr,tdataVaddr+tdataSize,tbssSize,0,0,tlsAlign,0);' 1
mutate 'm6: SysV PT_TLS p_align is hardcoded to 16 again' \
    'ptls.align=tlsAlign;}' 'ptls.align=kTlsBlockAlign;}' 1

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
# Full before/after A/B measured MOVED_COUNT=0 over all 393 rows: the D-03
# repair only relaxes a refusal, D-04 only changes the non-default project
# setting, and D-05 keeps tlsAlign at 16 for every shipped example (none
# carries @align above 16 on a thread-local). No frozen row was re-recorded.
cmp -s "$PREV" "$BASE" || fail "a frozen byte moved against ${_prev_v}"
printf '  %-40s %s\n' 'zero drift vs previous snapshot' "$prev_rows rows"; bump
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

printf '%s\n' 'PASS: all v0.23.79-dev link/project contract checks (D-03/D-04/D-05)'
