#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
MGL_SDK=iphonesimulator MGL_BUILD_DIR="$root/build-simulator" bash "$root/scripts/build-ios.sh"
app="$root/build-simulator/GBLinkSmoke.app"
mkdir -p "$app/Frameworks"
cp -R "$root/build-simulator/ManicGBLink.framework" "$app/Frameworks/"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -isysroot "$sdk" -fobjc-arc \
    "$root/Tests/simulator_main.m" -F "$app/Frameworks" -framework ManicGBLink -framework UIKit -framework Foundation \
    -Wl,-rpath,@executable_path/Frameworks -o "$app/GBLinkSmoke"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.manicemu.gblink.smoke</string>
<key>CFBundleExecutable</key><string>GBLinkSmoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1</string>
<key>MinimumOSVersion</key><string>15.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Frameworks/ManicGBLink.framework"
codesign --force --sign - "$app"
device="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"].startswith("iPhone")))')"
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$app"
xcrun simctl launch "$device" org.manicemu.gblink.smoke
sleep 8
xcrun simctl io "$device" screenshot "$root/build-simulator/gb-link-ui.png"
xcrun simctl terminate "$device" org.manicemu.gblink.smoke
xcrun simctl shutdown "$device"
