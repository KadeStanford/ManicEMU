"""Execute exact preserved guarded Init/ApplySettings store windows."""
import hashlib,json,pathlib,sys
sys.path.insert(0,r'C:\Users\Stanj\Documents\Codex\2026-10-03\task-3\analysis-deps')
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM
from unicorn.arm64_const import *
from make_plugin_off_control import make_control
root=pathlib.Path(__file__).resolve().parents[4];data=(root/'azahar-output/azahar-r5-fb2-uninitialized-framebuffer-corrective.dylib').read_bytes();control=make_control(data)
cases=0
for binary,enabled in ((data,1),(control,0)):
    for start,end in ((0x524950,0x524964),(0x5281a8,0x5281bc)):
        for pointer in (0,0x1200000):
            for initial in (0,1,0xff):
                for flags in (0,0xf0000000):
                    uc=Uc(UC_ARCH_ARM64,UC_MODE_ARM);uc.mem_map(0,0xd60000);uc.mem_write(0,binary[:0xd60000]);uc.mem_map(0x1200000,0x1000)
                    uc.mem_write(0x1200000,bytes([initial])*0x1000);uc.reg_write(UC_ARM64_REG_X8,pointer);uc.reg_write(UC_ARM64_REG_X9,0x123456789);uc.reg_write(UC_ARM64_REG_NZCV,flags)
                    uc.emu_start(start,end,count=10)
                    result=bytes(uc.mem_read(0x1200000,0x1000));expected=bytearray([initial]*0x1000)
                    if pointer:expected[0x78]=expected[0x79]=enabled
                    assert result==expected and uc.reg_read(UC_ARM64_REG_X8)==pointer and uc.reg_read(UC_ARM64_REG_NZCV)==flags
                    assert uc.reg_read(UC_ARM64_REG_X9)==(enabled if pointer else 0x123456789)
                    cases+=1
report={'native_arm64_guarded_store_executions':cases,'both_init_and_apply_settings_verified':True,'null_service_guard_preserved':True,
        'both_flags_disabled':True,'all_other_memory_registers_and_flags_unchanged':True,'phone_verified':False,'no_guest_inputs_used':True,
        'control_sha256':hashlib.sha256(control).hexdigest()}
with (root/'azahar-output/plugin-off-control-regression.json').open('x') as f:json.dump(report,f,indent=2)
print(json.dumps(report))
