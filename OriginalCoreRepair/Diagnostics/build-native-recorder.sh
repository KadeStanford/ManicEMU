#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
dir="$PWD/build/ManicNativeFaultRecorder.framework"
mkdir -p "$dir"
xcrun --sdk iphoneos clang -target arm64-apple-ios15.0 -isysroot "$sdk" -fobjc-arc -O2 -Wall -Wextra -Werror \
  -Wno-unused-parameter -dynamiclib ManicNativeFaultRecorder.m -framework Foundation \
  -install_name '@rpath/ManicNativeFaultRecorder.framework/ManicNativeFaultRecorder' -o "$dir/ManicNativeFaultRecorder"
cat > "$dir/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ManicNativeFaultRecorder</string>
<key>CFBundleIdentifier</key><string>org.manicemu.native-fault-recorder</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>15.0</string>
</dict></plist>
PLIST
git rev-parse HEAD > "$dir/SOURCE"
# Verify this recorder itself on an ARM64 macOS runner, in its private build dir.
testdir="$PWD/build/recorder-self-test"
mkdir -p "$testdir"
printf '#include <signal.h>\nint main(void){raise(SIGSEGV);return 0;}\n' > "$testdir/main.c"
xcrun clang -arch arm64 -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
  -DMANIC_NATIVE_RECORDER_SELF_TEST=1 ManicNativeFaultRecorder.m "$testdir/main.c" \
  -framework Foundation -o "$testdir/RecorderSelfTest"
set +e
MANIC_NATIVE_RECORDER_DIRECTORY="$testdir" "$testdir/RecorderSelfTest"
result=$?
set -e
test "$result" -eq 139
python3 - "$testdir" <<'PY'
import json,pathlib,struct,sys
root=pathlib.Path(sys.argv[1]);faults=list(root.glob('fault-*.bin'));assert len(faults)==1
values=struct.unpack('<39Q',faults[0].read_bytes())
assert values[0]==0x4d414e4943464c54 and values[1]==1 and values[2]==11 and values[5] and values[6] and values[7]
images=faults[0].with_suffix('.images').read_text();assert 'RecorderSelfTest' in images
stack=faults[0].with_suffix('.stack').read_bytes()
assert 528<=len(stack)<=16400 and (len(stack)-16)%512==0
assert struct.unpack_from('<2Q',stack)==(values[7],values[8])
report={'signal_verified':11,'native_pc_lr_sp_recorded':True,'loaded_image_ranges_recorded':True,'bounded_native_stack_recorded':True,'device_framework_separate_from_self_test':True}
(root/'self-test.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
PY
