#!/usr/bin/env python3
"""Builds a small (16 MiB) FAT16 test image laid out like a cartridge: a game folder with
CODE/MAIN.ITA plus its main.ita.md5 (long file name), DATA/ICON.PNG and a reserved-space file.
Used to test the C# FAT checker embedded in Read-Cartridge.ps1.

Usage: python3 make_test_fat.py [output.img]   (default: test.img in the current directory)
Prints the expected MD5 of MAIN.ITA.
"""
import struct, os, sys, hashlib
BPS=512; SPC=4; CL=BPS*SPC; RSV=4; NF=2; ROOTENT=512; TOT=16*1024*1024//BPS
nclus_est=TOT//SPC; FSZ=(nclus_est*2+BPS-1)//BPS+1
img=bytearray(TOT*BPS)
bs=bytearray(512); bs[0:3]=b'\xeb\x3c\x90'; bs[3:11]=b'MSWIN4.1'
struct.pack_into('<HBHBHHBHHHII',bs,11,BPS,SPC,RSV,NF,ROOTENT,0,0xF8,FSZ,63,255,0,TOT)
bs[510:512]=b'\x55\xaa'; img[0:512]=bs
fatoff=RSV*BPS; rootoff=fatoff+NF*FSZ*BPS; dataoff=rootoff+ROOTENT*32
fat=[0xFFF8,0xFFFF]+[0]*( (FSZ*BPS)//2 -2)
nextc=[2]
def alloc(data):
    n=max(1,(len(data)+CL-1)//CL); start=nextc[0]
    for i in range(n):
        c=start+i; fat[c]=c+1 if i<n-1 else 0xFFFF
        chunk=data[i*CL:(i+1)*CL]; off=dataoff+(c-2)*CL; img[off:off+len(chunk)]=chunk
    nextc[0]+=n; return start
def ent(short,attr,clus,size):
    n,e=(short.split('.')+[''])[:2]; e=e
    return n.ljust(8).encode()+e.ljust(3).encode()+bytes([attr])+b'\0'*8+struct.pack('<H',clus>>16)+b'\0'*4+struct.pack('<HI',clus&0xffff,size)
def lfn(long,short):
    sn=(short.split('.')+[''])
    s11=(sn[0].ljust(8)+sn[1].ljust(3)).encode(); cs=0
    for b in s11: cs=(((cs&1)<<7)+(cs>>1)+b)&0xff
    u=long.encode('utf-16-le')+b'\0\0'; chars=[u[i:i+2] for i in range(0,len(u),2)]
    while len(chars)%13: chars.append(b'\xff\xff')
    parts=[chars[i:i+13] for i in range(0,len(chars),13)]; out=b''
    for k in range(len(parts),0,-1):
        p=parts[k-1]; e=bytearray(32); e[0]=k|(0x40 if k==len(parts) else 0)
        e[1:11]=b''.join(p[0:5]); e[11]=0x0f; e[13]=cs; e[14:26]=b''.join(p[5:11]); e[28:32]=b''.join(p[11:13]); out+=bytes(e)
    return out
ita=os.urandom(3_000_123); md5=hashlib.md5(ita).hexdigest().upper().encode()
c_ita=alloc(ita); c_md5=alloc(md5)
code=ent('.',0x10,0,0)+ent('..',0x10,0,0)+ent('MAIN.ITA',0x20,c_ita,len(ita))+lfn('main.ita.md5','MAINIT~1.MD5')+ent('MAINIT~1.MD5',0x20,c_md5,len(md5))
c_code=alloc(code+b'\0'*32)
icon=os.urandom(13267); c_icon=alloc(icon)
data=ent('.',0x10,0,0)+ent('..',0x10,0,0)+ent('ICON.PNG',0x20,c_icon,len(icon)); c_data=alloc(data+b'\0'*32)
top=ent('.',0x10,0,0)+ent('..',0x10,0,0)+ent('CODE',0x10,c_code,0)+ent('DATA',0x10,c_data,0); c_top=alloc(top+b'\0'*32)
res=os.urandom(100000); c_res=alloc(res)
root=lfn('__RESERVED_SPACE__.bin','__RESE~1.BIN')+ent('__RESE~1.BIN',0x21,c_res,len(res))+lfn('80-274505-005-001.268E19095281A9933EBE56E2DBFBAC05','80-274~1')+ent('80-274~1',0x11,c_top,0)
img[rootoff:rootoff+len(root)]=root
fb=struct.pack('<%dH'%len(fat),*fat)
for i in range(NF): img[fatoff+i*FSZ*BPS:fatoff+i*FSZ*BPS+len(fb)]=fb
out=sys.argv[1] if len(sys.argv)>1 else 'test.img'
open(out,'wb').write(img); print('md5',md5.decode())
