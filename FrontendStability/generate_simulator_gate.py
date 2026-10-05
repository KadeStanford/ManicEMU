"""Relocate verified frame arithmetic into callable Simulator ARM64 routines.

Branch labels and the original global-page base are relocated to a supplied
private state page. Arithmetic and state instructions remain the actual native
gate instructions. UIKit/Metal/core behavior is not emulated by this harness.
"""
import argparse,json,pathlib,re
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_ARM
from repair_frame_skip_elapsed import ASSEMBLY

def generate():
    here=pathlib.Path(__file__).resolve().parent
    fixture=json.loads((here/'shipped-frame-skip-code.json').read_text())
    baseline=bytes.fromhex(fixture['blocks']['0x247a60'])
    original={i.address:f'{i.mnemonic} {i.op_str}'.strip()
              for i in Cs(CS_ARCH_ARM64,CS_MODE_ARM).disasm(baseline,0x247a60)}
    patched=dict(original);patched.update(ASSEMBLY)
    output=['.text','.p2align 2']
    for symbol,code in [('ManicOriginalFrameSkip',original),('ManicCorrectedFrameSkip',patched)]:
        prefix=symbol+'_'
        output.extend([f'.globl _{symbol}',f'_{symbol}:',
            'stp x23, x28, [sp, #-16]!','sub sp, sp, #0xa00',
            'mov x10, x0','mov x9, x0','mov x23, x1','mov w28, #1',
            'strh w2, [sp, #0x9fa]',f'b {prefix}247a60'])
        for address,instruction in code.items():
            if symbol=='ManicOriginalFrameSkip' and address==0x247a70:
                assert instruction=='adrp x14, #0xadf000'
                instruction='mov x14, x10'
            if instruction.split()[0].startswith(('b','cb','tb')):
                instruction=re.sub(r'#0x([0-9a-f]+)',lambda m:prefix+m[1],instruction)
            output.extend([f'{prefix}{address:x}:',instruction])
        output.extend([f'{prefix}2478a8:','str w11, [x10, #0xd10]','mov w28, #1',f'b {prefix}done',
                       f'{prefix}2478b0:',f'b {prefix}done',
                       f'{prefix}247d18:','brk #1',
                       f'{prefix}done:','str x23, [x10, #0xcf0]','mov w0, w28',
                       'add sp, sp, #0xa00','ldp x23, x28, [sp], #16','ret','.p2align 2'])
    return '\n'.join(output)+'\n'

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--output',type=pathlib.Path,required=True)
    args=parser.parse_args();args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(generate())
