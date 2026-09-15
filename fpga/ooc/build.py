#!/usr/bin/env python3
"""Build selected OOC partitions and reject stale checkpoints before merging."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import subprocess

BLOCKS = ('rapt_frontend', 'rapt_backend', 'rapt_l1i', 'rapt_l1d')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--block', choices=BLOCKS, action='append')
    parser.add_argument('--merge', action='store_true')
    parser.add_argument('--route', action='store_true', help='Place/route the merged OOC CPU')
    parser.add_argument('--part', default='xcku15p-ffva1156-2-e')
    parser.add_argument('--period', type=float, default=20.0)
    parser.add_argument('--no-timing-driven', action='store_true',
                        help='Disable partition synthesis timing optimization for runtime/area exploration')
    parser.add_argument('--vivado', default='vivado')
    args = parser.parse_args()
    if args.period <= 0 or (args.route and not args.merge):
        parser.error('period must be positive; --route requires --merge')
    directory = args.directory.resolve()
    script = Path(__file__).with_name('synth.tcl').resolve()
    with (directory / '.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        manifest = json.loads((directory / 'manifest.json').read_text())
        for name, expected in manifest['artifacts'].items():
            if digest(directory / name) != expected:
                raise RuntimeError(f'Changed exported file {name}; rerun export.py')
        version = subprocess.check_output([args.vivado, '-version'], text=True)
        script_bytes = script.read_bytes()
        if args.no_timing_driven:
            anchor = b'synth_design -top ${block}_ooc'
            if script_bytes.count(anchor) != 1:
                raise RuntimeError('Unexpected synthesis Tcl; cannot apply compile mode')
            script_bytes = script_bytes.replace(
                anchor, b'synth_design -no_timing_driven -top ${block}_ooc')
        common = {'tool': version, 'part': args.part, 'period': args.period,
                  'script_sha256': hashlib.sha256(script_bytes).hexdigest()}
        # A long build must not pick up edits to the source Tcl between blocks.
        frozen_script = directory / f"synth-{common['script_sha256']}.tcl"
        frozen_script.write_bytes(script_bytes)
        keys = {name: {**common, 'source_sha256': manifest['blocks'][name]['source_sha256']}
                for name in BLOCKS}

        def cached(name):
            stamp = directory / f'{name}.json'
            checkpoint = directory / f'{name}.dcp'
            if not stamp.exists() or not checkpoint.exists():
                return False
            record = json.loads(stamp.read_text())
            return record.get('key') == keys[name] and record.get('dcp_sha256') == digest(checkpoint)

        def run(name, key, route=False):
            stamp = directory / f'{name}.json'
            stamp.unlink(missing_ok=True)
            cmd = [args.vivado, '-mode', 'batch', '-source', str(frozen_script), '-tclargs',
                   name, args.part, str(args.period), str(int(route))]
            print(f'BUILD {name}', flush=True)
            with (directory / f'{name}-run.log').open('w') as log:
                subprocess.run(cmd, cwd=directory, stdout=log, stderr=subprocess.STDOUT, check=True)
            if 'CRITICAL WARNING:' in (directory / f'{name}-run.log').read_text():
                raise RuntimeError(f'{name} has critical warnings; inspect {name}-run.log')
            stamp.write_text(json.dumps({'key': key, 'command': cmd,
                                         'build_options': {'timing_driven': not args.no_timing_driven},
                                         'dcp_sha256': digest(directory / f'{name}.dcp')}, indent=2) + '\n')

        # With no selection, build all partitions. --merge alone only links
        # already-current checkpoints, so missing/stale blocks cannot be hidden.
        selected = args.block if args.block else ([] if args.merge else BLOCKS)
        for name in selected:
            if cached(name):
                print(f'REUSE {name}', flush=True)
            else:
                run(name, keys[name])
        if args.merge:
            stale = [name for name in BLOCKS if not cached(name)]
            if stale:
                raise RuntimeError('Missing/stale checkpoints; rebuild: ' + ', '.join(stale))
            key = {**common, 'top_sha256': manifest['top_sha256'], 'route': args.route,
                   'partitions': {name: digest(directory / f'{name}.dcp') for name in BLOCKS}}
            run('merge', key, args.route)


if __name__ == '__main__':
    main()
