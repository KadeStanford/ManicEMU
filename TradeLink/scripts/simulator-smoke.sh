#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
MGL_SDK=iphonesimulator MGL_BUILD_DIR="$root/build-simulator" bash "$root/scripts/build-ios.sh"
app="$root/build-simulator/TradeSmoke.app"
mkdir -p "$app/Frameworks"
cp -R "$root/build-simulator/ManicGBLink.framework" "$app/Frameworks/"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -isysroot "$sdk" -fobjc-arc \
  -I "$root/Core" "$root/Tests/simulator_main.m" -F "$app/Frameworks" -framework ManicGBLink -framework UIKit -framework Foundation -framework MultipeerConnectivity -framework QuartzCore \
  -Wl,-rpath,@executable_path/Frameworks -Wl,-export_dynamic -o "$app/TradeSmoke"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.manicemu.trade.smoke</string>
<key>CFBundleExecutable</key><string>TradeSmoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1</string>
<key>MinimumOSVersion</key><string>15.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
<key>MGLInjectTrade</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Find nearby synthetic test peers.</string>
<key>NSBonjourServices</key><array><string>_manic-trade._tcp</string></array>
</dict></plist>
PLIST
codesign --force --sign - "$app/Frameworks/ManicGBLink.framework"
codesign --force --sign - "$app"
device="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"].startswith("iPhone")))')"
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$app"
xcrun simctl launch "$device" org.manicemu.trade.smoke
container="$(xcrun simctl get_app_container "$device" org.manicemu.trade.smoke data)"
for attempt in {1..30}; do
  if [[ -s "$container/Documents/smoke.json" && -s "$container/Documents/latency.json" ]]; then break; fi
  sleep 2
done
if [[ ! -s "$container/Documents/smoke.json" || ! -s "$container/Documents/latency.json" ]]; then
  echo 'Simulator smoke app did not write both result files; recent app and crash diagnostics follow.' >&2
  xcrun simctl spawn "$device" log show --last 5m --style compact --predicate 'process == "TradeSmoke" OR eventMessage CONTAINS "TradeSmoke"' 2>/dev/null | tail -100 >&2 || true
  find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name '*TradeSmoke*' -type f -print -exec tail -80 {} \; >&2 || true
  exit 1
fi
cp "$container/Documents/smoke.json" "$root/build-simulator/smoke.json"
cp "$container/Documents/latency.json" "$root/build-simulator/latency.json"
python3 -c "import json; r=json.load(open('$root/build-simulator/smoke.json')); assert all(r.values()); print(r)"
xcrun simctl io "$device" screenshot "$root/build-simulator/gba-trade-ui.png"
xcrun simctl terminate "$device" org.manicemu.trade.smoke
xcrun simctl shutdown "$device"
