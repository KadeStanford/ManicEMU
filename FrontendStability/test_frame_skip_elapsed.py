"""Execute shipped ARM64 frame-skip code, not a reimplementation of its gate."""
import argparse,hashlib,itertools,json,pathlib,struct,zipfile
from repair_frame_skip_elapsed import ASSEMBLY,INPUT_SHA256,assemble_block,repair
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn.arm64_const import *

HERE=pathlib.Path(__file__).resolve().parent
FIXTURE=HERE/'shipped-frame-skip-code.json'

def model(elapsed,target,accumulator,state,nonblock,skip,menu,duped,data,saturate):
    if not (nonblock and skip and not (menu or (duped and data))):
        return True,0,0
    delta=min(elapsed,65535) if saturate else elapsed&65535
    before=accumulator
    if not state:state=-1
    elif state<0:state=1
    if state>0:accumulator+=delta
    render=accumulator>=target
    if render:
        accumulator-=target
        if before-accumulator>=delta:accumulator-=delta
        accumulator=max(0,accumulator)
        if accumulator>target:accumulator=0
    return render,accumulator,state

def machine(blocks,elapsed,target=16666,accumulator=0,state=1,
            nonblock=True,skip=True,menu=False,duped=False,data=True,
            previous_time=1000000):
    u=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
    u.mem_map(0x247000,0x1000)
    for address,code in blocks.items():u.mem_write(address,code)
    u.mem_map(0xacb000,0x1000);u.mem_map(0xadf000,0x1000)
    stack=0x2000000;u.mem_map(stack,0x2000)
    u.mem_write(0xadfcf0,struct.pack('<Q',previous_time))
    u.mem_write(0xadfd10,struct.pack('<i',accumulator))
    u.mem_write(0xadfd14,bytes([state&255]));u.mem_write(0xacbe78,bytes([bool(duped)]))
    u.mem_write(stack+0xe00,bytes([bool(nonblock)]));u.mem_write(stack+0xe16,bytes([bool(skip)]))
    u.mem_write(stack+0x9f8,struct.pack('<H',bool(menu)));u.mem_write(stack+0x9fa,struct.pack('<H',target))
    for index in range(19,29):u.reg_write(globals()['UC_ARM64_REG_X'+str(index)],0xabc000+index)
    u.reg_write(UC_ARM64_REG_SP,stack)
    u.reg_write(UC_ARM64_REG_X21,0xffffffffffffffff if data else 0)
    now=(previous_time+elapsed)&0xffffffffffffffff
    u.reg_write(UC_ARM64_REG_X23,now)
    stops=[]
    def stop(cpu,address,size,unused):
        if address==0x2478c0:stops.append(address);cpu.emu_stop()
    u.hook_add(UC_HOOK_CODE,stop)
    u.emu_start(0x247860,0x247ae0,count=120)
    assert stops==[0x2478c0],stops
    assert u.reg_read(UC_ARM64_REG_SP)==stack
    assert u.reg_read(UC_ARM64_REG_X21)==(0xffffffffffffffff if data else 0)
    assert u.reg_read(UC_ARM64_REG_X23)==now
    for index in (19,20,22,24,25,26,27):
        assert u.reg_read(globals()['UC_ARM64_REG_X'+str(index)])==0xabc000+index
    assert struct.unpack('<Q',u.mem_read(0xadfcf0,8))[0]==now
    assert bool(u.mem_read(0xacbe78,1)[0])==(not data)
    return (bool(u.reg_read(UC_ARM64_REG_W28)),
            struct.unpack('<i',u.mem_read(0xadfd10,4))[0],
            struct.unpack('<b',u.mem_read(0xadfd14,1))[0])

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--ipa',type=pathlib.Path)
    parser.add_argument('--output',type=pathlib.Path,required=True)
    parser.add_argument('--write-fixture',action='store_true');args=parser.parse_args()
    actual_binary_checked=False
    if args.ipa:
        with zipfile.ZipFile(args.ipa) as archive:
            baseline=archive.read('Payload/ManicEmuSideload.app/Frameworks/Libretro.framework/Libretro')
        assert hashlib.sha256(baseline).hexdigest()==INPUT_SHA256
        fixture={'frontend_sha256':INPUT_SHA256,'blocks':{
            '0x247860':baseline[0x247860:0x2478c0].hex(),
            '0x247a60':baseline[0x247a60:0x247adc].hex()}}
        if args.write_fixture:
            with FIXTURE.open('x') as file:json.dump(fixture,file,indent=2)
        else:assert json.loads(FIXTURE.read_text())==fixture
        fixed=repair(baseline)
        actual_binary_checked=True
        output_hash=hashlib.sha256(fixed).hexdigest()
    else:
        fixture=json.loads(FIXTURE.read_text());assert fixture['frontend_sha256']==INPUT_SHA256
        output_hash=None
    original={int(address,16):bytes.fromhex(code) for address,code in fixture['blocks'].items()}
    corrected=dict(original);block=bytearray(original[0x247a60])
    for address,code in assemble_block().items():block[address-0x247a60:address-0x247a60+4]=code
    corrected[0x247a60]=bytes(block)
    assert corrected[0x247860]==original[0x247860]
    assert block[0x34:0x3c]==original[0x247a60][0x34:0x3c]
    count=0;short_equivalent=0;long_corrected=0
    for target in (8333,16666,33333,65535):
        delays=(0,1,target//2,target-1,target,target+1,65535,65536,65537,131072,1000000,3600000000)
        for elapsed,state,accumulator in itertools.product(delays,(-1,0,1),(0,target//2,target-1)):
            settings=dict(elapsed=elapsed,target=target,state=state,accumulator=accumulator)
            observed_old=machine(original,**settings);observed_new=machine(corrected,**settings)
            model_args=dict(nonblock=True,skip=True,menu=False,duped=False,data=True,**settings)
            assert observed_old==model(**model_args,saturate=False),(settings,observed_old)
            assert observed_new==model(**model_args,saturate=True),(settings,observed_new)
            if elapsed<=65535:
                assert observed_new==observed_old;short_equivalent+=1
            elif state:
                assert observed_new[0];long_corrected+=1
            count+=2
    # The unchanged gate must preserve normal speed, skip-off, menu frames and
    # first nonduplicate frames for both null and hardware-frame data pointers.
    for nonblock,skip,menu,duped,data in itertools.product((False,True),repeat=5):
        settings=dict(elapsed=65536,nonblock=nonblock,skip=skip,menu=menu,duped=duped,data=data)
        observed_old=machine(original,**settings);observed_new=machine(corrected,**settings)
        expected=model(target=16666,accumulator=0,state=1,**settings,saturate=True)
        assert observed_new==expected
        if not(nonblock and skip and not(menu or(duped and data))):assert observed_new==observed_old
        count+=2
    # Full 64-bit timestamps, including crossing the low 32-bit boundary and
    # unsigned timestamp wrap. Only elapsed time, not timestamp width, matters.
    for previous in (0xffffffff-1000,0x100000000,0xffffffffffffffff-1000):
        for elapsed in (2000,65536,131072,3600000000):
            assert machine(corrected,elapsed,previous_time=previous)==model(elapsed,16666,0,1,True,True,False,False,True,True)
            count+=1
    old_rendered=new_rendered=0;old_state=new_state=1;old_acc=new_acc=0
    for index in range(12):
        old=machine(original,65536,accumulator=old_acc,state=old_state)
        new=machine(corrected,65536,accumulator=new_acc,state=new_state)
        old_rendered+=old[0];new_rendered+=new[0]
        old_acc,old_state=old[1:];new_acc,new_state=new[1:];count+=2
    assert old_rendered==0 and new_rendered==12
    report={'actual_ARM64_gate_executions':count,'actual_full_shipped_binary_checked':actual_binary_checked,
            'short_interval_equivalent_cases':short_equivalent,'long_interval_rendered_cases':long_corrected,
            'repeated_65536us_baseline_rendered':old_rendered,'repeated_65536us_corrected_rendered':new_rendered,
            'normal_skip_off_menu_duplicate_gates_preserved':True,'callee_saved_registers_and_stack_preserved':True,
            'uint64_timestamp_wrap_and_low32_crossing_checked':True,'corrected_frontend_sha256':output_hash,
            'GPU_or_game_executed':False,'physical_freeze_recovery_proven':False}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.open('x') as file:json.dump(report,file,indent=2)
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
