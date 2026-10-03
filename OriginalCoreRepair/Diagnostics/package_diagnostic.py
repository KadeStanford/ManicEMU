"""Add only a separate optional recorder to the verified R3 private IPA."""
import argparse,hashlib,importlib.util,json,pathlib,zipfile

ROOT=pathlib.Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('ipa_link',ROOT/'GBLink/scripts/ipa_link.py')
ipa=importlib.util.module_from_spec(spec);spec.loader.exec_module(ipa)
R3='9c1a2260c07a02b82b014bf0dbd8b924e582ef406f9cd32b2bd41ca63d02ffc2'
LOAD='@executable_path/Frameworks/ManicNativeFaultRecorder.framework/ManicNativeFaultRecorder'

def package(source,framework,output):
    source,framework,output=map(pathlib.Path,(source,framework,output))
    assert hashlib.file_digest(source.open('rb'),'sha256').hexdigest()==R3
    assert not output.exists() and source.resolve()!=output.resolve()
    binary=(framework/'ManicNativeFaultRecorder').read_bytes()
    info=ipa.inspect_slice(binary)
    assert info['platform']==2 and info['filetype']==6 and not info['encrypted']
    assert all(p.startswith(('/System/Library/','/usr/lib/')) for p in info['load_paths'])
    ipa.LOAD_PATH=LOAD
    with zipfile.ZipFile(source) as before:
        entries,plist_path,plist,executable_path,executable,exe_info=ipa.app_info(before)
        assert LOAD not in exe_info['load_paths']
        patched=ipa.patch_macho(executable)
        app_root=plist_path.rsplit('/',1)[0]
        added={app_root+'/Frameworks/ManicNativeFaultRecorder.framework/'+p.relative_to(framework).as_posix():p.read_bytes()
               for p in framework.rglob('*') if p.is_file()}
        assert all(p not in before.namelist() for p in added)
        with zipfile.ZipFile(output,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as after:
            for entry in entries:after.writestr(entry,patched if entry.filename==executable_path else before.read(entry))
            for name,data in added.items():after.writestr(name,data)
    with zipfile.ZipFile(source) as before,zipfile.ZipFile(output) as after:
        assert after.testzip() is None
        differences=[n for n in before.namelist() if before.read(n)!=after.read(n)]
        assert differences==[executable_path]
        assert set(after.namelist())-set(before.namelist())==set(added)
        assert LOAD in ipa.inspect_slice(after.read(executable_path))['load_paths']
    report={'diagnostic_only':True,'source_r3_sha256':R3,'output_sha256':hashlib.file_digest(output.open('rb'),'sha256').hexdigest(),
            'changed_r3_entries':differences,'added_entries':list(added),'all_other_r3_entries_byte_identical':True,
            'airplay_core_gba_moltenvk_byte_identical_to_r3':True,'device_framework_platform_verified':True}
    output.with_suffix('.ipa.verification.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(report,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('source');p.add_argument('framework');p.add_argument('output');a=p.parse_args()
    package(a.source,a.framework,a.output)
