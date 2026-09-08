#!/usr/bin/env python3
"""Assemble sampled Zkt inventory encodings for the actual decode-slot test."""
import argparse, json, subprocess
from pathlib import Path


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--xlen', type=int, choices=[32, 64], required=True)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[2]
    scope = json.loads((root/'verify/riscof/raptor-rv64s/zkt-scope.json').read_text())
    rv64 = set('addiw slliw srliw sraiw addw subw sllw srlw sraw mulw c.addiw c.subw c.addw rorw rolw roriw'.split())
    # ZEXT.H uses the RV64 PACKW encoding and this decoder's word marker.
    words = rv64 | ({'zext.h'} if args.xlen == 64 else set())
    shifts = set('slli srli srai slliw srliw sraiw rori roriw'.split())
    immediates = set('addi slti sltiu xori ori andi addiw'.split())
    names = [n for group in scope['instruction_groups'].values() for n in group] + ['zext.h']
    rows = []
    for name in names:
        if args.xlen == 32 and name in rv64:
            continue
        for variant in range(1 if name == 'c.nop' else 2):
            rd, rs1, rs2 = ((8, 9, 10) if variant == 0 else (15, 14, 13))
            if name.startswith('c.'):
                if name == 'c.nop': asm = name
                elif name in ['c.lui']: asm = f'{name} x{rd}, {1 if variant == 0 else 31}'
                elif name in ['c.addi', 'c.addiw', 'c.andi']: asm = f'{name} x{rd}, {1 if variant == 0 else -1}'
                elif name in ['c.slli', 'c.srli', 'c.srai']: asm = f'{name} x{rd}, {1 if variant == 0 else args.xlen-1}'
                else: asm = f'{name} x{rd}, x{rs1}'
            elif name in ['lui', 'auipc']: asm = f'{name} x{rd}, {1 if variant == 0 else 0xfffff}'
            elif name in shifts: asm = f'{name} x{rd}, x{rs1}, {1 if variant == 0 else (31 if name in words else args.xlen-1)}'
            elif name in immediates: asm = f'{name} x{rd}, x{rs1}, {1 if variant == 0 else -2048}'
            elif name in ['rev8', 'zext.h']: asm = f'{name} x{rd}, x{rs1}'
            else: asm = f'{name} x{rd}, x{rs1}, x{rs2}'
            rows.append({'mnemonic':name, 'asm':asm, 'mul':name in scope['instruction_groups']['M'], 'word':name in words, 'compressed':name.startswith('c.')})
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    source = '.section .text\n.option norelax\n' + ''.join(f'.option {"rvc" if row["compressed"] else "norvc"}\nzkt_{i}: {row["asm"]}\n' for i,row in enumerate(rows))
    (out/'vectors.S').write_text(source)
    cmd = ['riscv64-elf-gcc',f'-march=rv{args.xlen}imac_zicsr_zifencei_zbb_zbc',f'-mabi={"lp64" if args.xlen==64 else "ilp32"}','-c',str(out/'vectors.S'),'-o',str(out/'vectors.o')]
    subprocess.run(cmd,check=True)
    subprocess.run(['riscv64-elf-objcopy','-O','binary','-j','.text',str(out/'vectors.o'),str(out/'vectors.bin')],check=True)
    symbols = subprocess.check_output(['riscv64-elf-nm','--defined-only',str(out/'vectors.o')],text=True)
    offsets = {name:int(addr,16) for addr,kind,name in (line.split() for line in symbols.splitlines()) if name.startswith('zkt_')}
    blob = (out/'vectors.bin').read_bytes()
    for i,row in enumerate(rows):
        size = 2 if row['compressed'] else 4
        row['encoding'] = int.from_bytes(blob[offsets[f'zkt_{i}']:offsets[f'zkt_{i}']+size], 'little')
    (out/'vectors.txt').write_text(''.join(f'{row["encoding"]:08x} {int(row["mul"])} {int(row["word"])} {int(row["compressed"])}\n' for row in rows))
    (out/'manifest.json').write_text(json.dumps({'xlen':args.xlen,'command':cmd,'scope':'sampled encoding-to-execution-domain mapping, not exhaustive encodings or timing proof','rows':rows},indent=2)+'\n')
    print(f'Generated {len(rows)} encodings for {len(set(row["mnemonic"] for row in rows))} mnemonics')


if __name__ == '__main__':
    main()
