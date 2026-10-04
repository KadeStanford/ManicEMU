"""Keep original Vulkan presentation active for CPU-drawn 3GX framebuffers.

The original duplicate-frame gate tracks game GPU changes. A loaded 3GX plugin
can update its CPU framebuffer while that marker stays clear, preventing the
libretro frame/input cycle from completing. The guarded native comparison opens
the supplied Vapecord menu when duplicate skipping is disabled. This wrapper
applies that behavior only while the original loader's framebuffer is mapped.
"""
import argparse,hashlib,json,pathlib,struct
import repair_vulkan_fill as fill

ENTRY=0x9FC3B0
CAVE=0xD4C200
NORMAL=ENTRY+4
PRESENT=0x9FC408
FRAME_CHANGED=0xFC2E38
ENTRY_ORIGINAL=bytes.fromhex('28a36f39')

def branch(pc,target):
    assert (target-pc)%4==0 and -(1<<27)<=target-pc<(1<<27)
    return 0x14000000|(((target-pc)//4)&0x3ffffff)

def adrp(register,pc,target):
    delta=(target>>12)-(pc>>12)
    assert -(1<<20)<=delta<(1<<20)
    immediate=delta&0x1fffff
    return 0x90000000|((immediate&3)<<29)|((immediate>>2)<<5)|register

STUB=struct.pack('<10I',
    0xF9405E88,       # ldr x8,[x20,#0xb8] ; RendererVulkan::memory
    0xF9400108,       # ldr x8,[x8]        ; MemorySystem::Impl
    0x91406108,       # add x8,x8,#0x18,lsl #12
    0xB9474108,       # ldr w8,[x8,#0x740] ; plugin_fb_address at +0x18740
    0x34000088,       # cbz w8,normal
    adrp(24,CAVE+20,FRAME_CHANGED),
    0x9138E318,       # add x24,x24,#0xe38 ; original frame-change marker
    branch(CAVE+28,PRESENT),
    struct.unpack('<I',ENTRY_ORIGINAL)[0], # ldrb w8,[x25,#0xbe8]
    branch(CAVE+36,NORMAL))
ENTRY_BRANCH=struct.pack('<I',branch(ENTRY,CAVE))

def patch_core(data):
    canonical=bytearray(data)
    if data[fill.ENTRY:fill.ENTRY+4]==fill.ENTRY_BRANCH:
        if data[fill.CAVE:fill.CAVE+len(fill.STUB)]!=fill.STUB:
            raise ValueError('Input is not the exact R5 fill-view repair')
        canonical[fill.ENTRY:fill.ENTRY+4]=fill.ENTRY_ORIGINAL
        canonical[fill.CAVE:fill.CAVE+len(fill.STUB)]=bytes(len(fill.STUB))
        if fill.patch_core(bytes(canonical))!=data:
            raise ValueError('Unexpected changes outside the R5 repair')
        base=data
    else:
        base=fill.patch_core(data)
    if base[ENTRY:ENTRY+4]!=ENTRY_ORIGINAL or any(base[CAVE:CAVE+len(STUB)]):
        raise ValueError('Original present gate or unused executable padding guard failed')
    out=bytearray(base)
    out[ENTRY:ENTRY+4]=ENTRY_BRANCH;out[CAVE:CAVE+len(STUB)]=STUB
    allowed=set(range(ENTRY,ENTRY+4))|set(range(CAVE,CAVE+len(STUB)))
    assert len(out)==len(base)
    assert all(a==b or i in allowed for i,(a,b) in enumerate(zip(base,out)))
    return bytes(out)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input',required=True);p.add_argument('--output',required=True)
    args=p.parse_args();source=pathlib.Path(args.input);output=pathlib.Path(args.output)
    report_path=pathlib.Path(str(output)+'.verification.json')
    assert source.resolve()!=output.resolve() and not output.exists() and not report_path.exists()
    before=source.read_bytes();after=patch_core(before);output.write_bytes(after)
    report={'input_sha256':hashlib.sha256(before).hexdigest(),'output_sha256':hashlib.sha256(after).hexdigest(),
        'input_preserved':source.read_bytes()==before,'length_unchanged':len(before)==len(after),
        'entry_offset':hex(ENTRY),'wrapper_offset':hex(CAVE),'wrapper_bytes':len(STUB),
        'original_duplicate_frame_policy_retained_without_plugin_framebuffer':True,
        'plugin_framebuffer_guard_established_from_original_map_and_teardown':True,
        'physical_vulkan_plugin_verified':False,'signing':'Re-sign the modified embedded core and app'}
    report_path.write_text(json.dumps(report,indent=2));print(json.dumps(report))
if __name__=='__main__':main()
