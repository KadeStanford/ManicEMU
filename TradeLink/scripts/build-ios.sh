#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
sdk_name="${MGL_SDK:-iphoneos}"
build="${MGL_BUILD_DIR:-$root/build}"
sdk="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
cmake -S "$root" -B "$build/objects" -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
cmake --build "$build/objects" --parallel 3
for name in ManicGBLink gpsp.libretro; do
  dir="$build/$name.framework"
  mkdir -p "$dir"
  cp "$build/objects/$name" "$dir/$name"
  cat > "$dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundleIdentifier</key><string>org.manicemu.$(echo "$name" | tr '.' '-')</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.4</string>
<key>CFBundleVersion</key><string>4</string>
<key>MinimumOSVersion</key><string>15.0</string>
</dict></plist>
PLIST
  cp "$root/Vendor/gpSP/COPYING" "$dir/gpSP-COPYING"
  cp "$root/../LICENSE" "$dir/LICENSE"
  git -C "$root" rev-parse HEAD | sed 's|^|https://github.com/KadeStanford/ManicEMU/tree/|' > "$dir/SOURCE"
  xcrun --sdk "$sdk_name" otool -L "$dir/$name"
done
echo "Built unsigned in-game GBA trade plugin and interpreter gpSP framework. No signing credentials used."
