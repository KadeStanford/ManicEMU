#!/usr/bin/env python3
"""Execute original/repaired flag-transfer instructions using Unicorn ARM64.

Requires unicorn; uses only a local verified original core, never a game ROM.
"""
import argparse
import json
import pathlib
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM
from unicorn.arm64_const import UC_ARM64_REG_SP, UC_ARM64_REG_X21, UC_ARM64_REG_X25
from enable_3gx import patch_core, sha

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--input', required=True)
parser.add_argument('--report', required=True)
args = parser.parse_args()
original = pathlib.Path(args.input).read_bytes()
patched = patch_core(original)
results = []
for routine, start, end, stack_offset, settings_register in (
        ('startup', 0x52494C, 0x524964, 0x50, UC_ARM64_REG_X25),
        ('settings_update', 0x5281A4, 0x5281BC, 0x10, UC_ARM64_REG_X21)):
    for present in (False, True):
        for enabled, allow in ((False, False), (False, True), (True, False), (True, True)):
            outputs = []
            for binary in (original, patched):
                cpu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
                for address in (start & ~0xFFF, 0x400000, 0x500000, 0x600000):
                    cpu.mem_map(address, 0x1000)
                cpu.mem_write(start, binary[start:end])
                cpu.reg_write(UC_ARM64_REG_SP, 0x400100)
                cpu.reg_write(settings_register, 0x500000)
                cpu.mem_write(0x400100 + stack_offset, (0x600000 if present else 0).to_bytes(8, 'little'))
                cpu.mem_write(0x500650, bytes([enabled]))
                cpu.mem_write(0x500678, bytes([allow]))
                seed = b'\xa5' * 0x100
                cpu.mem_write(0x600000, seed)
                settings = bytes(cpu.mem_read(0x500000, 0x1000))
                cpu.emu_start(start, end)
                memory = bytes(cpu.mem_read(0x600000, len(seed)))
                expected = bytearray(seed)
                if present:
                    expected[0x78:0x7A] = bytes([enabled, allow]) if binary is original else b'\x01\x01'
                assert memory == expected, 'Unexpected plugin service memory change'
                assert bytes(cpu.mem_read(0x500000, 0x1000)) == settings, 'Settings memory changed'
                assert cpu.reg_read(UC_ARM64_REG_SP) == 0x400100
                assert cpu.reg_read(settings_register) == 0x500000
                outputs.append(list(memory[0x78:0x7A]))
            results.append({'routine': routine, 'service_present': present, 'settings_enabled': enabled, 'settings_allow': allow,
                            'original_service_flags': outputs[0], 'patched_service_flags': outputs[1]})
corrupt = bytearray(original)
corrupt[0x5281AC] ^= 1
try:
    patch_core(bytes(corrupt))
    raise AssertionError('Corrupted input accepted')
except ValueError:
    pass
report = {'original_sha256': sha(original), 'patched_sha256': sha(patched),
          'arm64_execution_cases': results, 'null_service_guard_preserved': True,
          'only_service_flags_written': True, 'settings_and_stack_preserved': True,
          'unknown_core_rejected': True, 'game_or_plugin_execution_tested': False}
pathlib.Path(args.report).write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
