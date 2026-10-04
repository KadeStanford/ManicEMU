"""Decode private ring captures locally; emit offsets/counters, not raw stacks."""
import argparse,base64,json,pathlib,struct

def decode(path):
    data=json.loads(path.read_text())
    prefix=path.name.split('.stability-')[0]
    events=[]
    for line in path.with_name(prefix+'.images').read_text().splitlines():
        generation,event,base,size,name=line.split(' ',4)
        events.append((int(generation),event,int(base,16),int(size,16),name))
    images={}
    for generation,event,base,size,name in sorted(events):
        if generation>data['image_generation']:
            break
        if event=='add':images[base]=(size,name)
        elif event=='remove':images.pop(base,None)
        else:raise ValueError('Unknown image event')
    def address(raw):
        for candidate in (raw,raw&0x0000ffffffffffff):
            for base,(size,name) in images.items():
                if base<=candidate<base+size:
                    return {'image':name,'offset':hex(candidate-base)}
        return {'unmapped_address':hex(raw)}
    rows=[]
    for thread in data['threads']:
        row={key:thread[key] for key in ('thread_id','run_state','state_result','info_result','cpu_usage','user_us','system_us')}
        if 'pc' in thread:
            row['pc']=address(thread['pc']);row['lr']=address(thread['lr'])
            stack=base64.b64decode(thread.get('stack_b64',''),validate=True)
            if len(stack)>4096:raise ValueError('Stack bound exceeded')
            sp,fp=thread['sp'],thread['fp']&0x0000ffffffffffff
            frames=[];seen=set()
            while sp<=fp and fp-sp+16<=len(stack) and fp not in seen and len(frames)<32:
                seen.add(fp)
                following,lr=struct.unpack_from('<2Q',stack,fp-sp)
                frames.append(address(lr));following&=0x0000ffffffffffff
                if following<=fp:break
                fp=following
            row['callers']=frames
        rows.append(row)
    result={k:data[k] for k in ('pid','sequence','capture_epoch','capture_duration_ms','memory','thermal_state','core_base')}
    result['session']=prefix
    result['threads']=rows
    return result

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=pathlib.Path)
    parser.add_argument('--output',required=True,type=pathlib.Path)
    args=parser.parse_args()
    samples=sorted((decode(p) for p in args.directory.glob('*.stability-*.json')),key=lambda s:s['capture_epoch'])
    previous={}
    for sample in samples:
        for row in sample['threads']:
            key=(sample['session'],row['thread_id']);prior=previous.get(key)
            cpu=row['user_us']+row['system_us']
            if prior:
                seconds=sample['capture_epoch']-prior[0]
                delta=cpu-prior[1]
                if seconds>0 and delta>=0:
                    row['cpu_us_since_previous']=delta
                    row['mean_cpu_percent_since_previous']=delta/seconds/10000
            previous[key]=(sample['capture_epoch'],cpu)
    result={'samples':samples,'coherent_thread_snapshot':False,'deadlock_or_leak_proven':False,
            'physical_gpu_completion_observed':False,'raw_stack_memory_in_output':False}
    with args.output.open('x') as output:json.dump(result,output,indent=2)
    print('Decoded private snapshots:',len(samples),'No raw stacks written to summary.')

if __name__=='__main__':main()
