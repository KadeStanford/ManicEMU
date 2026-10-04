"""Instrument the exact bundled melonDS DS 1.3.1 without replacing its engine.

Only the two WiFi UpdatePowerOn call sites are changed, never the shared no-op
function (also used by unrelated rendering/camera methods). A third hook reports
an attempted wireless packet before netpacket pairing. The existing environment
callback carries metadata synchronously to the core shim. No imported symbols,
new segments, game patches, writable executable memory, or JIT are introduced.
"""
import argparse, hashlib, json, pathlib, struct
SHA256='20b346952e860f7ca5dd2f92addcbbd8ffa3d1726c1764d3a94cebfefd05700b'
CAVE=0x260800
ENVIRONMENT=0x2b5740
COMMAND=0x4d445301
ON=0xe5d30
OFF=0xe5d6c
SEND=0x3aa9c

def branch(pc,target,link=False):
    distance=target-pc
    if distance%4 or not -(1<<27)<=distance<(1<<27):raise ValueError('branch range')
    return (0x94000000 if link else 0x14000000)|((distance//4)&0x3ffffff)
def cbz(pc,target,register=0):
    distance=target-pc
    if distance%4 or not -(1<<20)<=distance<(1<<20):raise ValueError('cbz range')
    return 0xb4000000|(((distance//4)&0x7ffff)<<5)|register
def adrp(pc,target,register):
    value=(target//4096)-(pc//4096)
    if not -(1<<20)<=value<(1<<20):raise ValueError('adrp range')
    return 0x90000000|((value&3)<<29)|(((value>>2)&0x7ffff)<<5)|register

def code():
    # Raw opcodes with labels. See instrumentation.s for the corresponding asm.
    instructions=[];labels={};fixups=[]
    def emit(word):instructions.append(word)
    def label(name):labels[name]=CAVE+len(instructions)*4
    def b(name,link=False):fixups.append((len(instructions),'b',name,link));emit(0)
    def z(name,reg=0):fixups.append((len(instructions),'z',name,reg));emit(0)
    label('on');emit(0x52800020);emit(0xaa1f03e1);b('signal')
    label('off');emit(0x52800040);emit(0xaa1f03e1);b('signal')
    label('send');z('activity');emit(0xaa0003f5);emit(branch(CAVE+len(instructions)*4,0x3aaa4))
    label('activity');emit(0x52800060);emit(0xaa1303e1);b('signal',True)
    emit(0xaa1f03e0);emit(branch(CAVE+len(instructions)*4,0x3aab4))
    label('signal')
    for word in (0xa9bd7bfd,0x910003fd,0xb90013e0,0xb90017ff,0xf9000fe1,
                 0x52800000|((COMMAND&0xffff)<<5),0x72a00000|((COMMAND>>16)<<5),0x910043e1):emit(word)
    emit(adrp(CAVE+len(instructions)*4,ENVIRONMENT,8))
    emit(0xf9400000|(((ENVIRONMENT&4095)//8)<<10)|(8<<5)|8)
    z('return',8);emit(0xd63f0100)
    label('return');emit(0xa8c37bfd);emit(0xd65f03c0)
    for i,kind,target,arg in fixups:
        pc=CAVE+i*4
        instructions[i]=branch(pc,labels[target],arg) if kind=='b' else cbz(pc,labels[target],arg)
    return b''.join(struct.pack('<I',word) for word in instructions),labels
STUB,LABELS=code()

def patch_core(data):
    if hashlib.sha256(data).hexdigest()!=SHA256:raise ValueError('Unknown DS core; exact R7 melonDS DS 1.3.1 required')
    if any(data[CAVE:CAVE+len(STUB)]):raise ValueError('Executable padding is occupied')
    expected={ON:branch(ON,0x3ab5c),OFF:branch(OFF,0x3ab5c),SEND:0x340000c0}
    result=bytearray(data)
    for offset,before in expected.items():
        if struct.unpack_from('<I',data,offset)[0]!=before:raise ValueError('Instruction guard failed')
        target=LABELS['on' if offset==ON else 'off' if offset==OFF else 'send']
        struct.pack_into('<I',result,offset,branch(offset,target))
    result[CAVE:CAVE+len(STUB)]=STUB
    allowed=set(range(CAVE,CAVE+len(STUB)))
    for offset in expected:allowed.update(range(offset,offset+4))
    if len(data)!=len(result) or any(a!=b and i not in allowed for i,(a,b) in enumerate(zip(data,result))):
        raise ValueError('Preservation guard failed')
    return bytes(result)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('source',type=pathlib.Path);p.add_argument('output',type=pathlib.Path)
    a=p.parse_args();report=pathlib.Path(str(a.output)+'.audit.json')
    if a.output.exists() or report.exists() or a.source.resolve()==a.output.resolve():raise ValueError('Choose fresh output paths')
    original=a.source.read_bytes();patched=patch_core(original);a.output.write_bytes(patched)
    audit={'original_sha256':SHA256,'instrumented_sha256':hashlib.sha256(patched).hexdigest(),
           'modified_instructions':[hex(ON),hex(OFF),hex(SEND)],'stub_offset':hex(CAVE),'stub_bytes':len(STUB),
           'all_other_bytes_preserved':True,'original_input_unchanged':a.source.read_bytes()==original,
           'new_segments_or_imports':False,'game_or_firmware_inputs_used':False,'physical_validation':False}
    report.write_text(json.dumps(audit,indent=2));print(json.dumps(audit))
if __name__=='__main__':main()
