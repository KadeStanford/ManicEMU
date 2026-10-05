"""Actual old/new ARM64 reschedule execution with controlled scheduler queues.

Reproduces the old unsolicited cross-core reschedule. Tests slice boundaries,
selection scope, pending-flag consumption/reentrant request, and full GP/SIMD ABI.
Existing ready-queue/context-switch helpers are stubs, not full game execution.
"""
import hashlib,json,pathlib,struct,sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
sys.path.insert(0,r'C:\Users\Stanj\Documents\Codex\2026-10-03\task-3\analysis-deps')
from repair_core_reschedule import patch_core,STUB,CAVE,LOOP,TAIL,LABELS
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn.arm64_const import *
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_ARM
root=pathlib.Path(__file__).resolve().parents[3];baseline=(root/'azahar-output/azahar-r5-fb2-uninitialized-framebuffer-corrective.dylib').read_bytes()
combined='--present' in sys.argv
if combined:
    from make_fb2_present_control import make_control
    baseline=make_control(baseline)
fixed=patch_core(baseline)
decoded=list(Cs(CS_ARCH_ARM64,CS_MODE_ARM).disasm(STUB,CAVE));assert len(decoded)*4==len(STUB)
system,kernel,table,vector,stack=0x2000000,0x2001000,0x2002000,0x2003000,0x201e000
cpus=[0x2004000+0x100*i for i in range(4)];managers=[0x2005000+0x100*i for i in range(4)]
def run(binary,entry,core=0,pending=True,current=True,ready=True,reentrant=False,null_running=False):
    uc=Uc(UC_ARCH_ARM64,UC_MODE_ARM);uc.mem_map(0,0xd60000);uc.mem_write(0,binary[:0xd60000]);uc.mem_map(0x2000000,0x20000)
    def qwrite(addr,value):uc.mem_write(addr,struct.pack('<Q',value))
    qwrite(system+0x300,kernel);qwrite(kernel+0xf0,table);qwrite(system+0xc8,vector);qwrite(system+0xd0,vector+64);qwrite(system+0xe0,0 if null_running else cpus[core]);uc.mem_write(system+0xf0,bytes([int(pending)]))
    for i in range(4):
        qwrite(vector+i*16,cpus[i]);qwrite(table+i*8,managers[i]);uc.mem_write(cpus[i]+0x1c,struct.pack('<I',i));qwrite(managers[i]+0x18,0x30000000+i if current else 0)
    regs={globals()['UC_ARM64_REG_X%d'%i]:0x100000+i for i in range(31)}
    regs[UC_ARM64_REG_X19]=system;regs[UC_ARM64_REG_X23]=vector;regs[UC_ARM64_REG_X29]=stack+0xd0
    for r,v in regs.items():uc.reg_write(r,v)
    simd={globals()['UC_ARM64_REG_Q%d'%i]:(i+1)*0x01010101010101010101010101010101 for i in range(32)}
    for r,v in simd.items():uc.reg_write(r,v)
    uc.reg_write(UC_ARM64_REG_SP,stack);uc.reg_write(UC_ARM64_REG_NZCV,0xa0000000)
    selects=[];switches=[];boundary=LOOP+4 if entry==LOOP else 0x5265e8
    def clobber(u):
        # Permitted C++ caller clobbers; preserve callee-saved GP/low SIMD halves.
        for i in range(19):u.reg_write(globals()['UC_ARM64_REG_X%d'%i],0xcccc0000+i)
        for i in list(range(8))+list(range(16,32)):u.reg_write(globals()['UC_ARM64_REG_Q%d'%i],0xcccc)
        u.reg_write(UC_ARM64_REG_NZCV,0x60000000)
    def hook(u,pc,size,data):
        if pc==boundary:u.emu_stop()
        elif pc==0x66114c:
            manager=u.reg_read(UC_ARM64_REG_X0);index=managers.index(manager);selects.append(index);lr=u.reg_read(UC_ARM64_REG_X30);clobber(u);u.reg_write(UC_ARM64_REG_X0,0x40000000+index if ready else 0);u.reg_write(UC_ARM64_REG_PC,lr)
        elif pc==0x660c6c:
            index=managers.index(u.reg_read(UC_ARM64_REG_X0));switches.append((index,u.reg_read(UC_ARM64_REG_X1)));lr=u.reg_read(UC_ARM64_REG_X30)
            if reentrant:uc.mem_write(system+0xf0,b'\1')
            clobber(u);u.reg_write(UC_ARM64_REG_PC,lr)
    uc.hook_add(UC_HOOK_CODE,hook);uc.emu_start(entry,boundary+4,count=4000);assert uc.reg_read(UC_ARM64_REG_PC)==boundary
    if binary is fixed:
        expected_regs=dict(regs)
        if entry==LOOP:expected_regs[UC_ARM64_REG_X23]+=16
        assert all(uc.reg_read(r)==v for r,v in expected_regs.items())
        assert all(uc.reg_read(r)==v for r,v in simd.items())
        assert uc.reg_read(UC_ARM64_REG_SP)==stack and uc.reg_read(UC_ARM64_REG_NZCV)==0xa0000000
    expected_selects=[] if not pending or null_running else [core]
    if binary is fixed:
        assert selects==expected_selects
        assert len(switches)==int(bool(expected_selects) and (current or ready))
        assert uc.mem_read(system+0xf0,1)==bytes([int(reentrant and bool(switches))])
    return selects,switches
count=0
for entry in (LOOP,TAIL):
 for core in range(4):
  for pending in (False,True):
   for current in (False,True):
    for ready in (False,True):
     for reentrant in (False,True):
      run(fixed,entry,core,pending,current,ready,reentrant);count+=1
for entry in (LOOP,TAIL):run(fixed,entry,null_running=True);count+=1
# Native negative control demonstrates old cross-core scheduling, not a mock bug.
old_selects,old_switches=run(baseline,TAIL,core=2);new_selects,new_switches=run(fixed,TAIL,core=2);count+=2
assert old_selects==[0,1,2,3] and new_selects==[2] and len(old_switches)==4 and len(new_switches)==1
# The loop fix consumes the request at the per-core boundary before advancing.
assert run(fixed,LOOP,core=1)[0]==[1];count+=1
for invalid in (fixed,baseline[:0x10000]+bytes([baseline[0x10000]^1])+baseline[0x10001:]):
 try:patch_core(invalid)
 except ValueError:pass
 else:raise AssertionError('Unknown/already patched input accepted')
report={'native_ARM64_executions':count,'old_unsolicited_all_core_reschedule_reproduced':True,
 'new_selects_only_executing_core':[2],'old_selects_all_cores':old_selects,
 'per_core_slice_boundary_request_consumed':True,'both_single_core_tail_and_equal_time_loop_sites_tested':True,
 'no_request_or_null_running_core_skips_scheduler':True,'null_current_and_ready_combinations_tested':True,
 'reentrant_pending_request_retained':True,'all31_GP_and32_SIMD_registers_SP_NZCV_preserved':True,
 'ready_queue_and_context_switch_helpers_stubbed':True,'guest_game_or_physical_Nookling_success_verified':False,
 'output_sha256':hashlib.sha256(fixed).hexdigest(),'stub_bytes':len(STUB),'instruction_count':len(decoded)}
with (root/('azahar-output/combined-core-reschedule-regression.json' if combined else 'azahar-output/core-reschedule-regression.json')).open('x') as f:json.dump(report,f,indent=2)
print(json.dumps(report,indent=2))
