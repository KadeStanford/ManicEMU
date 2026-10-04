"""Compile actual patched MpState bodies beside the frozen v0.8 regression."""
import argparse, hashlib, json, pathlib

def extract(source,name,prefix='std::optional<Packet>'):
    start=source.index(prefix+' MpState::'+name+'(')
    opening=source.index('{',start);depth=1;end=opening+1
    while depth:
        if source[end]=='{':depth+=1
        if source[end]=='}':depth-=1
        end+=1
    return source[start:end]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--source',type=pathlib.Path,required=True)
    parser.add_argument('--output',type=pathlib.Path,required=True)
    args=parser.parse_args()
    here=pathlib.Path(__file__).resolve().parent
    fixture=(here/'native_wait_before.inc').read_text()
    provenance=json.loads((here/'native_wait_before.json').read_text())
    if hashlib.sha256(fixture.encode()).hexdigest()!=provenance['fixture_sha256']:
        raise ValueError('Frozen exact v0.8 native source checksum differs')
    actual=(args.source/'src/libretro/net/mp.cpp').read_text()
    if 'return 8;' not in (args.source/'src/libretro/libretro.cpp').read_text():
        raise ValueError('Actual marker8 patched source required')
    before=extract(fixture,'NextPacketBlock')
    after=extract(actual,'NextPacketBlock')
    if before==after or before.count('_pollFn();')!=1 or after.count('_pollFn();')!=2:
        raise ValueError('Expected final available-packet poll missing')
    args.output.write_text(extract(actual,'NextPacket')+'\n'+
        before.replace('MpState::NextPacketBlock(', 'MpState::NextPacketBlockBefore(',1)+'\n'+
        after.replace('MpState::NextPacketBlock(', 'MpState::NextPacketBlockAfter(',1)+'\n',encoding='utf-8',newline='\n')
    result={**provenance,'before_function_sha256':hashlib.sha256(before.encode()).hexdigest(),
        'after_function_sha256':hashlib.sha256(after.encode()).hexdigest(),
        'after_nonblocking_function_sha256':hashlib.sha256(extract(actual,'NextPacket').encode()).hexdigest(),
        'compiled_actual_patched_functions':True,'function_bodies_unchanged_except_method_names':True}
    args.output.with_suffix('.json').write_text(json.dumps(result,indent=2))
    (args.output.parent/'native_send_function.inc').write_text(extract(actual,'SendPacket','void')+'\n',encoding='utf-8',newline='\n')
if __name__=='__main__':main()
