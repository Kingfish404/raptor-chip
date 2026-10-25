#!/usr/bin/env python3
"""Compile and exercise the actual NPC endpoint at both XLENs and queue limits."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    for xlen in (32, 64):
        obj = out / f'obj{xlen}'
        command = ['verilator', '--cc', '--exe', '--build', '-j', '4',
                   '--top-module', 'rapt_npc_soc', '--Mdir', str(obj)]
        if xlen == 64:
            command += ['-DRAPT_RV64', '-CFLAGS', '-DTEST_RV64']
        command += [f'-I{root / name}' for name in
                    ('hdl/configs/default', 'hdl/include', 'hdl/include/npc', 'hdl/include/dpic')]
        command += [str(root / name) for name in
                    ('hdl/rapt_pkg.sv', 'hdl/perip/rapt_dpi_c.sv', 'sim/rtl/rapt_npc_soc.sv',
                     'sim/tests/npc_write_outstanding.cc')]
        with (out / f'build{xlen}.log').open('w') as log:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
        for count in (1, 2, 4, 8, 64):
            with (out / f'run{xlen}-{count}.log').open('w') as log:
                subprocess.run([str(obj / 'Vrapt_npc_soc'), str(count)], check=True,
                               stdout=log, stderr=subprocess.STDOUT)
            print(f'PASS RV{xlen} outstanding={count}', flush=True)


if __name__ == '__main__':
    main()
