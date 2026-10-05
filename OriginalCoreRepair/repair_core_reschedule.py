"""Bounded original-core backport of upstream per-executing-core reschedule.

Upstream #2370: reschedule after each CPU slice, only its ThreadManager.
The preserved binary instead loops all managers once at RunLoop's tail.
No guest memory, options, core ABI, plugin or frontend changes.
"""
import argparse,hashlib,json,pathlib,struct
INPUTS={
 '3995bab1659c74979fa81226e4961fc7634d30a324ba9b97eb0eb50b5dc892e4':'FB2',
 '306c53df0b2e0f172445629d20eba8c8cd7c4e3f160a596f9df37963e498228c':'FB2-present',
}
CAVE=0xd4c600;LOOP=0x526020;TAIL=0x52658c
def branch(pc,target,link=False):
    delta=target-pc
    if delta%4 or not -(1<<27)<=delta<(1<<27):raise ValueError('Branch range')
    return (0x94000000 if link else 0x14000000)|((delta//4)&0x3ffffff)
def pair(load,quad,a,b,offset):
    scale=16 if quad else 8
    assert offset%scale==0 and 0<=offset//scale<64
    return ((0xad400000 if load else 0xad000000) if quad else (0xa9400000 if load else 0xa9000000))|((offset//scale)<<15)|(b<<10)|(31<<5)|a
def stub():
    code=[];labels={};fixups=[]
    def emit(word):code.append(word)
    def mark(name):labels[name]=CAVE+4*len(code)
    def jump(name,kind='b',reg=0):fixups.append((len(code),name,kind,reg));emit(0)
    # Two wrappers preserve the original LR/FP and replace exact original sites.
    mark('loop');emit(0xa9bf7bfd);jump('helper','bl');emit(0xa8c17bfd);emit(0x910042f7);emit(branch(CAVE+4*len(code),LOOP+4))
    mark('tail');emit(0xa9bf7bfd);jump('helper','bl');emit(0xa8c17bfd);emit(branch(CAVE+4*len(code),0x5265e8))
    mark('helper');emit(0xa9bf27e8);emit(0x3943c268);jump('fast_return','cbz32',8);emit(0xa8c127e8)
    # Preserve ALL GP/SIMD registers plus flags across the existing C++ helpers.
    emit(0xd10c43ff) # sub sp,sp,#0x310
    for a in range(0,32,2):emit(pair(False,False,a,a+1,a*8))
    for a in range(0,32,2):emit(pair(False,True,a,a+1,0x100+a*16))
    emit(0xd53b4208);emit(0xf90183e8) # mrs x8,nzcv; str x8,[sp,#0x300]
    emit(0x3903c27f) # clear current-core pending before rescheduling
    emit(0xf9407268);jump('restore','cbz64',8) # running_core at System+0xe0
    emit(0xb9401d09);emit(0xf9418268);jump('restore','cbz64',8)
    emit(0xf9407908);emit(0xf8697914);jump('restore','cbz64',20)
    emit(0xf9400e95);emit(0xaa1403e0);emit(branch(CAVE+4*len(code),0x66114c,True))
    emit(0xaa0002a8);jump('restore','cbz64',8)
    emit(0xaa0003e1);emit(0xaa1403e0);emit(branch(CAVE+4*len(code),0x660c6c,True))
    mark('restore');emit(0xf94183e8);emit(0xd51b4208)
    for a in range(0,32,2):emit(pair(True,True,a,a+1,0x100+a*16))
    for a in range(0,32,2):emit(pair(True,False,a,a+1,a*8))
    emit(0x910c43ff);emit(0xd65f03c0)
    mark('fast_return');emit(0xa8c127e8);emit(0xd65f03c0)
    for i,name,kind,reg in fixups:
        pc=CAVE+4*i;target=labels[name]
        if kind in ('b','bl'):code[i]=branch(pc,target,kind=='bl')
        else:code[i]=(0x34000000 if kind=='cbz32' else 0xb4000000)|(((target-pc)//4&0x7ffff)<<5)|reg
    return struct.pack('<%dI'%len(code),*code),labels
STUB,LABELS=stub()
def patch_core(data):
    digest=hashlib.sha256(data).hexdigest()
    if digest not in INPUTS:raise ValueError('Requires exact reviewed FB2 variant')
    if data[LOOP:LOOP+4]!=struct.pack('<I',0x910042f7) or data[TAIL:TAIL+4]!=struct.pack('<I',0x3943c268):raise ValueError('RunLoop site guard failed')
    if any(data[CAVE:CAVE+len(STUB)]):raise ValueError('Executable padding occupied')
    out=bytearray(data);out[LOOP:LOOP+4]=struct.pack('<I',branch(LOOP,LABELS['loop']));out[TAIL:TAIL+4]=struct.pack('<I',branch(TAIL,LABELS['tail']));out[CAVE:CAVE+len(STUB)]=STUB
    allowed=set(range(LOOP,LOOP+4))|set(range(TAIL,TAIL+4))|set(range(CAVE,CAVE+len(STUB)))
    assert len(out)==len(data) and all(a==b or i in allowed for i,(a,b) in enumerate(zip(data,out)))
    return bytes(out)
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--input',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
    report=pathlib.Path(str(a.output)+'.verification.json')
    if a.output.exists() or report.exists() or a.input.resolve()==a.output.resolve():raise ValueError('New output paths required')
    data=a.input.read_bytes();out=patch_core(data)
    with a.output.open('xb') as f:f.write(out)
    assert a.input.read_bytes()==data
    r={'input_sha256':hashlib.sha256(data).hexdigest(),'output_sha256':hashlib.sha256(out).hexdigest(),
       'upstream':'https://github.com/azahar-emu/azahar/pull/2370','kind':'Per-executing-core reschedule stability backport',
       'sites':[hex(LOOP),hex(TAIL)],'padding':hex(CAVE),'padding_bytes':len(STUB),
       'no_guest_settings_plugin_or_frontend_changes':True,'phone_Nookling_freeze_fixed_verified':False,
       'phone_FPS_improvement_verified':False,'signing':'Re-sign modified framework and app'}
    with report.open('x') as f:json.dump(r,f,indent=2)
    print(json.dumps(r,indent=2))
if __name__=='__main__':main()
