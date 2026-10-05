#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
build="$PWD/build-simulator"
app="$build/FrontendFrameSkip.app"
mkdir -p "$app"
python3 generate_simulator_gate.py --output "$build/frame-skip-gates.S"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -isysroot "$sdk" -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
  simulator_main.m "$build/frame-skip-gates.S" -framework UIKit -framework Foundation -o "$app/FrontendFrameSkip"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.manicemu.frontend-frame-skip-regression</string>
<key>CFBundleExecutable</key><string>FrontendFrameSkip</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1</string>
<key>MinimumOSVersion</key><string>15.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
device="$(xcrun simctl list devices available -j | python3 -c 'import json,sys;print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"].startswith("iPhone")))')"
trap 'xcrun simctl shutdown "$device" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$app"
xcrun simctl launch "$device" org.manicemu.frontend-frame-skip-regression
container="$(xcrun simctl get_app_container "$device" org.manicemu.frontend-frame-skip-regression data)"
for attempt in {1..30}; do
  if [[ -s "$container/Documents/frame-skip-simulator.json" ]]; then break; fi
  sleep 2
done
test -s "$container/Documents/frame-skip-simulator.json"
cp "$container/Documents/frame-skip-simulator.json" "$build/"
python3 -c "import json;r=json.load(open('$build/frame-skip-simulator.json'));print(r);assert r['passed'] and r['native_ARM64_gate_calls']>=900"
xcrun simctl terminate "$device" org.manicemu.frontend-frame-skip-regression
