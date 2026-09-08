#!/usr/bin/env python3
"""Prepare pinned upstream ysyxSoC; never apply Raptor interface patches."""
import argparse
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
REV = 'df38a4d93d1d71e621fe91b106d088bd33af984a'
URL = 'https://github.com/OSCPU/ysyxSoC.git'


def run(args, cwd, **kwargs):
    subprocess.run(args, cwd=cwd, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--soc', type=Path, default=ROOT / 'third_party/OSCPU/ysyxSoC')
    parser.add_argument('--mill', help='Mill 0.12.4 executable; also checks the existing Mill cache')
    parser.add_argument('--java-home', help='JDK 17 directory (does not change the system default)')
    args = parser.parse_args()
    soc = args.soc.resolve()
    if not soc.exists():
        soc.parent.mkdir(parents=True, exist_ok=True)
        run(['git', 'clone', '--depth', '1', '--branch', 'ysyx6', URL, str(soc)], ROOT)
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=soc, text=True).strip()
        if head != REV:
            run(['git', 'fetch', '--depth', '1', 'origin', REV], soc)
            run(['git', 'checkout', '--detach', REV], soc)
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=soc, text=True).strip()
    if head != REV:
        raise SystemExit(f'Expected upstream {REV}, found {head}. Use a separate --soc directory.')
    if subprocess.check_output(['git', 'diff', '--name-only', 'HEAD', '--', 'src', 'patch', 'Makefile', 'build.sc'], cwd=soc):
        raise SystemExit('Upstream source/build files are modified; use a separate --soc directory.')
    run(['git', '-c', 'url.https://github.com/.insteadOf=git@github.com:',
         'submodule', 'update', '--init', '--recursive', '--depth', '1'], soc)
    rocket = soc / 'rocket-chip'
    patch = '../patch/rocket-chip.patch'
    applied = subprocess.run(['git', 'apply', '--reverse', '--check', patch], cwd=rocket,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if not applied:
        run(['git', 'apply', '--check', patch], rocket)
        run(['git', 'apply', patch], rocket)
    version = (soc / '.mill-version').read_text().strip()
    cached_mill = Path.home() / '.cache/mill/download' / version
    mill = args.mill or (str(cached_mill) if cached_mill.is_file() else shutil.which('mill'))
    if not mill:
        raise SystemExit(f'Install Mill {version}, or pass --mill /path/to/mill-{version}.')
    mill = str(Path(mill).resolve())
    env = os.environ.copy()
    java = args.java_home or env.get('JAVA_HOME')
    if not java:
        candidates = [Path('/usr/lib/jvm/java-17-openjdk-amd64'),
                      Path('/home/linuxbrew/.linuxbrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home')]
        java = next((str(p) for p in candidates if (p / 'bin/java').is_file()), None)
    if java:
        env['JAVA_HOME'] = java
        env['PATH'] = str(Path(java) / 'bin') + os.pathsep + env['PATH']
    with tempfile.TemporaryDirectory(prefix='raptor-ysyxsoc-tools-') as tmp:
        # Mill's downloadable launcher is a shell/batch polyglot without a
        # shebang; execve cannot run it directly from Python.
        launcher = Path(tmp, 'mill')
        launcher.write_text('#!/bin/sh\nexec sh ' + shlex.quote(mill) + ' "$@"\n')
        launcher.chmod(0o755)
        env['PATH'] = tmp + os.pathsep + env['PATH']
        installed = subprocess.check_output([str(launcher), '--no-server', '--version'], cwd=soc, env=env, text=True)
        if f'Mill Build Tool version {version}' not in installed:
            raise SystemExit(f'Expected Mill {version}; pass --mill explicitly. Got:\n{installed}')
        run(['make', 'verilog'], soc, env=env)
    print(f'Prepared OSCPU/ysyxSoC {REV}; CPU interfaces remain upstream originals.')


if __name__ == '__main__':
    main()
