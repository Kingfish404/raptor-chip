#!/usr/bin/env python3
"""Build and run PLIC architectural width/fault/side-effect core checks."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    for name in ('npc', 'reference', 'mrom', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--cc', default='riscv64-elf-gcc')
    parser.add_argument('--objcopy', default='riscv64-elf-objcopy')
    parser.add_argument('--delays', nargs='+', type=int, default=[0, 7, 63])
    parser.add_argument('--seeds', nargs='+', type=int, default=[1, 42])
    parser.add_argument('--timeout', type=int, default=60)
    parser.add_argument('--cases', nargs='+', type=int, choices=range(5),
                        default=list(range(4)),
                        help='0 byte, 1 half integer, 2 double FP, 3 word control, 4 half FP')
    parser.add_argument('--translated', action='store_true',
                        help='use real Sv32/Sv39 walks with MPRV effective S-mode')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error('output must be empty; preserve previous evidence')
    for name in ('npc', 'reference', 'mrom'):
        value = getattr(args, name).resolve()
        if not value.is_file():
            parser.error(f'missing {name}: {value}')
        setattr(args, name, value)
    out.mkdir(parents=True, exist_ok=True)
    results = []
    failed = False
    for kind in ('load', 'store'):
        source = root / 'app/tests/baremetal/plic_access_width.S'
        for case in args.cases:
            stem = out / f'{kind}-case{case}'
            commands = [
                [args.cc, f'-DPLIC_WIDTH_CASE={case}',
                 f'-DPLIC_WIDTH_STORE={int(kind == "store")}',
                 f'-DPLIC_WIDTH_TRANSLATED={int(args.translated)}',
                 f'-march=rv{args.xlen}imafdc_zicsr_zifencei' + ('_zfhmin' if case == 4 else ''),
                 '-mabi=' + ('ilp32d' if args.xlen == 32 else 'lp64d'),
                 '-nostdlib', '-nostartfiles', '-static', '-Wl,--no-relax',
                 '-T', str(root / 'verify/scripts/fuzz_link.ld'), str(source),
                 '-o', str(stem) + '.elf'],
                [args.objcopy, '-O', 'binary', str(stem) + '.elf', str(stem) + '.bin'],
                [sys.executable, str(root / 'verify/scripts/rva22s64_privileged.py'),
                 '--npc', str(args.npc), '--reference', str(args.reference),
                 '--mrom', str(args.mrom), '--image', str(stem) + '.bin',
                 '--output', str(stem), '--name', f'plic-{kind}-width-{case}',
                 '--timeout', str(args.timeout), '--delays', *map(str, args.delays),
                 '--seeds', *map(str, args.seeds)],
            ]
            row = {'kind': kind, 'case': case, 'source': str(source),
                   'translated': args.translated,
                   'translation_header_sha256': hashlib.sha256(
                       (source.parent / 'plic_width_translate.h').read_bytes()).hexdigest(),
                   'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                   'commands': commands, 'exits': []}
            if case == 4:
                row['half_state_header_sha256'] = hashlib.sha256(
                    (source.parent / 'fp_half_plic_state.h').read_bytes()).hexdigest()
            for command in commands:
                status = subprocess.run(command, cwd=root).returncode
                row['exits'].append(status)
                if status:
                    failed = True
                    break
            results.append(row)
            (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())
