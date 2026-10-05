"""Execute complete original RenderToWindow control flow and delivery callbacks.

GPU draw/acquire/submit and frontend callbacks are controlled ABI fixtures.
Original layout copies, resize synchronization, settings reads, delivery flags,
stack guard and full function return execute. This is not physical GPU emulation.
"""
import hashlib,json,pathlib,struct,sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
sys.path.insert(0,r'C:\Users\Stanj\Documents\Codex\2026-10-03\task-3\analysis-deps')
from make_fb2_present_control import make_control
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn.arm64_const import *
root=pathlib.Path(__file__).resolve().parents[3]
baseline=(root/'azahar-output/azahar-r5-fb2-uninitialized-framebuffer-corrective.dylib').read_bytes()
fixed=make_control(baseline);combined='--reschedule' in sys.argv
if combined:
    from repair_core_reschedule import patch_core
    fixed=patch_core(fixed)
renderer,window,frame,acquired,semaphore,api,vtable,device,stack=range(0x2000000,0x2090000,0x10000)
settings=0xff2db0;stop=0xd4cf00;wait_fn=0xd4cf04;callback=0xd4cf08;poll=0xd4cf0c

def session(binary,skip,marker,resize,second_window,global_setting):
    uc=Uc(UC_ARCH_ARM64,UC_MODE_ARM);uc.mem_map(0,0xd60000);uc.mem_write(0,binary[:0xd60000])
    uc.mem_map(0xfc2000,0x1000);uc.mem_map(0xff2000,0x4000);uc.mem_map(renderer,0xa0000)
    def q(addr,value):uc.mem_write(addr,struct.pack('<Q',value))
    def w(addr,value):uc.mem_write(addr,struct.pack('<I',value))
    q(0xd50780,device+0x1000);q(device+0x1000,0x12345678)
    q(0xff2d18,api);q(api+8,device);q(api+0x48,callback)
    q(window,device+0x3000);q(device+0x3000,vtable);q(vtable+0x18,poll);q(window+8,device);w(device+0x878,3)
    q(renderer+0x9a8,semaphore);q(semaphore,vtable+0x100);q(vtable+0x118,wait_fn);q(semaphore+0x10,10)
    w(frame,400);w(frame+4,240);w(acquired,200 if resize else 400);w(acquired+4,240)
    q(acquired+0x20,0xabc000);q(acquired+0x28,0xdef000)
    uc.mem_write(window+0x38,bytes(range(80)))
    uc.mem_write(settings+0xbe8,bytes([global_setting]));uc.mem_write(settings+0xbe9,bytes([skip]))
    if global_setting:
        q(settings+0xbe0,device+0x2000);q(device+0x1fe8,0x200);uc.mem_write(settings+0xde8,bytes([skip]))
    for off,value in ((0x12ec,1.25),(0x132c,0.75),(0x136c,1.0)):
        uc.mem_write(settings+off,struct.pack('<f',value))
    uc.mem_write(renderer+0x3ed1,bytes([second_window]));uc.mem_write(renderer+0x3ed0,b'\0')
    events=[];cycle_events=[]
    def hook(u,pc,size,data):
        if pc==stop:u.emu_stop();return
        name=None
        if pc==0x4b44d0:name='acquire';u.reg_write(UC_ARM64_REG_X0,acquired)
        elif pc==0x4b38cc:name='resize_prepare'
        elif pc==0xa30ac8:
            name='submit';tick=struct.unpack('<Q',u.mem_read(semaphore+0x10,8))[0];q(semaphore+0x10,tick+1)
        elif pc==wait_fn:name='wait';assert u.reg_read(UC_ARM64_REG_X1)>=10
        elif pc==0x4b46d4:name='resize';w(acquired,400);w(acquired+4,240)
        elif pc==0x9fc6c0:
            name='draw';assert u.reg_read(UC_ARM64_REG_X1)==acquired and u.reg_read(UC_ARM64_REG_X2)==frame
        elif pc==callback:
            name='deliver';assert u.reg_read(UC_ARM64_REG_X1)==window+0xc8
            assert struct.unpack('<Q',u.mem_read(window+0xc8,8))[0]==0xabc000
            assert bytes(u.mem_read(window+0xd8,80))==bytes(range(80))
        elif pc==poll:name='poll'
        if name:events.append(name);cycle_events.append(name);u.reg_write(UC_ARM64_REG_PC,u.reg_read(UC_ARM64_REG_X30))
    uc.hook_add(UC_HOOK_CODE,hook)
    saved={globals()['UC_ARM64_REG_X%d'%i]:0x800000+i for i in range(19,30)}
    for cycle in range(120):
        cycle_events.clear();uc.mem_write(0xfc2e38,bytes([marker]));uc.mem_write(renderer+0x3ed2,b'\0')
        for r,v in saved.items():uc.reg_write(r,v)
        uc.reg_write(UC_ARM64_REG_X0,renderer);uc.reg_write(UC_ARM64_REG_X1,window);uc.reg_write(UC_ARM64_REG_X2,frame)
        uc.reg_write(UC_ARM64_REG_X30,stop);uc.reg_write(UC_ARM64_REG_SP,stack+0xf000)
        try:uc.emu_start(0x9fc370,stop,count=1500)
        except Exception as error:
            raise AssertionError((hex(uc.reg_read(UC_ARM64_REG_PC)),cycle,skip,marker,resize,second_window,global_setting,cycle_events)) from error
        assert uc.reg_read(UC_ARM64_REG_PC)==stop and uc.reg_read(UC_ARM64_REG_SP)==stack+0xf000
        assert all(uc.reg_read(r)==v for r,v in saved.items())
        presents=binary is fixed or not skip or bool(marker&1)
        assert ('deliver' in cycle_events)==presents
        assert ('draw' in cycle_events)==presents and ('poll' in cycle_events)==presents
        assert uc.mem_read(renderer+0x3ed2,1)==bytes([int(presents and not second_window)])
        assert cycle_events.count('wait')==int(presents and resize and cycle==0)
        assert ('submit' in cycle_events)==presents
    return len(events),events.count('deliver')

sessions=0;calls=0;starvation=[]
for skip in (0,1):
 for marker in (0,1):
  for resize in (0,1):
   for second in (0,1):
    for global_setting in (0,1):
     for binary in (baseline,fixed):
        events,delivered=session(binary,skip,marker,resize,second,global_setting);sessions+=1;calls+=120
        if skip and not marker and not resize and not second and not global_setting:starvation.append(delivered)
assert starvation==[0,120]
report={'native_complete_RenderToWindow_calls':calls,'synthetic_sessions':sessions,
 'old_duplicate_marker_deliveries':starvation[0],'corrected_duplicate_marker_deliveries':starvation[1],
 'normal_delivery_resize_wait_layout_copy_flags_and_callee_saved_ABI_pass':True,
 'direct_and_global_settings_and_second_window_paths_pass':True,
 'GPU_draw_submit_acquire_and_frontend_callbacks_controlled':True,'physical_GPU_or_Nookling_success_verified':False,
 'output_sha256':hashlib.sha256(fixed).hexdigest()}
with (root/('azahar-output/combined-present-delivery-regression.json' if combined else 'azahar-output/present-delivery-regression.json')).open('x') as f:json.dump(report,f,indent=2)
print(json.dumps(report,indent=2))
