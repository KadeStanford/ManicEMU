"""Decode a privately retrieved native diagnostic record with its image map."""
import argparse,json,pathlib,struct
def decode(path):
    path=pathlib.Path(path);v=struct.unpack('<39Q',path.read_bytes())
    assert v[0]==0x4d414e4943464c54 and v[1]==1
    images=[]
    for line in path.with_suffix('.images').read_text().splitlines():
        base,size,name=line.split(' ',2);images.append((int(base,16),int(size,16),name))
    def address(value):
        candidates=[(base,size,name) for base,size,name in images if base<=value<base+size]
        result={'address':hex(value)}
        if candidates:
            base,size,name=candidates[0];result.update(image=name,image_offset=hex(value-base))
        return result
    result={'signal':v[2],'signal_code':v[3],'fault':address(v[4]),'pc':address(v[5]),'lr':address(v[6]),
            'sp':hex(v[7]),'fp':hex(v[8]),'cpsr':hex(v[9]),'registers':{f'x{i}':address(v[10+i]) for i in range(29)}}
    stack_path=path.with_suffix('.stack')
    if stack_path.exists():
        data=stack_path.read_bytes();sp,fp=struct.unpack_from('<2Q',data)
        assert (sp,fp)==(v[7],v[8]) and len(data)<=16400
        frames=[];seen=set()
        while sp<=fp and fp-sp+16<=len(data)-16 and fp not in seen and len(frames)<64:
            seen.add(fp);next_fp,lr=struct.unpack_from('<2Q',data,16+fp-sp)
            mapped=address(lr)
            if 'image' not in mapped:
                stripped=address(lr&0x0000ffffffffffff)
                if 'image' in stripped:mapped={**stripped,'signed_address':hex(lr)}
            frames.append(mapped)
            if next_fp<=fp:break
            fp=next_fp
        result['bounded_native_stack_bytes']=len(data)-16
        result['frame_pointer_callers']=frames
    path.with_suffix('.decoded.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('record');decode(p.parse_args().record)
