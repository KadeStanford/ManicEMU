"""Hash-gated correction of the shipped frontend's 16-bit elapsed-time wrap.

This keeps every frontend entry point, flag, option and resource path intact.
Long monotonic intervals saturate at 65535us rather than wrapping to zero.
The source equivalent is frame_skip_elapsed.patch, against pinned RetroArch.
Only the existing frame-skip arithmetic block is rewritten. Its two interleaved
unrelated instructions remain untouched. No executable code cave is used.
"""
import argparse, hashlib, json, pathlib

INPUT_SHA256 = '0488c5edaa165b25ad29b0194150d868d3a4c66245277f17c26c2c7155d62ec8'
OUTPUT_SHA256 = '6d48094ad63a399ade8872308e1f504cd0db30fe38865ba66eef8d9287db2474'
START, END = 0x247a60, 0x247adc
PROTECTED = (0x247a94, 0x247a98)

# This is the assembled bounded source-equivalent block. Instructions have
# explicit original addresses so native regression and the Apple assembler can
# verify routing independently. Every destination is in the existing function.
ASSEMBLY = {
    0x247a60: 'ldr w12, [x10, #0xd10]',
    0x247a64: 'ldr x11, [x9, #0xcf0]',
    0x247a68: 'sub x13, x23, x11',
    0x247a6c: 'ldrh w11, [sp, #0x9fa]',
    0x247a70: 'mov w14, #0xffff',
    0x247a74: 'cmp x13, x14',
    0x247a78: 'csel w13, w13, w14, ls',
    0x247a7c: 'ldrsb w15, [x10, #0xd14]',
    0x247a80: 'cbz w15, #0x247a9c',
    0x247a84: 'cmp w15, #0',
    0x247a88: 'csinc w15, w15, wzr, ge',
    0x247a8c: 'strb w15, [x10, #0xd14]',
    0x247a90: 'b #0x247ad4',
    0x247a9c: 'mov w15, #0xff',
    0x247aa0: 'strb w15, [x10, #0xd14]',
    0x247aa4: 'mov w14, w12',
    0x247aa8: 'str w14, [x10, #0xd10]',
    0x247aac: 'subs w14, w14, w11',
    0x247ab0: 'cset w28, ge',
    0x247ab4: 'b.lt #0x2478b0',
    0x247ab8: 'sub w12, w11, w13',
    0x247abc: 'cmp w12, w13',
    0x247ac0: 'csel w12, wzr, w13, lt',
    0x247ac4: 'sub w12, w14, w12',
    # Unsigned HI clears both negative remainders and remainders above target.
    # The maintained accumulator is bounded [0,target], so this matches the
    # original signed clamp then runaway check without an overflowing add.
    0x247ac8: 'cmp w12, w11',
    0x247acc: 'csel w11, wzr, w12, hi',
    0x247ad0: 'b #0x2478a8',
    0x247ad4: 'add w14, w12, w13',
    0x247ad8: 'b #0x247aa8',
}

def sha(data):
    return hashlib.sha256(data).hexdigest()

def assemble_block():
    # Generated with Keystone 0.9.2 and checked through actual ARM64 execution.
    # Simulator independently compiles ASSEMBLY using Apple's ARM64 assembler.
    fixture=json.loads(pathlib.Path(__file__).with_name('assembled-frame-skip-code.json').read_text())
    assert set(map(lambda address:int(address,16),fixture))==set(ASSEMBLY)
    for address,instruction in ASSEMBLY.items():
        assert fixture[hex(address)]['assembly']==instruction
    return {int(address,16):bytes.fromhex(entry['bytes']) for address,entry in fixture.items()}

def repair(data):
    if sha(data) != INPUT_SHA256:
        raise ValueError('Refusing an unknown frontend binary')
    assert data[0x247a88:0x247a8c] == bytes.fromhex('8e212d0b')
    patched = bytearray(data)
    for address, instruction in assemble_block().items():
        assert len(instruction) == 4 and address not in PROTECTED
        patched[address:address+4] = instruction
    for address in PROTECTED:
        assert patched[address:address+4] == data[address:address+4]
    assert patched[:START] == data[:START] and patched[END:] == data[END:]
    assert sha(patched)==OUTPUT_SHA256
    return bytes(patched)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input-libretro', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    source = args.input_libretro.read_bytes()
    corrected = repair(source)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('xb') as file:
        file.write(corrected)
    report = {'input_sha256': sha(source), 'output_sha256': sha(corrected),
              'same_size': len(source) == len(corrected),
              'changed_bytes': sum(a != b for a,b in zip(source,corrected)),
              'allowed_range': [hex(START),hex(END)],
              'unrelated_interleaved_instructions_preserved': True,
              'phone_freeze_recovery_verified': False}
    with args.output.with_suffix('.verification.json').open('x') as file:
        json.dump(report,file,indent=2)
    print(json.dumps(report,indent=2))

if __name__ == '__main__':
    main()
