"""Backport explicit thread-switch monitor clearing; implement DynCom's no-op.

Official upstream2376 thread.cpp correction, without the interpreter replacement.
Exact preserved routines need only X0/X8/X9/LR protection and do not change NZCV.
"""
import argparse,hashlib,json,pathlib,struct
from repair_core_reschedule import branch
INPUTS={
 '3995bab1659c74979fa81226e4961fc7634d30a324ba9b97eb0eb50b5dc892e4':'FB2',
 '15d9b1e984155a72d1f1ef5f2dadc014b3664b5c4d74b71ea8603503f491009a':'FB3',
}
SWITCH=0x660ca8;CLEAR=0x4ffddc;CAVE=0xd4c800;METHOD=CAVE+0x40
words=[
 0xa9bf23e0, # stp x0,x8,[sp,#-16]!
 0xa9bf7be9, # stp x9,x30,[sp,#-16]!
 0xf9400800, # ldr x0,[x0,#16] ThreadManager::cpu
 0xf9400008, # ldr x8,[x0] CPU vtable
 0xf9401908, # ldr x8,[x8,#48] ClearExclusiveState
 0xd63f0100, # blr x8
 0xa8c17be9, # ldp x9,x30,[sp],#16
 0xa8c123e0, # ldp x0,x8,[sp],#16
 0xf9400008, # original ldr x8,[x0]
 branch(CAVE+36,SWITCH+4),
]
STUB=struct.pack('<10I',*words)+bytes(0x40-40)+struct.pack('<5I',
 0xf9401408, # ldr x8,[x0,#40] ARM_DynCom::state
 0x12800009, # mov w9,#-1
 0xb903a909, # str w9,[x8,#0x3a8] exclusive_tag
 0x390eb11f, # strb wzr,[x8,#0x3ac] exclusive_state
 0xd65f03c0)
def patch_core(data):
    if hashlib.sha256(data).hexdigest() not in INPUTS:raise ValueError('Exact reviewed FB2 or FB3 required')
    guards={SWITCH:0xf9400008,CLEAR:0xd65f03c0,0x9470d4:0xf9402c00,0x223e54:0xf9400408,0x223e58:0xb902e11f}
    for pos,word in guards.items():
        if data[pos:pos+4]!=struct.pack('<I',word):raise ValueError('Exact clear/switch ABI guard failed')
    if any(data[CAVE:CAVE+len(STUB)]):raise ValueError('Padding occupied')
    out=bytearray(data);out[SWITCH:SWITCH+4]=struct.pack('<I',branch(SWITCH,CAVE));out[CLEAR:CLEAR+4]=struct.pack('<I',branch(CLEAR,METHOD));out[CAVE:CAVE+len(STUB)]=STUB
    return bytes(out)
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--input',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
    report=pathlib.Path(str(a.output)+'.verification.json')
    if a.output.exists() or report.exists() or a.input.resolve()==a.output.resolve():raise ValueError('Exclusive new output required')
    original=a.input.read_bytes();out=patch_core(original)
    with a.output.open('xb') as f:f.write(out)
    assert a.input.read_bytes()==original
    r={'input_sha256':hashlib.sha256(original).hexdigest(),'output_sha256':hashlib.sha256(out).hexdigest(),
       'upstream':'https://github.com/azahar-emu/azahar/pull/2376','upstream_scope':'Only thread.cpp monitor-clear correction, no interpreter replacement',
       'switch_hook':hex(SWITCH),'DynCom_clear_hook':hex(CLEAR),'padding':hex(CAVE),'padding_bytes':len(STUB),
       'private_inputs_used':False,'phone_Isabelle_freeze_resolution_verified':False,'signing':'Framework and app require resigning'}
    with report.open('x') as f:json.dump(r,f,indent=2)
    print(json.dumps(r,indent=2))
if __name__=='__main__':main()
