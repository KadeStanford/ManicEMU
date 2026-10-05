"""Independent Mach-O import/export dependency check for preserved frameworks."""
import struct
LOADS=(0xC,0x80000018,0x8000001F)
def commands(data):
    pos=32
    for _ in range(struct.unpack_from('<I',data,16)[0]):
        cmd,size=struct.unpack_from('<II',data,pos)
        if size<8 or pos+size>len(data):raise ValueError('Invalid load command')
        yield cmd,pos,size
        pos+=size
def nlist(data):
    for cmd,pos,size in commands(data):
        if cmd==2:
            symbols,count,strings,length=struct.unpack_from('<4I',data,pos+8)
            if symbols+16*count>len(data) or strings+length>len(data):raise ValueError('Invalid symbol table')
            for i in range(count):
                offset,kind,section,desc,value=struct.unpack_from('<IBBHQ',data,symbols+16*i)
                if not offset or offset>=length or kind&0xE0:continue
                end=data.find(b'\0',strings+offset,strings+length)
                if end<0:raise ValueError('Unterminated symbol')
                yield data[strings+offset:end].decode(),kind,desc,value
def uleb(data,pos,end):
    value=shift=0
    while pos<end and shift<64:
        byte=data[pos];pos+=1;value|=(byte&127)<<shift
        if byte<128:return value,pos
        shift+=7
    raise ValueError('Invalid export trie ULEB')
def exports(data):
    result={name for name,kind,desc,value in nlist(data) if kind&1 and kind&0xE}
    for cmd,pos,size in commands(data):
        region=None
        if cmd==0x80000033:region=struct.unpack_from('<II',data,pos+8)
        if cmd in (0x22,0x80000022):region=struct.unpack_from('<II',data,pos+40)
        if not region or not region[1]:continue
        base,length=region;end=base+length
        if end>len(data):raise ValueError('Invalid export trie range')
        active=set()
        def node(offset,prefix):
            if offset in active or len(prefix)>16384:raise ValueError('Cyclic export trie')
            active.add(offset)
            cursor=base+offset
            terminal,cursor=uleb(data,cursor,end)
            if terminal:result.add(prefix)
            cursor+=terminal
            if cursor>=end:raise ValueError('Invalid export trie terminal')
            count=data[cursor];cursor+=1
            for _ in range(count):
                zero=data.find(b'\0',cursor,end)
                if zero<0:raise ValueError('Invalid export edge')
                edge=data[cursor:zero].decode();cursor=zero+1
                child,cursor=uleb(data,cursor,end)
                node(child,prefix+edge)
            active.remove(offset)
        node(0,'')
    return result
def loads(data):
    result=[]
    for cmd,pos,size in commands(data):
        if cmd in LOADS:
            start=struct.unpack_from('<I',data,pos+8)[0]
            result.append(data[pos+start:pos+size].split(b'\0',1)[0].decode())
    return result
def imports(data):
    paths=loads(data)
    result={}
    for name,kind,desc,value in nlist(data):
        if kind&1 and kind&0xE==0 and value==0:
            ordinal=desc>>8
            if 1<=ordinal<=len(paths):
                result.setdefault(paths[ordinal-1],set()).add(name)
    return result
def check_embedded_imports(main,frameworks):
    findings=[];checked={}
    for path,symbols in imports(main).items():
        if path.startswith(('/usr/lib/','/System/Library/')):continue
        name=path.rsplit('/',1)[-1]
        if name not in frameworks:
            findings.append({'dependency':path,'missing_framework':True});continue
        available=exports(frameworks[name])
        missing=sorted(symbols-available)
        checked[path]={'imports':len(symbols),'missing':missing}
        if missing:findings.append({'dependency':path,'missing_symbols':missing})
    if findings:raise ValueError('Preserved framework ABI mismatch: '+str(findings))
    return checked

