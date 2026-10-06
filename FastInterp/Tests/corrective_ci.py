"""Build one approved standard-runner target and keep concrete gate evidence."""
import argparse,ctypes,hashlib,json,os,pathlib,re,shutil,subprocess,sys
p=argparse.ArgumentParser();p.add_argument('--target',choices=['ios','native'],required=True);a=p.parse_args()
root=pathlib.Path.cwd();owner=root/'manic-source';src=root/'azahar-source';out=root/'deliverables';out.mkdir()
required=['retro_api_version','retro_run','retro_serialize','retro_unserialize','retro_azahar_set_keyboard_callback','retro_azahar_keyboard_input','retro_azahar_install_cia','retro_azahar_extension_version','retro_azahar_load_amiibo','retro_azahar_is_searching_amiibo','retro_azahar_remove_amiibo','retro_azahar_cpu_backend','retro_azahar_fastinterp_required','retro_azahar_storage_path']
report={'target':a.target,'source_commit':os.environ['GITHUB_SHA'],'run':os.environ['GITHUB_RUN_ID'],'private_inputs':False,'phone_scene_verified':False,'gates':{}}
def save(): (out/'build-gates.json').write_text(json.dumps(report,indent=2)+'\n')
def command(args,log=None):
    if log:
        with (out/log).open('w') as f:r=subprocess.run(args,stdout=f,stderr=subprocess.STDOUT)
        if r.returncode:raise RuntimeError(f'{log}: command exit {r.returncode}')
        return ''
    return subprocess.check_output(args,text=True,stderr=subprocess.STDOUT)
try:
    choices=[(tuple(int(n) for n in re.findall(r'\d+',q.name)),q) for q in pathlib.Path('/Applications').glob('Xcode_26*.app')]
    if not choices:raise RuntimeError('Installed Xcode 26 required')
    os.environ['DEVELOPER_DIR']=str(max(choices)[1]/'Contents/Developer')
    (out/'toolchain.txt').write_text(command(['xcodebuild','-version'])+command(['uname','-m']))
    patch=owner/'FastInterp/patches/0002-official-core-manic-integration.patch'
    provenance=json.loads((owner/'FastInterp/SOURCE-PROVENANCE.json').read_text())
    assert hashlib.sha256(patch.read_bytes()).hexdigest()==provenance['preferred_integration_patch_sha256']
    command(['git','-C',str(src),'apply',str(patch)])
    command(['git','-C',str(src),'apply',str(owner/'CorePatches/Azahar/0006-vulkan-string-format-ios15.patch')])
    exports=set((src/'src/citra_libretro/libretro.osx.def').read_text().splitlines())
    missing={'_'+s for s in required}-exports
    if missing:raise RuntimeError('Source export whitelist missing '+str(sorted(missing)))
    report['gates']['source_export_whitelist']=True
    shutil.copyfile(owner/'FastInterp/SOURCE-PROVENANCE.json',out/'SOURCE-PROVENANCE.json')
    if a.target=='ios':
        command([sys.executable,str(owner/'FastInterp/Tests/storage_paths.py'),'--source',str(src/'src/citra_libretro/core_settings.cpp'),'--compiler',command(['xcrun','-f','clang++']).strip(),'--output',str(out/'storage-parser.json')],'storage-parser.log')
        report['gates']['actual_parser_20_cases']=True
    build=root/('build-'+a.target)
    common=['-DCMAKE_OSX_ARCHITECTURES=arm64','-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0','-DENABLE_LIBRETRO=ON','-DENABLE_VULKAN=ON','-DENABLE_OPENGL=OFF','-DENABLE_LTO=OFF','-DENABLE_TESTS=OFF']
    if a.target=='ios':extra=['-G','Xcode','-DCMAKE_SYSTEM_NAME=iOS','-DCMAKE_OSX_SYSROOT=iphoneos','-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO']
    else:extra=['-G','Ninja','-DCMAKE_BUILD_TYPE=Release','-DCMAKE_CXX_FLAGS=-DMANIC_TEST_IOS_STORAGE=1']
    save();command(['cmake','-S',str(src),'-B',str(build)]+extra+common,'configure-'+a.target+'.log')
    compile_cmd=['cmake','--build',str(build),'--target','citra_libretro','--config','Release','--parallel','3']
    if a.target=='ios':compile_cmd+=['--','CODE_SIGNING_ALLOWED=NO']
    command(compile_cmd,'build-'+a.target+'.log');report['gates']['full_core_compile']=True;save()
    core=build/'bin/Release/azahar_libretro.dylib';assert core.is_file()
    original=out/('azahar-fastinterp-'+a.target+'.dylib');shutil.copyfile(core,original)
    symbols={line.split()[-1] for line in command(['nm','-gU',str(core)]).splitlines() if line.split()}
    missing={'_'+s for s in required}-symbols
    if missing:raise RuntimeError('Compiled core exports missing '+str(sorted(missing)))
    report['gates']['compiled_required_API_exports']=True
    assert 'FastInterp ARM interpreter created for core' in command(['strings',str(core)])
    variant=out/('azahar-fastinterp.libretro' if a.target=='ios' else 'azahar-fastinterp-native.libretro')
    shutil.copyfile(core,variant)
    if a.target=='ios':
        command(['install_name_tool','-id','@rpath/azahar-fastinterp.libretro.framework/azahar-fastinterp.libretro',str(variant)])
        (out/'iphoneos-abi.txt').write_text(command(['file',str(variant)])+command(['otool','-l',str(variant)])+command(['otool','-L',str(variant)]))
        report['gates']['iPhoneOS_variant_identity_written']=True
    else:
        # Basename is part of the variant contract; keep exactly the production name.
        variant.rename(out/'azahar-fastinterp.libretro');variant=out/'azahar-fastinterp.libretro'
        c=ctypes.CDLL(str(original));v=ctypes.CDLL(str(variant))
        c.retro_api_version.restype=ctypes.c_uint;c.retro_azahar_extension_version.restype=ctypes.c_uint
        assert c.retro_api_version()==1 and c.retro_azahar_extension_version()==1
        assert c.retro_azahar_cpu_backend()==0 and c.retro_azahar_fastinterp_required()==0
        assert v.retro_azahar_fastinterp_required()==1
        class Info(ctypes.Structure):
            _fields_=[('name',ctypes.c_char_p),('version',ctypes.c_char_p),('extensions',ctypes.c_char_p),('fullpath',ctypes.c_bool),('block_extract',ctypes.c_bool)]
        info=Info();v.retro_get_system_info(ctypes.byref(info));assert info.name==b'Azahar FastInterp'
        info=Info();c.retro_get_system_info(ctypes.byref(info));assert info.name==b'Azahar'
        report['gates']['native_load_API_and_variant_identity']=True;save()
        command([sys.executable,str(owner/'FastInterp/Tests/compiled_storage.py'),'--core',str(variant),'--output',str(out/'compiled-storage-routing.json')],'compiled-storage.log')
        report['gates']['compiled_core_6_routing_cases']=True
        command(['xcrun','clang++','-std=c++20','-arch','arm64','-O2','-I',str(src/'src'),str(owner/'FastInterp/Tests/boundaries.cpp'),'-o',str(out/'FastInterpBoundaries')])
        command([str(out/'FastInterpBoundaries')],'boundaries.txt');report['gates']['actual_interpreter_cache_regression']=True
    report['core_sha256']=hashlib.sha256(variant.read_bytes()).hexdigest();report['success']=True;save()
    print(json.dumps(report))
except Exception as e:
    report['success']=False;report['error']=str(e);save()
    for log in out.glob('*.log'):
        lines=log.read_text(errors='replace').splitlines()
        found=[line for line in lines if re.search(r'error:|CMake Error|FAILED:|fatal error:|Traceback|Error|Assertion',line)]
        if found:print(log.name+'\n'+'\n'.join(found[-12:]))
    raise
