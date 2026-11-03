#!/usr/bin/env python3
"""Build the sampled-JTAG/octal-link integration harness with bounded parallelism."""
import argparse
import hashlib
from pathlib import Path
import subprocess

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('--build', type=Path, required=True)
ap.add_argument('--config', default='small')
ap.add_argument('--xlen', choices=['32', '64'], default='32')
ap.add_argument('--jobs', type=int, default=4)
args = ap.parse_args()
root = Path(__file__).resolve().parents[2]
args.build = args.build.resolve()
args.build.mkdir(parents=True, exist_ok=True)
version = subprocess.check_output(['verilator', '--version'])
key = hashlib.sha256(version).hexdigest()[:12]
model = args.build / ('obj-' + key)
model.mkdir(exist_ok=True)
rtl = root / 'rtl'
sources = [rtl / 'rapt_pkg.sv'] + sorted(p for p in rtl.rglob('*.sv')
                                         if p.name != 'rapt_pkg.sv')
sources += sorted((root / 'synth/configs/pin-limited/rtl').glob('*.sv'))
sources += [root / 'fpga/common/rtl/rapt_xspi_target.sv',
            root / 'sim/tb/rapt_tb_mem.sv', root / 'verification/jtag/sba_top.sv',
            root / 'verification/jtag/sba_server.cc']
command = ['verilator', '--cc', '--exe', '--build', '--assert', '-j', str(max(1, min(4, args.jobs))),
           '--top-module', 'sba_top', '--Mdir', str(model), '-o', 'sba-server',
           '-Wno-fatal', '-Wno-TIMESCALEMOD', '-Wno-WIDTHEXPAND', '-Wno-WIDTHTRUNC',
           '-Wno-UNSIGNED', '-DRAPT_ASSERT_EN']
if args.xlen == '64':
    command += ['-DRAPT_RV64']
for include in [rtl / 'configs' / args.config, rtl / 'include', rtl / 'include/npc',
                rtl / 'include/dpic_mock']:
    command += ['-I' + str(include)]
command += list(map(str, sources))
with (args.build / 'build.log').open('w') as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    print('\n'.join((args.build / 'build.log').read_text().splitlines()[-40:]))
if result.returncode == 0:
    binary = args.build / 'sba-server'
    binary.unlink(missing_ok=True)
    binary.symlink_to(model / 'sba-server')
raise SystemExit(result.returncode)
