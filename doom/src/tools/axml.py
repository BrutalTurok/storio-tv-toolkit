import struct
def decode(d):
    """Returns a list of (event, name, attributes[(name,resid,type,data,raw)])"""
    out=[]; strings=[]; resids=[]
    off=8
    while off < len(d):
        t,hs,sz=struct.unpack_from('<HHI',d,off)
        if t==0x0001:
            sc,stc,flags,ss,sts=struct.unpack_from('<IIIII',d,off+8)
            utf8=flags & 0x100
            offs=struct.unpack_from('<%dI'%sc,d,off+hs)
            for o in offs:
                p=off+ss+o
                if utf8:
                    n=d[p]; p+=1
                    if n&0x80: p+=1
                    n=d[p]; p+=1
                    if n&0x80: n=((n&0x7f)<<8)|d[p]; p+=1
                    strings.append(d[p:p+n].decode('utf8'))
                else:
                    n=struct.unpack_from('<H',d,p)[0]; strings.append(d[p+2:p+2+n*2].decode('utf-16-le'))
        elif t==0x0180:
            resids=list(struct.unpack_from('<%dI'%((sz-8)//4),d,off+8))
        elif t==0x0102:
            ns,name,aStart,aSize,aCount=struct.unpack_from('<iiHHH',d,off+16)
            attrs=[]
            for i in range(aCount):
                ans,an,raw,_,_,typ,data=struct.unpack_from('<iiiHBBI',d,off+16+aStart+i*aSize)
                attrs.append((strings[an], resids[an] if an < len(resids) else None, typ, data, strings[raw] if raw>=0 else None))
            out.append(('start',strings[name],attrs))
        elif t==0x0103:
            ns,name=struct.unpack_from('<ii',d,off+16); out.append(('end',strings[name],[]))
        off+=sz
    return out
if __name__=='__main__':
    import sys,zipfile
    z=zipfile.ZipFile(sys.argv[1]); 
    for e in decode(z.read('AndroidManifest.xml')):
        if e[0]=='start': print(e[1], [(a[0],hex(a[1]) if a[1] else None,hex(a[2]),hex(a[3]),a[4]) for a in e[2]])
