"""Audit the exact preserved combined IPA; no modifications or installation."""
import hashlib,importlib.util,json,pathlib,plistlib,sys,zipfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('ipa_link',ROOT/'GBLink/scripts/ipa_link.py')
ipa=importlib.util.module_from_spec(spec);spec.loader.exec_module(ipa)
EXPECTED='6a2e3c999bd26c0529f5d04c512caa32c938cd243ed68474c1cb50d0d20ea860'
def digest(data):return hashlib.sha256(data).hexdigest()
def file_digest(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def inspect_binary(binary):
    start,size=ipa.slices(binary)
    return ipa.inspect_slice(binary[start:start+size])
def audit(path):
    path=pathlib.Path(path)
    if file_digest(path)!=EXPECTED:raise ValueError('Exact user-selected Downloads FB3 baseline required')
    with zipfile.ZipFile(path) as z:
        entries,info_path,info,exe_path,exe,exe_info=ipa.app_info(z)
        root=info_path.rsplit('/',1)[0]
        frameworks={}
        for entry in entries:
            name=entry.filename
            if name.startswith(root+'/Frameworks/') and '.framework/' in name:
                folder,relative=name.split('.framework/',1)
                basename=folder.rsplit('/',1)[1]
                if relative==basename:
                    data=z.read(entry)
                    try:parsed=inspect_binary(data)
                    except ValueError:continue
                    frameworks[basename]={'path':name,'sha256':digest(data),'load_paths':parsed['load_paths'],'platform':parsed['platform']}
        activations={}
        for name in ('ManicGBLink','ManicAirPlaySplit','ManicAzaharStabilityRecorder'):
            expected='@executable_path/Frameworks/'+name+'.framework/'+name
            if name not in frameworks or expected not in exe_info['load_paths']:
                raise ValueError('Missing existing activation component '+name)
            activations[name]={'embedded_binary_sha256':frameworks[name]['sha256'],'direct_load_command':expected}
        if not info.get('MASInjectAirPlaySplit'):raise ValueError('Baseline AirPlay activation flag missing')
        if not info.get('MGLInjectTrade'):raise ValueError('Baseline GBA trade activation flag missing')
        if 'gpsp.libretro' not in frameworks or 'melondsds.libretro' not in frameworks or 'Libretro' not in frameworks or 'azahar.libretro' not in frameworks:
            raise ValueError('Baseline required core/frontend absent')
        if 'DSOriginal' not in frameworks:raise ValueError('DS R6 original engine missing')
        wrapper=z.read(frameworks['melondsds.libretro']['path'])
        engine=z.read(frameworks['DSOriginal']['path'])
        if b'Frameworks/DSOriginal.framework/DSOriginal' not in wrapper:
            raise ValueError('DS R6 wrapper engine loading path missing')
        for symbol in (b'manic_ds_protocol_revision',b'manic_ds_async_radio_enable',b'manic_ds_wireless_identity'):
            if symbol not in wrapper or symbol not in engine:raise ValueError('DS R6 capability binding missing')
        activations['DS-R6']={'core_selection_index':0,'wrapper_sha256':digest(wrapper),
            'engine_sha256':digest(engine),'engine_dlopen_path':'Frameworks/DSOriginal.framework/DSOriginal',
            'protocol_and_async_radio_capability_symbols_present':True,'activation_via_selected_core':True}
        result={'baseline_path':str(path),'baseline_sha256':EXPECTED,'baseline_bytes':path.stat().st_size,
                'bundle_identifier':info['CFBundleIdentifier'],'bundle_executable':info['CFBundleExecutable'],
                'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],
                'Info_plist_sha256':digest(z.read(info_path)),'executable_path':exe_path,'main_sha256':digest(exe),
                'main_load_paths':exe_info['load_paths'],'activation_components':activations,'frameworks':frameworks,
                'entries':{i.filename:digest(z.read(i)) for i in entries},'archive_CRC_passed':z.testzip() is None,
                'original_input_preserved':file_digest(path)==EXPECTED,
                'new_runtime_execution':False,'new_UI_or_game_acceptance':False}
        if not result['archive_CRC_passed']:raise ValueError('CRC failure')
        return result
if __name__=='__main__':
    data=audit(sys.argv[1]);out=pathlib.Path(sys.argv[2])
    with out.open('x') as f:json.dump(data,f,indent=2)
    print(json.dumps({k:data[k] for k in ('baseline_sha256','baseline_bytes','bundle_identifier','version','build','archive_CRC_passed','original_input_preserved')}))
    print('Confirmed embedded and directly loaded:',', '.join(data['activation_components']))
