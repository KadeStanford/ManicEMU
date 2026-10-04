#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
build="${MDS_BUILD_DIR:-$root/build}"
sdk_name="${MDS_SDK:-iphoneos}"
sdk="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
target=arm64-apple-ios15.0
if [[ "$sdk_name" == iphonesimulator ]]; then target+=-simulator; fi
source="$build/melondsds-source"
mkdir -p "$build"
if [[ ! -d "$source/.git" ]]; then
  git clone https://github.com/Daiuno/melonds-ds.git "$source"
  git -C "$source" checkout --detach 1a28e0fe2a78c9d2318f4324835ff906488299a2
  python3 "$root/scripts/patch_source.py" "$source"
fi
cmake -S "$source" -B "$build/engine" -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DENABLE_JIT=ON -DENABLE_OPENGL=OFF -DENABLE_LTO=OFF \
  -DENABLE_LTO_RELEASE=OFF -DENABLE_TESTING=OFF -DBUILD_AS_SHARED_LIBRARY=ON
cmake --build "$build/engine" --parallel 3
for name in DSOriginal melondsds.libretro; do mkdir -p "$build/$name.framework"; done
cp "$build/engine/src/libretro/melondsds.libretro.framework/melondsds.libretro" "$build/DSOriginal.framework/DSOriginal"
codesign --remove-signature "$build/DSOriginal.framework/DSOriginal"
install_name_tool -id '@rpath/DSOriginal.framework/DSOriginal' "$build/DSOriginal.framework/DSOriginal"
xcrun --sdk "$sdk_name" clang++ -target "$target" -isysroot "$sdk" -std=c++17 -fobjc-arc \
  -O2 -Wall -Wextra -Werror -Wno-unused-parameter -dynamiclib \
  -I "$root/Core" -I "$root/../OriginalCoreRepair/Tests/vendor" \
  "$root/Core/Protocol.cpp" "$root/iOS/CoreShim.mm" "$root/iOS/Nearby.mm" \
  -framework Foundation -framework UIKit -framework MultipeerConnectivity -framework QuartzCore \
  -install_name '@rpath/melondsds.libretro.framework/melondsds.libretro' \
  -o "$build/melondsds.libretro.framework/melondsds.libretro"
for name in DSOriginal melondsds.libretro; do
  python3 - "$build/$name.framework" "$name" "$sdk_name" <<'PY'
import pathlib,plistlib,sys
p=pathlib.Path(sys.argv[1]);name=sys.argv[2]
info={'CFBundleExecutable':name,'CFBundleIdentifier':'org.manicemu.ds.'+name.replace('.','-'),
 'CFBundleName':name,'CFBundlePackageType':'FMWK','CFBundleShortVersionString':'0.1',
 'CFBundleVersion':'1','MinimumOSVersion':'15.0','CFBundleSupportedPlatforms':['iPhoneOS' if sys.argv[3]=='iphoneos' else 'iPhoneSimulator']}
(p/'Info.plist').write_bytes(plistlib.dumps(info))
PY
  cp "$root/../LICENSE" "$build/$name.framework/LICENSE"
  cp "$source/LICENSE" "$build/$name.framework/melonDSDS-LICENSE"
  git -C "$root" rev-parse HEAD | sed 's|^|https://github.com/KadeStanford/ManicEMU/tree/|' > "$build/$name.framework/SOURCE"
  xcrun --sdk "$sdk_name" otool -L "$build/$name.framework/$name"
done
nm -g "$build/DSOriginal.framework/DSOriginal" | grep ' T _manic_ds_protocol_revision$'
python3 - "$build" "$sdk_name" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
files={n:hashlib.sha256((p/(n+'.framework')/n).read_bytes()).hexdigest() for n in ('DSOriginal','melondsds.libretro')}
(p/'build-manifest.json').write_text(json.dumps({'sdk':sys.argv[2],'engine_version':'1.3.1',
 'upstream_repository':'https://github.com/Daiuno/melonds-ds',
 'upstream_commit':'1a28e0fe2a78c9d2318f4324835ff906488299a2','queue_reset_marker':2,
 'manic_custom_screen_layout_preserved':True,'optional_jit_compiled':True,
 'framework_sha256':files,'private_game_inputs_used':False,'physical_iPhone_verified':False},indent=2))
PY
echo 'Built unsigned DS shim and reset-capable core. Game compatibility remains unverified.'
