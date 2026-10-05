"""FB2:clear an owned texture for a proven zero-address startup framebuffer.

Fresh physical FB1 report:address0,width240,height400,pixel_stride0,format0.
Keep nonzero display/cache logic and the bounded FB1 failure diagnostic.
Do not sample stale pixels, remove the assertion, or touch guest memory/options.
"""
import argparse,hashlib,json,pathlib,struct
import instrument_framebuffer_fault as fault

FB1={
 '66df36d8d88e0c67c9cf1a3694cb6b4fc24473a751fa4caa3dd7cef7f179a6d7':'R5-FB1',
 'fd7e7009a32c1cc82c49d271d3b8d9360cccac536460dfb655d986b2b7577af8':'R6-FB1',
}
CAVE=0xd4c400;FILL=0x9fb28c;EPILOGUE=0x9fc320
# Normal route resumes the unchanged FB1 capture -> original AccelerateDisplay.
# Zero route calls the preserved R5 FillScreen with packed RGB black, then sets
# full owned-texture coordinates/view and performs the original guarded return.
def stub(data):
    return fault.words(
      0x34000042, # cbz w2,+8
      fault.branch(CAVE+4,fault.CAPTURE),
      0x52842a08, # mov w8,#0x2150 (rasterizer offset within renderer)
      0xcb080000, # sub x0,x0,x8
      0x52800001, # mov w1,#0 (RGB black)
      0xaa1303e2, # mov x2,x19 (ScreenInfo starts with owned TextureInfo)
      fault.branch(CAVE+24,FILL,True),
    )+data[0x9fc358:0x9fc368]+fault.words(fault.branch(CAVE+44,EPILOGUE))

def patch_core(data):
    digest=hashlib.sha256(data).hexdigest()
    if digest in fault.KNOWN:base=fault.patch_core(data)
    elif digest in FB1:base=data
    else:raise ValueError('Requires exact verified R5/R6 or their FB1 diagnostic')
    fault.verify_caves(base)
    if base[fault.CALL:fault.CALL+4]!=fault.words(fault.branch(fault.CALL,fault.CAPTURE)):
        raise ValueError('FB1 call guard failed')
    code=stub(base)
    if len(code)!=48 or any(base[CAVE:CAVE+len(code)]):raise ValueError('Corrective executable padding occupied')
    # Exact known hashes also preserve the original default-view reset bytes.
    result=bytearray(base)
    result[fault.CALL:fault.CALL+4]=fault.words(fault.branch(fault.CALL,CAVE))
    result[CAVE:CAVE+len(code)]=code
    allowed=set(range(fault.CALL,fault.CALL+4))|set(range(CAVE,CAVE+len(code)))
    assert len(result)==len(base)
    assert all(a==b or i in allowed for i,(a,b) in enumerate(zip(base,result)))
    return bytes(result)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input',type=pathlib.Path,required=True)
    parser.add_argument('--output',type=pathlib.Path,required=True);args=parser.parse_args()
    manifest=pathlib.Path(str(args.output)+'.verification.json')
    if args.input.resolve()==args.output.resolve() or args.output.exists() or manifest.exists():
        raise ValueError('Use new paths; never overwrite originals')
    original=args.input.read_bytes();corrective=patch_core(original)
    digest=hashlib.sha256(original).hexdigest()
    report={'kind':'FB2 experimental zero-address startup correction; FB1 nonzero fault diagnostic retained',
      'input_sha256':digest,'input_variant':FB1.get(digest,fault.KNOWN.get(digest)),
      'output_sha256':hashlib.sha256(corrective).hexdigest(),
      'corrective_regions_relative_to_FB1':[{'offset':hex(fault.CALL),'bytes':4},{'offset':hex(CAVE),'bytes':48}],
      'zero_address_routes_to_preserved_owned_black_clear_recording':True,'nonzero_accelerate_path_preserved':True,
      'nonzero_failed_cache_assertion_preserved':True,'no_guest_memory_settings_or_save_writes':True,
      'R5_fill_and_plugin_loader_and_optional_R6_guard_preserved':True,
      'length_and_load_commands_preserved':True,'input_preserved':True,
      'physical_phone_correction_verified':False,'random_gameplay_freeze_fix_proven':False,
      'signing':'Packaging owner must re-sign modified embedded core/framework and app'}
    with args.output.open('xb') as output:output.write(corrective)
    assert args.input.read_bytes()==original
    with manifest.open('x') as output:json.dump(report,output,indent=2)
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
