"""Execute actual complete settings/duplicate gate on synthetic layouts."""
import hashlib,json,pathlib,struct,sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
sys.path.insert(0,r'C:\Users\Stanj\Documents\Codex\2026-10-03\task-3\analysis-deps')
from make_fb2_present_control import make_control
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn.arm64_const import *
root=pathlib.Path(__file__).resolve().parents[3];baseline=(root/'azahar-output/azahar-r5-fb2-uninitialized-framebuffer-corrective.dylib').read_bytes();control=make_control(baseline)
cases=0
for global_setting in (False,True):
  for skip in (0,1,2):
    for marker in (0,1,2,3):
      for incoming_flags in (0,0xf0000000):
        pair=[]
        for binary,force_present in ((baseline,False),(control,True)):
          uc=Uc(UC_ARCH_ARM64,UC_MODE_ARM);uc.mem_map(0,0xd60000);uc.mem_write(0,binary[:0xd60000])
          uc.mem_map(0xfc2000,0x1000);uc.mem_map(0xff2000,0x4000);uc.mem_map(0x2000000,0x1000)
          settings=0xff2db0
          uc.mem_write(settings+0xbe8,bytes([int(global_setting)]));uc.mem_write(settings+0xbe9,bytes([skip]));uc.mem_write(0xfc2e38,bytes([marker]))
          if global_setting:
            uc.mem_write(settings+0xbe0,struct.pack('<Q',0x2000040));uc.mem_write(0x2000028,struct.pack('<Q',0x40));uc.mem_write(settings+0xbe0+0x40+8,bytes([skip]))
          uc.reg_write(UC_ARM64_REG_X25,settings);uc.reg_write(UC_ARM64_REG_X24,0x12345678);uc.reg_write(UC_ARM64_REG_NZCV,incoming_flags)
          original_memory=bytes(uc.mem_read(settings,0x1800))
          stops=[]
          def hook(u,pc,size,data):
            if pc in (0x9fc408,0x9fc688):stops.append(pc);u.emu_stop()
          uc.hook_add(UC_HOOK_CODE,hook);uc.emu_start(0x9fc3b0,0x9fc68c,count=40)
          expected=0x9fc408 if force_present or skip!=1 or marker&1 else 0x9fc688
          assert stops==[expected] and uc.reg_read(UC_ARM64_REG_X24)==0xfc2e38
          assert bytes(uc.mem_read(settings,0x1800))==original_memory and uc.mem_read(0xfc2e38,1)==bytes([marker])
          pair.append(tuple(uc.reg_read(r) for r in (UC_ARM64_REG_X8,UC_ARM64_REG_X9,UC_ARM64_REG_X24,UC_ARM64_REG_X25,UC_ARM64_REG_SP,UC_ARM64_REG_NZCV)))
          cases+=1
        assert pair[0]==pair[1]
report={'native_ARM64_gate_executions':cases,'settings_global_and_direct_paths_tested':True,
    'all_normal_routes_preserved':True,'duplicate_route_enters_existing_present_path':True,'frame_marker_and_settings_unchanged':True,
    'registers_stack_and_flags_equal_to_baseline':True,'GPU_helpers_executed':False,'phone_freeze_fix_verified':False,
    'output_sha256':hashlib.sha256(control).hexdigest()}
with (root/'azahar-output/fb2-present-control-regression.json').open('x') as f:json.dump(report,f,indent=2)
print(json.dumps(report,indent=2))
