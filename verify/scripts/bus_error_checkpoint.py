#!/usr/bin/env python3
"""Verify posted-write diagnostics across actual NPC save/exit/load runs.

Build bus_write_error.S with RAPT_CKPT_ERROR, then pass its ELF and binary.
The two milestones check pending+overflow and acknowledged diagnostic data.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('npc', 'reference', 'mrom', 'elf', 'image', 'output'):
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--nm', default='riscv64-elf-nm')
    p.add_argument('--delays', nargs='+', type=int, default=[0, 63])
    args = p.parse_args()
    root = Path(__file__).resolve().parents[2]
    paths = {n: getattr(args, n).resolve() for n in ('npc', 'reference', 'mrom', 'elf', 'image')}
    for f in paths.values():
        if not f.is_file():
            p.error(f'missing input: {f}')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    symbols = {}
    for line in subprocess.check_output([args.nm, str(paths['elf'])], text=True).splitlines():
        fields = line.split()
        if len(fields) == 3:
            symbols[fields[2]] = int(fields[0], 16)
    def sha(f):
        return hashlib.sha256(f.read_bytes()).hexdigest()
    result = {'inputs': {n: {'path': str(f), 'sha256': sha(f)} for n, f in paths.items()}, 'runs': []}
    for label, status in [('checkpoint_pending', 0xf03), ('checkpoint_acknowledged', 0xf00)]:
        for delay in args.delays:
            case = output / f'{label}-delay{delay}'
            case.mkdir(exist_ok=True)
            snapshot = case / 'snapshot'
            # Never reuse an old successful snapshot after a failed save.
            if snapshot.exists():
                p.error(f'use a fresh output directory; snapshot exists: {snapshot}')
            base = [str(paths['npc']), '-b', '-n', '--no-lightsss', '-t', '60',
                    f'--mem-random-delay={delay}', '--mem-random-seed=42',
                    '-d', str(paths['reference']), '-r', str(paths['mrom'])]
            commands = [base + [f'--ckpt-save={snapshot}', f'--ckpt-pc=0x{symbols[label]:x}', '--ckpt-save-exit', str(paths['image'])],
                        base + [f'--ckpt-load={snapshot}', str(paths['image'])]]
            for kind, command in zip(('save', 'load'), commands):
                log = case / (kind + '.log')
                with log.open('w') as out:
                    rc = subprocess.run(command, cwd=root / 'sim', stdout=out, stderr=subprocess.STDOUT, timeout=120).returncode
                text = log.read_text()
                assert rc == 0 and not any(s in text for s in ('[ERROR]', 'HIT BAD TRAP', 'Assertion failed', 'mismatch')), log
                if kind == 'save':
                    assert (snapshot / 'state.txt').is_file(), f'no snapshot generated; inspect {log}'
                    state = dict(line.split('=', 1) for line in (snapshot / 'state.txt').read_text().splitlines() if '=' in line)
                    assert int(state['csr_mberr_status'], 0) == status, state
                    assert int(state['csr_mberr_addr'], 0) == 0xc0001000, state
                    assert text.count('AXI write decode error') == 2, log
                else:
                    assert 'HIT GOOD TRAP' in text and 'resynchronized difftest REF' in text, log
                    assert text.count('AXI write decode error') == 3, log
                result['runs'].append({'milestone': label, 'delay': delay, 'kind': kind, 'command': command, 'log': str(log), 'sha256': sha(log), 'passed': True})
                print(f'PASS {label} delay={delay} {kind}', flush=True)
            result.setdefault('states', {})[str(snapshot / 'state.txt')] = sha(snapshot / 'state.txt')
    (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
