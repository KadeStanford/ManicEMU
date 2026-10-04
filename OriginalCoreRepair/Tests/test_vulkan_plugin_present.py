"""Execute the targeted ARM64 gate and verify both plugin lifecycle paths."""
import pathlib,struct,sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
from repair_vulkan_plugin_present import patch_core,ENTRY,CAVE,NORMAL,PRESENT,FRAME_CHANGED,STUB
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn.arm64_const import *

source=pathlib.Path(sys.argv[1]).read_bytes();patched=patch_core(source)
for framebuffer in (0,0x21002000):
    for property_type in (0,1):
        u=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
        for page,size in ((0x9fc000,0x1000),(0xd4c000,0x1000),(0x20000,0x10000),(0x50000,0x20000),(0x80000,0x10000)):
            u.mem_map(page,size)
        renderer,memory,impl,settings=0x20000,0x30000,0x50000,0x80000
        u.mem_map(memory,0x1000)
        u.mem_write(renderer+0xb8,struct.pack('<Q',memory));u.mem_write(memory,struct.pack('<Q',impl))
        u.mem_write(impl+0x18740,struct.pack('<I',framebuffer))
        u.mem_write(settings+0xbe8,bytes([property_type]))
        u.mem_write(ENTRY,patched[ENTRY:ENTRY+4]);u.mem_write(CAVE,STUB)
        u.reg_write(UC_ARM64_REG_X20,renderer);u.reg_write(UC_ARM64_REG_X25,settings)
        u.reg_write(UC_ARM64_REG_X24,0x24242424)
        preserved={UC_ARM64_REG_X0:10,UC_ARM64_REG_X1:11,UC_ARM64_REG_X2:12,UC_ARM64_REG_X9:19,
            UC_ARM64_REG_X19:0x1919,UC_ARM64_REG_X21:0x2121,UC_ARM64_REG_X22:0x2222,
            UC_ARM64_REG_X29:0x2929,UC_ARM64_REG_X30:0x3030,UC_ARM64_REG_SP:0x909000,UC_ARM64_REG_NZCV:0xA0000000}
        for r,v in preserved.items():u.reg_write(r,v)
        def stop(uc,address,size,_):
            if address in (NORMAL,PRESENT):uc.emu_stop()
        u.hook_add(UC_HOOK_CODE,stop);u.emu_start(ENTRY,0,count=30)
        assert u.reg_read(UC_ARM64_REG_PC)==(PRESENT if framebuffer else NORMAL)
        assert u.reg_read(UC_ARM64_REG_X24)==(FRAME_CHANGED if framebuffer else 0x24242424)
        if not framebuffer:assert u.reg_read(UC_ARM64_REG_X8)==property_type
        assert all(u.reg_read(r)==v for r,v in preserved.items())
        assert u.reg_read(UC_ARM64_REG_X20)==renderer and u.reg_read(UC_ARM64_REG_X25)==settings
        assert u.mem_read(impl+0x18740,4)==struct.pack('<I',framebuffer)
        assert u.mem_read(settings+0xbe8,1)==bytes([property_type])
try:patch_core(patched)
except ValueError:pass
else:raise AssertionError('Already-patched core accepted')
tampered=bytearray(source);tampered[0x10000]^=1
try:patch_core(bytes(tampered))
except ValueError:pass
else:raise AssertionError('Unknown core accepted')
print('PASS: actual ARM64 bytes, active/inactive plugin, dynamic/global setting, ABI, input guards')
