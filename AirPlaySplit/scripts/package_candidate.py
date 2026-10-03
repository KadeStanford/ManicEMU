#!/usr/bin/env python3
"""Make a private unsigned candidate from the verified GBA v0.7 IPA.

Preserves inputs. Allows only Azahar, one additional dylib load command,
one opt-in plist flag, and the new AirPlay framework. No network or signing.
"""
import argparse
import hashlib
import importlib.util
import json
import pathlib
import plistlib
import struct
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ipa_link', ROOT / 'GBLink/scripts/ipa_link.py')
ipa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ipa)
BASELINE = 'C2C290A428853822EAEF85330E5FFBD39B70C85212B7B951B3ADF4937EDFF6E5'
GBA_LOAD = ipa.LOAD_PATH
AIRPLAY_LOAD = '@executable_path/Frameworks/ManicAirPlaySplit.framework/ManicAirPlaySplit'


def digest(data):
    return hashlib.sha256(data).hexdigest().upper()


def exported_symbols(binary):
    offset, size = ipa.slices(binary)
    b = binary[offset:offset + size]
    pos = 32
    for _ in range(struct.unpack_from('<I', b, 16)[0]):
        command, length = struct.unpack_from('<II', b, pos)
        if command == 2:
            symbols, count, strings, string_size = struct.unpack_from('<4I', b, pos + 8)
            result = set()
            for i in range(count):
                name, kind, _, _, _ = struct.unpack_from('<IBBHQ', b, symbols + i * 16)
                if kind & 1 and kind & 14 and not kind & 224:
                    start = strings + name
                    if start >= strings + string_size:
                        raise ValueError('Invalid symbol string offset')
                    result.add(b[start:b.index(b'\0', start, strings + string_size)].decode())
            return result
        pos += length
    raise ValueError('Azahar lacks the symbol table required for ABI verification')


def package(source, core, framework, output):
    source, core, framework, output = map(pathlib.Path, (source, core, framework, output))
    manifest = output.with_suffix(output.suffix + '.verification.json')
    if output.exists() or manifest.exists() or output.resolve() == source.resolve():
        raise ValueError('Choose new output and manifest paths; originals are preserved')
    baseline_hash = digest(source.read_bytes())
    if baseline_hash != BASELINE:
        raise ValueError('Input is not the verified GBA v0.7 IPA')
    files = ipa.framework_files(framework, 'ManicAirPlaySplit')
    core_bytes = core.read_bytes()
    core_info = ipa.inspect_slice(core_bytes)
    if core_info['platform'] != 2 or core_info['filetype'] != 6 or core_info['encrypted']:
        raise ValueError('Azahar must be an unencrypted arm64 physical iOS dylib')
    if any(not path.startswith(('/System/Library/', '/usr/lib/')) for path in core_info['load_paths']):
        raise ValueError('Azahar introduces an unbundled runtime dependency')
    with zipfile.ZipFile(source) as before:
        entries, plist_path, info, binary_path, binary, binary_info = ipa.app_info(before)
        if GBA_LOAD not in binary_info['load_paths']:
            raise ValueError('Existing GBA injection load command is absent')
        app_root = plist_path.rsplit('/', 1)[0]
        core_path = app_root + '/Frameworks/azahar.libretro.framework/azahar.libretro'
        old_core = before.read(core_path)
        missing = exported_symbols(old_core) - exported_symbols(core_bytes)
        if missing:
            raise ValueError('Replacement loses original Azahar exports: ' + ', '.join(sorted(missing)))
        ipa.LOAD_PATH = AIRPLAY_LOAD
        patched = ipa.patch_macho(binary)
        offset, _ = ipa.slices(binary)
        start = offset + binary_info['command_end']
        added_size = (24 + len(AIRPLAY_LOAD.encode()) + 1 + 7) & ~7
        if binary[24:start] != patched[24:start] or binary[start + added_size:] != patched[start + added_size:]:
            raise ValueError('Executable changed outside the load-command insertion')
        new_info = dict(info, MASInjectAirPlaySplit=True)
        replacements = {binary_path: patched, core_path: core_bytes,
                        plist_path: plistlib.dumps(new_info, fmt=plistlib.FMT_BINARY, sort_keys=False)}
        original_hashes = {entry.filename: digest(before.read(entry)) for entry in entries}
        added = {}
        for file in files:
            name = app_root + '/Frameworks/ManicAirPlaySplit.framework/' + file.relative_to(framework).as_posix()
            if name in original_hashes:
                raise ValueError('AirPlay component is already embedded')
            added[name] = file.read_bytes()
        try:
            with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as after:
                for entry in entries:
                    after.writestr(entry, replacements.get(entry.filename, before.read(entry)))
                for name, data in added.items():
                    after.writestr(name, data)
            with zipfile.ZipFile(output) as after:
                bad = after.testzip()
                if bad:
                    raise ValueError('ZIP CRC failed: ' + bad)
                output_hashes = {entry.filename: digest(after.read(entry)) for entry in ipa.checked_entries(after)}
                if set(output_hashes) != set(original_hashes) | set(added):
                    raise ValueError('Unexpected added or missing IPA entry')
                for name, old_hash in original_hashes.items():
                    expected = digest(replacements[name]) if name in replacements else old_hash
                    if output_hashes[name] != expected:
                        raise ValueError('Unexpected content change: ' + name)
                packaged_info = plistlib.loads(after.read(plist_path))
                if {k: v for k, v in packaged_info.items() if k != 'MASInjectAirPlaySplit'} != info:
                    raise ValueError('Unexpected Info.plist change')
            if digest(source.read_bytes()) != baseline_hash:
                raise ValueError('Input IPA changed while packaging')
            report = {
                'baseline_sha256': baseline_hash, 'output_sha256': digest(output.read_bytes()),
                'output_bytes': output.stat().st_size, 'archive_crc_passed': True,
                'original_input_preserved': digest(source.read_bytes()) == baseline_hash,
                'gba_load_command_preserved': GBA_LOAD in ipa.inspect_slice(patched[offset:])['load_paths'],
                'executable_only_adds_load_command': AIRPLAY_LOAD,
                'plist_only_adds_key': 'MASInjectAirPlaySplit',
                'azahar_original_exports_preserved': sorted(exported_symbols(old_core)),
                'changed_entries': {name: {'before': original_hashes[name], 'after': output_hashes[name]} for name in replacements},
                'added_entries': {name: output_hashes[name] for name in added},
                'unchanged_entries': {name: value for name, value in original_hashes.items() if name not in replacements},
                'signing': 'Unsigned. Re-sign the app and all embedded frameworks.',
                'physical_airplay_and_vapecord_tested': False,
            }
            manifest.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
            print(json.dumps({k: report[k] for k in ('output_sha256', 'output_bytes', 'archive_crc_passed', 'gba_load_command_preserved')}))
        except Exception:
            output.unlink(missing_ok=True)
            manifest.unlink(missing_ok=True)
            raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True)
    parser.add_argument('--azahar', required=True)
    parser.add_argument('--framework', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    package(args.input, args.azahar, args.framework, args.output)
