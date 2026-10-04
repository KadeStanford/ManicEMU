"""Execute the actual repair bytes to verify ARM64 ABI and all screen paths."""
import pathlib,struct,sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
from repair_vulkan_fill import patch_core,ENTRY,CAVE,CONFIGURE,STUB
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn.arm64_const import *

data=pathlib.Path(sys.argv[1]).read_bytes();patched=patch_core(data)
for screen in (0x3d58,0x3d98,0x3dd8):
    for existing in (False,True):
        u=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
        u.mem_map(0x9fb000,0x1000);u.mem_map(0xd4c000,0x1000)
        u.mem_write(ENTRY,patched[ENTRY:ENTRY+4]);u.mem_write(CAVE,STUB)
        renderer,gpu,sp=0x20000,0x50000,0x310000
        u.mem_map(renderer,0x10000);u.mem_map(gpu,0x10000);u.mem_map(0x300000,0x20000)
        texture=renderer+screen;image=0xfeedbeef
        u.mem_write(renderer+0xc0,struct.pack('<Q',gpu))
        u.mem_write(texture+16,struct.pack('<Q',image if existing else 0))
        u.reg_write(UC_ARM64_REG_X0,renderer);u.reg_write(UC_ARM64_REG_X1,0x112233);u.reg_write(UC_ARM64_REG_X2,texture)
        u.reg_write(UC_ARM64_REG_SP,sp)
        preserved={UC_ARM64_REG_X19:19,UC_ARM64_REG_X20:20,UC_ARM64_REG_X21:21,UC_ARM64_REG_X22:22,UC_ARM64_REG_X29:29,UC_ARM64_REG_X30:30}
        for r,v in preserved.items():u.reg_write(r,v)
        u.reg_write(UC_ARM64_REG_D10,0x12345678);u.reg_write(UC_ARM64_REG_D11,0x87654321)
        calls=[]
        def hook(uc,addr,size,_):
            if addr==CONFIGURE:
                args=tuple(uc.reg_read(r) for r in (UC_ARM64_REG_X0,UC_ARM64_REG_X1,UC_ARM64_REG_X2))
                assert args==(renderer,texture,gpu+(0x1500 if screen==0x3dd8 else 0x1400))
                calls.append(args);uc.mem_write(texture+16,struct.pack('<Q',image))
                uc.reg_write(UC_ARM64_REG_PC,uc.reg_read(UC_ARM64_REG_X30))
            elif addr==ENTRY+4:uc.emu_stop()
        u.hook_add(UC_HOOK_CODE,hook);u.emu_start(ENTRY,0,count=200)
        assert len(calls)==(0 if existing else 1)
        assert u.reg_read(UC_ARM64_REG_PC)==ENTRY+4 and u.reg_read(UC_ARM64_REG_SP)==sp-64
        assert tuple(u.reg_read(r) for r in (UC_ARM64_REG_X0,UC_ARM64_REG_X1,UC_ARM64_REG_X2))==(renderer,0x112233,texture)
        assert all(u.reg_read(r)==v for r,v in preserved.items())
        assert struct.unpack('<2Q',u.mem_read(sp-64,16))==(0x87654321,0x12345678)
        assert struct.unpack('<Q',u.mem_read(texture+16,8))[0]==image
try:patch_core(patched)
except ValueError:pass
else:raise AssertionError('Already patched input was accepted')
unknown=bytearray(data);unknown[0x4000]^=1
try:patch_core(unknown)
except ValueError:pass
else:raise AssertionError('Unknown original core was accepted')
print('PASS: six actual ARM64 screen paths; preserved ABI, framebuffer selection, existing images, and input guards')
