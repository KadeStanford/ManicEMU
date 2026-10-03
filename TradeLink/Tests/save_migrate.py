import hashlib
import pathlib
import struct
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    rom = bytearray(1024 * 1024)
    struct.pack_into('<I', rom, 0, 0xea00002e)
    struct.pack_into('<I', rom, 0xc0, 0xeafffffe)
    rom[0xac:0xb0] = b'BPRE'
    rom[0xb2] = 0x96
    rom[0x200:0x209] = b'FLASH1M_V'
    (root / 'legal.gba').write_bytes(rom)
    battery = root / 'existing.sav'
    subprocess.run([sys.argv[1], sys.argv[2], 'export', str(battery), tmp], check=True)
    before = hashlib.sha256(battery.read_bytes()).hexdigest()
    subprocess.run([sys.argv[1], sys.argv[3], 'import', str(battery), tmp], check=True)
    assert hashlib.sha256(battery.read_bytes()).hexdigest() == before
    print('PASS: existing .sav on disk stayed byte-identical; no save conversion or in-place overwrite')
