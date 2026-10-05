"""Decode only this experiment's Apple crash PC and bounded register metadata."""
import argparse, json, pathlib
from instrument_framebuffer_fault import ZERO_ADDRESS_TRAP,INVALID_SURFACE_TRAP

CORE_UUID='77f4a4b3-3a4c-35a8-8b2d-8be6268bb763'
def decode(text):
    _,separator,body=text.partition('\n')
    if not separator:raise ValueError('Expected Apple IPS header and body')
    crash=json.loads(body);threads=crash.get('threads',[])
    index=crash.get('faultingThread',-1)
    if not 0<=index<len(threads):raise ValueError('No faulting thread')
    thread=threads[index];frames=thread.get('frames',[]);images=crash.get('usedImages',[])
    if not frames:raise ValueError('No crash frames')
    frame=frames[0];image_index=frame.get('imageIndex',-1)
    if not 0<=image_index<len(images):raise ValueError('Missing fault image')
    image=images[image_index]
    if image.get('name')!='azahar.libretro' or image.get('uuid','').lower()!=CORE_UUID:
        raise ValueError('Fault is not the expected core/UUID')
    pc=frame.get('imageOffset')
    if pc not in (ZERO_ADDRESS_TRAP,INVALID_SURFACE_TRAP):
        raise ValueError('Not this diagnostic signature; do not reinterpret old reports')
    if crash.get('exception',{}).get('type')!='EXC_BREAKPOINT':
        raise ValueError('Not an assertion breakpoint')
    registers=thread.get('threadState',{}).get('x',[])
    if len(registers)<11:raise ValueError('No ARM64 x8/x9/x10 metadata')
    addr,dimensions,stride_format=(registers[i]['value'] for i in (8,9,10))
    if not all(isinstance(v,int) and 0<=v<1<<64 for v in (addr,dimensions,stride_format)):
        raise ValueError('Invalid metadata values')
    if addr>0xffffffff or dimensions>0xffffffff or stride_format>>32>4:
        raise ValueError('Unexpected framebuffer metadata bounds')
    zero=pc==ZERO_ADDRESS_TRAP
    if zero!=(addr==0):raise ValueError('Fault PC and captured address disagree')
    result={'diagnostic_fault_offset':hex(pc),'reason':'zero_address' if zero else 'invalid_cache_surface',
        'selected_framebuffer_address':hex(addr),'width':dimensions&0xffff,'height':dimensions>>16,
        'pixel_stride':stride_format&0xffffffff,'pixel_format':stride_format>>32,
        'timestamp':crash.get('captureTime'),'pid':crash.get('pid'),
        'raw_native_stacks_emitted':False,'guest_pixels_emitted':False}
    result['zero_geometry']=not result['width'] or not result['height'] or not result['pixel_stride']
    return result

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report',required=True,type=pathlib.Path)
    parser.add_argument('--output',required=True,type=pathlib.Path);args=parser.parse_args()
    result=decode(args.report.read_text())
    with args.output.open('x') as output:json.dump(result,output,indent=2)
    print(json.dumps(result,indent=2))
if __name__=='__main__':main()
