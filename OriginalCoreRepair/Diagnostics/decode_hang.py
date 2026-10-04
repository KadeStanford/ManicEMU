"""Decode private own-process hang snapshots into image offsets and CPU deltas."""
import argparse,base64,json,pathlib,re,struct
STATES={1:'running',2:'stopped',3:'waiting',4:'uninterruptible',5:'halted'}
def decode(path):
    path=pathlib.Path(path);sample=json.loads(path.read_text())
    prefix=re.sub(r'\.hang-\d+\.json$','',path.name)
    images=[]
    maps=[path.with_name(prefix+'.images')]+list(path.parent.glob(prefix+'.images.*'))
    latest=max((p for p in maps if p.exists()),key=lambda p:p.stat().st_mtime_ns)
    for line in latest.read_text().splitlines():
        b,n,name=line.split(' ',2);images.append((int(b,16),int(n,16),name))
    def address(raw):
        for candidate in (raw,raw&0x0000ffffffffffff):
            for start,size,name in images:
                if start<=candidate<start+size:
                    result={'image':name,'offset':hex(candidate-start)}
                    if name=='azahar.libretro' and 0xd4c100<=candidate-start<0xd4c170:
                        result['repair_wrapper']=True
                    return result
        return {'unmapped_address':hex(raw)}
    rows=[]
    for thread in sample['threads']:
        row={k:thread[k] for k in ('thread_id','state_result','suspend_count','user_us','system_us')}
        row.update(run_state=STATES.get(thread['run_state'],str(thread['run_state'])),cpu_usage_percent=thread['cpu_usage']/10)
        if 'pc' in thread:
            row.update(pc=address(thread['pc']),lr=address(thread['lr']))
            data=base64.b64decode(thread.get('stack_b64',''));sp=thread['sp'];fp=thread['fp'];seen=set();frames=[]
            assert len(data)<=8192
            while sp<=fp and fp-sp+16<=len(data) and fp not in seen and len(frames)<64:
                seen.add(fp);following,lr=struct.unpack_from('<2Q',data,fp-sp)
                frames.append(address(lr))
                if following<=fp:break
                fp=following
            row.update(stack_bytes=len(data),callers=frames)
        rows.append(row)
    result={k:sample[k] for k in ('format_version','pid','sample_index','capture_epoch','task_threads_result','thread_count','thread_suspension_performed')}
    result['threads']=rows
    path.with_name(path.stem+'.decoded.json').write_text(json.dumps(result,indent=2))
    return result
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('snapshots',nargs='+');a=p.parse_args()
    results=sorted((decode(n) for n in a.snapshots),key=lambda x:x['capture_epoch'])
    previous={}
    for result in results:
        for row in result['threads']:
            prior=previous.get((result['pid'],row['thread_id']))
            if prior:
                row['cpu_us_since_previous']=row['user_us']+row['system_us']-prior[1]
                row['elapsed_seconds_since_previous']=result['capture_epoch']-prior[0]
            previous[(result['pid'],row['thread_id'])]=(result['capture_epoch'],row['user_us']+row['system_us'])
        print(json.dumps(result,indent=2))
if __name__=='__main__':main()
