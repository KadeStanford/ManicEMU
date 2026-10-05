"""Bounded ARM64 diagnostic regression; no game, GPU, or phone dependencies."""
import argparse, hashlib, json, pathlib, struct, sys
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--r5',type=pathlib.Path,required=True)
parser.add_argument('--r6',type=pathlib.Path,required=True)
parser.add_argument('--deps',type=pathlib.Path,required=True)
parser.add_argument('--output',type=pathlib.Path,required=True);args=parser.parse_args()
sys.path.insert(0,str(args.deps))
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_ARM
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn.arm64_const import *
import instrument_framebuffer_fault as patch

def execute(binary,address,width,height,pixel_stride,fmt,cache_valid,active,right_eye):
    machine=Uc(UC_ARCH_ARM64,UC_MODE_ARM);machine.mem_map(0,0xd60000)
    machine.mem_write(0,binary[:0xd60000])
    for base,size in ((0xe00000,0x1000),(0x1000000,0x10000),(0x1100000,0x6000),
                      (0x1200000,0x1000),(0x1300000,0x1000),(0x1400000,0x1000)):
        machine.mem_map(base,size)
    renderer,fb,screen,sp=0x1100000,0x1200000,0x1300000,0x1008000
    machine.mem_write(0xd50780,struct.pack('<Q',0x1400800))
    machine.mem_write(0x1400800,struct.pack('<Q',0x12345678))
    config=bytearray(0xa0)
    selected_offset=(0x94 if active==0 else 0x98) if right_eye else (0x68 if active==0 else 0x6c)
    for offset in (0x68,0x6c,0x94,0x98):struct.pack_into('<I',config,offset,0x22004000)
    struct.pack_into('<I',config,selected_offset,address)
    # Nonzero opposite right buffer is needed for the routine to honor right_eye.
    # Test zero addresses using left eye; right-eye selection is tested nonzero.
    for offset,value in ((0x5c,width|(height<<16)),(0x70,fmt),(0x78,active),
                         (0x90,pixel_stride*(4,3,2,2,2)[fmt])):
        struct.pack_into('<I',config,offset,value)
    machine.mem_write(fb,bytes(config));machine.mem_write(screen+0x18,struct.pack('<Q',0x71000100))
    machine.mem_write(renderer+0x2150+0x14a8,struct.pack('<Q',0x1400000))
    machine.mem_write(0x1400000+0xc,struct.pack('<2I',320,240))
    machine.mem_write(0x1400000+0x1c,struct.pack('<I',1))
    preserved={reg:0x440000+index for index,reg in enumerate((UC_ARM64_REG_X18,
        UC_ARM64_REG_X19,UC_ARM64_REG_X20,UC_ARM64_REG_X21,UC_ARM64_REG_X22,
        UC_ARM64_REG_X23,UC_ARM64_REG_X24,UC_ARM64_REG_X25,UC_ARM64_REG_X26,
        UC_ARM64_REG_X27,UC_ARM64_REG_X28,UC_ARM64_REG_X29))}
    for reg,value in preserved.items():machine.reg_write(reg,value)
    for reg,value in ((UC_ARM64_REG_X0,renderer),(UC_ARM64_REG_X1,fb),
                      (UC_ARM64_REG_X2,screen),(UC_ARM64_REG_X3,int(right_eye)),
                      (UC_ARM64_REG_SP,sp),(UC_ARM64_REG_X30,0xe00000)):
        machine.reg_write(reg,value)
    result={'pc':None,'log_calls':0,'log_stop_calls':0,'real_zero_geometry_guard':False,'instruction_count':0}
    def hook(cpu,pc,size,data):
        result['instruction_count']+=1
        if pc in (0xe00000,patch.ZERO_ADDRESS_TRAP,patch.INVALID_SURFACE_TRAP) or (pc==patch.TRAP and binary[pc:pc+4]==patch.words(0xd4200020)):
            result['pc']=pc;cpu.emu_stop()
        elif pc==0xa23e68:
            params=cpu.reg_read(UC_ARM64_REG_X1)
            dimensions=struct.unpack('<2I',cpu.mem_read(params+0xc,8))
            if not dimensions[0] or not dimensions[1]:
                # Let preserved instructions execute their actual zero-dimension
                # guard and return. No cache stub hides this branch.
                result['real_zero_geometry_guard']=True
                return
            destination=cpu.reg_read(UC_ARM64_REG_X8)
            cpu.mem_write(destination,struct.pack('<5I',0 if cache_valid else 0xffffffff,0,0,320,240))
            cpu.reg_write(UC_ARM64_REG_PC,cpu.reg_read(UC_ARM64_REG_X30))
        elif pc in (0x9ad4b4,0xa6130c,0x497720,0x4c696c,0x4d7d34):
            if pc==0xa6130c:cpu.reg_write(UC_ARM64_REG_X0,0x71000200)
            if pc==0x4c696c:result['log_calls']+=1
            if pc==0x4d7d34:
                result['log_stop_calls']+=1
                # Logging may clobber all volatile scratch registers; metadata
                # must still be recovered from the caller frame/callee-saved x20.
                for reg in (UC_ARM64_REG_X0,UC_ARM64_REG_X1,UC_ARM64_REG_X2,
                            UC_ARM64_REG_X8,UC_ARM64_REG_X9,UC_ARM64_REG_X10):
                    cpu.reg_write(reg,0xdead1234)
            cpu.reg_write(UC_ARM64_REG_PC,cpu.reg_read(UC_ARM64_REG_X30))
    machine.hook_add(UC_HOOK_CODE,hook);machine.emu_start(0x9fc274,0,count=3000)
    failure=not address or not width or not height or not pixel_stride or not cache_valid
    assert result['pc']!=None
    if failure:
        expected=patch.ZERO_ADDRESS_TRAP if not address else patch.INVALID_SURFACE_TRAP
        assert result['pc']==(patch.TRAP if binary[patch.TRAP:patch.TRAP+4]==patch.words(0xd4200020) else expected)
        assert result['log_calls']==result['log_stop_calls']==1
        assert machine.reg_read(UC_ARM64_REG_SP)==sp-0x40 # original lambda frame
        if result['pc']!=patch.TRAP:
            assert machine.reg_read(UC_ARM64_REG_X8)==address
            assert machine.reg_read(UC_ARM64_REG_X9)==width|(height<<16)
            assert machine.reg_read(UC_ARM64_REG_X10)==pixel_stride|(fmt<<32)
    else:
        assert result['pc']==0xe00000
        assert all(machine.reg_read(reg)==value for reg,value in preserved.items())
        assert machine.reg_read(UC_ARM64_REG_SP)==sp
        assert machine.reg_read(UC_ARM64_REG_X30)==0xe00000
        assert not result['log_calls'] and not result['log_stop_calls']
    assert bytes(machine.mem_read(fb,len(config)))==bytes(config)
    result['screen_bytes']=bytes(machine.mem_read(screen,0x50)).hex()
    return result

results=[];executions=0;real_guards=0;successes=0
for path in (args.r5,args.r6):
    original=path.read_bytes();instrumented=patch.patch_core(original)
    assert path.read_bytes()==original
    for code,address in ((patch.CAPTURE_CODE,patch.CAPTURE),(patch.CLASSIFY_CODE,patch.CLASSIFY)):
        instructions=list(Cs(CS_ARCH_ARM64,CS_MODE_ARM).disasm(code,address))
        assert len(instructions)==len(code)//4
        print('\n'.join(f'{i.address:x}: {i.mnemonic} {i.op_str}' for i in instructions))
    count=0
    for fmt in range(5):
        for active,right in ((0,False),(1,False),(0,True),(1,True)):
            cases=[(0x21002000,320,240,320,True),(0x21002000,320,240,320,False),
                   (0x21002000,0,240,320,True),(0x21002000,320,0,320,True),
                   (0x21002000,320,240,0,True)]
            if not right:cases.append((0,320,240,320,True))
            for address,width,height,stride,valid in cases:
                before=execute(original,address,width,height,stride,fmt,valid,active,right)
                after=execute(instrumented,address,width,height,stride,fmt,valid,active,right)
                assert before['screen_bytes']==after['screen_bytes']
                assert before['real_zero_geometry_guard']==after['real_zero_geometry_guard']
                if after['pc']==0xe00000:
                    assert after['instruction_count']-before['instruction_count']==7
                real_guards+=int(after['real_zero_geometry_guard'])
                successes+=int(after['pc']==0xe00000);count+=1;executions+=2
    corrupt=bytearray(original);corrupt[patch.CALL]^=1
    for rejected in (bytes(corrupt),instrumented):
        try:patch.patch_core(rejected)
        except ValueError:pass
        else:raise AssertionError('Unknown/already modified binary accepted')
    results.append({'variant':patch.KNOWN[hashlib.sha256(original).hexdigest()],
                    'paired_cases':count,'output_sha256':hashlib.sha256(instrumented).hexdigest()})
report={'paired_cases':executions//2,'actual_arm64_routine_executions':executions,
        'variants':results,'successful_path_register_and_stack_preservation_cases':successes,
        'real_preserved_zero_geometry_guard_cases':real_guards,
        'fatal_log_and_stop_preserved':True,'metadata_survives_volatile_logging_clobber':True,
        'screen_info_bytes_match_baseline':True,'framebuffer_config_not_written':True,
        'added_native_instructions_per_successful_display_call':7,
        'unknown_or_already_modified_core_rejected':True,'physical_gpu_test':False,
        'new_leaf_or_plugin_gameplay_test':False,'crash_or_rendering_fix_claimed':False}
from decode_framebuffer_fault import decode,CORE_UUID
for pc,address,width,height,stride,fmt in (
        (patch.ZERO_ADDRESS_TRAP,0,320,240,320,1),
        (patch.INVALID_SURFACE_TRAP,0x21002000,0,240,320,4),
        (patch.INVALID_SURFACE_TRAP,0x21002000,320,240,0,0),
        (patch.INVALID_SURFACE_TRAP,0x21002000,320,240,320,1)):
    registers=[{'value':0} for _ in range(29)]
    for index,value in ((8,address),(9,width|(height<<16)),(10,stride|(fmt<<32))):registers[index]['value']=value
    crash={'faultingThread':0,'exception':{'type':'EXC_BREAKPOINT'},
      'usedImages':[{'name':'azahar.libretro','uuid':CORE_UUID}],
      'threads':[{'frames':[{'imageIndex':0,'imageOffset':pc}], 'threadState':{'x':registers}}]}
    decoded=decode('{}\n'+json.dumps(crash))
    assert (decoded['width'],decoded['height'],decoded['pixel_stride'],decoded['pixel_format'])==(width,height,stride,fmt)
    crash['threads'][0]['frames'][0]['imageOffset']=patch.TRAP
    try:decode('{}\n'+json.dumps(crash))
    except ValueError:pass
    else:raise AssertionError('Old reports must not be decoded as new metadata')
report['bounded_metadata_decoder_cases']=4
report['old_signature_rejected_by_decoder']=True
with args.output.open('x') as output:json.dump(report,output,indent=2)
print(json.dumps(report,indent=2))
