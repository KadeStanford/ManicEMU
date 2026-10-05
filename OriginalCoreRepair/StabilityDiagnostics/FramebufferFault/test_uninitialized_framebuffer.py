"""FB2 actual ARM64 tests, including preserved R5 deferred clear recording.

No game/phone/GPU. Host image allocation, nonzero cache acquisition and
EndRendering helpers are controlled. The actual clear-recording instructions
run and their image/RGBA command payloads are checked.
"""
import argparse,hashlib,json,pathlib,struct,sys
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--r5',type=pathlib.Path,required=True)
parser.add_argument('--r6',type=pathlib.Path,required=True)
parser.add_argument('--deps',type=pathlib.Path,required=True)
parser.add_argument('--output',type=pathlib.Path,required=True);args=parser.parse_args()
sys.path.insert(0,str(args.deps))
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn.arm64_const import *
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_ARM
import instrument_framebuffer_fault as fault
import repair_uninitialized_framebuffer as repair

def execute(binary,screen_offset,existing,fmt,stride,mode,sequence=None):
    cpu=Uc(UC_ARCH_ARM64,UC_MODE_ARM);cpu.mem_map(0,0xd60000);cpu.mem_write(0,binary[:0xd60000])
    for base,size in ((0xe00000,0x1000),(0x1000000,0x10000),(0x1100000,0x10000),
                      (0x1200000,0x1000),(0x1400000,0x4000),(0x1600000,0x10000),(0x1700000,0x1000)):
        cpu.mem_map(base,size)
    renderer,fb,sp,gpu,queue=0x1100000,0x1200000,0x1008000,0x1400000,0x1600000
    screen=renderer+screen_offset;width,height=240,(320 if screen_offset==0x3dd8 else 400)
    image,owned_view,display_view=0xfeed1000+screen_offset,0x71000100,0x71000200
    cpu.mem_write(0xd50780,struct.pack('<Q',0x1700800));cpu.mem_write(0x1700800,struct.pack('<Q',0x12345678))
    cpu.mem_write(renderer+0xc0,struct.pack('<Q',gpu));cpu.mem_write(renderer+0xa28,struct.pack('<Q',queue))
    cpu.mem_write(renderer+0x2150+0x14a8,struct.pack('<Q',0x1700000))
    cpu.mem_write(0x1700000+0xc,struct.pack('<2I',width,height));cpu.mem_write(0x1700000+0x1c,struct.pack('<I',1))
    cpu.mem_write(screen+0x10,struct.pack('<Q',image if existing else 0))
    cpu.mem_write(screen+0x18,struct.pack('<Q',owned_view if existing else 0))
    cpu.mem_write(screen+0x38,struct.pack('<Q',0xbad000))
    registers=(UC_ARM64_REG_X18,UC_ARM64_REG_X19,UC_ARM64_REG_X20,UC_ARM64_REG_X21,
       UC_ARM64_REG_X22,UC_ARM64_REG_X23,UC_ARM64_REG_X24,UC_ARM64_REG_X25,
       UC_ARM64_REG_X26,UC_ARM64_REG_X27,UC_ARM64_REG_X28,UC_ARM64_REG_X29,
       UC_ARM64_REG_D8,UC_ARM64_REG_D9,UC_ARM64_REG_D10,UC_ARM64_REG_D11,
       UC_ARM64_REG_D12,UC_ARM64_REG_D13,UC_ARM64_REG_D14,UC_ARM64_REG_D15)
    preserved={reg:0x800100+index for index,reg in enumerate(registers)}
    result={'calls':[],'clear_commands':0,'allocation_calls':0,'render_end_calls':0}
    current={}
    def hook(machine,pc,size,data):
        current['instructions']+=1
        if pc in (0xe00000,0xa80088,0xa800d0,fault.ZERO_ADDRESS_TRAP,fault.INVALID_SURFACE_TRAP) or (pc==fault.TRAP and binary[pc:pc+4]==fault.words(0xd4200020)):
            current['pc']=pc;machine.emu_stop()
        elif pc==0x9fb388:
            expected_config=gpu+(0x1500 if screen_offset==0x3dd8 else 0x1400)
            assert tuple(machine.reg_read(r) for r in (UC_ARM64_REG_X0,UC_ARM64_REG_X1,UC_ARM64_REG_X2))==(renderer,screen,expected_config)
            machine.mem_write(screen+0x10,struct.pack('<Q',image));machine.mem_write(screen+0x18,struct.pack('<Q',owned_view))
            result['allocation_calls']+=1
            machine.reg_write(UC_ARM64_REG_PC,machine.reg_read(UC_ARM64_REG_X30))
        elif pc==0xa23e68:
            current['cache_called']=True
            params=machine.reg_read(UC_ARM64_REG_X1)
            dimensions=struct.unpack('<2I',machine.mem_read(params+0xc,8))
            if not dimensions[0] or not dimensions[1]:return # run actual zero-geometry guard
            destination=machine.reg_read(UC_ARM64_REG_X8)
            machine.mem_write(destination,struct.pack('<5I',0 if current['mode']=='valid' else 0xffffffff,0,0,width,height))
            machine.reg_write(UC_ARM64_REG_PC,machine.reg_read(UC_ARM64_REG_X30))
        elif pc in (0x9ad4b4,0xa6130c,0x497720,0x4c696c,0x4d7d34,0xa42e50):
            if pc==0xa6130c:machine.reg_write(UC_ARM64_REG_X0,display_view)
            if pc==0xa42e50:result['render_end_calls']+=1
            machine.reg_write(UC_ARM64_REG_PC,machine.reg_read(UC_ARM64_REG_X30))
        elif pc==repair.FILL:
            assert tuple(machine.reg_read(r) for r in (UC_ARM64_REG_X0,UC_ARM64_REG_X1,UC_ARM64_REG_X2))==(renderer,0,screen)
            current['fill_called']=True # let actual R5 wrapper and clear recorder execute
    cpu.hook_add(UC_HOOK_CODE,hook)
    for current_mode in (sequence or [mode]):
        current.clear();current.update(mode=current_mode,pc=None,cache_called=False,fill_called=False,instructions=0)
        address=0 if current_mode=='zero' else 0x21002000
        pixel_stride=0 if current_mode=='nonzero_zero_stride' else 1 if current_mode=='misaligned_stride' else stride
        byte_stride=1 if current_mode=='bad_byte_stride' else pixel_stride*(4,3,2,2,2)[fmt]
        config=bytearray(0xa0)
        for offset,value in ((0x5c,width|(height<<16)),(0x68,address),(0x6c,address),
             (0x94,address),(0x98,address),(0x70,fmt),(0x90,byte_stride)):
            struct.pack_into('<I',config,offset,value)
        cpu.mem_write(fb,bytes(config));cpu.mem_write(gpu+0x1400,bytes(config));cpu.mem_write(gpu+0x1500,bytes(config))
        for reg,value in preserved.items():cpu.reg_write(reg,value)
        for reg,value in ((UC_ARM64_REG_X0,renderer),(UC_ARM64_REG_X1,fb),(UC_ARM64_REG_X2,screen),
                         (UC_ARM64_REG_X3,int(screen_offset==0x3d98)),(UC_ARM64_REG_X30,0xe00000),(UC_ARM64_REG_SP,sp)):
            cpu.reg_write(reg,value)
        cpu.emu_start(0x9fc274,0,count=5000)
        corrected=binary[fault.CALL:fault.CALL+4]==fault.words(fault.branch(fault.CALL,repair.CAVE))
        returns=current_mode=='valid' and pixel_stride!=0 or corrected and current_mode=='zero'
        expected_pc=(0xe00000 if returns else fault.ZERO_ADDRESS_TRAP if current_mode=='zero'
                     else 0xa80088 if current_mode=='bad_byte_stride' else 0xa800d0 if current_mode=='misaligned_stride'
                     else fault.INVALID_SURFACE_TRAP)
        assert current['pc']==expected_pc, (current,fmt,screen_offset,existing,corrected,hex(cpu.reg_read(UC_ARM64_REG_PC)))
        if returns:
            assert cpu.reg_read(UC_ARM64_REG_SP)==sp and cpu.reg_read(UC_ARM64_REG_X30)==0xe00000
            assert all(cpu.reg_read(reg)==value for reg,value in preserved.items())
        if corrected and current_mode=='zero':
            assert current['fill_called'] and not current['cache_called']
            assert struct.unpack('<Q',cpu.mem_read(screen+0x38,8))[0]==owned_view
            assert struct.unpack('<4f',cpu.mem_read(screen+0x28,16))==(0,0,1,1)
            tail=struct.unpack('<Q',cpu.mem_read(queue+8,8))[0]
            assert tail and struct.unpack('<Q',cpu.mem_read(tail+0x10,8))[0]==image
            assert struct.unpack('<4f',cpu.mem_read(tail+0x18,16))==(0,0,0,1)
            result['clear_commands']+=1
        else:assert not current['fill_called']
        if returns and current_mode=='valid':
            assert struct.unpack('<Q',cpu.mem_read(screen+0x38,8))[0]==display_view
        assert bytes(cpu.mem_read(fb,len(config)))==bytes(config)
        assert bytes(cpu.mem_read(gpu+0x1400,len(config)))==bytes(config)
        assert bytes(cpu.mem_read(gpu+0x1500,len(config)))==bytes(config)
        result['calls'].append(dict(current))
    if result['clear_commands']:
        assert result['allocation_calls']==(0 if existing else 1)
        assert result['render_end_calls']==result['clear_commands']
    return result

paired=0;clear=0;variants=[]
for path in (args.r5,args.r6):
    base=path.read_bytes();diagnostic=fault.patch_core(base);corrective=repair.patch_core(base)
    assert corrective==repair.patch_core(diagnostic)
    assert path.read_bytes()==base
    print('\n'.join(f'{i.address:x}: {i.mnemonic} {i.op_str}' for i in Cs(CS_ARCH_ARM64,CS_MODE_ARM).disasm(repair.stub(diagnostic),repair.CAVE)))
    for screen in (0x3d58,0x3d98,0x3dd8):
        for existing in (False,True):
            for fmt in range(5):
                for mode in ('zero','valid','invalid','nonzero_zero_stride','misaligned_stride','bad_byte_stride'):
                    # Include the physical crash's zero stride on zero-address
                    # startup, and initialized strides on normal/cache paths.
                    stride=0 if mode=='zero' else 240
                    before=execute(diagnostic,screen,existing,fmt,stride,mode)
                    after=execute(corrective,screen,existing,fmt,stride,mode)
                    if mode=='valid':assert after['calls'][0]['instructions']-before['calls'][0]['instructions']==2
                    clear+=after['clear_commands'];paired+=1
    cycle=['zero','valid','zero','valid']*32
    transitions=execute(corrective,0x3d58,False,0,240,'zero',sequence=cycle)
    assert transitions['clear_commands']==64 and transitions['allocation_calls']==1
    variants.append({'input':fault.KNOWN[hashlib.sha256(base).hexdigest()],
       'output_sha256':hashlib.sha256(corrective).hexdigest(),'state_transition_calls':len(cycle),
       'single_allocation_reused_across_transitions':True})
    for bad in (corrective,base[:100]):
        try:repair.patch_core(bad)
        except ValueError:pass
        else:raise AssertionError('Unknown/already corrected core accepted')
report={'paired_cases':paired,'paired_actual_ARM64_executions':paired*2,
        'transition_actual_ARM64_calls':sum(v['state_transition_calls'] for v in variants),
        'total_actual_ARM64_routine_executions':paired*2+sum(v['state_transition_calls'] for v in variants),
        'variants':variants,'owned_image_actual_black_clear_command_checks':clear,
        'actual_R5_fill_wrapper_and_clear_recording_executed':True,
        'nonzero_cache_failure_and_stride_assertion_behavior_retained':True,
        'callee_saved_GP_and_FP_registers_and_stack_preserved_on_returns':True,
        'no_framebuffer_config_or_guest_memory_writes':True,
        'added_normal_path_instructions_relative_to_FB1':2,
        'host_image_allocation_and_nonzero_cache_and_RenderEnd_are_stubs':True,
        'physical_Vulkan_execution_verified':False,'game_or_plugin_sessions_verified':False,
        'random_freeze_eliminated':False}
with args.output.open('x') as output:json.dump(report,output,indent=2)
print(json.dumps(report,indent=2))
