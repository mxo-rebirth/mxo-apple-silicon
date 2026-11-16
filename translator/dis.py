import sys,struct,subprocess,tempfile,os
def load(p):
    b=open(p,'rb').read(); pe=struct.unpack_from('<I',b,0x3c)[0]
    nsec=struct.unpack_from('<H',b,pe+6)[0]; opt=struct.unpack_from('<H',b,pe+20)[0]
    base=struct.unpack_from('<I',b,pe+24+28)[0]
    secs=[struct.unpack_from('<IIII',b,pe+24+opt+40*i+8) for i in range(nsec)]
    return b,secs,base
def off(secs,rva):
    for vs,va,rs,raw in secs:
        if va<=rva<va+max(vs,rs): return raw+rva-va
def dis(b,secs,base,s,e):
    code=b[off(secs,s):off(secs,e)]
    with tempfile.NamedTemporaryFile(suffix='.bin',delete=False) as f: f.write(code); n=f.name
    out=subprocess.run(['i686-w64-mingw32-objdump','-D','-b','binary','-mi386','-Mintel','--adjust-vma=0x%x'%(base+s),n],capture_output=True,text=True).stdout
    os.unlink(n)
    return [l for l in out.splitlines() if ':\t' in l]
if __name__=='__main__':
    b,secs,base=load(sys.argv[1]); print('image base %x'%base)
    for a in sys.argv[2:]:
        s,e=[int(x,16) for x in a.split('-')]
        print('==== %x-%x'%(s,e))
        for l in dis(b,secs,base,s,e): print(l)
