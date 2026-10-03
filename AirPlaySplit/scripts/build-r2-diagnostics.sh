#!/usr/bin/env bash
# Instrument the installed R2 source without including the later resolution change.
set -euo pipefail
cd "$(dirname "$0")/../.."
repo="$PWD"
base=3f4894d01846a928aa2af17f5cd8bfa1a122b022
metrics=466a171d5e486e253d1ac3c449b23b6f0d5e2f07
git fetch --depth=2 origin "$base" "$metrics"
source_root=AirPlaySplit/build-r2-diagnostic-source
mkdir -p "$source_root/AirPlaySplit/iOS" "$source_root/AirPlaySplit/scripts"
for name in iOS/ManicAirPlaySplit.m iOS/MASRender.m iOS/MASRender.h scripts/build-ios.sh; do
  git show "$base:AirPlaySplit/$name" > "$source_root/AirPlaySplit/$name"
done
git diff "$metrics^" "$metrics" -- AirPlaySplit/iOS/ManicAirPlaySplit.m > "$source_root/metrics.patch"
git apply --check --directory="$source_root" "$source_root/metrics.patch"
git apply --directory="$source_root" "$source_root/metrics.patch"
MAS_BUILD_DIR="$repo/AirPlaySplit/build-r2-diagnostics" bash "$source_root/AirPlaySplit/scripts/build-ios.sh"
python3 - "$base" "$metrics" <<'PY'
import json,pathlib,sys,hashlib
root=pathlib.Path('AirPlaySplit/build-r2-diagnostics')
source=pathlib.Path('AirPlaySplit/build-r2-diagnostic-source/AirPlaySplit/iOS/ManicAirPlaySplit.m')
r={'behavior_source_commit':sys.argv[1],'instrumentation_commit':sys.argv[2],
   'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
   'later_resolution_changes_included':False,'runtime_fix_claimed':False}
(root/'diagnostic-build.json').write_text(json.dumps(r,indent=2))
(root/'ManicAirPlaySplit.framework/SOURCE').write_text(
    f'R2 source: {sys.argv[1]}\nNumeric timing instrumentation: {sys.argv[2]}\n')
PY
