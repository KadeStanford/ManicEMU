#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
build="${MANIC_STABILITY_BUILD_DIR:-$PWD/build}"
mkdir -p "$build"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
framework="$build/ManicAzaharStabilityRecorder.framework"
mkdir -p "$framework"
xcrun --sdk iphoneos clang -target arm64-apple-ios15.0 -isysroot "$sdk" \
  -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter -dynamiclib \
  ManicAzaharStabilityRecorder.m -framework Foundation \
  -install_name '@rpath/ManicAzaharStabilityRecorder.framework/ManicAzaharStabilityRecorder' \
  -o "$framework/ManicAzaharStabilityRecorder"
cat > "$framework/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ManicAzaharStabilityRecorder</string>
<key>CFBundleIdentifier</key><string>org.manicemu.azahar-stability-recorder</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>2</string>
<key>MinimumOSVersion</key><string>15.0</string>
</dict></plist>
PLIST
git rev-parse HEAD > "$framework/SOURCE"
testdir="$build/native-self-test"
mkdir -p "$testdir"
xcrun clang -arch arm64 -Wall -Wextra -Werror metadata_self_test.c -o "$testdir/MetadataSelfTest"
"$testdir/MetadataSelfTest" > "$testdir/metadata-self-test.json"
xcrun clang -arch arm64 -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
  -DMANIC_STABILITY_SELF_TEST=1 ManicAzaharStabilityRecorder.m self_test.c \
  -framework Foundation -o "$testdir/StabilitySelfTest"
MANIC_STABILITY_DIRECTORY="$testdir" "$testdir/StabilitySelfTest"
python3 - "$testdir" <<'PY'
import base64,json,pathlib,sys
root=pathlib.Path(sys.argv[1]);files=list(root.glob('*.stability-*.json'))
assert len(files)==8
samples=[json.loads(p.read_text()) for p in files]
assert sorted(s['sequence'] for s in samples)==list(range(16,24))
identifier=int((root/'waiting-thread-id.txt').read_text())
durations=[]
for s in samples:
    assert s['task_threads_result']==0
    assert s['thread_suspension_performed'] is False and s['guest_ram_read'] is False
    assert s['thread_limit']==64 and len(s['threads'])<=64
    assert s['memory']['result']==0 and s['memory']['physical_footprint_bytes']>0
    assert s['capture_duration_ms']>=0
    assert any(t['thread_id']==identifier and t['run_state']==3 and t['state_result']==0 and t.get('stack_b64') for t in s['threads'])
    for t in s['threads']:
        assert len(base64.b64decode(t.get('stack_b64','')))<=4096
    durations.append(s['capture_duration_ms'])
report={'real_own_task_sampling_passed':True,'known_waiting_thread_captured':True,
    'memory_footprint_observed':True,'ring_files':8,'captures_executed':24,
    'no_thread_suspension':True,'no_guest_ram_read':True,
    'host_capture_max_ms':max(durations),'physical_iphone_overhead_measured':False,
    'game_or_plugin_test_performed':False}
(root/'self-test.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report))
PY
python3 decode.py "$testdir" --output "$testdir/private-decoded-summary.json"
python3 - "$framework" "$build/component-manifest.json" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]);binary=root/'ManicAzaharStabilityRecorder'
report={'framework':root.name,'binary_sha256':hashlib.file_digest(binary.open('rb'),'sha256').hexdigest(),
    'source_commit':(root/'SOURCE').read_text().strip(),'unsigned':True,
    'scope':'Optional diagnostic component; no production freeze fix claimed',
    'core_binary_modified':False,'private_inputs_used':False,'physical_gameplay_verified':False}
pathlib.Path(sys.argv[2]).write_text(json.dumps(report,indent=2));print(json.dumps(report))
PY
