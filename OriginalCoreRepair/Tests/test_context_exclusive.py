"""Actual ARM64 kernel switch prefix and LDREX/preemption/STREX regression.

Guest MemoryRead/Write are controlled shared-memory fixtures. Context Save/Load,
kernel switch prefix, DynCom/JIT monitor clear and exclusive handlers execute.
"""
import argparse,hashlib,json,os,pathlib,struct,sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
if os.environ.get('AZAHAR_ANALYSIS_DEPS'):sys.path.insert(0,os.environ['AZAHAR_ANALYSIS_DEPS'])
from repair_context_exclusive import patch_core,STUB,CAVE,METHOD
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn.arm64_const import *
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_ARM
root=pathlib.Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=pathlib.Path,default=root/'azahar-output/context-exclusive-regression.json')
args=p.parse_args()
if args.output.exists():raise ValueError('Exclusive new report required')
state,inst,stack,mem,ctx,cpu,manager,kernel,vt,jit,jitstate=range(0x2000000,0x20b0000,0x10000)
stack+=0x8000;stop=0xd4cfc0
decoded=list(Cs(CS_ARCH_ARM64,CS_MODE_ARM).disasm(STUB[:40],CAVE))+list(Cs(CS_ARCH_ARM64,CS_MODE_ARM).disasm(STUB[64:],METHOD))
assert len(decoded)==15
handler_exec=0;switch_exec=0;context_exec=0;cases=[]

def machine(binary,jit_mode=False):
    u=Uc(UC_ARCH_ARM64,UC_MODE_ARM);u.mem_map(0,0xd60000);u.mem_write(0,binary[:0xd60000]);u.mem_map(state,0xc0000)
    def q(addr,value):u.mem_write(addr,struct.pack('<Q',value))
    def w(addr,value):u.mem_write(addr,struct.pack('<I',value))
    q(cpu,vt);q(cpu+0x28,state);q(cpu+0x58,jit);q(jit+8,jitstate);q(vt+0x30,0x9470d4 if jit_mode else 0x4ffddc)
    q(manager,kernel);q(manager+0x10,cpu);q(kernel+0x68,0xabc000);q(0xd50780,mem+0x500);q(mem+0x500,0xdeadbeef)
    q(state+8,mem);q(mem,mem+0x100);w(state+0x320,0x10);w(state+0x4c,0x07000200)
    u.mem_write(inst,struct.pack('<7I',0,14,0,0,2,1,3));w(state+0x14,0x07001000);w(state+0x18,1)
    q(stack+0x28,state+0x34c);memory={0x07001000:0};writes=[]
    def hook(uc,pc,size,data):
        if pc==0x91c874:
            uc.reg_write(UC_ARM64_REG_W0,memory[uc.reg_read(UC_ARM64_REG_W2)])
        elif pc==0x91dabc:
            addr=uc.reg_read(UC_ARM64_REG_W2);value=uc.reg_read(UC_ARM64_REG_W3);writes.append((addr,value));memory[addr]=value
        else:return
        uc.reg_write(UC_ARM64_REG_PC,uc.reg_read(UC_ARM64_REG_X30))
    u.hook_add(UC_HOOK_CODE,hook)
    return u,q,w,memory,writes

def handler(u,entry):
    global handler_exec
    for r,v in ((UC_ARM64_REG_X20,state),(UC_ARM64_REG_X28,state+0x10),(UC_ARM64_REG_X26,inst),(UC_ARM64_REG_X23,state+0x34c),(UC_ARM64_REG_SP,stack)):
        u.reg_write(r,v)
    u.emu_start(entry,0x509cc0,count=1500);assert u.reg_read(UC_ARM64_REG_PC)==0x509cc0;handler_exec+=1

def context(u,entry):
    global context_exec
    u.reg_write(UC_ARM64_REG_X0,cpu);u.reg_write(UC_ARM64_REG_X1,ctx);u.reg_write(UC_ARM64_REG_X30,stop);u.reg_write(UC_ARM64_REG_SP,stack+0x1000)
    u.emu_start(entry,stop,count=500);assert u.reg_read(UC_ARM64_REG_PC)==stop;context_exec+=1

def switch(u,previous,newthread,flags=0xa0000000):
    global switch_exec
    u.mem_write(manager+0x18,struct.pack('<Q',previous))
    for i in range(31):u.reg_write(globals()['UC_ARM64_REG_X%d'%i],0x12340000+i)
    for i in range(32):u.reg_write(globals()['UC_ARM64_REG_Q%d'%i],(i+1)*0x01010101010101010101010101010101)
    u.reg_write(UC_ARM64_REG_X0,manager);u.reg_write(UC_ARM64_REG_X1,newthread);u.reg_write(UC_ARM64_REG_SP,stack+0x2000);u.reg_write(UC_ARM64_REG_NZCV,flags)
    u.emu_start(0x660c6c,0x660cb0,count=300);assert u.reg_read(UC_ARM64_REG_PC)==0x660cb0;switch_exec+=1
    return tuple(u.reg_read(globals()['UC_ARM64_REG_X%d'%i]) for i in range(31)),tuple(u.reg_read(globals()['UC_ARM64_REG_Q%d'%i]) for i in range(32)),u.reg_read(UC_ARM64_REG_SP),u.reg_read(UC_ARM64_REG_NZCV)

variants={}
for name,filename in [('FB2','azahar-r5-fb2-uninitialized-framebuffer-corrective.dylib'),('FB3','azahar-fb2-per-core-reschedule-present-corrective.dylib')]:
    baseline=(root/'azahar-output'/filename).read_bytes();fixed=patch_core(baseline);variants[name]=hashlib.sha256(fixed).hexdigest()
    # Both monitor implementations and null/same/other-thread incoming branches.
    for jit_mode in (False,True):
     for active in (0,1):
      for previous,newthread in ((0,0),(0,0x333000),(0x222000,0),(0x222000,0x222000),(0x222000,0x333000)):
       for flags in (0,0xf0000000):
        snapshots=[]
        for binary,corrected in ((baseline,False),(fixed,True)):
            u,q,w,memory,writes=machine(binary,jit_mode);w(state+0x3a8,0x07001000);u.mem_write(state+0x3ac,bytes([active]));w(jitstate+0x2e0,active)
            snapshots.append(switch(u,previous,newthread,flags))
            monitor=struct.unpack('<I',u.mem_read(jitstate+0x2e0,4))[0] if jit_mode else u.mem_read(state+0x3ac,1)[0]
            assert monitor==(0 if corrected else active)
            if corrected and not jit_mode:assert u.mem_read(state+0x3a8,4)==b'\xff'*4
        assert snapshots[0]==snapshots[1]
    # Native guest atomic negative control: stale reservation loses a competing write.
    for preempt in (False,True):
     for binary,corrected in ((baseline,False),(fixed,True)):
        u,q,w,memory,writes=machine(binary);handler(u,0x505368);context(u,0x4ffca0)
        if preempt:
            switch(u,0x222000,0x333000);memory[0x07001000]=2
            switch(u,0x333000,0x222000);context(u,0x4ffd38)
        handler(u,0x504c78)
        result=struct.unpack('<I',u.mem_read(state+0x1c,4))[0]
        expect_fail=preempt and corrected
        assert result==int(expect_fail) and memory[0x07001000]==(2 if expect_fail else 1)
        if expect_fail:
            handler(u,0x505368);w(state+0x18,3);handler(u,0x504c78)
            assert struct.unpack('<I',u.mem_read(state+0x1c,4))[0]==0 and memory[0x07001000]==3
        cases.append({'input':name,'corrected':corrected,'preempted':preempt,'first_STREX_status':result,'competing_write_preserved':expect_fail})
    for bad in (fixed,baseline[:0x10000]+bytes([baseline[0x10000]^1])+baseline[0x10001:]):
        try:patch_core(bad)
        except ValueError:pass
        else:raise AssertionError('Unknown/already patched input accepted')
report={'actual_kernel_switch_prefix_executions':switch_exec,'native_LDREX_STREX_executions':handler_exec,
 'native_context_Save_Load_executions':context_exec,'all_GP_SIMD_SP_NZCV_equal_to_unpatched_prefix':True,
 'interpreter_and_existing_JIT_monitor_clear_tested':True,'old_preempted_store_spuriously_succeeds_and_loses_competing_write':True,
 'fixed_preempted_store_fails_and_retry_makes_progress':True,'uninterrupted_atomics_preserved':True,
 'FB2_and_FB3_negative_controls_and_fixes':cases,'output_sha256_by_input':variants,
 'controlled_shared_memory_helpers':True,'physical_Isabelle_freeze_resolution_verified':False}
with args.output.open('x') as f:json.dump(report,f,indent=2)
print(json.dumps(report,indent=2))
