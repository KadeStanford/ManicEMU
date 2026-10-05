"""Derive instruction-equivalent host controls from the immutable public core.

Public signature bytes/length differ from the preserved iOS baseline. Outputs
have distinct hashes; complete non-signature payload equivalence was verified.
"""
import argparse,hashlib,json,pathlib
MANIFEST=json.loads(pathlib.Path(__file__).with_name('reviewed_public_replay_edits.json').read_text())

def derive(original,variant):
    if len(original)!=MANIFEST['public_input_bytes'] or hashlib.sha256(original).hexdigest()!=MANIFEST['public_input_sha256']:
        raise ValueError('Exact immutable public original required')
    spec=MANIFEST['variants'][variant];out=bytearray(original);seen=set()
    for edit in spec['edits']:
        start=edit['offset'];before=bytes.fromhex(edit['before']);after=bytes.fromhex(edit['after'])
        if len(before)!=len(after) or len(before)%4 or start%4 or start<0x4000 or start+len(before)>0xd50000:
            raise ValueError('Invalid executable instruction edit')
        positions=set(range(start,start+len(before)))
        if positions&seen or original[start:start+len(before)]!=before:raise ValueError('Instruction region guard failed')
        seen.update(positions);out[start:start+len(before)]=after
    if hashlib.sha256(out).hexdigest()!=spec['public_host_output_sha256']:raise ValueError('Reviewed host output correspondence failed')
    return bytes(out)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--input',type=pathlib.Path,required=True)
    p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--variant',choices=list(MANIFEST['variants']),required=True);a=p.parse_args()
    if a.output.exists() or a.output.resolve()==a.input.resolve():raise ValueError('Exclusive new output required')
    original=a.input.read_bytes();result=derive(original,a.variant)
    with a.output.open('xb') as f:f.write(result)
    if a.input.read_bytes()!=original:raise ValueError('Original changed')
    print('Instruction-equivalent host core derived:',a.variant,hashlib.sha256(result).hexdigest())
