#!/usr/bin/env python3
"""Mutate a valid aster -g/.o in place (section bytes / sh_size) for
linker/DWARF bounds probes.

A probe builds a good object with `aster build-obj`, mutates one structural
fact about it (a relocation offset, a DWARF form byte, a section size, an
.eh_frame length), and asks `aster link-obj` to refuse it or link it. The
mutations are deliberately small and in place, so the file stays a valid ELF
and only the one fact under test changes. Used by tests/linker-checks.sh,
tests/debug-info-checks.sh and tests/debugline-checks.sh; see those suites
for the case list.
"""
import struct, sys

def load(path):
    return bytearray(open(path,'rb').read())

def sections(b):
    e_shoff, = struct.unpack_from('<Q', b, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from('<HHH', b, 0x3a)
    assert e_shentsize == 64
    secs = []
    for i in range(e_shnum):
        off = e_shoff + i*64
        name, typ, flags, addr, offset, size = struct.unpack_from('<IIQQQQ', b, off)
        secs.append({'i':i,'name_off':name,'type':typ,'flags':flags,'addr':addr,
                     'offset':offset,'size':size,'shoff':off})
    strsec = secs[e_shstrndx]
    for s in secs:
        end = b.index(b'\0', strsec['offset']+s['name_off'])
        s['name'] = b[strsec['offset']+s['name_off']:end].decode()
    return secs

def find(secs, name):
    for s in secs:
        if s['name']==name: return s
    raise KeyError('no section '+name)

def uleb(b, p):
    v=0; shift=0
    while True:
        c=b[p]; p+=1; v |= (c&0x7f)<<shift
        if not (c&0x80): return v,p
        shift+=7

def stmt_list_field(b, secs):
    """Walk the .debug_info CU the way dwarfCuStmtListOffset does; return field offset."""
    di = find(secs,'.debug_info'); ab = find(secs,'.debug_abbrev')
    info = bytes(b[di['offset']:di['offset']+di['size']])
    abbrev = bytes(b[ab['offset']:ab['offset']+ab['size']])
    assert len(info)>=12
    ver, = struct.unpack_from('<H', info, 4)
    aboff, = struct.unpack_from('<I', info, 6)
    addrsize = info[10]
    assert ver==4 and aboff==0, (ver, aboff)
    p=11; code,p = uleb(info,p)
    assert code!=0
    # parse abbrev table into {code: [(attr,form)]}
    q=0; table={}
    while q < len(abbrev):
        c,q = uleb(abbrev,q)
        if c==0: break
        tag,q = uleb(abbrev,q)
        q+=1  # has_children
        attrs=[]
        while True:
            a,q = uleb(abbrev,q); f,q = uleb(abbrev,q)
            if a==0 and f==0: break
            attrs.append((a,f))
        table[c]=attrs
    attrs = table[code]
    for (a,f) in attrs:
        if f==0x08:  # string
            while info[p]!=0: p+=1
            p+=1; size=0
        elif f==0x01: size=addrsize
        elif f==0x0b: size=1
        elif f==0x05: size=2
        elif f==0x06: size=4
        elif f==0x07: size=8
        elif f==0x17: size=4
        elif f==0x13: size=4
        elif f==0x18:
            n,p = uleb(info,p); size=n
        else: raise ValueError('form %02x'%f)
        assert p+size<=len(info), (a,f,p,size,len(info))
        if a==0x10: return p, size, f
        p+=size
    raise ValueError('no stmt_list')

def abbrev_stmt_form_pos(b, secs):
    """File offset of the CU abbrev entry's stmt_list form byte (must be 0x17)."""
    ab = find(secs,'.debug_abbrev')
    base = ab['offset']
    tab = bytes(b[base:base+ab['size']])
    q=0
    while q < len(tab):
        c,q = uleb(tab, q)
        if c==0: break
        tag,q = uleb(tab, q)
        q+=1  # has_children
        while True:
            a,q = uleb(tab, q); f_pos=q; f,q = uleb(tab, q)
            if a==0 and f==0: break
            if c==1 and a==0x10:
                assert f==0x17, hex(f)
                return base+f_pos
    raise ValueError('stmt form not found')

def set_sh_size(b, secs, name, size):
    s=find(secs,name)
    struct.pack_into('<Q', b, s['shoff']+32, size)

def main():
    inp, outp, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
    b = load(inp); secs = sections(b)
    if cmd=='stmt-value':
        di=find(secs,'.debug_info')
        p,size,f = stmt_list_field(b, secs)
        print(struct.unpack_from('<I', b, di['offset']+p)[0])
    elif cmd=='stmt-off':
        p,size,f = stmt_list_field(b, secs)
        print('stmt_list field at .debug_info+%d size=%d form=%02x  info_size=%d' % (
            p,size,f,find(secs,'.debug_info')['size']))
    elif cmd=='abbrev-form':
        pos = abbrev_stmt_form_pos(b, secs)
        b[pos]=int(sys.argv[4],0)
        print('abbrev stmt form byte at file+%d set to %02x' % (pos, b[pos]))
    elif cmd=='trunc-info':
        set_sh_size(b, secs, '.debug_info', int(sys.argv[4],0))
    elif cmd=='set-info-byte':
        di=find(secs,'.debug_info'); b[di['offset']+int(sys.argv[4],0)]=int(sys.argv[5],16)
    elif cmd=='set-info-u32':
        di=find(secs,'.debug_info'); struct.pack_into('<I', b, di['offset']+int(sys.argv[4],0), int(sys.argv[5],16))
    elif cmd=='set-addrsize':
        di=find(secs,'.debug_info'); b[di['offset']+10]=int(sys.argv[4],0)
    elif cmd=='trunc-line':
        set_sh_size(b, secs, '.debug_line', int(sys.argv[4],0))
    elif cmd=='fill-line':
        dl=find(secs,'.debug_line'); b[dl['offset']:dl['offset']+dl['size']]=bytes([int(sys.argv[4],16)])*dl['size']
    elif cmd=='trunc-abbrev':
        set_sh_size(b, secs, '.debug_abbrev', int(sys.argv[4],0))
    elif cmd=='fill-abbrev':
        ab=find(secs,'.debug_abbrev'); b[ab['offset']:ab['offset']+ab['size']]=bytes([int(sys.argv[4],16)])*ab['size']
    elif cmd=='fde-len':
        ef=find(secs,'.eh_frame'); struct.pack_into('<I', b, ef['offset'], int(sys.argv[4],16))
    elif cmd=='fde-len-at':
        ef=find(secs,'.eh_frame'); pos=ef['offset']
        for _ in range(int(sys.argv[4],0)):
            ln,=struct.unpack_from('<I', b, pos); pos += 4+ln
        struct.pack_into('<I', b, pos, int(sys.argv[5],16))
    elif cmd=='trunc-eh':
        set_sh_size(b, secs, '.eh_frame', int(sys.argv[4],0))
    elif cmd=='trunc-rela-info':
        set_sh_size(b, secs, '.rela.debug_info', int(sys.argv[4],0))
    elif cmd=='trunc-rela-eh':
        set_sh_size(b, secs, '.rela.eh_frame', int(sys.argv[4],0))
    elif cmd=='rela-text-off':
        r=find(secs,'.rela.text'); idx=int(sys.argv[4],0)
        struct.pack_into('<Q', b, r['offset']+idx*24, int(sys.argv[5],0))
    elif cmd=='rela-text-type':
        r=find(secs,'.rela.text'); idx=int(sys.argv[4],0)
        info,=struct.unpack_from('<Q', b, r['offset']+idx*24+8)
        struct.pack_into('<Q', b, r['offset']+idx*24+8, (info & 0xffffffff00000000) | int(sys.argv[5],0))
    elif cmd=='sec-sizes':
        for s in secs: print('%-18s off=%-6d size=%d' % (s['name'], s['offset'], s['size']))
    else:
        raise SystemExit('unknown cmd '+cmd)
    if outp!='-':
        open(outp,'wb').write(bytes(b))

if __name__=='__main__':
    main()
