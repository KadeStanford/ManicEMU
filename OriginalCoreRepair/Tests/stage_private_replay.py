"""Prepare exclusive local replay copies; never upload, execute or touch live saves."""
import argparse,hashlib,json,pathlib,stat,struct,zipfile

CORES={
 '3995bab1659c74979fa81226e4961fc7634d30a324ba9b97eb0eb50b5dc892e4':'FB2',
 '15d9b1e984155a72d1f1ef5f2dadc014b3664b5c4d74b71ea8603503f491009a':'FB3',
 '3e7f1f1fedcc5bbbc19a9d42123934f132f43600a31cc927f6eca29ba73b5df3':'FB2-monitor-clear',
 '7de82460deb3da6aeda143e8ddf0fe8e2bd36646808cf4ec0de9ca3d333dcb9a':'FB3-monitor-clear',
}
host_manifest=pathlib.Path(__file__).with_name('reviewed_public_replay_edits.json')
if host_manifest.exists():
    for label,spec in json.loads(host_manifest.read_text())['variants'].items():
        CORES[spec['public_host_output_sha256']]='host-'+label
TITLE='sdmc/Nintendo 3DS/'+'0'*32+'/'+'0'*32+'/title/00040000/00198e00/data/00000001/'
SAVE_NAMES={'garden_plus.dat','exhibition.dat','amiibo.dat','friend1.dat','updated.dat'}

def digest(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def read_save(path):
    """Strict normal-title-save ZIP, bounded and portable; not a save-state loader."""
    records={}
    with zipfile.ZipFile(path) as z:
        if len(z.infolist())>32:raise ValueError('Too many save entries')
        for i in z.infolist():
            if '\\' in i.filename or i.flag_bits&1 or stat.S_ISLNK(i.external_attr>>16):raise ValueError('Unsafe save record')
            if i.is_dir():
                if not (TITLE.startswith(i.filename) or i.filename==TITLE):raise ValueError('Unexpected save directory')
                continue
            if not i.filename.startswith(TITLE) or i.filename[len(TITLE):] not in SAVE_NAMES:raise ValueError('Unexpected title save path')
            if i.filename in records or i.file_size>16*1024*1024:raise ValueError('Duplicate or oversized save')
            records[i.filename]=z.read(i) # Includes ZIP CRC verification.
        if sum(map(len,records.values()))>32*1024*1024:raise ValueError('Oversized save archive')
        if {p[len(TITLE):] for p in records}!=SAVE_NAMES:raise ValueError('Incomplete normal title save')
    return records

def copy_exclusive(source,target):
    target.parent.mkdir(parents=True,exist_ok=True)
    with source.open('rb') as src,target.open('xb') as dst:
        while chunk:=src.read(4*1024*1024):dst.write(chunk)
    if digest(source)!=digest(target):raise ValueError('Input copy verification failed')

def stage(game,save,plugin,core,sandbox,game_sha256,save_sha256,plugin_sha256,macos=False,assets=None):
    sources=(game,save,plugin,core)
    expected=(game_sha256,save_sha256,plugin_sha256,None)
    hashes=[digest(p) for p in sources]
    if any(want and got!=want for want,got in zip(expected,hashes)):raise ValueError('Input hash mismatch')
    if hashes[3] not in CORES:raise ValueError('Unreviewed core')
    records=read_save(save)
    asset_files=[]
    if assets:
        if not assets.is_dir() or assets.is_symlink():raise ValueError('Invalid asset directory')
        for entry in assets.rglob('*'):
            if entry.is_symlink():raise ValueError('Symlink in assets')
            if entry.is_file():asset_files.append(entry)
        if len(asset_files)>4096 or sum(p.stat().st_size for p in asset_files)>64*1024*1024:raise ValueError('Oversized assets')
    resolved=sandbox.resolve()
    if any(p.resolve()==resolved or p.resolve().is_relative_to(resolved) for p in sources):raise ValueError('Sandbox overlaps inputs')
    if assets and (resolved.is_relative_to(assets.resolve()) or assets.resolve().is_relative_to(resolved)):raise ValueError('Sandbox overlaps assets')
    sandbox.mkdir(parents=False,exist_ok=False)
    data=sandbox/'native-data';resources=sandbox/'native-resources'
    copy_exclusive(game,data/'input/game.cxi')
    for prefix in ('','3DS/','citra/'):
        copy_exclusive(plugin,data/(prefix+'sdmc/luma/plugins/0004000000198E00/Vapecord_Public.3gx'))
        for asset in asset_files:copy_exclusive(asset,data/(prefix+'sdmc/Vapecord')/asset.relative_to(assets))
        for name,contents in records.items():
            target=data/(prefix+name);target.parent.mkdir(parents=True,exist_ok=True)
            with target.open('xb') as f:f.write(contents)
    copy_exclusive(core,resources/'game-probe-core.dylib')
    if macos:
        target=resources/'game-probe-core.dylib';binary=bytearray(target.read_bytes())
        if struct.unpack_from('<I',binary)[0]!=0xfeedfacf:raise ValueError('Expected thin MachO')
        cursor=32;found=0
        for _ in range(struct.unpack_from('<I',binary,16)[0]):
            cmd,size=struct.unpack_from('<II',binary,cursor)
            if cmd==0x32:
                if struct.unpack_from('<I',binary,cursor+8)[0]!=2:raise ValueError('Expected iOS input platform')
                struct.pack_into('<I',binary,cursor+8,1);found+=1
            cursor+=size
        if found!=1:raise ValueError('Expected one build version command')
        target.write_bytes(binary) # Only newly made sandbox copy; needs ad-hoc signing on macOS.
    if [digest(p) for p in sources]!=hashes:raise ValueError('Original input changed')
    result={'core_variant':CORES[hashes[3]],'original_input_hashes':dict(zip(('game','normal_title_save','plugin','core'),hashes)),
        'game_copy_bytes':game.stat().st_size,'normal_title_save_files':len(records),'save_state_loaded':False,
        'plugin_asset_files_copied':len(asset_files),'macOS_platform_conversion_on_copy_only':macos,
        'original_inputs_unchanged':True,'network_or_phone_actions':False,'Apple_execution_attempted':False,
        'Isabelle_scene_passed_verified':False}
    with (sandbox/'private-staging-audit.json').open('x') as f:json.dump(result,f,indent=2)
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for key in ('game','save','plugin','core','sandbox'):p.add_argument('--'+key,type=pathlib.Path,required=True)
    for key in ('game','save','plugin'):p.add_argument('--'+key+'-sha256',required=True)
    p.add_argument('--macos-host-copy',action='store_true');p.add_argument('--plugin-assets',type=pathlib.Path);a=p.parse_args()
    result=stage(a.game,a.save,a.plugin,a.core,a.sandbox,a.game_sha256,a.save_sha256,a.plugin_sha256,a.macos_host_copy,a.plugin_assets)
    print(json.dumps({k:result[k] for k in ('core_variant','normal_title_save_files','original_inputs_unchanged','Apple_execution_attempted')}))
