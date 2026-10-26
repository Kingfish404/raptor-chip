#!/usr/bin/env python3
"""Check the actual AXI endpoint with independent burst/data/ordering scoreboards."""
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
        for depth in (1, 3, 8):
            name = f'rv{xlen}-depth{depth}'
            obj = out / name
            command = ['verilator', '--cc', '--exe', '--build', '-j', '4',
                       '--top-module', 'rapt_npc_soc', '--Mdir', str(obj),
                       f'-GReadOutstanding={depth}']
            if xlen == 64:
                command += ['-DRAPT_RV64', '-CFLAGS', '-DTEST_RV64']
            command += [f'-I{root / p}' for p in
                        ('rtl/configs/default', 'rtl/include', 'rtl/include/npc',
                         'rtl/include/dpic')]
            command += [str(root / p) for p in
                        ('rtl/perip/rapt_dpi_c.sv', 'sim/rtl/rapt_npc_soc.sv',
                         'sim/tests/npc_axi_protocol.cc')]
            with (out / f'{name}-build.log').open('w') as log:
                subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
            for latency, jitter, seed in ((0, 0, 1), (2, 0, 1), (7, 0, 1),
                                           (0, 3, 1), (2, 3, 7), (0, 3, 42)):
                for strict in (0, 1):
                    case = f'{name}-lat{latency}-jitter{jitter}-seed{seed}-strict{strict}'
                    with (out / f'{case}.log').open('w') as log:
                        subprocess.run([str(obj / 'Vrapt_npc_soc'), str(depth),
                                        str(latency), str(jitter), str(seed), str(strict)],
                                       check=True, stdout=log, stderr=subprocess.STDOUT)
                    print(f'PASS {case}', flush=True)


if __name__ == '__main__':
    main()
