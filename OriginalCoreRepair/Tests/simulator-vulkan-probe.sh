#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
build="$PWD/build-probe"
sdkroot="${MANIC_MOLTENVK_SDK:-$build/moltenvk-1.2.8}"
mkdir -p "$sdkroot"
if [[ -z "${MANIC_MOLTENVK_SDK:-}" ]]; then
curl --fail --location --retry 3 --silent --show-error \
  https://github.com/KhronosGroup/MoltenVK/releases/download/v1.2.8/MoltenVK-ios.tar -o "$sdkroot/sdk.tar"
python3 - "$sdkroot/sdk.tar" <<'PY'
import hashlib,pathlib,sys
assert hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()=='778980f84f1afe7f5058df469fe9715d767a9891afb5497dd90ff29a7fa384a1'
PY
tar -xf "$sdkroot/sdk.tar" -C "$sdkroot"
fi
app="$build/VulkanProbe.app"
mkdir -p "$app"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -isysroot "$sdk" \
  -fobjc-arc -Wall -Werror -I "${MANIC_MOLTENVK_INCLUDE:-$sdkroot/MoltenVK/MoltenVK/include}" simulator_vulkan_probe.m \
  -framework UIKit -framework Foundation -o "$app/VulkanProbe"
driver="${MANIC_MOLTENVK_BINARY:-$sdkroot/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework/MoltenVK}"
if [[ "$(xcrun lipo -archs "$driver")" == arm64 ]]; then
  cp "$driver" "$build/moltenvk-arm64.dylib"
else
  xcrun lipo "$driver" -thin arm64 -output "$build/moltenvk-arm64.dylib"
fi
python3 - "$build/moltenvk-arm64.dylib" "$app/moltenvk-probe.dylib" <<'PY'
import pathlib,struct,sys
b=bytearray(pathlib.Path(sys.argv[1]).read_bytes());assert b[:4]==bytes.fromhex('cffaedfe')
pos=32;found=False
for _ in range(struct.unpack_from('<I',b,16)[0]):
    cmd,size=struct.unpack_from('<II',b,pos)
    if cmd==0x32:
        assert struct.unpack_from('<I',b,pos+8)[0] in (2,7)
        struct.pack_into('<I',b,pos+8,7);found=True
    pos+=size
assert found
pathlib.Path(sys.argv[2]).write_bytes(b)
PY
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.manicemu.vulkan-probe</string>
<key>CFBundleExecutable</key><string>VulkanProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>15.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$app/moltenvk-probe.dylib"
codesign --force --sign - "$app"
device="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"].startswith("iPhone")))')"
trap 'python3 run_bounded.py 20 xcrun simctl uninstall "$device" org.manicemu.vulkan-probe >/dev/null 2>&1 || true; python3 run_bounded.py 20 xcrun simctl shutdown "$device" >/dev/null 2>&1 || true' EXIT
python3 run_bounded.py 120 xcrun simctl boot "$device"
python3 run_bounded.py 180 xcrun simctl bootstatus "$device" -b
python3 run_bounded.py 120 xcrun simctl install "$device" "$app"
container="$(xcrun simctl get_app_container "$device" org.manicemu.vulkan-probe data)"
python3 run_bounded.py 180 xcrun simctl launch "$device" org.manicemu.vulkan-probe
for attempt in {1..30}; do
  [[ -s "$container/Documents/vulkan-fatal.bin" ]] && break
  if [[ -s "$container/Documents/vulkan-preflight.json" ]] && python3 - "$container/Documents/vulkan-preflight.json" <<'PY'
import json,sys
sys.exit(0 if json.load(open(sys.argv[1])).get('stage') in ['completed','failed','missing_vkGetInstanceProcAddr','objc_exception'] else 1)
PY
  then break; fi
  sleep 1
done
cp "$container/Documents/vulkan-preflight.json" "$build/vulkan-preflight.json"
cp "$container/Documents/vulkan-fatal.bin" "$build/vulkan-fatal.bin"
python3 run_bounded.py 20 xcrun simctl spawn "$device" log show --last 2m --style compact --predicate 'process == "VulkanProbe"' > "$build/vulkan-preflight-system.log" 2>/dev/null || true
python3 - "$build/vulkan-preflight.json" "$build/vulkan-fatal.bin" <<'PY'
import json,sys,pathlib,struct
p=pathlib.Path(sys.argv[1]);r=json.loads(p.read_text());b=pathlib.Path(sys.argv[2]).read_bytes()
if len(b)==56:
    x=struct.unpack('<7Q',b);r.update(fatal_signal=x[1],fault_address=hex(x[2]),pc_offset_from_moltenvk=hex(x[4]-x[3]),lr_offset_from_moltenvk=hex(x[5]-x[3]))
p.write_text(json.dumps(r,indent=2));print(json.dumps(r));assert r.get('vulkan_device_verified')
PY
