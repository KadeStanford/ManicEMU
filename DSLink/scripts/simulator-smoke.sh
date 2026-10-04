#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD";build="$root/build-simulator";app="$build/DSSmoke.app"
mkdir -p "$app"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang++ -target arm64-apple-ios15.0-simulator -isysroot "$sdk" -std=c++17 -fobjc-arc \
  -O1 -Wall -Wextra -Werror -Wno-unused-parameter -I "$root/Core" -I "$root/../OriginalCoreRepair/Tests/vendor" \
  "$root/Core/Protocol.cpp" "$root/Tests/simulator_main.mm" -framework UIKit -framework Foundation \
  -framework MultipeerConnectivity -framework QuartzCore -Wl,-export_dynamic -o "$app/DSSmoke"
python3 - "$app" <<'PY'
import pathlib,plistlib,sys
p=pathlib.Path(sys.argv[1]);p.joinpath('Info.plist').write_bytes(plistlib.dumps({
'CFBundleIdentifier':'org.manicemu.ds.smoke','CFBundleExecutable':'DSSmoke','CFBundlePackageType':'APPL',
'CFBundleVersion':'1','CFBundleShortVersionString':'1','MinimumOSVersion':'15.0','UIDeviceFamily':[1],
'UILaunchScreen':{},'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,
'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Test','UISceneDelegateClassName':'TestScene'}]}},
'NSLocalNetworkUsageDescription':'Synthetic local bridge tests.','NSBonjourServices':['_manic-ds._tcp']}))
PY
codesign --force --sign - "$app"
device="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"].startswith("iPhone")))')"
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$app"
xcrun simctl launch "$device" org.manicemu.ds.smoke
container="$(xcrun simctl get_app_container "$device" org.manicemu.ds.smoke data)"
for attempt in {1..30}; do if [[ -s "$container/Documents/smoke.json" ]]; then break; fi; sleep 2; done
if [[ ! -s "$container/Documents/smoke.json" ]]; then
  xcrun simctl spawn "$device" log show --last 3m --style compact --predicate 'process == "DSSmoke"' 2>/dev/null | tail -100 >&2 || true
  exit 1
fi
cp "$container/Documents/smoke.json" "$build/smoke.json"
python3 - "$build/smoke.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));print(json.dumps(r,indent=2));assert r['error'] is None and len(r['checks'])>=18 and all(r['checks'].values())
PY
xcrun simctl terminate "$device" org.manicemu.ds.smoke
xcrun simctl shutdown "$device"
