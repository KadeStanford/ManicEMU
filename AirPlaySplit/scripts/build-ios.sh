#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
sdk_name="${MAS_SDK:-iphoneos}"
build="${MAS_BUILD_DIR:-$root/build}"
sdk="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
target=arm64-apple-ios15.0
if [[ "$sdk_name" == iphonesimulator ]]; then target+=-simulator; fi
dir="$build/ManicAirPlaySplit.framework"
mkdir -p "$dir"
xcrun --sdk "$sdk_name" clang -target "$target" -isysroot "$sdk" -fobjc-arc -O2 -Wall -Wextra \
  -Wno-unused-parameter -dynamiclib "$root/iOS/ManicAirPlaySplit.m" "$root/iOS/MASRender.m" \
  -framework Foundation -framework UIKit -framework QuartzCore -framework Metal \
  -install_name '@rpath/ManicAirPlaySplit.framework/ManicAirPlaySplit' \
  -o "$dir/ManicAirPlaySplit"
cat > "$dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ManicAirPlaySplit</string>
<key>CFBundleIdentifier</key><string>org.manicemu.airplay-split</string>
<key>CFBundleName</key><string>ManicAirPlaySplit</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>15.0</string>
</dict></plist>
PLIST
cp "$root/../LICENSE" "$dir/LICENSE"
git -C "$root" rev-parse HEAD | sed 's|^|https://github.com/KadeStanford/ManicEMU/tree/|' > "$dir/SOURCE"
xcrun --sdk "$sdk_name" otool -L "$dir/ManicAirPlaySplit"
