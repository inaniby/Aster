#!/bin/sh
# Validate the relocatable object writer without relying on external binutils.
set -eu
[ -x ./aster ] || { echo "build ./aster first" >&2; exit 2; }
for name in hello arithmetic negative_division if_less if_greater_equal if_equal if_not_equal_false if_less_equal if_greater_false assignment while_count nested_while scope_shadow nested_if many_locals long_expression if_return while_break while_continue nested_loop_break; do
  ./aster build-obj "examples/$name.ast" -o "tmp-$name.o"
done
python3 - <<'PY'
import os, struct
names = ['hello', 'arithmetic', 'negative_division', 'if_less', 'if_greater_equal', 'if_equal', 'if_not_equal_false', 'if_less_equal', 'if_greater_false', 'assignment', 'while_count', 'nested_while', 'scope_shadow', 'nested_if', 'many_locals', 'long_expression', 'if_return', 'while_break', 'while_continue', 'nested_loop_break']
for name in names:
    path = 'tmp-' + name + '.o'
    b = open(path, 'rb').read()
    assert b[:4] == b'\x7fELF' and b[4:6] == b'\x02\x01', path
    etype, machine = struct.unpack_from('<HH', b, 16)
    assert (etype, machine) == (1, 183), (path, etype, machine)
    shoff = struct.unpack_from('<Q', b, 40)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
    assert (shentsize, shnum, shstrndx) == (64, 6, 5), path
    sections = [struct.unpack_from('<IIQQQQIIQQ', b, shoff+i*shentsize) for i in range(shnum)]
    shstr = sections[shstrndx]
    namestr = b[shstr[4]:shstr[4]+shstr[5]]
    def cstr(data, off):
        end = data.index(b'\0', off)
        return data[off:end].decode()
    byname = {cstr(namestr, s[0]): (i, s) for i, s in enumerate(sections) if s[0] < len(namestr) and namestr[s[0]:s[0]+1] != b'\0'}
    assert set(byname) == {'.text', '.rela.text', '.symtab', '.strtab', '.shstrtab'}, (path, byname.keys())
    text_i, text = byname['.text']
    assert text[1] == 1 and text[2] == 0x6 and text[7] == 0 and text[8] == 4, path
    rela = byname['.rela.text'][1]
    assert rela[1] == 4 and rela[5] == 0 and rela[9] == 24, path
    sym_i, sym = byname['.symtab']
    assert sym[1] == 2 and sym[6] == byname['.strtab'][0] and sym[9] == 24 and sym[5] == 48, path
    strsec = byname['.strtab'][1]
    strings = b[strsec[4]:strsec[4]+strsec[5]]
    found = False
    for off in range(24, sym[5], 24):
        st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from('<IBBHQQ', b, sym[4]+off)
        if st_name and cstr(strings, st_name) == '_start':
            assert st_info == 0x12 and st_shndx == text_i and st_value == 0 and st_size == text[5], path
            found = True
    assert found, path
    print(f'{path}: ELF64 AArch64 ET_REL, .text={text[5]} bytes, global _start, RELA section present')
    os.remove(path)
print('PASS: all relocatable object checks')
PY
