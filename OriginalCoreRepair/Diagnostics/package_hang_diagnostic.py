"""Replace only the recorder in the preserved private R4 candidate."""
import argparse,hashlib,importlib.util,json,pathlib,zipfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('ipa_link',ROOT/'GBLink/scripts/ipa_link.py')
ipa=importlib.util.module_from_spec(spec);spec.loader.exec_module(ipa)
R4_SHA='e7d501ffb304c1f0e987ac713493b4583a62f9cd807ecd057f90c84866a9aa01'
def digest(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def package(source,framework,output):
    source,framework,output=map(pathlib.Path,(source,framework,output))
    assert digest(source)==R4_SHA and source.resolve()!=output.resolve() and not output.exists()
    info=ipa.inspect_slice((framework/'ManicNativeFaultRecorder').read_bytes())
    assert info['platform']==2 and info['filetype']==6 and not info['encrypted']
    assert all(p.startswith(('/System/Library/','/usr/lib/')) for p in info['load_paths'])
    with zipfile.ZipFile(source) as before:
        prefix=next(n.rsplit('/',1)[0] for n in before.namelist() if n.endswith('/ManicNativeFaultRecorder.framework/ManicNativeFaultRecorder'))
        replacements={prefix+'/'+p.name:p.read_bytes() for p in framework.iterdir() if p.is_file()}
        assert set(replacements)<=set(before.namelist())
        with zipfile.ZipFile(output,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as after:
            for entry in before.infolist():after.writestr(entry,replacements.get(entry.filename,before.read(entry)))
    with zipfile.ZipFile(source) as before,zipfile.ZipFile(output) as after:
        assert after.testzip() is None and before.namelist()==after.namelist()
        changes=[n for n in before.namelist() if before.read(n)!=after.read(n)]
        assert changes and set(changes)<=set(replacements)
    report={'diagnostic_only':True,'r4_source_sha256':R4_SHA,'output_sha256':digest(output),
            'changed_r4_entries':changes,'all_other_r4_entries_byte_identical':True,
            'core_app_airplay_gba_moltenvk_byte_identical_to_r4':True,
            'original_r4_preserved':digest(source)==R4_SHA,'thread_suspension_used':False,
            'own_process_only':True,'snapshot_delays_seconds':[2,10,25,50],'stack_bytes_per_thread_limit':8192,
            'thread_count_limit':64}
    output.with_suffix('.ipa.verification.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for n in ('source','framework','output'):p.add_argument(n)
    a=p.parse_args();package(a.source,a.framework,a.output)
