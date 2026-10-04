"""Package only the verified original-core fill repair into private Trace2.

Keep R3 AirPlay and every GBA/core/asset entry unchanged except Azahar and
the already verified recorder load command. Originals and saves untouched.
"""
import argparse,hashlib,json,pathlib,zipfile
from repair_vulkan_fill import patch_core
R3_SHA='9c1a2260c07a02b82b014bf0dbd8b924e582ef406f9cd32b2bd41ca63d02ffc2'
TRACE_SHA='562588e582d73071154e467786c40ea08690ab078ea9c220284e18e0a4337c2d'
def digest(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def package(r3,trace,core,output):
    r3,trace,core,output=map(pathlib.Path,(r3,trace,core,output))
    assert digest(r3)==R3_SHA and digest(trace)==TRACE_SHA
    assert not output.exists() and output.resolve() not in (r3.resolve(),trace.resolve(),core.resolve())
    replacement=core.read_bytes()
    with zipfile.ZipFile(r3) as baseline,zipfile.ZipFile(trace) as source:
        entry=next(n for n in baseline.namelist() if n.endswith('/azahar.libretro.framework/azahar.libretro'))
        assert replacement==patch_core(baseline.read(entry))
        with zipfile.ZipFile(output,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as target:
            for info in source.infolist():target.writestr(info,replacement if info.filename==entry else source.read(info))
    with zipfile.ZipFile(r3) as baseline,zipfile.ZipFile(trace) as trace_zip,zipfile.ZipFile(output) as target:
        assert target.testzip() is None
        trace_changes=[n for n in trace_zip.namelist() if trace_zip.read(n)!=target.read(n)]
        assert trace_changes==[entry]
        changes=[n for n in baseline.namelist() if baseline.read(n)!=target.read(n)]
        expected=[entry,next(n for n in baseline.namelist() if n.endswith('/ManicEmuSideload'))]
        assert sorted(changes)==sorted(expected)
        added=set(target.namelist())-set(baseline.namelist())
        assert len(added)==3 and all('/ManicNativeFaultRecorder.framework/' in n for n in added)
    report={'candidate_only':True,'source_r3_sha256':R3_SHA,'source_trace2_sha256':TRACE_SHA,
            'output_sha256':digest(output),'core_sha256':hashlib.sha256(replacement).hexdigest(),
            'changed_r3_entries':changes,'trace2_changed_entries':trace_changes,
            'airplay_and_all_gba_entries_byte_identical_to_r3':True,'all_other_r3_entries_byte_identical':True,
            'original_inputs_preserved':digest(r3)==R3_SHA and digest(trace)==TRACE_SHA,
            'physical_vulkan_boot_and_plugin_verified':False,'private_fault_recorder_retained':True}
    output.with_suffix('.ipa.verification.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('r3','trace2','core','output'):p.add_argument(name)
    a=p.parse_args();package(a.r3,a.trace2,a.core,a.output)
