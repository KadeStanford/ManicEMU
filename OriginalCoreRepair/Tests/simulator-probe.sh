#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
build="$PWD/build-probe"
app="$build/OriginalCoreProbe.app"
mkdir -p "$app"
curl --fail --location --silent --show-error \
  https://media.githubusercontent.com/media/Manic-EMU/ManicEMU/fbaeab79c214d5920bb51afa6f2d786fb2b12a58/Cores/azahar.libretro.framework/azahar.libretro \
  -o "$app/device-core.dylib"
python3 - "$app" <<'PY'
import hashlib,pathlib,struct,sys
root=pathlib.Path(sys.argv[1]);b=(root/'device-core.dylib').read_bytes()
assert hashlib.sha256(b).hexdigest()=='183159290d777d42a68c17f5f4d90d8b88f7aa0281e4788bad4e5954a6df940c'
out=bytearray(b);pos=32;changed=False
for _ in range(struct.unpack_from('<I',b,16)[0]):
    c,n=struct.unpack_from('<II',b,pos)
    if c==0x32:
        assert struct.unpack_from('<I',b,pos+8)[0]==2
        struct.pack_into('<I',out,pos+8,7);changed=True
    pos+=n
assert changed
(root/'platform-probe-core.dylib').write_bytes(out)
PY
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -isysroot "$sdk" \
  -fobjc-arc simulator_probe.m -framework UIKit -framework Foundation -o "$app/OriginalCoreProbe"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.manicemu.original-core-probe</string>
<key>CFBundleExecutable</key><string>OriginalCoreProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>15.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$app/device-core.dylib"
codesign --force --sign - "$app/platform-probe-core.dylib"
codesign --force --sign - "$app"
device="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"].startswith("iPhone")))')"
trap 'xcrun simctl shutdown "$device" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$app"
xcrun simctl launch "$device" org.manicemu.original-core-probe
container="$(xcrun simctl get_app_container "$device" org.manicemu.original-core-probe data)"
for attempt in {1..30}; do
  if [[ -s "$container/Documents/probe.json" ]]; then
    if python3 - "$container/Documents/probe.json" <<'PY'
import json,sys
sys.exit(0 if json.load(open(sys.argv[1])).get('probe_completed') else 1)
PY
    then break; fi
  fi
  sleep 2
done
if [[ -s "$container/Documents/probe.json" ]]; then cp "$container/Documents/probe.json" "$build/probe.json";cat "$build/probe.json";fi
xcrun simctl spawn "$device" log show --last 3m --style compact --predicate 'process == "OriginalCoreProbe"' > "$build/probe.log" 2>&1 || true
test -s "$build/probe.json"
