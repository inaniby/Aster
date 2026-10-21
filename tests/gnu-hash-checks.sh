#!/bin/sh
# v0.19.1: validate bucket-sorted GNU hash metadata and SysV compatibility.
set -eu
[ -x ./aster ] || { echo 'build ./aster first' >&2; exit 2; }
./aster build-so examples/so_link_lib.ast -o tmp-gnu-hash.so --soname libgnu-hash.so
./aster build-so examples/so_link_import.ast -o tmp-gnu-hash-import.so --needed libdyn.so
python3 - <<'PY'
import struct
p='tmp-gnu-hash.so'; b=open(p,'rb').read()
assert b[:6] == b'\x7fELF\x02\x01'
shoff=struct.unpack_from('<Q',b,40)[0]; ents,num,si=struct.unpack_from('<HHH',b,58)
raw=[struct.unpack_from('<IIQQQQIIQQ',b,shoff+i*ents) for i in range(num)]
ns=raw[si]; names=b[ns[4]:ns[4]+ns[5]]
sec={names[x[0]:names.index(b'\0',x[0])].decode():x for x in raw}
def dyn():
 s=sec['.dynamic']; out={}
 for i in range(s[5]//16):
  tag,val=struct.unpack_from('<qQ',b,s[4]+i*16)
  if tag: out.setdefault(tag,[]).append(val)
 return out
d=dyn(); assert 0x6ffffef5 in d, 'DT_GNU_HASH missing'
s=sec['.gnu.hash']; off=s[4]; size=s[5]
nb,so,bs,shift=struct.unpack_from('<IIII',b,off)
assert nb>=1 and so>=1 and bs>=1 and shift<32
assert 16+bs*8+nb*4 <= size
bloom=struct.unpack_from('<'+'Q'*bs,b,off+16)
buckets=struct.unpack_from('<'+'I'*nb,b,off+16+bs*8)
chains_off=off+16+bs*8+nb*4
sy=sec['.dynsym']; st=sec['.dynstr']; strings=b[st[4]:st[4]+st[5]]
symcount=sy[5]//24
syms=[]
for i in range(symcount):
 name,info,other,shndx,value,sz=struct.unpack_from('<IBBHQQ',b,sy[4]+i*24)
 end=strings.index(b'\0',name); syms.append(strings[name:end].decode() if name else '')
def gh(n):
 h=5381
 for c in n.encode(): h=((h*33)+c)&0xffffffff
 return h
# GNU hash covers defined global symbols only; undefined imports follow the hashed range.
def_count=sum(1 for i in range(1,symcount) if struct.unpack_from('<H',b,sy[4]+i*24+6)[0] != 0)
assert so==1 and def_count>=1 and nb>1
assert 16+bs*8+nb*4+4*def_count == size, (nb,bs,def_count,size)
chains=struct.unpack_from('<'+'I'*def_count,b,chains_off)
last_bucket=-1
for j in range(def_count):
 i=so+j; h=gh(syms[i]); stored=chains[j]
 assert (stored&~1)==(h&~1), (i,syms[i],hex(stored),hex(h))
 bucket=h%nb
 assert bucket>=last_bucket, ('dynsym definitions not bucket-sorted',syms[i])
 last_bucket=bucket
 assert bloom[(h//64)%bs] & (1 << (h%64)), ('bloom bit 1',syms[i])
 assert bloom[((h>>shift)//64)%bs] & (1 << ((h>>shift)%64)), ('bloom bit 2',syms[i])
 assert buckets[bucket] != 0
 for idx in range(so,so+def_count):
  if gh(syms[idx])%nb==bucket:
   assert buckets[bucket] <= idx, ('bucket points after first symbol',bucket,idx)
   break
# Each non-empty bucket's chain must end at a symbol with the low terminator bit set.
for bucket,start in enumerate(buckets):
 if not start: continue
 j=start-so
 assert 0<=j<def_count
 while j<def_count and not (chains[j]&1):
  assert gh(syms[so+j])%nb==bucket
  j+=1
 assert j<def_count and gh(syms[so+j])%nb==bucket, ('missing bucket terminator',bucket)
assert chains[-1]&1, 'last defined-symbol chain entry must terminate'
assert d[0x6ffffef5][0] == s[3], 'DT_GNU_HASH address mismatch'
assert 4 in d and d[4][0] == sec['.hash'][3], 'SysV hash compatibility lost'
print('PASS: DT_GNU_HASH header, bloom filter, buckets, chains and DT tag are valid')
print('PASS: SysV DT_HASH remains present for backward compatibility')
print('PASS: GNU hash metadata covers %d defined dynamic symbols across %d buckets' % (def_count,nb))
PY

python3 - <<'PY'
import struct
p='tmp-gnu-hash-import.so'; b=open(p,'rb').read()
shoff=struct.unpack_from('<Q',b,40)[0]; ents,num,si=struct.unpack_from('<HHH',b,58)
raw=[struct.unpack_from('<IIQQQQIIQQ',b,shoff+i*ents) for i in range(num)]
ns=raw[si]; names=b[ns[4]:ns[4]+ns[5]]
sec={names[x[0]:names.index(b'\0',x[0])].decode():x for x in raw}
sy,st=sec['.dynsym'],sec['.dynstr']; strings=b[st[4]:st[4]+st[5]]; syms=[]
for i in range(sy[5]//24):
 no,info,other,shndx,val,size=struct.unpack_from('<IBBHQQ',b,sy[4]+i*24)
 syms.append((strings[no:].split(b'\0')[0].decode(),shndx))
for relsec,wanted,rtype in [('.rela.plt',{'add','mul'},1026),('.rela.dyn',{'counter'},1025)]:
 secinfo=sec[relsec]; found=set()
 for off in range(secinfo[4],secinfo[4]+secinfo[5],24):
  info=struct.unpack_from('<Q',b,off+8)[0]; idx,typ=info>>32,info&0xffffffff
  if typ==rtype:
   assert idx<len(syms),(relsec,idx,len(syms))
   if syms[idx][0] in wanted: found.add(syms[idx][0])
 assert found==wanted,(relsec,found,wanted)
print('PASS: GNU-hash dynsym reordering preserves JUMP_SLOT/GLOB_DAT import symbol indices')
PY
