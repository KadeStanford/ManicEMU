"""Create a new unsigned DS candidate from the exact combined R7 baseline.

Local files only. Refuse overwritten outputs, unexpected frameworks, private
inputs and content changes outside the DS binaries/discovery plist settings.
"""
import argparse,hashlib,importlib.util,json,pathlib,plistlib,struct,zipfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('ipa_link',ROOT/'GBLink/scripts/ipa_link.py')
ipa=importlib.util.module_from_spec(spec);spec.loader.exec_module(ipa)
BASELINE='26b2f6fef67e390e971e2ddc62fedfc349b2c7428a7e2835c9d631d3a67384d4'
CORE_BASELINE='20b346952e860f7ca5dd2f92addcbbd8ffa3d1726c1764d3a94cebfefd05700b'
UPSTREAM='1a28e0fe2a78c9d2318f4324835ff906488299a2'
ALLOWED_FILES={'Info.plist','LICENSE','melonDSDS-LICENSE','SOURCE'}
def digest(data):return hashlib.sha256(data).hexdigest()
def symbols(b):
    pos=32
    for _ in range(struct.unpack_from('<I',b,16)[0]):
        command,length=struct.unpack_from('<II',b,pos)
        if command==2:
            off,count,strings,size=struct.unpack_from('<4I',b,pos+8);result=set()
            for i in range(count):
                index,kind,_,_,_=struct.unpack_from('<IBBHQ',b,off+i*16)
                if kind&1 and kind&14 and not kind&224:
                    result.add(b[strings+index:b.index(0,strings+index,strings+size)].decode())
            return result
        pos+=length
    raise ValueError('Expected exported symbol table')
def frameworks(build):
    manifest=json.loads((build/'build-manifest.json').read_text());result={};metadata={}
    if manifest['sdk']!='iphoneos' or manifest['upstream_commit']!=UPSTREAM or manifest['queue_reset_marker']!=2 or manifest['private_game_inputs_used'] or not manifest['manic_custom_screen_layout_preserved']:
        raise ValueError('Physical iOS Manic fork build and reset-capability evidence required')
    for name in ('DSOriginal','melondsds.libretro'):
        folder=build/(name+'.framework');files={p.relative_to(folder).as_posix():p.read_bytes() for p in folder.rglob('*') if p.is_file()}
        if set(files)!=ALLOWED_FILES|{name}:raise ValueError('Unexpected framework files: '+str(set(files)))
        info=ipa.inspect_slice(files[name]);exports=symbols(files[name])
        if info['platform']!=2 or info['filetype']!=6 or info['encrypted'] or any(not p.startswith(('/System/Library/','/usr/lib/')) for p in info['load_paths']):raise ValueError('Invalid physical iOS framework dependency/platform')
        if digest(files[name])!=manifest['framework_sha256'][name]:raise ValueError('Build checksum mismatch')
        if name=='DSOriginal' and ('_manic_ds_protocol_revision' not in exports or b'melonds_custom_layout_config' not in files[name]):raise ValueError('Missing lifecycle reset marker or Manic screen layouts')
        result[name]=files;metadata[name]=dict(sha256=digest(files[name]),macho=info,export_count=len(exports))
    return manifest,result,metadata
def package(source,build,output,audit):
    for p in (output,audit):
        if p.exists():raise ValueError('Output already exists; originals are never overwritten: '+str(p))
    if source.resolve()==output.resolve() or digest(source.read_bytes())!=BASELINE:raise ValueError('Exact combined R7 baseline required')
    manifest,files,metadata=frameworks(build)
    with zipfile.ZipFile(source) as before:
        entries,plist_path,info,binary_path,binary,binary_info=ipa.app_info(before)
        app=plist_path.rsplit('/',1)[0];ds=app+'/Frameworks/melondsds.libretro.framework/'
        if digest(before.read(ds+'melondsds.libretro'))!=CORE_BASELINE:raise ValueError('Unexpected original DS engine')
        required={s for s in symbols(before.read(ds+'melondsds.libretro')) if s.startswith('_retro_')}
        if required-symbols(files['melondsds.libretro']['melondsds.libretro']):raise ValueError('DS wrapper loses frontend ABI exports')
        if required-symbols(files['DSOriginal']['DSOriginal']):raise ValueError('DS engine loses frontend ABI exports')
        updated=dict(info);services=list(info.get('NSBonjourServices',[]))
        if '_manic-ds._tcp' not in services:services.append('_manic-ds._tcp')
        updated['NSBonjourServices']=services
        if not updated.get('NSLocalNetworkUsageDescription'):updated['NSLocalNetworkUsageDescription']='Find nearby players for local game trading and battles.'
        replacements={ds+'melondsds.libretro':files['melondsds.libretro']['melondsds.libretro'],plist_path:plistlib.dumps(updated,fmt=plistlib.FMT_BINARY,sort_keys=False)}
        added={}
        old_names={entry.filename for entry in entries}
        for name,contents in files.items():
            prefix=app+'/Frameworks/'+name+'.framework/'
            for relative,data in contents.items():
                if name=='melondsds.libretro' and relative in ('Info.plist','melondsds.libretro'):continue
                target=prefix+relative
                if target in old_names:raise ValueError('Unexpected preexisting DS file: '+target)
                added[target]=data
        # Preserve the original DS wrapper bundle identity/info; its filename
        # and complete public libretro ABI remain the frontend's selection.
        old_hashes={entry.filename:digest(before.read(entry)) for entry in entries}
        with zipfile.ZipFile(output,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as after:
            for entry in entries:after.writestr(entry,replacements.get(entry.filename,before.read(entry)))
            for name,data in added.items():after.writestr(name,data)
    with zipfile.ZipFile(output) as after:
        if after.testzip():raise ValueError('Archive CRC failure')
        new_hashes={entry.filename:digest(after.read(entry)) for entry in ipa.checked_entries(after)}
        if set(new_hashes)!=set(old_hashes)|set(added):raise ValueError('Unexpected archive entries')
        changed=[]
        for name,old in old_hashes.items():
            expected=digest(replacements[name]) if name in replacements else old
            if new_hashes[name]!=expected:raise ValueError('Unexpected content change: '+name)
            if new_hashes[name]!=old:changed.append(name)
        packaged=plistlib.loads(after.read(plist_path))
        permitted={'NSBonjourServices','NSLocalNetworkUsageDescription'}
        if {k:v for k,v in packaged.items() if k not in permitted}!={k:v for k,v in info.items() if k not in permitted}:raise ValueError('App identity/settings changed')
        if new_hashes[binary_path]!=old_hashes[binary_path]:raise ValueError('App executable changed')
    if digest(source.read_bytes())!=BASELINE:raise ValueError('Baseline changed during packaging')
    preserved={name:sha for name,sha in old_hashes.items() if name==binary_path or any('/'+n+'.framework/' in name for n in ('gpsp.libretro','ManicGBLink','azahar.libretro','ManicAirPlaySplit','Libretro','MoltenVK','desmume.libretro'))}
    report=dict(output=str(output.resolve()),output_sha256=digest(output.read_bytes()),output_bytes=output.stat().st_size,
        baseline_r7_sha256=BASELINE,baseline_preserved=True,archive_crc_passed=True,
        changed_r7_entries=changed,added_entries=sorted(added),deleted_entries=[],
        all_other_r7_entries_byte_identical=True,preserved_entry_sha256=preserved,
        app_identity_and_executable_preserved=True,assets_preserved=True,gba_v07_byte_preserved=True,
        azahar_r5_vulkan_vapecord_byte_preserved=True,airplay_r7_byte_preserved=True,
        user_saves_or_settings_modified=False,private_games_firmware_saves_plugins_included=False,
        framework_metadata=metadata,build_manifest=manifest,
        actual_game_trade_save_reload_verified=False,actual_game_battle_verified=False,physical_iPhone_verified=False,
        limitations=['Actual game modes/pairings unverified','Gen 5 cartridge infrared absent','Four-player/Download Play absent','DS local timing on phone Wi-Fi unverified','DeSmuME has no DS nearby bridge','AirPlay quality/latency retains existing validation gap'],
        signing='Unsigned candidate; existing sideload tool must re-sign app and all embedded frameworks')
    audit.write_text(json.dumps(report,indent=2),encoding='utf-8');return report
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('baseline','build','output','audit'):parser.add_argument(name,type=pathlib.Path)
    args=parser.parse_args();result=package(args.baseline,args.build,args.output,args.audit)
    print(json.dumps({k:result[k] for k in ('output','output_sha256','output_bytes','changed_r7_entries','added_entries','all_other_r7_entries_byte_identical')},indent=2))
