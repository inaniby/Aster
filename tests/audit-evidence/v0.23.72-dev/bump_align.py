import struct,sys
def bump(path,changes,out):
    b=bytearray(open(path,'rb').read())
    so=struct.unpack_from('<Q',b,0x28)[0]
    es,n,x=struct.unpack_from('<HHH',b,0x3a)
    st=struct.unpack_from('<Q',b,so+x*es+0x18)[0]
    names={}
    for i in range(n):
        o=so+i*es; nm=struct.unpack_from('<I',b,o)[0]; e=b.index(0,st+nm)
        names[b[st+nm:e].decode()]=o
    for sec,a in changes.items():
        if sec not in names: print('MISSING SECTION',sec); continue
        struct.pack_into('<Q',b,names[sec]+48,a)
        print(f'  {sec}: addralign -> {a}')
    open(out,'wb').write(b)
if __name__=='__main__':
    p,o=sys.argv[1],sys.argv[2]; ch={}
    for kv in sys.argv[3:]:
        k,v=kv.split('='); ch[k]=int(v)
    bump(p,ch,o)
