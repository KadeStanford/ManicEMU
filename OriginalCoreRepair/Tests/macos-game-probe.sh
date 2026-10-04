#!/usr/bin/env bash
# Private runner-only execution; the iPhone core is never replaced by this copy.
set -euo pipefail
cd "$(dirname "$0")"
build="$PWD/build-probe"
resource="$build/native-resources"
data="$build/native-data"
mkdir -p "$resource" "$data/input"
test "$#" -eq 3
game="$1"; plugin="$2"; driver="$3"
cp "$game" "$data/input/game.cxi"
for prefix in '' '3DS/' 'citra/'; do
  target="$data/${prefix}sdmc/luma/plugins/0004000000198E00"
  mkdir -p "$target"
  cp -R "$(dirname "$plugin")/." "$target/"
  assets="$(dirname "$(dirname "$(dirname "$(dirname "$plugin")")")")/Vapecord"
  if [[ -d "$assets" ]]; then
    mkdir -p "$data/${prefix}sdmc/Vapecord"
    cp -R "$assets/." "$data/${prefix}sdmc/Vapecord/"
  fi
done
python3 - "$build/original-core-download.dylib" "$resource/game-probe-core.dylib" <<'PY'
import hashlib,os,pathlib,struct,sys
sys.path.insert(0,str(pathlib.Path('..').resolve()))
from enable_3gx import PATCHES
from repair_vulkan_fill import patch_core,PUBLIC_SHA256
b=pathlib.Path(sys.argv[1]).read_bytes()
assert hashlib.sha256(b).hexdigest().upper()==PUBLIC_SHA256
out=bytearray(b)
if os.environ['MANIC_PROBE_PLUGIN_ENABLED']=='1':
    for offset,before,after,_ in PATCHES:
        assert out[offset:offset+4]==before
        out[offset:offset+4]=after
repair=os.environ.get('MANIC_PROBE_FILL_REPAIR','0')
if repair in ('4','5'):
    out=bytearray(patch_core(bytes(out),refresh_sampled_view=repair=='5'))
pos=32;found=False
for _ in range(struct.unpack_from('<I',b,16)[0]):
    cmd,size=struct.unpack_from('<II',b,pos)
    if cmd==0x32:
        assert struct.unpack_from('<I',b,pos+8)[0]==2
        struct.pack_into('<I',out,pos+8,1);found=True
    pos+=size
assert found
pathlib.Path(sys.argv[2]).write_bytes(out)
PY
xcrun lipo "$driver" -thin arm64 -output "$resource/moltenvk-probe.dylib"
codesign --force --sign - "$resource/moltenvk-probe.dylib"
codesign --force --sign - "$resource/game-probe-core.dylib"
set +e
MANIC_PROBE_RESOURCE_DIR="$resource" MANIC_PROBE_DATA_DIR="$data" MANIC_NATIVE_RECORDER_DIRECTORY="$data/native-diagnostics" \
  python3 run_bounded.py 180 "$build/GameProbe"
status=$?
set -e
python3 - "$data" "$build" "$status" <<'PY'
import json,pathlib,shutil,sys
data,build=map(pathlib.Path,sys.argv[1:3]);status=int(sys.argv[3])
for name in ['game-probe.json','core-runtime.log','fatal-signal.bin']:
    p=data/name
    if p.exists():shutil.copyfile(p,build/('private-'+name))
for p in data.glob('private-frame-*.png'):shutil.copyfile(p,build/p.name)
for p in (data/'native-diagnostics').glob('*'):
    if '.hang-' in p.name or p.suffix=='.images':
        shutil.copyfile(p,build/('private-native-'+p.name))
state=build/'private-game-probe.json'
if state.exists():
    report=json.loads(state.read_text());report['native_process_exit_status']=status
    report['host_platform']='macOS ARM64';report['physical_phone_verified']=False
    state.write_text(json.dumps(report,indent=2))
else:
    state.write_text(json.dumps({'native_process_exit_status':status,'game_state_unavailable':True}))
PY
