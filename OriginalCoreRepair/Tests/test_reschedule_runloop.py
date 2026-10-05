"""Execute actual four-core RunLoop slice/idle/single-step and scheduling flow.

CPU execution, KernelSetRunningCPU, ready queues and context switching are ABI
fixtures. Actual timer budget calculations, loop order and pending checks execute.
"""
import hashlib,json,pathlib,struct,sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
sys.path.insert(0,r'C:\Users\Stanj\Documents\Codex\2026-10-03\task-3\analysis-deps')
from repair_core_reschedule import patch_core
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn.arm64_const import *
root=pathlib.Path(__file__).resolve().parents[3]
baseline=(root/'azahar-output/azahar-r5-fb2-uninitialized-framebuffer-corrective.dylib').read_bytes();combined='--present' in sys.argv
if combined:
    from make_fb2_present_control import make_control
    baseline=make_control(baseline)
fixed=patch_core(baseline)
system,kernel,table,vector,stack=0x2000000,0x2001000,0x2002000,0x2003000,0x201e000
cpus=[0x2004000+i*0x100 for i in range(4)];managers=[0x2005000+i*0x100 for i in range(4)]
timers=[0x2006000+i*0x200 for i in range(4)];vt=0x2008000;runfn,stepfn,idlefn=0xd4cd00,0xd4cd04,0xd4cd08

def execute(binary,tight,requests,idles):
    u=Uc(UC_ARCH_ARM64,UC_MODE_ARM);u.mem_map(0,0xd60000);u.mem_write(0,binary[:0xd60000]);u.mem_map(system,0x20000)
    def q(addr,v):u.mem_write(addr,struct.pack('<Q',v))
    q(system+0x300,kernel);q(kernel+0xf0,table);q(system+0xc8,vector);q(system+0xd0,vector+64)
    q(vt+0x10,runfn);q(vt+0x18,stepfn);q(vt+0xb0,idlefn)
    for i in range(4):
        q(vector+i*16,cpus[i]);q(table+i*8,managers[i]);q(cpus[i],vt);q(cpus[i]+8,timers[i]);u.mem_write(cpus[i]+0x1c,struct.pack('<I',i))
        q(managers[i]+0x18,0 if idles>>i&1 else 0x30000000+i)
        u.mem_write(timers[i]+0xe8,b'\0')
    for reg,val in ((UC_ARM64_REG_X19,system),(UC_ARM64_REG_X20,tight),(UC_ARM64_REG_X22,100),(UC_ARM64_REG_X23,vector),(UC_ARM64_REG_X24,vector+64),(UC_ARM64_REG_SP,stack)):
        u.reg_write(reg,val)
    trace=[]
    def hook(uc,pc,size,data):
        if pc==0x5265e8:uc.emu_stop();return
        if pc==0x60b758:
            q(kernel+0x58,uc.reg_read(UC_ARM64_REG_X1))
        elif pc in (runfn,stepfn,idlefn):
            index=cpus.index(uc.reg_read(UC_ARM64_REG_X0));trace.append(('idle' if pc==idlefn else 'run' if pc==runfn else 'step',index))
            if pc!=idlefn:
                timer=timers[index];budget=struct.unpack('<Q',uc.mem_read(timer+0xf8,8))[0]
                assert budget==100
                q(timer+0xf8,0) # consume this slice's down-counter
                if requests>>index&1:uc.mem_write(system+0xf0,b'\1')
        elif pc==0x66114c:
            index=managers.index(uc.reg_read(UC_ARM64_REG_X0));trace.append(('ready',index));uc.reg_write(UC_ARM64_REG_X0,0x40000000+index)
        elif pc==0x660c6c:
            index=managers.index(uc.reg_read(UC_ARM64_REG_X0));trace.append(('switch',index))
        else:return
        uc.reg_write(UC_ARM64_REG_PC,uc.reg_read(UC_ARM64_REG_X30))
    u.hook_add(UC_HOOK_CODE,hook);u.emu_start(0x526000,0x5265e8+4,count=10000)
    assert u.reg_read(UC_ARM64_REG_PC)==0x5265e8
    assert [i for event,i in trace if event in ('run','step','idle')]==list(range(4))
    assert all(struct.unpack('<Q',u.mem_read(t+0xf0,8))[0]==100 and struct.unpack('<Q',u.mem_read(t+0xf8,8))[0]==0 for t in timers)
    assert all(struct.unpack('<Q',u.mem_read(t+0x108,8))[0]==(100 if idles>>i&1 else 0) for i,t in enumerate(timers))
    expected=[]
    for i in range(4):
        expected.append(('idle' if idles>>i&1 else 'run' if tight else 'step',i))
        if idles>>i&1 or requests>>i&1:expected.extend([('ready',i),('switch',i)])
    if binary is fixed:assert trace==expected
    else:
        actual_requests=idles | (requests & ~idles)
        assert trace[:4]==[('idle' if idles>>i&1 else 'run' if tight else 'step',i) for i in range(4)]
        assert trace[4:]==([item for i in range(4) for item in [('ready',i),('switch',i)]] if actual_requests else [])
    assert u.mem_read(system+0xf0,1)==b'\0'
    return trace
count=0
for tight in (0,1):
 for requests in (0,1,2,4,8,15):
  for idles in (0,1,8,15):
   for binary in (baseline,fixed):execute(binary,tight,requests,idles);count+=1
old=execute(baseline,1,2,0);new=execute(fixed,1,2,0);count+=2
report={'native_four_core_RunLoop_executions':count,'actual_timer_budget_and_idle_accounting_preserved':True,
 'Run_Step_idle_and_each_requesting_core_tested':True,'old_one_core_request_forces_four_context_switches':old,
 'new_one_core_request_switches_only_requester_before_next_slice':new,
 'CPU_and_kernel_scheduler_helpers_controlled':True,'game_or_physical_Nookling_success_verified':False,
 'output_sha256':hashlib.sha256(fixed).hexdigest()}
with (root/('azahar-output/combined-runloop-reschedule-regression.json' if combined else 'azahar-output/runloop-reschedule-regression.json')).open('x') as f:json.dump(report,f,indent=2)
print(json.dumps(report,indent=2))
