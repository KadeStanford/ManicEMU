"""Execute actual patched ARM64 branches; uses no games, firmware or saves."""
import argparse,json,pathlib,struct,sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'scripts'))
from patch_core import patch_core,CAVE,STUB,ON,OFF,SEND,COMMAND,ENVIRONMENT
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn.arm64_const import *
p=argparse.ArgumentParser();p.add_argument('core',type=pathlib.Path);p.add_argument('report',type=pathlib.Path);a=p.parse_args()
original=a.core.read_bytes();patched=patch_core(original);results=[]
for base in (0,0x100000000):
 for entry,event,ready in ((ON,1,0),(OFF,2,0),(SEND,3,0),(SEND,0,1),(SEND,0,7)):
  for available in (False,True):
   cpu=Uc(UC_ARCH_ARM64,UC_MODE_ARM);cpu.mem_map(base,0x2c0000);cpu.mem_write(base,patched[:0x2b8000])
   stack=base+0x300000;callback=base+0x400000;sentinel=base+0x500000
   for page in (stack,callback,sentinel):cpu.mem_map(page,0x1000)
   sp=stack+0x800;packet=base+0x2b9000;seen=[];sent=[]
   cpu.mem_write(base+ENVIRONMENT,struct.pack('<Q',callback if available else 0))
   cpu.reg_write(UC_ARM64_REG_SP,sp);cpu.reg_write(UC_ARM64_REG_X30,sentinel)
   saved=[0x1919,0x2020,0x2121,0x2222,0x2929,sentinel]
   for reg,val in zip((UC_ARM64_REG_X19,UC_ARM64_REG_X20,UC_ARM64_REG_X21,UC_ARM64_REG_X22,UC_ARM64_REG_X29),saved[:5]):cpu.reg_write(reg,val)
   if entry==SEND:
    # The original function already saved its callee registers in its 48-byte frame.
    cpu.mem_write(sp,struct.pack('<6Q',saved[3],saved[2],saved[1],saved[0],saved[4],sentinel))
    cpu.reg_write(UC_ARM64_REG_X19,packet);cpu.reg_write(UC_ARM64_REG_X20,base+0x2b0000)
    cpu.reg_write(UC_ARM64_REG_X0,ready)
   else:cpu.reg_write(UC_ARM64_REG_X0,0xaabbccdd)
   def hook(uc,address,size,_):
    if address==callback:
     assert uc.reg_read(UC_ARM64_REG_X0)==COMMAND
     event_ptr=uc.reg_read(UC_ARM64_REG_X1)
     seen.append(struct.unpack('<IIQ',bytes(uc.mem_read(event_ptr,16))))
     # Exercise caller-saved clobbering, as a real callback may do.
     for reg in (UC_ARM64_REG_X0,UC_ARM64_REG_X1,UC_ARM64_REG_X8):uc.reg_write(reg,0xcccc)
     uc.reg_write(UC_ARM64_REG_PC,uc.reg_read(UC_ARM64_REG_X30))
    if address==base+0x392f8:
     sent.append((uc.reg_read(UC_ARM64_REG_X0),uc.reg_read(UC_ARM64_REG_X1)))
     uc.reg_write(UC_ARM64_REG_PC,uc.reg_read(UC_ARM64_REG_X30))
   cpu.hook_add(UC_HOOK_CODE,hook);cpu.emu_start(base+entry,sentinel,count=500)
   assert cpu.reg_read(UC_ARM64_REG_PC)==sentinel
   assert cpu.reg_read(UC_ARM64_REG_SP)==sp+(48 if entry==SEND else 0)
   for reg,val in zip((UC_ARM64_REG_X19,UC_ARM64_REG_X20,UC_ARM64_REG_X21,UC_ARM64_REG_X22,UC_ARM64_REG_X29),saved[:5]):assert cpu.reg_read(reg)==val
   assert seen==([(event,0,packet if entry==SEND else 0)] if event and available else [])
   assert bool(sent)==bool(entry==SEND and ready)
   if entry==SEND:assert cpu.reg_read(UC_ARM64_REG_X0)==ready
   results.append({'base':hex(base),'entry':hex(entry),'callback_available':available,'event':event,'ready_value':ready,'passed':True})
for changed in (ON,OFF,SEND,CAVE,0x4000):
 corrupt=bytearray(original);corrupt[changed]^=1
 try:patch_core(bytes(corrupt));raise AssertionError('corrupt binary accepted')
 except ValueError:pass
a.report.write_text(json.dumps({'arm64_cases':results,'hash_guards':5,'games_executed':0,'physical_iPhone_validation':False},indent=2))
print(f'{len(results)} ARM64 execution cases and 5 corruption guards passed')
