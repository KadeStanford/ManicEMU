"""Initialize the original core's screen texture before an early Vulkan fill.

Phone Trace2 confirmed FillScreen's deferred clear at +0xa017a0 passed a
null VkImage. SwapBuffers skips ConfigureFramebufferTexture while color-fill
is enabled. This wrapper initializes a missing texture from the appropriate
existing GPU framebuffer config, then resumes the unchanged FillScreen.
No driver changes, new load commands, or original files overwritten.
"""
import argparse,hashlib,json,pathlib,struct
from enable_3gx import PATCHES,ORIGINAL_SHA256

PUBLIC_SHA256='183159290D777D42A68C17F5F4D90D8B88F7AA0281E4788BAD4E5954A6DF940C'
ENTRY=0x9FB28C
CAVE=0xD4C100
CONFIGURE=0x9FB388
ENTRY_ORIGINAL=bytes.fromhex('eb2bbc6d')
ENTRY_BRANCH=bytes.fromhex('9d430d14')
# ARM64 assembly is included in repair_vulkan_fill.s for review.
R4_STUB=bytes.fromhex(
 'fd7bbca9fd030091f35301a9f55b02a9f30300aaf40301aaf50302aa480840f9'
 '880100b5686240f9a90213cb0abb87d23f010aeb098082d20aa082d24a21899a'
 '02010a8be10315aae00313aa8fbcf297e00313aae10314aae20315aaf55b42a9'
 'f35341a9fd7bc4a8eb2bbc6d49bcf217')
STUB=bytearray(R4_STUB[:0x50]+bytes.fromhex('a80e40f9a81e00f9')+R4_STUB[0x50:])
# Existing-image branch skips allocation and its view refresh. The final
# resume branch moves eight bytes while retaining the same destination.
struct.pack_into('<I',STUB,0x20,struct.unpack_from('<I',R4_STUB,0x20)[0]+(2<<5))
struct.pack_into('<I',STUB,len(STUB)-4,struct.unpack_from('<I',R4_STUB,len(R4_STUB)-4)[0]-2)
STUB=bytes(STUB)

def patch_core(data,refresh_sampled_view=True):
    stub=STUB if refresh_sampled_view else R4_STUB
    canonical=bytearray(data)
    for offset,before,after,_ in PATCHES:
        if data[offset:offset+4] not in (before,after):
            raise ValueError('Unexpected original loader instructions')
        canonical[offset:offset+4]=before
    digest=hashlib.sha256(canonical).hexdigest().upper()
    if digest not in (ORIGINAL_SHA256,PUBLIC_SHA256):
        raise ValueError('Input is not a hash-verified original Manic core')
    if data[ENTRY:ENTRY+4]!=ENTRY_ORIGINAL or any(data[CAVE:CAVE+len(stub)]):
        raise ValueError('Entry or unused executable padding guard failed')
    # Exact hash guarantees __TEXT VM == file offset and executable protection;
    # cave lies beyond all __TEXT sections, within existing zero page padding.
    out=bytearray(data)
    out[ENTRY:ENTRY+4]=ENTRY_BRANCH
    out[CAVE:CAVE+len(stub)]=stub
    allowed=set(range(ENTRY,ENTRY+4))|set(range(CAVE,CAVE+len(stub)))
    assert len(out)==len(data)
    assert all(a==b or i in allowed for i,(a,b) in enumerate(zip(data,out)))
    return bytes(out)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--input',required=True);p.add_argument('--output',required=True)
    a=p.parse_args();source=pathlib.Path(a.input);output=pathlib.Path(a.output)
    report_path=pathlib.Path(str(output)+'.verification.json')
    assert source.resolve()!=output.resolve() and not output.exists() and not report_path.exists()
    before=source.read_bytes();after=patch_core(before);output.write_bytes(after)
    report={'input_sha256':hashlib.sha256(before).hexdigest(),'output_sha256':hashlib.sha256(after).hexdigest(),
            'input_preserved':source.read_bytes()==before,'length_unchanged':len(before)==len(after),
            'entry_offset':hex(ENTRY),'wrapper_offset':hex(CAVE),'wrapper_bytes':len(STUB),
            'all_other_bytes_unchanged':True,'physical_vulkan_repair_tested':False,
            'purpose':'Initialize missing top/right/bottom screen textures before color fill',
            'signing':'Re-sign modified embedded core and app'}
    report_path.write_text(json.dumps(report,indent=2));print(json.dumps(report))
if __name__=='__main__':main()
