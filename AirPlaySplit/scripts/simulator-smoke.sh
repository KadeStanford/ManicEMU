#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
build="$root/build-simulator"
app="$build/AirPlaySmoke.app"
mkdir -p "$app"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -isysroot "$sdk" -fobjc-arc -O0 -g \
  "$root/Tests/simulator_main.m" "$root/iOS/MASRender.m" -framework UIKit -framework Foundation \
  -framework QuartzCore -framework Metal -framework CoreGraphics -Wl,-export_dynamic -o "$app/AirPlaySmoke"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.manicemu.airplay.smoke</string>
<key>CFBundleExecutable</key><string>AirPlaySmoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1</string>
<key>MinimumOSVersion</key><string>15.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
<key>MASInjectAirPlaySplit</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
device="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"].startswith("iPhone")))')"
trap 'xcrun simctl shutdown "$device" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$app"
xcrun simctl launch "$device" org.manicemu.airplay.smoke
container="$(xcrun simctl get_app_container "$device" org.manicemu.airplay.smoke data)"
for attempt in {1..30}; do
  if [[ -s "$container/Documents/smoke.json" ]]; then break; fi
  sleep 2
done
if [[ ! -s "$container/Documents/smoke.json" ]]; then
  xcrun simctl spawn "$device" log show --last 5m --style compact --predicate 'process == "AirPlaySmoke"' 2>/dev/null | tail -100 >&2 || true
  exit 1
fi
cp "$container/Documents/smoke.json" "$build/smoke.json"
cp "$container/Documents/performance.json" "$build/performance.json"
python3 -c "import json; r=json.load(open('$build/smoke.json')); print(r); assert len(r)>=16 and all(r.values())"
xcrun simctl terminate "$device" org.manicemu.airplay.smoke
