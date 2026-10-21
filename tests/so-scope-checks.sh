#!/bin/sh
# Structural checks for same-named symbols in separate DSOs and their SONAMEs.
set -eu
[ -x ./aster ] || { echo 'build ./aster first' >&2; exit 2; }
WORK=tmp-so-scope
rm -rf "$WORK"; mkdir -p "$WORK"
./aster build-so examples/so_scope_a.ast -o "$WORK/libscope-a.so" --soname libscope-a.so
./aster build-so examples/so_scope_b.ast -o "$WORK/libscope-b.so" --soname libscope-b.so
python3 - "$WORK" <<'PY'
import struct, sys
from pathlib import Path
work=Path(sys.argv[1])
def parse(path):
    b=path.read_bytes()
    assert b[:4] == b'\x7fELF' and struct.unpack_from('<H',b,16)[0] == 3
    shoff=struct.unpack_from('<Q',b,40)[0]; ents,n,si=struct.unpack_from('<HHH',b,58)
    raw=[struct.unpack_from('<IIQQQQIIQQ',b,shoff+i*ents) for i in range(n)]
    shstr=b[raw[si][4]:raw[si][4]+raw[si][5]]
    sec={shstr[s[0]:shstr.index(b'\0',s[0])].decode():s for s in raw}
    dynstr=sec['.dynstr']; strings=b[dynstr[4]:dynstr[4]+dynstr[5]]
    sym=sec['.dynsym']; names=[]
    for i in range(sym[5]//24):
        name,info,other,shndx,value,size=struct.unpack_from('<IBBHQQ',b,sym[4]+i*24)
        names.append((strings[name:].split(b'\0')[0].decode(),shndx,info))
    dyn=sec['.dynamic']; tags=[]
    for i in range(dyn[5]//16):
        tag,val=struct.unpack_from('<qQ',b,dyn[4]+i*16)
        if tag==0: break
        tags.append((tag,val))
    sonames=[]
    for tag,val in tags:
        if tag==14: sonames.append(strings[val:].split(b'\0')[0].decode())
    return names,sonames
for file,soname in [('libscope-a.so','libscope-a.so'),('libscope-b.so','libscope-b.so')]:
    names,sonames=parse(work/file)
    assert sonames == [soname], (file,sonames)
    for symbol in ('scope_state','scope_get','scope_bump'):
        matches=[x for x in names if x[0]==symbol]
        assert len(matches)==1 and matches[0][1]!=0, (file,symbol,matches)
    print(f'PASS: {file} exports its own defined scope_state/scope_get/scope_bump and has DT_SONAME={soname}')
print('PASS: same-named exports are defined independently in two ET_DYN objects')
PY
${HOSTCC:-cc} -O2 -Wall -Wextra -Wpedantic -Werror -o "$WORK/so-scope-host" tests/so-scope-host.c -ldl
echo 'PASS: strict RTLD_LOCAL scope harness compile'
${HOSTCC:-cc} -O2 -Wall -Wextra -Wpedantic -Werror -o "$WORK/so-loader-lifecycle-host" tests/so-loader-lifecycle-host.c -ldl
echo 'PASS: strict RTLD_GLOBAL and isolated lifecycle harness compile'
rm -rf "$WORK"
