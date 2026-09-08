#!/usr/bin/env python3
"""Round-trip non-HINT oracle expansions through the independent GNU assembler."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path
from compressed_vectors import expand, sext


def mnemonic(word, group):
    rd, rs1, rs2 = (word >> 7) & 31, (word >> 15) & 31, (word >> 20) & 31
    op, f = word & 127, (word >> 12) & 7
    imm = sext(word >> 20, 12)
    if group in ('register-load', 'stack-load', 'register-store', 'stack-store'):
        store = 'store' in group
        fp = op in (7, 0x27)
        reg = rs2 if store else rd
        if store:
            imm = sext(((word >> 25) << 5) | ((word >> 7) & 31), 12)
        name = ('f' if fp else '') + ('s' if store else 'l') + ('d' if f == 3 else 'w')
        if group.startswith('stack'):
            name += 'sp'
        return f'c.{name} {"f" if fp else "x"}{reg},{imm}(x{rs1})'
    if group == 'addi4spn':
        return f'c.addi4spn x{rd},sp,{imm}'
    if group == 'addi16sp':
        return f'c.addi16sp sp,{imm}'
    if group in ('addi/nop', 'addiw', 'li', 'andi'):
        return f'c.{"addi" if group == "addi/nop" else group} x{rd},{imm}'
    if group == 'lui':
        return f'c.lui x{rd},{word >> 12}'
    if group in ('slli', 'right-shift'):
        name = 'slli' if group == 'slli' else ('srai' if word & (1 << 30) else 'srli')
        return f'c.{name} x{rd},{(word >> 20) & 63}'
    if group == 'register-arithmetic':
        return f'c.{ {0:"sub",4:"xor",6:"or",7:"and"}[f] } x{rd},x{rs2}'
    if group == 'word-arithmetic':
        return f'c.{"subw" if word & (1<<30) else "addw"} x{rd},x{rs2}'
    if group == 'add/mv':
        return f'c.{"add" if rs1 else "mv"} x{rd},x{rs2}'
    if group in ('jr', 'jalr'):
        return f'c.{group} x{rs1}'
    if group in ('j', 'jal'):
        v = ((word >> 31) << 20) | (((word >> 21) & 1023) << 1) | (((word >> 20) & 1) << 11) | (word & 0xff000)
        return f'c.{group} .+({sext(v,21)})'
    if group == 'branch':
        v = ((word >> 31) << 12) | (((word >> 25) & 63) << 5) | (((word >> 8) & 15) << 1) | (((word >> 7) & 1) << 11)
        return f'c.{"beqz" if f == 0 else "bnez"} x{rs1},.+({sext(v,13)})'
    if group == 'ebreak':
        return 'c.ebreak'
    raise ValueError(group)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--xlen', type=int, choices=[32,64], required=True)
    ap.add_argument('--output', type=Path, required=True)
    a = ap.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    rows = []
    for c in range(65536):
        if c & 3 == 3:
            continue
        kind, word, group = expand(c, a.xlen)
        if kind in (0,3):
            rows.append({'compressed':c,'expanded':word,'asm':mnemonic(word, group)})
    asm = a.output / 'roundtrip.S'
    asm.write_text('.option rvc\n.option norelax\n.section .text\n.globl _start\n_start:\n' + '\n'.join(r['asm'] for r in rows) + '\n')
    elf, binary = a.output/'roundtrip.elf', a.output/'roundtrip.bin'
    commands = [
        ['riscv64-elf-gcc',f'-march=rv{a.xlen}imafdc_zicsr','-mabi='+('lp64d' if a.xlen==64 else 'ilp32d'),'-nostdlib','-nostartfiles','-Wl,--no-relax,-Ttext=0x80000000',str(asm),'-o',str(elf)],
        ['riscv64-elf-objcopy','-O','binary','--only-section=.text',str(elf),str(binary)]]
    for c in commands:
        subprocess.run(c, check=True)
    data = binary.read_bytes()
    expected = b''.join(r['compressed'].to_bytes(2,'little') for r in rows)
    if data != expected:
        for i in range(min(len(rows),len(data)//2)):
            if data[2*i:2*i+2] != expected[2*i:2*i+2]:
                raise AssertionError((i, rows[i], data[2*i:2*i+2].hex(),len(data),len(expected)))
        raise AssertionError((len(data),len(expected)))
    result={'xlen':a.xlen,'cases':len(rows),'commands':commands,'binary_sha256':hashlib.sha256(data).hexdigest(),'source_sha256':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in [Path(__file__),Path(__file__).with_name('compressed_vectors.py')]},'rows':rows,'scope':'GNU assembler round-trip of all included non-HINT legal C encodings; does not check traps, excluded extensions or execution'}
    (a.output/'manifest.json').write_text(json.dumps(result,indent=2)+'\n')
    print(f'PASS: RV{a.xlen} independent assembler round-trip {len(rows)} encodings')


if __name__ == '__main__':
    main()
