#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
build="${MGL_BUILD_DIR:-$root/build}"
mkdir -p "$build/ManicGBLink.framework"
rgbasm -I "$root/Vendor/SameBoy/BootROMs/" -o "$build/dmg_boot.o" "$root/Vendor/SameBoy/BootROMs/dmg_boot.asm"
rgblink -x -o "$build/dmg_boot.bin" "$build/dmg_boot.o"
node "$root/scripts/embed-boot.mjs" "$build/dmg_boot.bin" "$build/dmg_boot.h"
sdk_name="${MGL_SDK:-iphoneos}"
sdk="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
cc="$(xcrun --sdk "$sdk_name" --find clang)"
target="arm64-apple-ios15.0"
if [[ "$sdk_name" == "iphonesimulator" ]]; then target="$target-simulator"; fi
flags=(-target "$target" -isysroot "$sdk" -O2
       -DGB_DISABLE_TIMEKEEPING -DGB_DISABLE_REWIND -DGB_DISABLE_DEBUGGER -DGB_DISABLE_CHEATS
       '-DGB_VERSION="1.0.3"' '-DGB_COPYRIGHT_YEAR="2026"'
       -I "$root/Core" -I "$root/Vendor/SameBoy/Core" -I "$build")
objects=()
for source in gb sgb apu memory mbc timing display camera sm83_cpu joypad save_state random rumble; do
    "$cc" "${flags[@]}" -DGB_INTERNAL -std=gnu11 -c "$root/Vendor/SameBoy/Core/$source.c" -o "$build/$source.o"
    objects+=("$build/$source.o")
done
"$cc" "${flags[@]}" -std=gnu11 -c "$root/Core/MGLCore.c" -o "$build/MGLCore.o"
"$cc" "${flags[@]}" -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror -c "$root/iOS/MGLViewController.m" -o "$build/MGLViewController.o"
"$cc" "${flags[@]}" -dynamiclib -install_name '@rpath/ManicGBLink.framework/ManicGBLink' \
    "${objects[@]}" "$build/MGLCore.o" "$build/MGLViewController.o" \
    -framework Foundation -framework UIKit -framework MultipeerConnectivity \
    -framework UniformTypeIdentifiers -framework QuartzCore -framework CoreGraphics \
    -o "$build/ManicGBLink.framework/ManicGBLink"
cat > "$build/ManicGBLink.framework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ManicGBLink</string>
<key>CFBundleIdentifier</key><string>org.manicemu.gblink</string>
<key>CFBundleName</key><string>ManicGBLink</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>15.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
</dict></plist>
PLIST
cp "$root/Vendor/SameBoy/LICENSE" "$build/ManicGBLink.framework/SameBoy-LICENSE"
cp "$root/../LICENSE" "$build/ManicGBLink.framework/LICENSE"
git -C "$root" rev-parse HEAD | sed 's|^|https://github.com/KadeStanford/ManicEMU/tree/|' > "$build/ManicGBLink.framework/SOURCE"
xcrun --sdk "$sdk_name" otool -L "$build/ManicGBLink.framework/ManicGBLink"
if [[ "$sdk_name" == "iphoneos" ]]; then python3 "$root/scripts/check-swift-bridge.py" "$sdk"; fi
echo "Built unsigned arm64 iOS framework. No signing credentials used."
