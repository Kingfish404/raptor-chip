#!/usr/bin/env python3
"""Audit static M instruction/register coverage of architectural test ELFs.

This does not infer execution coverage from disassembly. Run/signature evidence
must be bound separately to the same ELF hashes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

OPS = {(0x33, f): n for f, n in enumerate(
    ['mul', 'mulh', 'mulhsu', 'mulhu', 'div', 'divu', 'rem', 'remu'])}
OPS.update({(0x3b, f): n for f, n in [(0, 'mulw'), (4, 'divw'),
                                   (5, 'divuw'), (6, 'remw'), (7, 'remuw')]})


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--elf-dir', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--objdump', default='riscv64-elf-objdump')
    args = ap.parse_args()
    rows = []
    failures = []
    seen = set()
    for elf in sorted(args.elf_dir.glob('*.elf')):
        expected = elf.stem.removeprefix('M-').removesuffix('-00')
        if expected not in OPS.values():
            failures.append(f'unrecognized test {elf.name}')
            continue
        seen.add(expected)
        command = [args.objdump, '-d', str(elf)]
        listing = subprocess.check_output(command, text=True)
        ops = []
        for line in listing.splitlines():
            hit = re.match(r'\s*([0-9a-f]+):\s+([0-9a-f]{8})\s', line)
            if not hit:
                continue
            word = int(hit[2], 16)
            if word >> 25 != 1 or word & 127 not in (0x33, 0x3b):
                continue
            op = OPS.get((word & 127, (word >> 12) & 7))
            if op != expected:
                failures.append(f'{elf.name}: unexpected M-space instruction {hit[2]}')
            ops.append({'pc': hit[1], 'encoding': hit[2], 'rd': (word >> 7) & 31,
                        'rs1': (word >> 15) & 31, 'rs2': (word >> 20) & 31})
        regs = {r: sorted({v[r] for v in ops}) for r in ['rd', 'rs1', 'rs2']}
        relations = {
            'rd_rs1': sum(v['rd'] == v['rs1'] for v in ops),
            'rd_rs2': sum(v['rd'] == v['rs2'] for v in ops),
            'rs1_rs2': sum(v['rs1'] == v['rs2'] for v in ops),
            'all_same': sum(v['rd'] == v['rs1'] == v['rs2'] for v in ops),
        }
        if any(v != list(range(32)) for v in regs.values()) or not all(relations.values()):
            failures.append(f'{elf.name}: register or overlap coverage missing')
        rows.append({'elf': str(elf.resolve()), 'sha256': hashlib.sha256(elf.read_bytes()).hexdigest(),
                     'command': command, 'instruction': expected, 'count': len(ops),
                     'registers': regs, 'overlaps': relations, 'sites': ops})
    if seen != set(OPS.values()):
        failures.append('missing instruction families: ' + ', '.join(sorted(set(OPS.values()) - seen)))
    report = {'scope': 'static M instruction sites and register-field coverage; not executed coverage',
              'objdump_version': subprocess.check_output([args.objdump, '--version'], text=True),
              'rows': rows, 'failures': failures}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'{"FAIL" if failures else "PASS"}: {len(rows)} M ELFs, {sum(r["count"] for r in rows)} static sites')
    return int(bool(failures))


if __name__ == '__main__':
    raise SystemExit(main())
