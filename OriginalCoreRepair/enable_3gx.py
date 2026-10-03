#!/usr/bin/env python3
"""Enable the existing 3GX service in the verified original Manic Azahar.

No executable is distributed with this script. Accepts only the exact original
unencrypted iOS core supplied by the user; preserves input and rejects overwrite.
"""
import argparse
import hashlib
import json
import pathlib
import struct

ORIGINAL_SHA256 = '03F7647B550727894E67A72F3F4683033E25C9D3817D43C32887F06999DBC943'
PATCHES = (
    (0x524954, bytes.fromhex('29435939'), bytes.fromhex('29008052'),
     'Core::System::Init: loader is_enabled = true before process start'),
    (0x52495C, bytes.fromhex('29e35939'), bytes.fromhex('29008052'),
     'Core::System::Init: allow_game_change = true before process start'),
    (0x5281AC, bytes.fromhex('a9425939'), bytes.fromhex('29008052'),
     'Core::System::ApplySettings: loader is_enabled = true'),
    (0x5281B4, bytes.fromhex('a9e25939'), bytes.fromhex('29008052'),
     'Core::System::ApplySettings: allow_game_change = true'),
)


def sha(data):
    return hashlib.sha256(data).hexdigest().upper()


def patch_core(data):
    if sha(data) != ORIGINAL_SHA256:
        raise ValueError('Input is not the verified original Manic Azahar core')
    # Thin little-endian ARM64 dylib; addresses below equal file offsets only for
    # this hash. Both loader service null guards and all STRB stores are retained.
    # MOV W9,#1 replaces each flag read, without adding calls or code.
    if struct.unpack_from('<III', data) != (0xFEEDFACF, 0x0100000C, 0):
        raise ValueError('Unexpected original Mach-O architecture')
    out = bytearray(data)
    for offset, before, after, _ in PATCHES:
        if data[offset:offset + 4] != before:
            raise ValueError('Instruction guard failed')
        out[offset:offset + 4] = after
    allowed = {i for offset, before, after, _ in PATCHES for i in range(offset, offset + 4)}
    if len(out) != len(data) or any(a != b and i not in allowed for i, (a, b) in enumerate(zip(data, out))):
        raise ValueError('Unexpected binary change')
    return bytes(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    source, output = pathlib.Path(args.input), pathlib.Path(args.output)
    manifest = pathlib.Path(str(output) + '.verification.json')
    if output.exists() or manifest.exists() or source.resolve() == output.resolve():
        raise ValueError('Output and manifest must be new paths')
    before = source.read_bytes()
    after = patch_core(before)
    output.write_bytes(after)
    report = {'input_sha256': sha(before), 'output_sha256': sha(after),
              'bytes': len(after), 'input_preserved': source.read_bytes() == before,
              'instruction_replacements': [{'offset': hex(o), 'before': b.hex(), 'after': a.hex(), 'purpose': p}
                                           for o, b, a, p in PATCHES],
              'all_other_bytes_unchanged': True, 'instruction_bytes_replaced': 16,
              'original_title_folder_format': 'uppercase 16-digit hexadecimal',
              'plugin_extension': '.3gx', 'physical_plugin_tested': False,
              'signing': 'Unsigned modification; re-sign the embedded core and app.'}
    manifest.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
