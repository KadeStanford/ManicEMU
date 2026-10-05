"""Optional FB2 presentation control; not a proven fast-forward freeze fix.

Bypass only the heuristic duplicate-frame early return. Existing presentation,
Vulkan synchronization, plugin loader and FB2 startup handling remain intact.
Upstream disabled duplicate skipping by default after regressions (#2530).
"""
import argparse, hashlib, json, pathlib, struct

INPUT='3995bab1659c74979fa81226e4961fc7634d30a324ba9b97eb0eb50b5dc892e4'
GATE=0x9fc404
ORIGINAL=struct.pack('<I',0x36001428)  # tbz w8,#0,0x9fc688
NOP=struct.pack('<I',0xd503201f)

def make_control(data):
    if hashlib.sha256(data).hexdigest()!=INPUT:raise ValueError('Requires exact reviewed plugin-enabled R5-FB2')
    if data[GATE:GATE+4]!=ORIGINAL:raise ValueError('Original gate guard failed')
    result=bytearray(data);result[GATE:GATE+4]=NOP
    assert len(result)==len(data) and result[:GATE]==data[:GATE] and result[GATE+4:]==data[GATE+4:]
    return bytes(result)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--input',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
    report=pathlib.Path(str(a.output)+'.verification.json')
    if a.output.exists() or report.exists() or a.input.resolve()==a.output.resolve():raise ValueError('New output paths required')
    original=a.input.read_bytes();control=make_control(original)
    with a.output.open('xb') as f:f.write(control)
    assert a.input.read_bytes()==original
    r={'purpose':'Optional duplicate-presentation control; not verified freeze repair','input_sha256':INPUT,
       'output_sha256':hashlib.sha256(control).hexdigest(),'instruction_offset':hex(GATE),
       'only_four_byte_instruction_region_changed':True,'load_commands_size_plugin_FB2_and_guest_execution_preserved':True,
       'private_inputs_used':False,'phone_freeze_fix_verified':False,'phone_FPS_improvement_verified':False,
       'tradeoff':'May render/present more frames and increase GPU cost; do not integrate as proven production fix',
       'upstream_context':'https://github.com/azahar-emu/azahar/pull/2530','signing':'Packaging owner re-signs framework and app'}
    with report.open('x') as f:json.dump(r,f,indent=2)
    print(json.dumps(r,indent=2))
if __name__=='__main__':main()
