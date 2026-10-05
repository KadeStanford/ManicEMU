"""Reuse approved transport and authenticated evidence for one matched core comparison.

Requires the separately completed secure transfer handoff. Contains no credentials
or URLs. This module never mutates repository secrets or original input files.
"""
import argparse, hashlib, json, os, pathlib, struct, sys

HELPERS=pathlib.Path(__file__).resolve().parents[2]/'OriginalCoreRepair/Tests'
sys.path.insert(0,str(HELPERS))
import private_house_ci as ci
import stage_private_replay as staging

original_config=ci.config
def config():
    if not os.environ.get('PRIVATE_HOUSE_TRANSFERS'):
        raise RuntimeError('Fresh approved secure transfer handoff required')
    result=original_config()
    if result.get('game_sha256')!='9fcd23afadf099fdda861a6050db39701e4fb4643c2be141d70440a7615a0d0b':
        raise RuntimeError('Expected original game identity required')
    if result.get('save',{}).get('sha256')!='8947461b462608fa7e96f7b4c13d1fcb1edebdd30cd239b7160c15b7d54e967e':
        raise RuntimeError('Expected original normal-save identity required')
    return result
ci.config=config

original_stage=staging.stage
def stage(game,save,plugin,core,sandbox,game_sha256,save_sha256,plugin_sha256,macos=False,assets=None):
    expected=os.environ.get('MANIC_EXPECTED_HOST_CORE_SHA256','')
    if len(expected)!=64 or any(c not in '0123456789abcdef' for c in expected):
        raise RuntimeError('Reviewed source-build digest required')
    if staging.digest(core)!=expected:
        raise RuntimeError('Source-build core identity mismatch')
    data=core.read_bytes()
    if struct.unpack_from('<I',data)[0]!=0xfeedfacf:
        raise RuntimeError('Expected native thin Mach-O source-build core')
    cursor=32;platforms=[]
    for _ in range(struct.unpack_from('<I',data,16)[0]):
        command,size=struct.unpack_from('<II',data,cursor)
        if size<8 or cursor+size>len(data):raise RuntimeError('Invalid core load command')
        if command==0x32:platforms.append(struct.unpack_from('<I',data,cursor+8)[0])
        cursor+=size
    if platforms!=[1]:raise RuntimeError('Expected actual macOS build; no platform conversion permitted')
    staging.CORES[expected]='official-source-with-selectable-DynCom-and-FastInterp'
    return original_stage(game,save,plugin,core,sandbox,game_sha256,save_sha256,plugin_sha256,False,assets)
staging.stage=stage

def seal():
    ci.seal()
    output=ci.ROOT/'deliverables'
    state=ci.ROOT/'case/native-data/game-probe.json'
    summary={'Isabelle_scene_passed_verified':False,'physical_phone_FPS_verified':False}
    if state.is_file():
        record=json.loads(state.read_text())
        for key in ('retro_run_thread_cpu_seconds_total','retro_run_thread_cpu_seconds_maximum'):
            value=record.get(key)
            if isinstance(value,(int,float)) and 0<=value<=1000:summary[key]=value
        backend=record.get('actual_cpu_backend')
        if backend in (0,1,2,3):summary['actual_cpu_backend']=backend
        for key in ('backend_selection_mismatch','uses_preserved_binary_offsets'):
            if isinstance(record.get(key),bool):summary[key]=record[key]
        for key in ('retro_run_wall_histogram','retro_run_thread_cpu_histogram'):
            values=record.get(key)
            if isinstance(values,list) and len(values)==8 and all(type(v)==int and 0<=v<=12000 for v in values):
                summary[key]=values
    (output/'comparison-summary.json').write_text(json.dumps(summary,indent=2,allow_nan=False))
    if sum(p.stat().st_size for p in output.iterdir() if p.is_file())>8*1024*1024:
        raise RuntimeError('Eight MiB total per-job evidence limit exceeded')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=('fetch','seal','cleanup'))
    args=p.parse_args()
    {'fetch':ci.fetch,'seal':seal,'cleanup':ci.cleanup}[args.action]()
