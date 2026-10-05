"""Package a distinct FastInterp core beside every exact Downloads baseline component.

Source-built executable is necessary for the explicit Core Select entry. Fail
closed on archive preservation, injection activation or imported framework ABI.
Never install, sign, replace an existing output, or touch game/save inputs.
"""
import argparse, copy, hashlib, json, pathlib, plistlib, struct, zipfile
import baseline_audit as baseline
import macho_dependencies as dependency

ipa = baseline.ipa
NAME = 'azahar-fastinterp.libretro'
IDENTITY = '@rpath/' + NAME + '.framework/' + NAME

def thin(data):
    offset, size = ipa.slices(data)
    return data[offset:offset + size]

def identifier(data):
    for cmd,pos,size in dependency.commands(thin(data)):
        if cmd == 0xD:
            start = struct.unpack_from('<I',thin(data),pos + 8)[0]
            return thin(data)[pos + start:pos + size].split(b'\0',1)[0].decode()
    return None

def validate_core(core):
    info = ipa.inspect_slice(thin(core))
    if info['encrypted'] or info['filetype'] != 6 or info['platform'] != 2:
        raise ValueError('New core must be ordinary physical-iOS arm64 dylib')
    if identifier(core) != IDENTITY:
        raise ValueError('New core requires its distinct framework install identity')
    required = {'_retro_api_version', '_retro_run', '_retro_serialize', '_retro_unserialize',
                '_retro_azahar_set_keyboard_callback', '_retro_azahar_keyboard_input',
                '_retro_azahar_install_cia', '_retro_azahar_extension_version',
                '_retro_azahar_load_amiibo', '_retro_azahar_is_searching_amiibo',
                '_retro_azahar_remove_amiibo', '_retro_azahar_cpu_backend',
                '_retro_azahar_fastinterp_required'}
    missing = required - dependency.exports(thin(core))
    if missing: raise ValueError('Missing required core ABI: ' + str(sorted(missing)))
    if b'Azahar FastInterp' not in core or b'FastInterp ARM interpreter created for core' not in core:
        raise ValueError('Missing actual upstream FastInterp variant code')
    return info

def framework_binary_map(archive, audit):
    return {name:thin(archive.read(item['path'])) for name,item in audit['frameworks'].items()}

def inject_existing(main, load_paths):
    original_path = ipa.LOAD_PATH
    try:
        for path in load_paths:
            if path not in ipa.inspect_slice(thin(main))['load_paths']:
                ipa.LOAD_PATH = path
                main = ipa.patch_macho(main)
    finally: ipa.LOAD_PATH = original_path
    return main

def verify(source, output, report, expected_main=None, expected_core=None):
    """Reopen the completed output and audit all entries independently of ZIP writing."""
    audited = baseline.audit(source)
    with zipfile.ZipFile(source) as old, zipfile.ZipFile(output) as new:
        _, plist_path, app_info, exe_path, main, main_info = ipa.app_info(new)
        old_names = set(audited['entries'])
        new_entries = ipa.checked_entries(new)
        new_names = {entry.filename for entry in new_entries}
        root = exe_path.rsplit('/',1)[0]
        core_prefix = root + '/Frameworks/' + NAME + '.framework/'
        additions = {core_prefix + NAME, core_prefix + 'Info.plist'}
        if new_names != old_names | additions:
            raise ValueError('Unexpected removed or additional archive entries')
        mismatches = [name for name,value in audited['entries'].items()
                      if name != exe_path and baseline.digest(new.read(name)) != value]
        if mismatches: raise ValueError('Existing payload changed: ' + str(mismatches))
        if new.testzip() is not None: raise ValueError('Output ZIP CRC failure')
        if new.read(plist_path) != old.read(plist_path):
            raise ValueError('Baseline app identity/activation flags changed')
        if main_info['encrypted'] or main_info['platform'] != 2:
            raise ValueError('New app must target physical iOS without encryption')
        old_injections = [c['direct_load_command'] for c in audited['activation_components'].values()
                          if 'direct_load_command' in c]
        if [p for p in main_info['load_paths'] if p in old_injections] != old_injections:
            raise ValueError('Baseline injection order or activation changed')
        for path in audited['main_load_paths']:
            if path.startswith(('@rpath/','@executable_path/')) and path not in main_info['load_paths']:
                raise ValueError('Existing embedded dependency dropped: ' + path)
        frameworks = framework_binary_map(old, audited)
        abi = dependency.check_embedded_imports(thin(main),frameworks)
        core = new.read(core_prefix + NAME)
        core_info = validate_core(core)
        core_abi = dependency.check_embedded_imports(thin(core),frameworks)
        if expected_main is not None and main != expected_main: raise ValueError('Written app binary mismatch')
        if expected_core is not None and core != expected_core: raise ValueError('Written core binary mismatch')
        plist = plistlib.loads(new.read(core_prefix + 'Info.plist'))
        if plist.get('CFBundleExecutable') != NAME or plist.get('CFBundlePackageType') != 'FMWK':
            raise ValueError('Incorrect new framework metadata')
        result = {
            'baseline_path':str(source), 'baseline_sha256':baseline.EXPECTED,
            'output_path':str(output), 'output_sha256':baseline.file_digest(pathlib.Path(output)),
            'output_bytes':pathlib.Path(output).stat().st_size,
            'existing_entries_preserved_byte_for_byte':len(old_names) - 1,
            'replaced_entries':[exe_path], 'new_entries':sorted(additions),
            'bundle_identifier':app_info['CFBundleIdentifier'],
            'app_Info_plist_byte_identical':True, 'original_baseline_preserved':True,
            'old_Azahar_DS_R6_gpSP_AirPlay_plugin_resources_preserved':True,
            'existing_activation_components':audited['activation_components'],
            'restored_direct_injections':old_injections,
            'new_main_sha256':baseline.digest(main),
            'new_core_sha256':baseline.digest(core),
            'new_main_load_paths':main_info['load_paths'],
            'embedded_framework_import_ABI':abi,
            'new_core_import_ABI':core_abi,
            'new_core_identity':identifier(core),
            'new_core_iPhoneOS_platform':core_info['platform'],
            'archive_CRC_passed':True,
            'coverage': {
                'archive_and_static_activation_gates':True,
                'signing_and_installation_performed':False,
                'new_phone_feature_acceptance':False,
                'actual_game_scene_verified':False,
                'same_game_backend_speedup_measured':False,
                'original_feature_acceptance_applies_to_preserved_components':True,
                'candidate_status':'Experimental substantive upstream core; first-house freeze unproven'
            }
        }
    with pathlib.Path(report).open('x') as f: json.dump(result,f,indent=2)
    return result

def package(source, executable, core_path, framework_plist, output, report):
    source, output, report = map(pathlib.Path,(source,output,report))
    if output.exists() or report.exists() or source.resolve() == output.resolve():
        raise ValueError('All outputs must be new; preserve original IPA')
    audited = baseline.audit(source)
    main = pathlib.Path(executable).read_bytes()
    parsed = ipa.inspect_slice(thin(main))
    if parsed['filetype'] != 2 or parsed['platform'] != 2 or parsed['encrypted']:
        raise ValueError('App input must be a physical-iOS arm64 source-built executable')
    if b'Azahar FastInterp' not in main or b'azahar-fastinterp.libretro' not in main:
        raise ValueError('Executable lacks compiled separate FastInterp selector')
    required_loads = [c['direct_load_command'] for c in audited['activation_components'].values()
                      if 'direct_load_command' in c]
    main = inject_existing(main,required_loads)
    core = pathlib.Path(core_path).read_bytes()
    validate_core(core)
    metadata = pathlib.Path(framework_plist).read_bytes()
    parsed_plist = plistlib.loads(metadata)
    if parsed_plist.get('CFBundleExecutable') != NAME:
        raise ValueError('Separate FastInterp framework metadata required')
    with zipfile.ZipFile(source) as old:
        binaries = framework_binary_map(old,audited)
        dependency.check_embedded_imports(thin(main),binaries)
        dependency.check_embedded_imports(thin(core),binaries)
        root = audited['executable_path'].rsplit('/',1)[0]
        prefix = root + '/Frameworks/' + NAME + '.framework/'
        with zipfile.ZipFile(output,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as new:
            for item in ipa.checked_entries(old):
                entry = copy.copy(item)
                data = main if item.filename == audited['executable_path'] else old.read(item)
                new.writestr(entry,data)
            for name,data,mode in ((NAME,core,0o100755),('Info.plist',metadata,0o100644)):
                entry = zipfile.ZipInfo(prefix + name)
                entry.create_system = 3
                entry.external_attr = mode << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                new.writestr(entry,data)
    return verify(source,output,report,main,core)

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('baseline');p.add_argument('--executable',required=True)
    p.add_argument('--core',required=True);p.add_argument('--framework-plist',required=True)
    p.add_argument('--output',required=True);p.add_argument('--report',required=True)
    args=p.parse_args()
    result=package(args.baseline,args.executable,args.core,args.framework_plist,args.output,args.report)
    print(json.dumps({key:result[key] for key in (
        'output_path','output_sha256','existing_entries_preserved_byte_for_byte',
        'restored_direct_injections','new_core_identity','archive_CRC_passed')}))
