"""Private Apple CI transport/evidence helper. Requires separate user approval."""
import argparse,hashlib,hmac,json,os,pathlib,shutil,stat,subprocess,urllib.parse,urllib.request,zipfile
ROOT=pathlib.Path(os.environ.get('RUNNER_TEMP','INVALID_RUNNER_TEMP'))/'azahar-private-house'
TRUSTED={'oaisdmntprcentralus.blob.core.windows.net','oaisdmntprsouthcentralus.blob.core.windows.net'}

def config():
    try:
        base=json.loads(os.environ['PRIVATE_INPUTS'])
        fresh=os.environ.get('PRIVATE_HOUSE_TRANSFERS')
        if not fresh:return base
        fresh=json.loads(fresh);records=fresh['transfers'];references=fresh['approved_library_ids']
        if len(records)!=5:raise ValueError('Exact approved transfer set required')
        if len(references)!=5 or len(set(references))!=5:raise ValueError('Exact approved reference set required')
        by_id={i['library_file_id']:i for i in records}
        if len(by_id)!=5:raise ValueError('Duplicate transfer identities')
        if len(base['parts'])!=3:raise ValueError('Existing game part count changed')
        for reference,item in zip(references[:3],base['parts']):
            record=by_id.pop(reference)
            if record['size_bytes']!=item['bytes']:raise ValueError('Existing part size changed')
            item['url']=record['download_url'];item['headers']=record.get('headers') or {}
        plugin=by_id.pop(references[3])
        if plugin['size_bytes']!=base['plugin']['bytes']:raise ValueError('Existing plugin size changed')
        base['plugin']['url']=plugin['download_url'];base['plugin']['headers']=plugin.get('headers') or {}
        save=by_id.pop(references[4])
        if by_id:raise ValueError('Unapproved extra transfers')
        if save['file_name']!='azahar-house-replay-temporary-save.zip' or save['size_bytes']!=2293576:raise ValueError('Unexpected normal save copy')
        save_hash=fresh['save_sha256']
        if len(save_hash)!=64 or any(c not in '0123456789abcdef' for c in save_hash):raise ValueError('Expected save digest required')
        base['save']={'url':save['download_url'],'bytes':2293576,'sha256':save_hash,'headers':save.get('headers') or {}}
        return base
    except Exception:raise RuntimeError('Approved private input configuration unavailable') from None

def download(item,target,normal_save_copy=False):
    try:
        url=urllib.parse.urlsplit(item['url'])
        allowed=TRUSTED|({'oaisdmntprkoreacentral.blob.core.windows.net'} if normal_save_copy else set())
        if url.scheme!='https' or url.hostname not in allowed:raise ValueError('Unexpected transfer service')
        size=int(item['bytes'])
        if not 0<size<=400*1024*1024:raise ValueError('Unexpected private input size')
        count=0;digest=hashlib.sha256()
        request=urllib.request.Request(item['url'],headers=item.get('headers') or {})
        with urllib.request.urlopen(request,timeout=60) as response,target.open('xb') as dst:
            if urllib.parse.urlsplit(response.geturl()).hostname not in allowed:raise ValueError('Unexpected redirect service')
            while chunk:=response.read(4*1024*1024):
                count+=len(chunk)
                if count>size:raise ValueError('Private transfer exceeds declared size')
                dst.write(chunk);digest.update(chunk)
        if count!=size or digest.hexdigest()!=item['sha256']:raise ValueError('Private input hash mismatch')
    except Exception:raise RuntimeError('Private transfer failed or input failed verification; URLs suppressed') from None

def fetch():
    c=config()
    if 'save' not in c:raise RuntimeError('Approved normal-save transfer is required; no fallback to unrelated saves')
    ROOT.mkdir(exist_ok=False);inputs=ROOT/'inputs';inputs.mkdir()
    if not 1<=len(c['parts'])<=16:raise RuntimeError('Invalid game part count')
    with (inputs/'game.cxi').open('xb') as game:
        for index,item in enumerate(c['parts']):
            part=inputs/f'game-part-{index}';download(item,part)
            with part.open('rb') as src:shutil.copyfileobj(src,game,4*1024*1024)
            part.unlink()
    with (inputs/'game.cxi').open('rb') as f:
        if hashlib.file_digest(f,'sha256').hexdigest()!=c['game_sha256']:raise RuntimeError('Game copy hash mismatch')
    download(c['save'],inputs/'normal-title-save.zip',normal_save_copy=True);download(c['plugin'],inputs/'plugin.zip')
    destination=inputs/'plugin-content';destination.mkdir()
    try:
        with zipfile.ZipFile(inputs/'plugin.zip') as z:
            if len(z.infolist())>4096 or sum(i.file_size for i in z.infolist())>64*1024*1024:raise ValueError('Oversized plugin input')
            seen=set()
            for i in z.infolist():
                name=pathlib.PurePosixPath(i.filename);target=destination/i.filename
                if '\\' in i.filename or name.is_absolute() or '..' in name.parts or stat.S_ISLNK(i.external_attr>>16) or i.flag_bits&1:
                    raise ValueError('Unsafe plugin input')
                if i.filename.casefold() in seen:raise ValueError('Duplicate plugin record')
                seen.add(i.filename.casefold())
                if not target.resolve().is_relative_to(destination.resolve()):raise ValueError('Escaping plugin path')
                if i.is_dir():target.mkdir(parents=True,exist_ok=True)
                else:
                    target.parent.mkdir(parents=True,exist_ok=True)
                    with target.open('xb') as f:f.write(z.read(i))
    except Exception:raise RuntimeError('Plugin copy validation failed; private paths suppressed') from None
    # The expected plugin location was used by the already authorized historical runner.
    plugin=destination/'sdmc/luma/plugins/0004000000198E00/Vapecord_Public.3gx'
    if not plugin.is_file():raise RuntimeError('Expected authorized plugin input absent')
    from stage_private_replay import stage,digest
    stage(inputs/'game.cxi',inputs/'normal-title-save.zip',plugin,ROOT.parent/'azahar-reviewed-house-core.dylib',ROOT/'case',
        c['game_sha256'],c['save']['sha256'],digest(plugin),True,
        destination/'sdmc/Vapecord' if (destination/'sdmc/Vapecord').is_dir() else None)

def seal():
    data=ROOT/'case/native-data';output=ROOT/'deliverables';output.mkdir(exist_ok=True)
    state=data/'game-probe.json';summary={'Isabelle_scene_passed_verified':False,'physical_phone_FPS_verified':False}
    status=ROOT/'exit-status.txt'
    if status.exists():summary['native_process_exit_status']=int(status.read_text())
    if state.exists():
        r=json.loads(state.read_text())
        for key in ('run_calls','frames','audio_sample_frames','retro_run_seconds_total','retro_run_seconds_maximum',
                    'execution_wall_seconds','replay_enabled','real_vulkan_device_created','vulkan_context_reset_returned',
                    'host_frontend_waits_GPU_every_frame'):
            if isinstance(r.get(key),(bool,int,float)):summary[key]=r[key]
        if r.get('stage') in ('completed','retro_run','retro_unload_game','load_rejected','dlopen_failed','missing_entrypoint',
                              'vulkan_initialization_failed','invalid_replay_configuration'):summary['stage']=r['stage']
    (output/'sanitized-summary.json').write_text(json.dumps(summary,indent=2,allow_nan=False))
    records=[p for name in ('game-probe.json','core-runtime.log','fatal-signal.bin') if (p:=data/name).is_file()]
    records+=list(data.glob('private-frame-*.png'))
    records+=list((data/'native-diagnostics').glob('*'))
    records += [p for p in (ROOT/'case/private-staging-audit.json',ROOT/'private-process.log',status) if p.is_file()]
    archive=ROOT/'private-evidence.zip'
    with zipfile.ZipFile(archive,'x',zipfile.ZIP_DEFLATED) as z:
        for p in records:
            if p.is_file() and not p.is_symlink():z.write(p,str(p.relative_to(ROOT)))
    if archive.stat().st_size>8*1024*1024:raise RuntimeError('Encrypted evidence upload size cap exceeded; raw evidence is not uploaded')
    password=config()['evidence_password']
    if not isinstance(password,str) or len(password)<20:raise RuntimeError('Existing private evidence password is insufficient')
    cipher=ROOT/'private-evidence.cipher';env=os.environ.copy();env.pop('PRIVATE_INPUTS',None);env['AZAHAR_EVIDENCE_PASSWORD']=password
    result=subprocess.run(['openssl','enc','-aes-256-cbc','-pbkdf2','-iter','200000','-salt',
        '-pass','env:AZAHAR_EVIDENCE_PASSWORD','-in',str(archive),'-out',str(cipher)],env=env,capture_output=True)
    if result.returncode:raise RuntimeError('Private evidence encryption failed; output suppressed')
    salt=os.urandom(16);key=hashlib.pbkdf2_hmac('sha256',password.encode(),salt,200000,32)
    body=b'AZAHAR-EVIDENCE-HMAC-V1\0'+salt+cipher.read_bytes()
    with (output/'private-evidence.authenticated.enc').open('xb') as f:f.write(body+hmac.digest(key,body,'sha256'))
    archive.unlink();cipher.unlink()
    print(json.dumps(summary,allow_nan=False))

def cleanup():
    base=pathlib.Path(os.environ['RUNNER_TEMP']).resolve();target=ROOT.resolve()
    if target.name!='azahar-private-house' or not target.is_relative_to(base) or target==base:raise RuntimeError('Cleanup boundary failed')
    if target.exists():shutil.rmtree(target)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=('fetch','seal','cleanup'));a=p.parse_args()
    {'fetch':fetch,'seal':seal,'cleanup':cleanup}[a.action]()
