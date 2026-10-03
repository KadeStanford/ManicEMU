#!/usr/bin/env bash
# Private input paths are local to the runner; never include them in artifacts.
set -euo pipefail
cd "$(dirname "$0")"
build="$PWD/build-probe"
app="$build/GameProbe.app"
mkdir -p "$app"
cp "$build/GameProbe" "$app/GameProbe"
python3 - "$build/original-core-download.dylib" "$app/game-probe-core.dylib" <<'PY'
import hashlib,pathlib,struct,sys,os
b=pathlib.Path(sys.argv[1]).read_bytes()
assert hashlib.sha256(b).hexdigest()=='183159290d777d42a68c17f5f4d90d8b88f7aa0281e4788bad4e5954a6df940c'
out=bytearray(b)
for offset,expected in ([(0x524954,'29435939'),(0x52495c,'29e35939'),(0x5281ac,'a9425939'),(0x5281b4,'a9e25939')] if os.environ.get('MANIC_PROBE_PLUGIN_ENABLED','1')=='1' else []):
    assert b[offset:offset+4]==bytes.fromhex(expected)
    out[offset:offset+4]=bytes.fromhex('29008052')
pos=32;found=False
for _ in range(struct.unpack_from('<I',b,16)[0]):
    cmd,size=struct.unpack_from('<II',b,pos)
    if cmd==0x32:
        assert struct.unpack_from('<I',b,pos+8)[0]==2
        struct.pack_into('<I',out,pos+8,7);found=True
    pos+=size
assert found
pathlib.Path(sys.argv[2]).write_bytes(out)
PY
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.manicemu.game-probe</string>
<key>CFBundleExecutable</key><string>GameProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>15.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$app/game-probe-core.dylib"
codesign --force --sign - "$app"
device="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"].startswith("iPhone")))')"
trap 'xcrun simctl uninstall "$device" org.manicemu.game-probe >/dev/null 2>&1 || true; xcrun simctl shutdown "$device" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$app"
container="$(xcrun simctl get_app_container "$device" org.manicemu.game-probe data)"
mkdir -p "$container/Documents"
if [[ "${1:-}" == '--self-test' ]]; then
  SIMCTL_CHILD_MANIC_PROBE_SIGNAL_TEST=1 xcrun simctl launch "$device" org.manicemu.game-probe
  for attempt in {1..20}; do
    [[ -s "$container/Documents/fatal-signal.bin" ]] && break
    sleep 1
  done
  python3 - "$container/Documents" "$build/fault-recorder-self-test.json" <<'PY'
import json,pathlib,struct,sys
root=pathlib.Path(sys.argv[1]);record=struct.unpack('<8Q',(root/'fatal-signal.bin').read_bytes())
stage=json.loads((root/'game-probe.json').read_text())
assert record[0]==0x4d414e4943505242 and record[1]==11 and record[4]!=0 and record[7]==0
assert stage['stage']=='diagnostic_signal_self_test'
result={'fatal_signal_recorded':True,'signal':11,'native_program_counter_present':True,
        'checkpoint_survived':True,'actual_game_executed':False,'plugin_executed':False}
pathlib.Path(sys.argv[2]).write_text(json.dumps(result,indent=2))
print(json.dumps(result))
PY
else
  test "$#" -eq 2
  game="$1";plugin="$2"
  python3 - "$game" "$plugin" <<'PY'
import pathlib,sys,hashlib
with pathlib.Path(sys.argv[1]).open('rb') as f:header=f.read(512)
assert header[256:260]==b'NCCH' and header[0x18f]&4, 'Expected decrypted private NCCH copy'
assert hashlib.sha256(pathlib.Path(sys.argv[2]).read_bytes()).hexdigest()=='fa03d320392242f2367ef04402822b2d0778c1fcef12a504e940135cb4f4a9d8'
PY
  mkdir -p "$container/Documents/input"
  cp "$game" "$container/Documents/input/game.cxi"
  for prefix in '' '3DS/' 'citra/'; do
    target="$container/Documents/${prefix}sdmc/luma/plugins/0004000000198E00"
    mkdir -p "$target"
    cp -R "$(dirname "$plugin")/." "$target/"
    resources="$(dirname "$(dirname "$(dirname "$(dirname "$plugin")")")")/Vapecord"
    if [[ -d "$resources" ]]; then
      mkdir -p "$container/Documents/${prefix}sdmc/Vapecord"
      cp -R "$resources/." "$container/Documents/${prefix}sdmc/Vapecord/"
    fi
  done
  xcrun simctl launch "$device" org.manicemu.game-probe
  for attempt in {1..150}; do
    [[ -s "$container/Documents/fatal-signal.bin" ]] && break
    if [[ -s "$container/Documents/game-probe.json" ]] && python3 - "$container/Documents/game-probe.json" <<'PY'
import json,sys
sys.exit(0 if json.load(open(sys.argv[1])).get('stage') in ['completed','dlopen_failed','missing_entrypoint'] else 1)
PY
    then break; fi
    sleep 1
  done
  # Evidence stays in the runner sandbox until explicitly selected for retention.
  cp "$container/Documents/game-probe.json" "$build/private-game-probe.json"
  cp "$container/Documents/core-runtime.log" "$build/private-core-runtime.log"
  cp "$container/Documents/fatal-signal.bin" "$build/private-fatal-signal.bin"
  for frame in "$container/Documents"/private-frame-*.png; do
    if [[ -f "$frame" ]]; then cp "$frame" "$build/"; fi
  done
fi
