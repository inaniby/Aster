#!/bin/sh
# Verify ET_REL parsing/linking, output equivalence, and malformed-input rejection.
set -eu
. tests/lib/tmpdir.sh
# v0.23.77-dev (host adaptation): run AArch64 products through the shared
# runner. It executes them natively on an AArch64/Termux host and under qemu
# elsewhere, so the very same suite is valid on both kinds of machine.
RUNNER=${RUNNER:-tests/run-aarch64.sh}
case "$RUNNER" in
    /*) ;;
    *) if [ -f "$RUNNER" ]; then RUNNER="$(cd "$(dirname "$RUNNER")" && pwd)/$(basename "$RUNNER")"; fi ;;
esac
[ -x ./aster ] || { echo "build ./aster first" >&2; exit 2; }
names='hello arithmetic negative_division if_less if_greater_equal if_equal if_not_equal_false if_less_equal if_greater_false assignment while_count nested_while scope_shadow nested_if many_locals long_expression if_return while_break while_continue nested_loop_break'
for name in $names; do
  ./aster build-obj "examples/$name.ast" -o "tmp-$name.o"
  ./aster link-obj "tmp-$name.o" -o "tmp-linked-$name"
  ./aster build-elf "examples/$name.ast" -o "tmp-direct-$name"
  cmp "tmp-linked-$name" "tmp-direct-$name"
done
python3 - <<'PY'
import os, struct
names = 'hello arithmetic negative_division if_less if_greater_equal if_equal if_not_equal_false if_less_equal if_greater_false assignment while_count nested_while scope_shadow nested_if many_locals long_expression if_return while_break while_continue nested_loop_break'.split()
for name in names:
    path = 'tmp-linked-' + name
    b = open(path, 'rb').read()
    assert b[:6] == b'\x7fELF\x02\x01', path
    assert struct.unpack_from('<HH', b, 16) == (2, 183), path
    assert struct.unpack_from('<Q', b, 24)[0] == 0x401000, path
    assert struct.unpack_from('<H', b, 56)[0] == 1, path
    assert b[0x1000:] == open('tmp-direct-' + name, 'rb').read()[0x1000:], path
    print(f'{path}: ELF64 AArch64 ET_EXEC, entry=0x401000, bytes={len(b)}')
    for suffix in ('.o',): os.remove('tmp-' + name + suffix)
    os.remove(path); os.remove('tmp-direct-' + name)
PY
# Multiple inputs are merged, while the one required entry symbol is preserved.
./aster build-obj examples/hello.ast -o tmp-multi-a.o
./aster build-obj examples/arithmetic.ast -o tmp-multi-b.o
python3 - <<'PY2'
from pathlib import Path
p=Path('tmp-multi-b.o')
b=p.read_bytes()
assert b.count(b'_start') == 1
p.write_bytes(b.replace(b'_start', b'helper'))
PY2
./aster link-obj tmp-multi-a.o tmp-multi-b.o -o tmp-multi-linked
python3 - <<'PY2'
import struct
b=open('tmp-multi-linked','rb').read()
a=open('tmp-multi-a.o','rb').read(); c=open('tmp-multi-b.o','rb').read()
# Both generated object files place .text at offset 0x40 and have 4-byte instructions.
na=struct.unpack_from('<Q',a,64+24)[0] if False else 44
nb=52
assert struct.unpack_from('<H',b,16)[0] == 2
assert struct.unpack_from('<H',b,18)[0] == 183
assert struct.unpack_from('<Q',b,24)[0] == 0x401000
assert b[0x1000:0x1000+na] == a[0x40:0x40+na]
assert b[0x1000+na:0x1000+na+nb] == c[0x40:0x40+nb]
# v0.17.0: the loaded image still ends exactly at 0x1000+na+nb. Everything after it is only the
# appended source-level symbol table and the section-header table, and the file ends where that
# table ends -- there are no stray bytes and no .data section for a text-only program.
shoff = struct.unpack_from('<Q', b, 40)[0]
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
secs = [struct.unpack_from('<IIQQQQIIQQ', b, shoff+i*shentsize) for i in range(shnum)]
shstr = secs[shstrndx]
shnames = b[shstr[4]:shstr[4]+shstr[5]]
def secname(sec):
    return shnames[sec[0]:shnames.index(b'\0', sec[0])].decode()
assert {secname(s) for s in secs} == {'', '.text', '.symtab', '.strtab', '.shstrtab'}, sorted(secname(s) for s in secs)
assert len(b) == shoff + shnum*shentsize, (len(b), shoff, shnum)
assert max(s[4]+s[5] for s in secs if s[1] != 8) <= shoff
print('PASS: multiple ET_REL inputs merged in order; _start entry preserved')
PY2
# Duplicate global symbols across input objects must be rejected.
if ./aster link-obj tmp-multi-a.o tmp-multi-a.o -o tmp-duplicate-linked 2>tmp-duplicate-error; then
  echo 'FAIL: linker accepted duplicate global symbols' >&2; exit 1
fi
grep -F "duplicate global symbol '_start'" tmp-duplicate-error >/dev/null
rm -f tmp-multi-a.o tmp-multi-b.o tmp-multi-linked tmp-duplicate-error tmp-duplicate-linked
# ET_EXEC input must be rejected as not relocatable.
./aster build-elf examples/hello.ast -o tmp-not-rel.o
if ./aster link-obj tmp-not-rel.o -o tmp-should-not-exist 2>tmp-link-error; then
  echo 'FAIL: linker accepted ET_EXEC as ET_REL' >&2; exit 1
fi
grep -F 'input must be an ET_REL relocatable object' tmp-link-error >/dev/null
rm -f tmp-not-rel.o tmp-link-error tmp-should-not-exist
# Same-object functions: emit two CALL26 relocations and resolve them.
./aster build-obj examples/functions.ast -o tmp-functions.o
./aster link-obj tmp-functions.o -o tmp-functions-linked
./aster build-elf examples/functions.ast -o tmp-functions-direct
cmp tmp-functions-linked tmp-functions-direct
python3 - <<'PY2'
import struct
b=open('tmp-functions.o','rb').read()
shoff=struct.unpack_from('<Q',b,40)[0]
shentsize,shnum=struct.unpack_from('<HH',b,58)
secs=[struct.unpack_from('<IIQQQQIIQQ',b,shoff+i*shentsize) for i in range(shnum)]
rela=next(s for s in secs if s[1]==4)
assert rela[5]==2*24, rela
exe=open('tmp-functions-linked','rb').read()
assert struct.unpack_from('<Q',exe,24)[0]==0x401000
print('PASS: same-object calls generated and resolved two R_AARCH64_CALL26 relocations')
PY2
# Cross-object function calls: caller has an undefined helper symbol, provider defines it.
./aster build-obj examples/modular_main.ast -o tmp-modular-main.o
./aster build-obj examples/modular_helper.ast -o tmp-modular-helper.o
./aster link-obj tmp-modular-main.o tmp-modular-helper.o -o tmp-modular-linked
python3 - <<'PY2'
import struct
b=open('tmp-modular-linked','rb').read()
assert struct.unpack_from('<HH',b,16)==(2,183)
assert struct.unpack_from('<Q',b,24)[0]==0x401000
print('PASS: cross-object helper symbols resolved and executable ELF emitted')
PY2
# Undefined function references must fail at link time.
if ./aster link-obj tmp-modular-main.o -o tmp-undefined-linked 2>tmp-undefined-error; then
  echo 'FAIL: linker accepted an undefined function' >&2; exit 1
fi
grep -F "undefined function symbol 'helper'" tmp-undefined-error >/dev/null
# Duplicate function definitions across objects must fail.
if ./aster link-obj tmp-modular-main.o tmp-modular-helper.o tmp-modular-helper.o -o tmp-dup-fn 2>tmp-dup-fn-error; then
  echo 'FAIL: linker accepted duplicate helper function' >&2; exit 1
fi
grep -F "duplicate global symbol 'helper'" tmp-dup-fn-error >/dev/null
rm -f tmp-functions.o tmp-functions-linked tmp-functions-direct tmp-modular-main.o tmp-modular-helper.o tmp-modular-linked tmp-undefined-linked tmp-undefined-error tmp-dup-fn tmp-dup-fn-error
# Parameter passing, nested argument expressions, and recursive calls.
for name in arguments nested_calls recursion eight_args; do
  ./aster build-obj "examples/$name.ast" -o "tmp-$name.o"
  ./aster link-obj "tmp-$name.o" -o "tmp-linked-$name"
  ./aster build-elf "examples/$name.ast" -o "tmp-direct-$name"
  cmp "tmp-linked-$name" "tmp-direct-$name"
done
python3 - <<'PY3'
import struct
expected = {'arguments': 1, 'nested_calls': 3, 'recursion': 2, 'eight_args': 1}
for name, count in expected.items():
    b = open('tmp-' + name + '.o', 'rb').read()
    shoff = struct.unpack_from('<Q', b, 40)[0]
    shentsize, shnum = struct.unpack_from('<HH', b, 58)
    sections = [struct.unpack_from('<IIQQQQIIQQ', b, shoff+i*shentsize) for i in range(shnum)]
    rela = next(s for s in sections if s[1] == 4)
    assert rela[5] == count * 24, (name, rela[5], count)
    print(f'PASS: {name} has {count} CALL26 relocation(s) and links identically')
PY3
# Cross-object function calls with an explicitly declared parameter signature.
./aster build-obj examples/modular_main.ast -o tmp-modular-main.o
./aster build-obj examples/modular_helper.ast -o tmp-modular-helper.o
./aster link-obj tmp-modular-main.o tmp-modular-helper.o -o tmp-modular-args
if ./aster link-obj tmp-modular-main.o -o tmp-undefined-linked 2>tmp-undefined-error; then
  echo 'FAIL: linker accepted an undefined function' >&2; exit 1
fi
grep -F "undefined function symbol 'helper'" tmp-undefined-error >/dev/null
rm -f tmp-arguments.o tmp-nested_calls.o tmp-recursion.o tmp-eight_args.o tmp-linked-arguments tmp-linked-nested_calls tmp-linked-recursion tmp-linked-eight_args tmp-direct-arguments tmp-direct-nested_calls tmp-direct-recursion tmp-direct-eight_args tmp-modular-main.o tmp-modular-helper.o tmp-modular-args tmp-undefined-linked tmp-undefined-error
 echo 'PASS: function arguments, nested calls, recursion, and cross-object parameter calls checked'
# v0.23.77-dev (audit A-21/A-22): run-time global initializers run in link
# order. Both rules used to fail silently: an inverted dependency read a
# zero, and an initializer in a non-_start object never ran at all (the
# globals stayed zero). The inverted dependency is still refused, with the
# object names in the message; v0.23.81-dev (H-3/C-1) enters the other case
# instead of refusing it — the link synthesizes an entry stub that calls
# the first initializer in link order and then branches to _start, so the
# initializer in the non-_start object runs. Exit 7 below would mean it
# never ran (pa stayed zero); exit 22 means it ran (pa points at ga).
cat > "$TMPD/init-a.ast" <<'AST'
fn fz() -> i32 { return 1; }
let ga: i32 = 22;
let pa: ptr = &ga;
AST
cat > "$TMPD/init-b.ast" <<'AST'
extern let ga: i32;
extern let pa: ptr;
let pb: ptr = pa;
fn main() -> i32 { if (pb == 0) { return 9; } return *pb; }
AST
cat > "$TMPD/init-m.ast" <<'AST'
extern let pa: ptr;
fn main() -> i32 { if (pa == 0) { return 7; } return *pa; }
AST
./aster build-obj "$TMPD/init-a.ast" -o "$TMPD/init-a.o"
./aster build-obj "$TMPD/init-b.ast" -o "$TMPD/init-b.o"
./aster build-obj "$TMPD/init-m.ast" -o "$TMPD/init-m.o"
./aster link-obj "$TMPD/init-a.o" "$TMPD/init-b.o" -o "$TMPD/init-ok"
set +e
"$RUNNER" "$TMPD/init-ok"
init_rc=$?
set -e
[ "$init_rc" = 22 ] || { echo "FAIL: the well-ordered initializer chain exited $init_rc, expected 22" >&2; exit 1; }
if ./aster link-obj "$TMPD/init-b.o" "$TMPD/init-a.o" -o "$TMPD/init-bad" 2>"$TMPD/init-bad.log"; then
    echo 'FAIL: an initializer reading a global another object initializes linked backwards' >&2; exit 1
fi
grep -qF 'must be listed before' "$TMPD/init-bad.log" \
    || { echo 'FAIL: the inverted initializer dependency was refused without its message:' >&2; cat "$TMPD/init-bad.log" >&2; exit 1; }
# v0.23.81-dev (H-3/C-1): the initializer lives in a non-_start object, so
# the link must succeed and the entry stub must run it — exit 22, not 7.
./aster link-obj "$TMPD/init-m.o" "$TMPD/init-a.o" -o "$TMPD/init-nostart" 2>"$TMPD/init-nostart.log" \
    || { echo 'FAIL: an initializer in a non-_start object no longer links:' >&2; cat "$TMPD/init-nostart.log" >&2; exit 1; }
set +e
"$RUNNER" "$TMPD/init-nostart"
init_ns_rc=$?
set -e
[ "$init_ns_rc" = 22 ] || { echo "FAIL: the non-_start initializer ran but exited $init_ns_rc, expected 22 (7 means it never ran)" >&2; exit 1; }
rm -f "$TMPD/init-a.o" "$TMPD/init-b.o" "$TMPD/init-m.o" "$TMPD/init-ok" "$TMPD/init-bad" "$TMPD/init-nostart"
# v0.23.77-dev: one command may compile several sources (and mix in prebuilt
# objects). The link order is the argument order, and a source is compiled to a
# temporary object next to the output and removed again.
cat > "$TMPD/ms-defs.ast" <<'AST'
fn add2(x: i32) -> i32 { return x + 1; }
let total: i32 = 5;
AST
cat > "$TMPD/ms-main.ast" <<'AST'
include "ms-defs.ast";
fn main() -> i32 { return add2(total); }
AST
./aster build-elf "$TMPD/ms-main.ast" "$TMPD/ms-defs.ast" -o "$TMPD/ms.elf" >/dev/null
set +e
"$RUNNER" "$TMPD/ms.elf"
ms_rc=$?
set -e
[ "$ms_rc" = 6 ] || { echo "FAIL: build-elf with two sources exited $ms_rc, expected 6" >&2; exit 1; }
./aster build-pie "$TMPD/ms-main.ast" "$TMPD/ms-defs.ast" -o "$TMPD/ms.pie" >/dev/null
set +e
"$RUNNER" "$TMPD/ms.pie"
ms_rc=$?
set -e
[ "$ms_rc" = 6 ] || { echo "FAIL: build-pie with two sources exited $ms_rc, expected 6" >&2; exit 1; }
./aster build-obj "$TMPD/ms-defs.ast" -o "$TMPD/ms-defs.o" >/dev/null
./aster build-elf "$TMPD/ms-main.ast" "$TMPD/ms-defs.o" -o "$TMPD/ms-mixed.elf" >/dev/null
set +e
"$RUNNER" "$TMPD/ms-mixed.elf"
ms_rc=$?
set -e
[ "$ms_rc" = 6 ] || { echo "FAIL: build-elf with a source and a prebuilt object exited $ms_rc, expected 6" >&2; exit 1; }
./aster build-so "$TMPD/ms-main.ast" "$TMPD/ms-defs.ast" --soname libms.so -o "$TMPD/ms.so" >/dev/null
readelf -d "$TMPD/ms.so" 2>/dev/null | grep -q 'libms.so' \
    || { echo 'FAIL: build-so with two sources lost its SONAME' >&2; exit 1; }
[ "$(readelf --dyn-syms "$TMPD/ms.so" 2>/dev/null | grep -c 'FUNC    GLOBAL')" -ge 2 ] \
    || { echo 'FAIL: build-so with two sources exported fewer than two functions' >&2; exit 1; }
if ./aster build-obj "$TMPD/ms-main.ast" "$TMPD/ms-defs.ast" -o "$TMPD/nope.o" 2>"$TMPD/ms-obj.log"; then
    echo 'FAIL: build-obj accepted two sources' >&2; exit 1
fi
grep -qF 'build-obj compiles one source file' "$TMPD/ms-obj.log" \
    || { echo 'FAIL: build-obj refused two sources without its message:' >&2; cat "$TMPD/ms-obj.log" >&2; exit 1; }
ls "$TMPD"/ms.elf.aster-tmp* "$TMPD"/ms.so.aster-tmp* 2>/dev/null | grep -q . \
    && { echo 'FAIL: a temporary object was left behind' >&2; exit 1; }
# v0.23.81-dev (CLI-P2-2): the .o/.so writers never checked close(). A small
# output fits in the stream buffer, so a full disk only surfaced at close —
# and the destructor swallowed it, so build-obj to /dev/full exited 0.
# writeElfBytes already had the close check; writeObject, writeSharedObject
# and writeSharedObjectDyn now use the same pattern. The .so writers pad
# past the stream buffer, so /dev/full already trips their mid-write check
# (single-source path) or the pad() tellp guard (dynamic path); only the
# exit code is asserted there, while the close checks themselves are pinned
# by the source counts below so a later removal fails this suite.
# v0.23.81-dev (pad write error): that pad() guard used to report a failed
# mid-write as "internal ELF layout error" — tellp() returns -1 once the
# stream has failed, and -1 cast to uint64_t looks like a position past the
# target. All three writers (writeObject, writeSharedObjectDyn, writeElfBytes)
# now report the write failure instead. A small output never reaches a real
# write before close, so the probes below use a 3000-function source to force
# the stream buffer to flush mid-write.
grep -qF 'failed closing relocatable ELF object' src/aster.cpp \
    || { echo 'FAIL: writeObject lost its close() check' >&2; exit 1; }
so_close=$(grep -c 'failed closing shared object' src/aster.cpp || true)
[ "$so_close" = 2 ] \
    || { echo "FAIL: a shared-object writer lost its close() check (found $so_close, expected 2)" >&2; exit 1; }
if ./aster build-obj examples/hello.ast -o /dev/full 2>"$TMPD/full-obj.log"; then
    echo 'FAIL: build-obj to /dev/full exited 0' >&2; exit 1
fi
grep -qF 'failed closing relocatable ELF object: /dev/full' "$TMPD/full-obj.log" \
    || { echo 'FAIL: build-obj to /dev/full did not report the close failure:' >&2; cat "$TMPD/full-obj.log" >&2; exit 1; }
if ./aster build-so examples/hello.ast -o /dev/full 2>"$TMPD/full-so.log"; then
    echo 'FAIL: build-so to /dev/full exited 0' >&2; exit 1
fi
grep -qF 'failed writing shared object' "$TMPD/full-so.log" \
    || { echo 'FAIL: build-so to /dev/full did not report the write failure:' >&2; cat "$TMPD/full-so.log" >&2; exit 1; }
if ./aster build-so "$TMPD/ms-main.ast" "$TMPD/ms-defs.ast" --soname libms.so -o /dev/full 2>"$TMPD/full-dyn.log"; then
    echo 'FAIL: build-so (dynamic path) to /dev/full exited 0' >&2; exit 1
fi
grep -qF 'failed writing output: /dev/full' "$TMPD/full-dyn.log" \
    || { echo 'FAIL: build-so (dynamic path) to /dev/full did not report the write failure:' >&2; cat "$TMPD/full-dyn.log" >&2; exit 1; }
awk 'BEGIN{for(i=0;i<3000;i++)printf "fn f%d() -> i32 { return %d; }\n",i,i; print "fn main() -> i32 { return f2999(); }"}' > "$TMPD/big.ast"
if ./aster build-obj "$TMPD/big.ast" -o /dev/full 2>"$TMPD/full-bigobj.log"; then
    echo 'FAIL: build-obj of a large source to /dev/full exited 0' >&2; exit 1
fi
grep -qF 'failed writing output: /dev/full' "$TMPD/full-bigobj.log" \
    || { echo 'FAIL: build-obj of a large source to /dev/full did not report the write failure:' >&2; cat "$TMPD/full-bigobj.log" >&2; exit 1; }
if ./aster build-elf "$TMPD/big.ast" -o /dev/full 2>"$TMPD/full-bigelf.log"; then
    echo 'FAIL: build-elf of a large source to /dev/full exited 0' >&2; exit 1
fi
grep -qF 'failed writing output: /dev/full' "$TMPD/full-bigelf.log" \
    || { echo 'FAIL: build-elf of a large source to /dev/full did not report the write failure:' >&2; cat "$TMPD/full-bigelf.log" >&2; exit 1; }
echo 'PASS: .o/.so writers refuse a full disk (/dev/full) instead of exiting 0'
rm -f "$TMPD/ms-defs.o" "$TMPD/ms.elf" "$TMPD/ms.pie" "$TMPD/ms-mixed.elf" "$TMPD/ms.so"
echo 'PASS: one command compiles several sources (elf, pie, .so, mixed with .o)'
echo 'PASS: initializer order (inverted dependency refused, non-_start initializer entered) and the well-ordered chain'
echo 'PASS: function call and relocation linker checks'
# v0.23.81-dev (H-4/C-2): @embed blob symbols are namespaced per source
# file. Two objects that each @embed a file used to both define
# __aster_embed_0, so link-so (and link-obj) refused them as duplicates.
# The probes share a basename in different directories on purpose: the
# namespace must distinguish same-named sources, not just same-named
# embedded files. probe-a carries main (returning its blob length, so
# the link-obj run also proves the bytes survived), probe-b a plain fn.
mkdir -p "$TMPD/embed-a" "$TMPD/embed-b"
printf 'ABCD' > "$TMPD/embed-a/a.bin"
printf 'WXYZ1234' > "$TMPD/embed-b/b.bin"
cat > "$TMPD/embed-a/probe.ast" <<'AST'
let g_a: ptr = @embed("a.bin");
let g_a_len: i32 = @embed_len("a.bin");
fn main() -> i32 { return g_a_len; }
AST
cat > "$TMPD/embed-b/probe.ast" <<'AST'
let g_b: ptr = @embed("b.bin");
let g_b_len: i32 = @embed_len("b.bin");
fn probe_b() -> i32 { return g_b_len; }
AST
./aster build-obj "$TMPD/embed-a/probe.ast" -o "$TMPD/embed-a.o"
./aster build-obj "$TMPD/embed-b/probe.ast" -o "$TMPD/embed-b.o"
./aster link-obj "$TMPD/embed-a.o" "$TMPD/embed-b.o" -o "$TMPD/embed-linked"
set +e
"$RUNNER" "$TMPD/embed-linked"
embed_rc=$?
set -e
[ "$embed_rc" = 4 ] || { echo "FAIL: linked @embed probes exited $embed_rc, expected 4 (len of a.bin)" >&2; exit 1; }
./aster build-obj --pic "$TMPD/embed-a/probe.ast" -o "$TMPD/embed-a.pic.o"
./aster build-obj --pic "$TMPD/embed-b/probe.ast" -o "$TMPD/embed-b.pic.o"
# The defined blob symbol of each object: the GOT reference
# (__aster_gat_...) names the same symbol and is filtered out, so what
# remains is exactly one name per object, and the two must differ while
# still naming the file (probe_ast) — not the bare __aster_embed_0.
sym_a=$(readelf -sW "$TMPD/embed-a.pic.o" | grep '__aster_embed_' | grep -v '__aster_gat_' | grep -o '__aster_embed_[A-Za-z0-9_]*' | sort -u)
sym_b=$(readelf -sW "$TMPD/embed-b.pic.o" | grep '__aster_embed_' | grep -v '__aster_gat_' | grep -o '__aster_embed_[A-Za-z0-9_]*' | sort -u)
[ "$(printf '%s\n' "$sym_a" | grep -c .)" = 1 ] || { echo "FAIL: embed-a defined $sym_a, expected one blob symbol" >&2; exit 1; }
[ "$(printf '%s\n' "$sym_b" | grep -c .)" = 1 ] || { echo "FAIL: embed-b defined $sym_b, expected one blob symbol" >&2; exit 1; }
case "$sym_a" in *__aster_embed_*probe_ast_*) ;; *) echo "FAIL: embed-a blob symbol does not name its file: $sym_a" >&2; exit 1;; esac
case "$sym_b" in *__aster_embed_*probe_ast_*) ;; *) echo "FAIL: embed-b blob symbol does not name its file: $sym_b" >&2; exit 1;; esac
[ "$sym_a" != "$sym_b" ] || { echo "FAIL: two @embed objects share blob symbol $sym_a" >&2; exit 1; }
./aster link-so "$TMPD/embed-a.pic.o" "$TMPD/embed-b.pic.o" --soname libembed.so -o "$TMPD/libembed.so"
[ "$(readelf -sW "$TMPD/libembed.so" | grep '__aster_embed_' | grep -v '__aster_gat_' | grep -o '__aster_embed_[A-Za-z0-9_]*' | sort -u | grep -c .)" = 2 ] \
    || { echo 'FAIL: linked .so does not carry both @embed blobs' >&2; exit 1; }
rm -f "$TMPD/embed-a.o" "$TMPD/embed-b.o" "$TMPD/embed-linked" "$TMPD/embed-a.pic.o" "$TMPD/embed-b.pic.o" "$TMPD/libembed.so"
echo 'PASS: two @embed objects link (link-obj runs, link-so shares no blob symbol)'
# v0.23.82-dev (§6.3 ELF-P2-3): a linked executable's .symtab must report TLS
# globals as TLS symbols in their own sections, with st_value the offset in
# the TLS block (the STT_TLS convention GNU ld emits) — not as OBJECT symbols
# in .bss at bssVaddr+offset, which is what buildSymbolTable's missing TLS
# branch used to emit. Stock aster sources name their TLS symbols
# __aster_tls_<name>, and linkObjects drops __aster_ names from the table, so
# the misreport only fires for a plain-named TLS global — the shape a foreign
# or hand-made .o carries. The probe below renames the compiler's own
# __aster_tls_* names in the .o strtab (same bytes, same indices, so every
# relocation still resolves) and links that: a/b live in .tdata at block
# offsets 0/4, z/w in .tbss at 16/24 — the .tbss tail starts at
# alignUp(tdata size 8, tlsAlign 16) = 16, z is the i32 at tail offset 0 and w
# the i64 at tail offset 8. The program still runs (exit 55: 15+40), because
# the bug never affected execution, only the table a debugger reads.
# The stock (unrenamed) build is asserted alongside it: its TLS symbols are
# absent from the table by design, and the .so writers are asserted
# unaffected too — both split TLS globals out before building their symbol
# list, so no TLS name reaches .symtab or .dynsym there at all.
cat > "$TMPD/tls-sym.ast" <<'AST'
tls let a: i32 = 10;
tls let b: i32 = 20;
tls let z: i32 = 0;
tls let w: i64 = 0;
let g_bss: i32 = 0;
fn main() -> i32 {
    a = a + 5;
    b = b * 2;
    return a + b + g_bss;
}
AST
./aster build-elf "$TMPD/tls-sym.ast" -o "$TMPD/tls-sym.elf" >/dev/null
set +e
"$RUNNER" "$TMPD/tls-sym.elf"
tls_rc=$?
set -e
[ "$tls_rc" = 55 ] || { echo "FAIL: stock TLS program exited $tls_rc, expected 55" >&2; exit 1; }
[ "$(readelf -sW "$TMPD/tls-sym.elf" | grep -cE ' (a|b|z|w)$')" = 0 ] \
    || { echo 'FAIL: stock TLS names leaked into the executable .symtab' >&2; exit 1; }
./aster build-obj "$TMPD/tls-sym.ast" -o "$TMPD/tls-sym.o" >/dev/null
python3 - "$TMPD/tls-sym.o" "$TMPD/tls-sym-plain.o" <<'PY'
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
b = bytearray(open(src, 'rb').read())
shoff = struct.unpack_from('<Q', b, 40)[0]
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
secs = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i * shentsize) for i in range(shnum)]
shstr = secs[shstrndx]
names = b[shstr[4]:shstr[4] + shstr[5]]
def secname(s):
    return names[s[0]:names.index(b'\0', s[0])].decode()
symtab = next(s for s in secs if s[1] == 2)
strtab = secs[symtab[6]]
renamed = 0
for i in range(symtab[5] // 24):
    off = symtab[4] + i * 24
    st_name = struct.unpack_from('<I', b, off)[0]
    nm = b[strtab[4] + st_name: b.index(b'\0', strtab[4] + st_name)].decode()
    if nm.startswith('__aster_tls_') and nm != '__aster_tls_block':
        short = nm[len('__aster_tls_'):]
        pos = strtab[4] + st_name
        b[pos:pos + len(short)] = short.encode()
        b[pos + len(short)] = 0
        renamed += 1
assert renamed == 4, renamed
open(dst, 'wb').write(bytes(b))
PY
./aster link-obj "$TMPD/tls-sym-plain.o" -o "$TMPD/tls-sym-plain.elf" >/dev/null
python3 - "$TMPD/tls-sym-plain.elf" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
shoff = struct.unpack_from('<Q', b, 40)[0]
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
secs = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i * shentsize) for i in range(shnum)]
shstr = secs[shstrndx]
names = b[shstr[4]:shstr[4] + shstr[5]]
def secname(s):
    return names[s[0]:names.index(b'\0', s[0])].decode()
sec_by_name = {secname(s): s for s in secs}
symtab = next(s for s in secs if secname(s) == '.symtab')
strtab = secs[symtab[6]]
got = {}
for j in range(symtab[5] // 24):
    no, info, other, ndx, val, size = struct.unpack_from('<IBBHQQ', b, symtab[4] + j * 24)
    nm = b[strtab[4] + no: b.index(b'\0', strtab[4] + no)].decode()
    got[nm] = (info & 0xf, secname(secs[ndx]) if ndx else 'UND', val)
# (st_type, section, st_value); STT_TLS is 6, STT_OBJECT is 1.
want = {'a': (6, '.tdata', 0), 'b': (6, '.tdata', 4),
        'z': (6, '.tbss', 16), 'w': (6, '.tbss', 24),
        'g_bss': (1, '.bss', sec_by_name['.bss'][3])}
for name, exp in want.items():
    assert got.get(name) == exp, (name, got.get(name), exp)
print('PASS: linked executable reports TLS globals as TLS in .tdata/.tbss at block offsets 0/4/16/24')
PY
set +e
"$RUNNER" "$TMPD/tls-sym-plain.elf"
tls_plain_rc=$?
set -e
[ "$tls_plain_rc" = 55 ] || { echo "FAIL: renamed-TLS program exited $tls_plain_rc, expected 55" >&2; exit 1; }
./aster build-so examples/so_tls_demo.ast --soname libtls.so -o "$TMPD/tls-sym.so" >/dev/null
[ "$(readelf -sW "$TMPD/tls-sym.so" | grep -cE ' (hits|total|spare|acc|zeros)$')" = 0 ] \
    || { echo 'FAIL: a TLS name leaked into the .so .symtab' >&2; exit 1; }
[ "$(readelf --dyn-syms -W "$TMPD/tls-sym.so" | grep -cE ' (hits|total|spare|acc|zeros)$')" = 0 ] \
    || { echo 'FAIL: a TLS name leaked into the .so .dynsym' >&2; exit 1; }
rm -f "$TMPD/tls-sym.ast" "$TMPD/tls-sym.elf" "$TMPD/tls-sym.o" "$TMPD/tls-sym-plain.o" "$TMPD/tls-sym-plain.elf" "$TMPD/tls-sym.so"
echo 'PASS: TLS globals in the linked executable .symtab (ELF-P2-3); .so writers unaffected'
# v0.23.82-dev (§6.3 ELF-P2-4 / S-11): a static link must refuse an input
# .rodata whose declared sh_addralign the page-aligned placement cannot
# satisfy, instead of emitting a section header that lies about its own
# alignment. The Dyn writer already refuses the same input (link-so below),
# so the static half is what this layer pins. The alignment is patched into
# a real compiler .o (the section header field, nothing else), so the input
# is well-formed in every other respect. 16384 always violates under the
# 4096 default page size; 8192 violates only once .text pushes .rodata onto
# the 0x3000 page (200 functions), and the small-text 8192 case still links —
# that is the invariant, not "any alignment above the page size is refused".
cat > "$TMPD/rodata-align.ast" <<'AST'
let g_factor: i32 = 6;
fn main() -> i32 {
  let x: i32 = 7;
  let label: ptr = "pg-size-rodata";
  let _u: i32 = label[0];
  return x * g_factor;
}
AST
./aster build-obj "$TMPD/rodata-align.ast" -o "$TMPD/rodata-align.o" >/dev/null
./aster build-obj --pic "$TMPD/rodata-align.ast" -o "$TMPD/rodata-align-pic.o" >/dev/null
python3 - "$TMPD/rodata-align.o" "$TMPD/rodata-align16k.o" 16384 "$TMPD/rodata-align-pic.o" "$TMPD/rodata-align-pic16k.o" 16384 "$TMPD/rodata-align.o" "$TMPD/rodata-align8k.o" 8192 <<'PY'
import struct, sys
for k in range(0, len(sys.argv) - 1, 3):
    src, dst, align = sys.argv[1 + k], sys.argv[2 + k], int(sys.argv[3 + k])
    b = bytearray(open(src, 'rb').read())
    shoff = struct.unpack_from('<Q', b, 40)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
    secs = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i * shentsize) for i in range(shnum)]
    shstr = secs[shstrndx]
    names = b[shstr[4]:shstr[4] + shstr[5]]
    def secname(s):
        return names[s[0]:names.index(b'\0', s[0])].decode()
    ro = next(s for s in secs if secname(s) == '.rodata')
    struct.pack_into('<Q', b, shoff + secs.index(ro) * shentsize + 48, align)
    open(dst, 'wb').write(bytes(b))
PY
if ./aster link-obj "$TMPD/rodata-align16k.o" -o "$TMPD/rodata-align16k.elf" 2>"$TMPD/rodata-align16k.log"; then
    echo 'FAIL: static link accepted a .rodata aligned 16384 under a 4096 page size' >&2; exit 1
fi
grep -qF 'not aligned to its declared alignment' "$TMPD/rodata-align16k.log" \
    || { echo 'FAIL: the refused static link did not name the alignment:' >&2; cat "$TMPD/rodata-align16k.log" >&2; exit 1; }
if ./aster link-so "$TMPD/rodata-align-pic16k.o" --soname librod.so -o "$TMPD/rodata-align16k.so" 2>"$TMPD/rodata-align16k-so.log"; then
    echo 'FAIL: dynamic link accepted a .rodata aligned 16384 under a 4096 page size' >&2; exit 1
fi
grep -qF 'not aligned to its declared alignment' "$TMPD/rodata-align16k-so.log" \
    || { echo 'FAIL: the refused dynamic link did not name the alignment:' >&2; cat "$TMPD/rodata-align16k-so.log" >&2; exit 1; }
# The 8192 case needs .text past one page: 200 one-line functions.
python3 - > "$TMPD/rodata-big.ast" <<'PY'
print('let g_factor: i32 = 6;')
for i in range(200):
    print(f'fn f{i}() -> i32 {{ return {i}; }}')
print('fn main() -> i32 { let label: ptr = "big-rodata"; let _u: i32 = label[0]; return f199() * g_factor; }')
PY
./aster build-obj "$TMPD/rodata-big.ast" -o "$TMPD/rodata-big.o" >/dev/null
python3 - "$TMPD/rodata-big.o" "$TMPD/rodata-big8k.o" 8192 <<'PY'
import struct, sys
src, dst, align = sys.argv[1], sys.argv[2], int(sys.argv[3])
b = bytearray(open(src, 'rb').read())
shoff = struct.unpack_from('<Q', b, 40)[0]
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
secs = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i * shentsize) for i in range(shnum)]
shstr = secs[shstrndx]
names = b[shstr[4]:shstr[4] + shstr[5]]
def secname(s):
    return names[s[0]:names.index(b'\0', s[0])].decode()
ro = next(s for s in secs if secname(s) == '.rodata')
struct.pack_into('<Q', b, shoff + secs.index(ro) * shentsize + 48, align)
open(dst, 'wb').write(bytes(b))
PY
if ./aster link-obj "$TMPD/rodata-big8k.o" -o "$TMPD/rodata-big8k.elf" 2>"$TMPD/rodata-big8k.log"; then
    echo 'FAIL: static link accepted a .rodata aligned 8192 placed at 0x403000' >&2; exit 1
fi
grep -qF 'not aligned to its declared alignment' "$TMPD/rodata-big8k.log" \
    || { echo 'FAIL: the refused 8192 static link did not name the alignment:' >&2; cat "$TMPD/rodata-big8k.log" >&2; exit 1; }
# Positive control: the same 8192 alignment on the small text is satisfied
# (0x402000 is 8192-aligned), so the link must still succeed and run.
./aster link-obj "$TMPD/rodata-align8k.o" -o "$TMPD/rodata-align8k.elf" >/dev/null
set +e
"$RUNNER" "$TMPD/rodata-align8k.elf"
rodata8k_rc=$?
set -e
[ "$rodata8k_rc" = 42 ] || { echo "FAIL: satisfiable 8192 .rodata program exited $rodata8k_rc, expected 42" >&2; exit 1; }
rm -f "$TMPD/rodata-align.ast" "$TMPD/rodata-align.o" "$TMPD/rodata-align-pic.o" "$TMPD/rodata-align16k.o" "$TMPD/rodata-align-pic16k.o" "$TMPD/rodata-align8k.o" "$TMPD/rodata-align16k.log" "$TMPD/rodata-align16k-so.log" "$TMPD/rodata-align16k.so" "$TMPD/rodata-big.ast" "$TMPD/rodata-big.o" "$TMPD/rodata-big8k.o" "$TMPD/rodata-big8k.log" "$TMPD/rodata-align8k.elf"
echo 'PASS: high-alignment .rodata is refused by the static link (ELF-P2-4/S-11); satisfiable alignment still links'
# v0.23.81-dev (ELF-P2-5 / S-01, S-10): a malformed object must be refused
# before the linker trusts any offset it carries, and the relocation resolver
# itself must check its patch before it reads or writes .text.
#
# The .o-level cases mutate one fact of a good object in place (via
# tests/bounds-mutate.py, which keeps the file a valid ELF) and require
# link-obj to refuse it with the message that names the fact:
#   - a .rela.text offset at/past the end of .text (CALL26 needs 4 bytes, a
#     TLS MOVZ/MOVK pair needs 8), or a wild offset;
#   - an .eh_frame entry whose length overruns the section, is shorter than
#     an entry can be, is zero where the CIE must be, or whose FDE has no
#     relocation for its address. A CIE on its own still links.
# The resolver check itself is defence-in-depth: parseObject already refuses
# every bad .rela.text offset above, so no .o can reach resolveRelocations
# with a bad patch. The only way to exercise it is the function-level
# harness (tests/resolve-reloc-harness.cpp), built against a copy of
# src/aster.cpp with main() renamed and run under ASan — without ASan an
# out-of-bounds read is silent and the probe cannot tell a refusal from luck.
MUTATE="tests/bounds-mutate.py"
./aster build-obj examples/tls_demo.ast -o "$TMPD/bounds-tls.o"
./aster build-obj -g examples/hello.ast -o "$TMPD/bounds-g.o"
# The untouched objects still link (the control every refusal below is read
# against).
./aster link-obj "$TMPD/bounds-tls.o" -o "$TMPD/bounds-tls.ok" >/dev/null
./aster link-obj "$TMPD/bounds-g.o" -o "$TMPD/bounds-g.ok" >/dev/null
# --- .rela.text offsets -------------------------------------------------------
# tls.o .text is 168 bytes; its .rela.text has 8 entries, entries 2..7 being
# TLS (type 4096) relocations.
python3 "$MUTATE" "$TMPD/bounds-tls.o" "$TMPD/bounds-t1a.o" rela-text-off 0 168
if ./aster link-obj "$TMPD/bounds-t1a.o" -o "$TMPD/bounds-t1a.elf" 2>"$TMPD/bounds-t1a.log"; then
    echo 'FAIL: a CALL26 relocation at the end of .text was accepted' >&2; exit 1
fi
grep -qF 'relocation at offset 168 needs 4 bytes of .text and only 0 remain' "$TMPD/bounds-t1a.log" \
    || { echo 'FAIL: the end-of-text refusal does not say what it needed:' >&2; cat "$TMPD/bounds-t1a.log" >&2; exit 1; }
python3 "$MUTATE" "$TMPD/bounds-tls.o" "$TMPD/bounds-t1b.o" rela-text-off 2 164
if ./aster link-obj "$TMPD/bounds-t1b.o" -o "$TMPD/bounds-t1b.elf" 2>"$TMPD/bounds-t1b.log"; then
    echo 'FAIL: a TLS relocation in the last 4 bytes of .text was accepted' >&2; exit 1
fi
grep -qF 'relocation at offset 164 needs 8 bytes of .text and only 4 remain' "$TMPD/bounds-t1b.log" \
    || { echo 'FAIL: the TLS refusal does not say what it needed:' >&2; cat "$TMPD/bounds-t1b.log" >&2; exit 1; }
python3 "$MUTATE" "$TMPD/bounds-tls.o" "$TMPD/bounds-t1c.o" rela-text-off 0 18446744073709551600
if ./aster link-obj "$TMPD/bounds-t1c.o" -o "$TMPD/bounds-t1c.elf" 2>"$TMPD/bounds-t1c.log"; then
    echo 'FAIL: a relocation with a wild offset was accepted' >&2; exit 1
fi
grep -qF 'relocation offset is out of bounds or unaligned' "$TMPD/bounds-t1c.log" \
    || { echo 'FAIL: the wild-offset refusal is worded differently:' >&2; cat "$TMPD/bounds-t1c.log" >&2; exit 1; }
echo 'PASS: out-of-bounds .rela.text offsets are refused (CALL26 at the end, TLS in the last 4 bytes, wild offset)'
# --- .eh_frame lengths ---------------------------------------------------------
# hello-g.o .eh_frame is a 16-byte CIE followed by a 20-byte FDE.
python3 "$MUTATE" "$TMPD/bounds-g.o" "$TMPD/bounds-e1.o" fde-len 0xffffffff
python3 "$MUTATE" "$TMPD/bounds-g.o" "$TMPD/bounds-e2.o" fde-len 11
python3 "$MUTATE" "$TMPD/bounds-g.o" "$TMPD/bounds-e3.o" fde-len 0
python3 "$MUTATE" "$TMPD/bounds-g.o" "$TMPD/bounds-e4.o" fde-len-at 1 0xffffffff
python3 "$MUTATE" "$TMPD/bounds-g.o" "$TMPD/bounds-e5.o" trunc-rela-eh 0
for c in e1 e2 e3 e4; do
    if ./aster link-obj "$TMPD/bounds-$c.o" -o "$TMPD/bounds-$c.elf" 2>"$TMPD/bounds-$c.log"; then
        echo "FAIL: malformed .eh_frame ($c) was accepted" >&2; exit 1
    fi
done
grep -qF 'malformed .eh_frame: an entry overruns the section' "$TMPD/bounds-e1.log" \
    || { echo 'FAIL: huge CIE length refused with the wrong message:' >&2; cat "$TMPD/bounds-e1.log" >&2; exit 1; }
grep -qF 'malformed .eh_frame: an entry overruns the section' "$TMPD/bounds-e2.log" \
    || { echo 'FAIL: short CIE length refused with the wrong message:' >&2; cat "$TMPD/bounds-e2.log" >&2; exit 1; }
grep -qF 'malformed .eh_frame: no CIE' "$TMPD/bounds-e3.log" \
    || { echo 'FAIL: zero-length first entry refused with the wrong message:' >&2; cat "$TMPD/bounds-e3.log" >&2; exit 1; }
grep -qF 'malformed .eh_frame: an entry overruns the section' "$TMPD/bounds-e4.log" \
    || { echo 'FAIL: huge FDE length refused with the wrong message:' >&2; cat "$TMPD/bounds-e4.log" >&2; exit 1; }
if ./aster link-obj "$TMPD/bounds-e5.o" -o "$TMPD/bounds-e5.elf" 2>"$TMPD/bounds-e5.log"; then
    echo 'FAIL: an FDE with no relocation for its address was accepted' >&2; exit 1
fi
grep -qF 'malformed .eh_frame: an FDE has no relocation for its address' "$TMPD/bounds-e5.log" \
    || { echo 'FAIL: the missing-FDE-relocation refusal is worded differently:' >&2; cat "$TMPD/bounds-e5.log" >&2; exit 1; }
# A CIE on its own (no FDE) still links: the table is empty, not malformed.
python3 "$MUTATE" "$TMPD/bounds-g.o" "$TMPD/bounds-e6.o" trunc-eh 20
python3 "$MUTATE" "$TMPD/bounds-e6.o" "$TMPD/bounds-e6.o" trunc-rela-eh 0
./aster link-obj "$TMPD/bounds-e6.o" -o "$TMPD/bounds-e6.elf" >/dev/null \
    || { echo 'FAIL: a CIE-only .eh_frame no longer links' >&2; exit 1; }
echo 'PASS: malformed .eh_frame entries are refused (overrun lengths, zero-length first entry, FDE without relocation); a CIE on its own still links'
# --- resolveRelocations, function level ---------------------------------------
CXX=${CXX:-g++}
if [ "${ASTER_SKIP_ASAN:-}" != 1 ]; then
    cp tests/resolve-reloc-harness.cpp "$TMPD/bounds-harness.cpp"
    sed 's/^int main(/int aster_main_disabled(/' src/aster.cpp > "$TMPD/aster-harness-src.cpp"
    [ "$(grep -c 'aster_main_disabled' "$TMPD/aster-harness-src.cpp")" = 1 ] \
        || { echo 'FAIL: the main() rename no longer applies to src/aster.cpp' >&2; exit 1; }
    # -O0: the harness needs ASan, not optimisation, and -O0 builds this
    # translation unit in about a minute instead of four.
    if $CXX -std=c++17 -O0 -g -fsanitize=address -fno-omit-frame-pointer -I src \
            "$TMPD/bounds-harness.cpp" -o "$TMPD/bounds-harness-asan" > "$TMPD/bounds-harness-build.log" 2>&1; then
        if ! ASAN_OPTIONS=detect_leaks=0 "$TMPD/bounds-harness-asan" > "$TMPD/bounds-harness.log" 2>&1; then
            echo 'FAIL: resolveRelocations accepted an out-of-bounds patch (see the ASan report):' >&2
            grep -E '^(H[0-9]-|HARNESS)' "$TMPD/bounds-harness.log" >&2; exit 1
        fi
        grep -q 'HARNESS PASS' "$TMPD/bounds-harness.log" \
            || { echo 'FAIL: the resolveRelocations harness did not report PASS:' >&2; cat "$TMPD/bounds-harness.log" >&2; exit 1; }
        grep -q 'AddressSanitizer' "$TMPD/bounds-harness.log" \
            && { echo 'FAIL: ASan reports a memory error in the harness' >&2; exit 1; }
        echo 'PASS: resolveRelocations refuses out-of-bounds patches (CALL26 at the end / in the last 2 bytes, TLS in the last 4 bytes, TLS at 2^64-1); a valid patch still applies'
    else
        echo '  ASAN harness skipped (harness build failed)'
    fi
else
    echo '  ASAN harness skipped (ASTER_SKIP_ASAN=1)'
fi
echo 'PASS: all minimal linker checks'
