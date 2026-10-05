"""Exact FB2-only no-plugin control; not a proposed plugin-support fix."""
import argparse,hashlib,json,pathlib,struct
EXPECTED='3995bab1659c74979fa81226e4961fc7634d30a324ba9b97eb0eb50b5dc892e4'
OFFSETS=(0x524954,0x52495c,0x5281ac,0x5281b4)
def make_control(data):
    if hashlib.sha256(data).hexdigest()!=EXPECTED:raise ValueError('Requires exact reviewed FB2 core')
    out=bytearray(data)
    for offset in OFFSETS:
        if data[offset:offset+4]!=bytes.fromhex('29008052'):raise ValueError('Enable flag instruction mismatch')
        out[offset:offset+4]=bytes.fromhex('09008052')
    assert len(out)==len(data)
    assert all(a==b or i in OFFSETS for i,(a,b) in enumerate(zip(data,out)))
    return bytes(out)
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('input',type=pathlib.Path);parser.add_argument('output',type=pathlib.Path)
    args=parser.parse_args();data=args.input.read_bytes();out=make_control(data)
    manifest=pathlib.Path(str(args.output)+'.verification.json')
    if args.output.exists() or manifest.exists() or args.input.resolve()==args.output.resolve():raise ValueError('New output paths required')
    with args.output.open('xb') as f:f.write(out)
    report={'scope':'Temporary fresh-launch diagnostic control, plugin loader disabled; not a production fix',
        'input_sha256':EXPECTED,'output_sha256':hashlib.sha256(out).hexdigest(),'actual_changed_bytes':4,
        'four_flag_offsets':[hex(o) for o in OFFSETS],'all_other_core_bytes_unchanged':True,'input_preserved':args.input.read_bytes()==data,
        'phone_verified':False,'private_inputs_modified':False,'settings_files_modified':False,'plugin_files_modified':False,
        'integration':'Sole combined-IPA owner only. Keep plugin-enabled FB2 candidate; label this PluginOffControl. Keep identity/DS/GBA/AirPlay unchanged.'}
    with manifest.open('x') as f:json.dump(report,f,indent=2)
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
