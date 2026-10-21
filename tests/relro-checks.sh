#!/bin/sh
# v0.20.0: validate PT_GNU_RELRO page boundaries and section coverage in both .so writers.
set -eu
[ -x ./aster ] || { echo "build ./aster first" >&2; exit 2; }
./aster build-so examples/so_link_lib.ast -o tmp-relro-build.so --soname librelro-build.so
./aster build-so examples/so_link_import.ast -o tmp-relro-import.so --needed librelro-build.so
./aster build-obj --pic examples/link_so_part_a.ast -o tmp-relro-a.o
./aster build-obj --pic examples/link_so_part_b.ast -o tmp-relro-b.o
./aster link-so tmp-relro-a.o tmp-relro-b.o -o tmp-relro-link.so --soname librelro-link.so
./aster build-obj --pic examples/so_link_import.ast -o tmp-relro-import.o
./aster link-so tmp-relro-import.o -o tmp-relro-link-import.so --soname librelro-link-import.so --needed librelro-build.so
python3 - <<'PY'
import struct
PAGE=0x1000
PT_LOAD=1
PT_DYNAMIC=2
PT_GNU_RELRO=0x6474e552
PF_R,PF_W,PF_X=4,2,1

def inspect(path, require_plt):
    b=open(path,'rb').read()
    assert b[:6] == b'\x7fELF\x02\x01', path
    phoff=struct.unpack_from('<Q',b,32)[0]
    phentsize,phnum=struct.unpack_from('<HH',b,54)
    ph=[struct.unpack_from('<IIQQQQQQ',b,phoff+i*phentsize) for i in range(phnum)]
    loads=[p for p in ph if p[0]==PT_LOAD]
    assert len(loads)==2, (path, [(p[0],p[1]) for p in ph])
    assert any(p[1] & (PF_R|PF_X)==(PF_R|PF_X) and not p[1]&PF_W for p in loads), path
    assert any(p[1] & (PF_R|PF_W)==(PF_R|PF_W) and not p[1]&PF_X for p in loads), path
    rel=[p for p in ph if p[0]==PT_GNU_RELRO]
    assert len(rel)==1, (path, rel)
    r=rel[0]; start,end=r[3],r[3]+r[6]
    assert start%PAGE==0 and r[6]>0 and r[6]%PAGE==0, (path,hex(start),hex(r[6]))
    assert r[2]==start, (path,hex(r[2]),hex(start))
    shoff=struct.unpack_from('<Q',b,40)[0]
    shentsize,shnum,shstrndx=struct.unpack_from('<HHH',b,58)
    sh=[struct.unpack_from('<IIQQQQIIQQ',b,shoff+i*shentsize) for i in range(shnum)]
    ns=sh[shstrndx]; names=b[ns[4]:ns[4]+ns[5]]
    sec={names[x[0]:names.index(b'\0',x[0])].decode():x for x in sh if x[0]<len(names)}
    for name in ('.dynamic','.got'):
        if name in sec and sec[name][5]:
            x=sec[name]; assert start<=x[3] and x[3]+x[5]<=end, (path,name,hex(x[3]),hex(x[5]),hex(start),hex(end))
    if '.init_array' in sec and sec['.init_array'][5]:
        x=sec['.init_array']; assert start<=x[3] and x[3]+x[5]<=end, (path,'.init_array')
    if '.data' in sec and sec['.data'][5]:
        x=sec['.data']; assert x[3]+x[5]<=start, (path,'.data overlaps RELRO',hex(x[3]+x[5]),hex(start))
    if require_plt:
        for name in ('.got.plt',):
            x=sec[name]; assert start<=x[3] and x[3]+x[5]<=end, (path,name)
        dyn=sec['.dynamic']; tags=[]
        for i in range(dyn[5]//16): tags.append(struct.unpack_from('<qQ',b,dyn[4]+i*16))
        if '.rela.plt' in sec and sec['.rela.plt'][5]:
            assert any(t==24 for t,v in tags) or any(t==30 and (v&8) for t,v in tags), 'PLT must use eager binding with RELRO'
    print('PASS: '+path+' has page-aligned PT_GNU_RELRO; writable .data remains outside; loader metadata/GOT are covered')

inspect('tmp-relro-build.so',False)
inspect('tmp-relro-import.so',True)
inspect('tmp-relro-link.so',False)
inspect('tmp-relro-link-import.so',True)
PY
if command -v readelf >/dev/null 2>&1; then
  readelf -lW tmp-relro-build.so | grep -q 'GNU_RELRO'
  readelf -lW tmp-relro-import.so | grep -q 'GNU_RELRO'
  readelf -lW tmp-relro-link.so | grep -q 'GNU_RELRO'
  readelf -lW tmp-relro-link-import.so | grep -q 'GNU_RELRO'
  echo 'PASS: readelf reports PT_GNU_RELRO for both shared-object writers'
fi
rm -f tmp-relro-build.so tmp-relro-import.so tmp-relro-a.o tmp-relro-b.o tmp-relro-import.o tmp-relro-link.so tmp-relro-link-import.so
