#!/usr/bin/env python3
"""Check actual NPC save/load time projection and legacy metadata compatibility.

Compile clint_time_checkpoint.S for the selected XLEN. No reference comparison
of MMIO time is claimed: the guest brackets CSR time with fenced MMIO reads,
and this driver checks the saved counter projection independently.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('npc', 'reference', 'mrom', 'elf', 'image', 'output'):
        parser.add_argument('--' + key, type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    parser.add_argument('--nm', default='riscv64-elf-nm')
    parser.add_argument('--delays', nargs='+', type=int, default=[0, 63])
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    inputs = {key: getattr(args, key).resolve()
              for key in ('npc', 'reference', 'mrom', 'elf', 'image')}
    for path in inputs.values():
        if not path.is_file():
            parser.error(f'missing input: {path}')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    symbols = {}
    for line in subprocess.check_output([args.nm, str(inputs['elf'])], text=True).splitlines():
        fields = line.split()
        if len(fields) == 3:
            symbols[fields[2]] = int(fields[0], 16)
    result = {'xlen': args.xlen, 'inputs': {
        key: {'path': str(path), 'sha256': sha(path)} for key, path in inputs.items()},
        'runs': [], 'passed': False}
    try:
        for delay in args.delays:
            case = output / f'delay{delay}'
            case.mkdir()
            snapshot = case / 'snapshot'
            base = [str(inputs['npc']), '-b', '-n', '--no-lightsss', '-t', '60',
                    f'--mem-random-delay={delay}', '--mem-random-seed=42',
                    '-d', str(inputs['reference']), '-r', str(inputs['mrom'])]

            def run(kind, options):
                command = base + options + [str(inputs['image'])]
                log = case / (kind + '.log')
                record = {'kind': kind, 'delay': delay, 'command': command, 'log': str(log)}
                state_file = snapshot / 'state.txt'
                if state_file.exists():
                    record['input_state_sha256'] = sha(state_file)
                result['runs'].append(record)
                with log.open('w') as stream:
                    rc = subprocess.run(command, cwd=root / 'sim', stdout=stream,
                                        stderr=subprocess.STDOUT, timeout=120).returncode
                text = log.read_text()
                record.update(returncode=rc, sha256=sha(log))
                assert rc == 0 and not any(token in text for token in (
                    '[ERROR]', 'HIT BAD TRAP', 'Assertion failed', 'mismatch')), log
                if kind != 'save':
                    assert 'HIT GOOD TRAP' in text and 'resynchronized difftest REF' in text, log
                record['passed'] = True

            run('save', [f'--ckpt-save={snapshot}',
                         f'--ckpt-pc=0x{symbols["checkpoint_time"]:x}', '--ckpt-save-exit'])
            state_file = snapshot / 'state.txt'
            original = state_file.read_text()
            (case / 'original-state.txt').write_text(original)
            state = dict(line.split('=', 1) for line in original.splitlines() if '=' in line)
            mtime = int(state['clint_mtime'], 0)
            assert mtime >> 32 == 0x12345678, state
            assert int(state['csr_time'], 0) == mtime & ((1 << args.xlen) - 1), state
            assert int(state['csr_timeh'], 0) == mtime >> 32, state
            run('load', [f'--ckpt-load={snapshot}'])
            # Old snapshots could contain unrelated CSR time values. They must
            # not override the authoritative CLINT counter on restore.
            poisoned = '\n'.join(
                line.split('=', 1)[0] + '=0x0' if line.startswith(('csr_time=', 'csr_timeh='))
                else line for line in original.splitlines()) + '\n'
            (case / 'legacy-state.txt').write_text(poisoned)
            try:
                state_file.write_text(poisoned)
                run('load-legacy-time', [f'--ckpt-load={snapshot}'])
            finally:
                state_file.write_text(original)
            print(f'PASS RV{args.xlen} delay={delay}: export, restore, legacy time metadata', flush=True)
        result['passed'] = True
    finally:
        (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
