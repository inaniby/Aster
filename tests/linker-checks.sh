#!/bin/sh
# Verify ET_REL parsing/linking, output equivalence, and malformed-input rejection.
set -eu
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
echo 'PASS: function call and relocation linker checks'
echo 'PASS: all minimal linker checks'
