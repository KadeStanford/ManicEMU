"""Preserve the verified display assertion, distinguish its failure reason.

Diagnostic only. This is not a rendering repair, fallback, or crash workaround.
Unknown core binaries, changed instructions, and occupied caves are rejected.
"""
import argparse, hashlib, json, pathlib, struct

KNOWN={
 '834eeec376d261f6f10ebe753bfafcb98bf3b67c2127330c95ae963f51c3801e':'R5',
 'e6345deddeea4813b555ae7bbd283610cd68938f10182da582e92295dbf83e0d':'R6',
}
CALL=0x9fc318;ACCELERATE=0xa20cb8;RETURN=0x9fc31c;TRAP=0xa80118
CAPTURE=0xd4c300;CLASSIFY=0xd4c340;INVALID_SURFACE_TRAP=0xd4c34c;ZERO_ADDRESS_TRAP=0xd4c350

def branch(source,target,link=False):
    delta=target-source
    if delta%4 or not -(1<<27)<=delta<(1<<27):raise ValueError('Branch out of range')
    return (0x94000000 if link else 0x14000000)|((delta//4)&0x3ffffff)
def words(*values):return struct.pack('<'+'I'*len(values),*values)

# See the matching .s file. x20 is saved at LoadFBToScreenInfo entry and unused
# until its epilogue; all called functions preserve it under the AArch64 ABI.
# sp[0:8] is unused by this routine on the AccelerateDisplay call path. The
# existing guard starts at sp+8, saved x20/x19 at sp+16, and FP/LR at sp+32.
CAPTURE_CODE=words(
 0xb9405c28,  # ldr w8,[x1,#0x5c] packed width/height
 0x290023e2,  # stp w2,w8,[sp] selected address, dimensions
 0xb9407028,  # ldr w8,[x1,#0x70] framebuffer format register
 0x12000908,  # and w8,w8,#7
 0xaa088074,  # orr x20,x3,x8,lsl#32 (pixel stride | format<<32)
 branch(CAPTURE+20,ACCELERATE,True),
 branch(CAPTURE+24,RETURN),
)
CLASSIFY_CODE=words(
 0x294227e8,  # ldp w8,w9,[sp,#16] caller metadata, below guard
 0xaa1403ea,  # mov x10,x20 (stride | format<<32)
 0x34000048,  # cbz w8,+8 (ZERO_ADDRESS_TRAP)
 0xd4200000|(0x4d02<<5), # brk #0x4d02:nonzero address, invalid cache surface
 0xd4200000|(0x4d01<<5), # brk #0x4d01:zero selected framebuffer address
)

def verify_caves(data):
    position=32;found=False
    if struct.unpack_from('<I',data)[0]!=0xfeedfacf:raise ValueError('Not thin Mach-O')
    for _ in range(struct.unpack_from('<I',data,16)[0]):
        command,size=struct.unpack_from('<II',data,position)
        if command==0x19 and data[position+8:position+24].rstrip(b'\0')==b'__TEXT':
            vm,vm_size,offset,file_size=struct.unpack_from('<4Q',data,position+24)
            maxprot,initial,count=struct.unpack_from('<3I',data,position+56)
            if vm!=0 or offset!=0 or initial&5!=5:raise ValueError('Unexpected text mapping')
            section_end=0
            for i in range(count):
                section=position+72+80*i
                address,length=struct.unpack_from('<2Q',data,section+32)
                section_end=max(section_end,address+length)
            if not section_end<=CAPTURE<CLASSIFY+len(CLASSIFY_CODE)<=min(vm_size,file_size):
                raise ValueError('Caves not within existing executable section padding')
            found=True
        position+=size
    if not found:raise ValueError('No verified text segment')

def patch_core(data):
    digest=hashlib.sha256(data).hexdigest()
    if digest not in KNOWN:raise ValueError('Only exact verified R5/R6 core accepted')
    verify_caves(data)
    if data[CALL:CALL+4]!=words(branch(CALL,ACCELERATE,True)) or data[TRAP:TRAP+4]!=words(0xd4200020):
        raise ValueError('Instruction guards failed')
    for start,code in ((CAPTURE,CAPTURE_CODE),(CLASSIFY,CLASSIFY_CODE)):
        if any(data[start:start+len(code)]):raise ValueError('Executable padding occupied')
    result=bytearray(data)
    changes=((CALL,words(branch(CALL,CAPTURE))),
             (TRAP,words(branch(TRAP,CLASSIFY))),
             (CAPTURE,CAPTURE_CODE),(CLASSIFY,CLASSIFY_CODE))
    allowed=set()
    for start,code in changes:
        result[start:start+len(code)]=code;allowed.update(range(start,start+len(code)))
    assert len(result)==len(data)
    assert all(a==b or i in allowed for i,(a,b) in enumerate(zip(data,result)))
    return bytes(result)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input',type=pathlib.Path,required=True)
    parser.add_argument('--output',type=pathlib.Path,required=True);args=parser.parse_args()
    manifest=pathlib.Path(str(args.output)+'.verification.json')
    if args.input.resolve()==args.output.resolve() or args.output.exists() or manifest.exists():
        raise ValueError('Must use new output paths; no originals overwritten')
    original=args.input.read_bytes();diagnostic=patch_core(original)
    report={'kind':'diagnostic-only; original assertion still fatal',
      'input_sha256':hashlib.sha256(original).hexdigest(),
      'output_sha256':hashlib.sha256(diagnostic).hexdigest(),
      'input_variant':KNOWN[hashlib.sha256(original).hexdigest()],
      'input_preserved':True,'length_and_load_commands_preserved':True,
      'changes':[{'offset':hex(start),'bytes':len(code)} for start,code in
                 ((CALL,words(branch(CALL,CAPTURE))),(TRAP,words(branch(TRAP,CLASSIFY))),
                  (CAPTURE,CAPTURE_CODE),(CLASSIFY,CLASSIFY_CODE))],
      'zero_address_fault_pc':hex(ZERO_ADDRESS_TRAP),'invalid_surface_fault_pc':hex(INVALID_SURFACE_TRAP),
      'fault_registers':{'x8':'selected framebuffer physical address (32 bits)',
                         'x9':'width low16 / height high16',
                         'x10':'pixel stride low32 / pixel format high32'},
      'guest_pixels_saves_or_settings_accessed':False,'fatal_log_and_logging_shutdown_preserved':True,
      'successful_rendering_path_preserved':True,'physical_validation':False,
      'install_or_combined_packaging_performed':False,
      'signing':'Packaging owner must sign modified embedded framework and app'}
    with args.output.open('xb') as output:output.write(diagnostic)
    assert args.input.read_bytes()==original
    with manifest.open('x') as output:json.dump(report,output,indent=2)
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
