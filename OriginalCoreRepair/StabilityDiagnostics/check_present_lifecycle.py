"""Execute the existing R6 ARM64 gate over repeated synthetic loader states.

This is an instruction-level regression, not a gameplay/unload or GPU test.
"""
import argparse,hashlib,json,pathlib,struct,sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
from repair_vulkan_plugin_present import patch_core,ENTRY,CAVE,NORMAL,PRESENT,FRAME_CHANGED,STUB
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn.arm64_const import *

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline',type=pathlib.Path)
    parser.add_argument('--output',required=True,type=pathlib.Path)
    args=parser.parse_args()
    source=args.baseline.read_bytes()
    assert hashlib.sha256(source).hexdigest()=='834eeec376d261f6f10ebe753bfafcb98bf3b67c2127330c95ae963f51c3801e'
    patched=patch_core(source)
    u=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
    for page,size in ((0x9fc000,0x1000),(0xd4c000,0x1000),(0x20000,0x20000),(0x50000,0x20000),(0x80000,0x10000)):
        u.mem_map(page,size)
    renderer,memory,impl,settings=0x20000,0x30000,0x50000,0x80000
    u.mem_write(renderer+0xb8,struct.pack('<Q',memory));u.mem_write(memory,struct.pack('<Q',impl))
    u.mem_write(ENTRY,patched[ENTRY:ENTRY+4]);u.mem_write(CAVE,STUB)
    def stop(uc,address,size,data):
        if address in (NORMAL,PRESENT):uc.emu_stop()
    u.hook_add(UC_HOOK_CODE,stop)
    count=0
    for cycle in range(128):
        # Cleared -> mapped -> cleared -> new mapping -> cleared. The test
        # supplies these states; it does not execute the real loader teardown.
        for framebuffer in (0,0x21002000,0,0x21004000,0):
            for property_type in (0,1):
                u.mem_write(impl+0x18740,struct.pack('<I',framebuffer))
                u.mem_write(settings+0xbe8,bytes([property_type]))
                preserved={r:0x100+index for index,r in enumerate((UC_ARM64_REG_X0,UC_ARM64_REG_X1,
                    UC_ARM64_REG_X2,UC_ARM64_REG_X9,UC_ARM64_REG_X19,UC_ARM64_REG_X21,
                    UC_ARM64_REG_X22,UC_ARM64_REG_X23,UC_ARM64_REG_X26,UC_ARM64_REG_X27,
                    UC_ARM64_REG_X28,UC_ARM64_REG_X29,UC_ARM64_REG_X30))}
                preserved.update({UC_ARM64_REG_X20:renderer,UC_ARM64_REG_X25:settings,
                    UC_ARM64_REG_SP:0x909000,UC_ARM64_REG_NZCV:0xA0000000})
                for register,value in preserved.items():u.reg_write(register,value)
                u.reg_write(UC_ARM64_REG_X24,0x24242424)
                u.emu_start(ENTRY,0,count=30)
                assert u.reg_read(UC_ARM64_REG_PC)==(PRESENT if framebuffer else NORMAL)
                assert u.reg_read(UC_ARM64_REG_X24)==(FRAME_CHANGED if framebuffer else 0x24242424)
                assert all(u.reg_read(register)==value for register,value in preserved.items())
                if not framebuffer:assert u.reg_read(UC_ARM64_REG_X8)==property_type
                assert u.mem_read(impl+0x18740,4)==struct.pack('<I',framebuffer)
                assert u.mem_read(settings+0xbe8,1)==bytes([property_type])
                count+=1
    report={'actual_arm64_gate_executions':count,'synthetic_loader_cycles':128,
        'mapped_unmapped_transitions_passed':True,'both_setting_storage_types_passed':True,
        'callee_registers_and_flags_preserved':True,'core_settings_not_written':True,
        'real_game_unload_test':False,'physical_gpu_test':False,
        'random_freeze_fix_proven':False}
    with args.output.open('x') as output:json.dump(report,output,indent=2)
    print(json.dumps(report))

if __name__=='__main__':main()
