#!/usr/bin/env python3
"""Run an explicit supported subset of the upstream debug suite; never use git."""
import argparse
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('--suite', type=Path, required=True)
ap.add_argument('--setup', action='store_true')
ap.add_argument('--npc')
ap.add_argument('--gdb', default='riscv64-elf-gdb')
ap.add_argument('--gcc', default='riscv64-elf-gcc')
ap.add_argument('--openocd', default='openocd')
ap.add_argument('--xlen', choices=['32', '64'], default='32')
ap.add_argument('--port', type=int, default=9824)
ap.add_argument('--output', type=Path)
ap.add_argument('--tests', nargs='+', default=[
    'SimpleS0Test', 'SimpleS1Test', 'SimpleT0Test', 'SimpleT1Test',
    'MemTest8', 'MemTest16', 'MemTest32', 'InstantHaltTest', 'InstantChangePc', 'StepTest'])
args = ap.parse_args()
here = Path(__file__).resolve().parent
suite = args.suite.resolve()
if args.setup and not (suite / 'debug/gdbserver.py').exists():
    suite.parent.mkdir(parents=True, exist_ok=True)
    archive = suite.parent / 'riscv-tests.tar.gz'
    url = 'https://codeload.github.com/riscv-software-src/riscv-tests/tar.gz/refs/heads/master'
    archive.write_bytes(urllib.request.urlopen(url, timeout=60).read())
    with tarfile.open(archive) as source:
        source.extractall(suite.parent, filter='data')
    extracted = suite.parent / 'riscv-tests-master'
    if extracted != suite:
        extracted.rename(suite)
if args.setup:
    # Source archives omit the env submodule needed by the upstream entry code.
    if not (suite / 'env/encoding.h').exists():
        archive = suite.parent / 'riscv-test-env.tar.gz'
        url = 'https://codeload.github.com/riscv/riscv-test-env/tar.gz/refs/heads/master'
        archive.write_bytes(urllib.request.urlopen(url, timeout=60).read())
        with tarfile.open(archive) as source:
            source.extractall(suite.parent, filter='data')
        shutil.copytree(suite.parent / 'riscv-test-env-master', suite / 'env',
                        dirs_exist_ok=True)
    raise SystemExit(0)
if not (suite / 'debug/gdbserver.py').is_file():
    sys.exit('upstream suite missing; run debug-tests-setup or set RISCV_TESTS_REPO')
for name in (args.npc, args.gdb, args.gcc, args.openocd):
    if not name or not shutil.which(name):
        sys.exit(f'upstream prerequisite unavailable: {name}')
if args.output is None:
    ap.error('--output is required')
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env['TMPDIR'] = str(out)
env['PYTHONDONTWRITEBYTECODE'] = '1'
env['RAPT_UPSTREAM_XLEN'] = args.xlen
env['RAPT_UPSTREAM_JTAG_PORT'] = str(args.port)
misa = ((1 if args.xlen == '32' else 2) << (int(args.xlen) - 2)) | 0x14112f
server_command = shlex.join([sys.executable, str(here / 'upstream_openocd.py'),
                             '--openocd', args.openocd])
npc_command = shlex.join([str(Path(args.npc).resolve()), f'--jtag-port={args.port}'])
command = [sys.executable, 'gdbserver.py', str(here / 'upstream.py')] + args.tests + [
           '--sim_cmd', npc_command, '--server_cmd', server_command,
           '--gcc', args.gcc, '--gdb', args.gdb, '--misaval', hex(misa),
           '--logs', str(out / 'logs'), '--isolate', '--print-failures']
print('Running supported upstream subset: ' + ' '.join(args.tests), flush=True)
raise SystemExit(subprocess.call(command, cwd=suite / 'debug', env=env))
