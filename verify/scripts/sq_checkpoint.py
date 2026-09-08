#!/usr/bin/env python3
"""Verify pending retired stores survive an actual architectural save/load."""
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
    parser.add_argument('--kind', choices=('word', 'fp64', 'unaligned'), default='word')
    parser.add_argument('--nm', default='riscv64-elf-nm')
    args = parser.parse_args()
    inputs = {key: getattr(args, key).resolve()
              for key in ('npc', 'reference', 'mrom', 'elf', 'image')}
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[2]
    symbols = {}
    for line in subprocess.check_output([args.nm, str(inputs['elf'])], text=True).splitlines():
        fields = line.split()
        if len(fields) == 3:
            symbols[fields[2]] = int(fields[0], 16)
    result = {'xlen': args.xlen, 'kind': args.kind, 'inputs': {
        key: {'path': str(path), 'sha256': sha(path)} for key, path in inputs.items()},
        'runs': [], 'passed': False}
    snapshot = out / 'snapshot'
    base = [str(inputs['npc']), '-b', '-n', '--no-lightsss', '-t', '60',
            '--mem-random-delay=63', '--mem-random-seed=42',
            '-d', str(inputs['reference']), '-r', str(inputs['mrom'])]

    def run(kind, options):
        command = base + options + [str(inputs['image'])]
        log = out / (kind + '.log')
        with log.open('w') as stream:
            rc = subprocess.run(command, cwd=root / 'sim', stdout=stream,
                                stderr=subprocess.STDOUT, timeout=120).returncode
        text = log.read_text()
        result['runs'].append({'kind': kind, 'command': command,
                               'returncode': rc, 'sha256': sha(log)})
        assert rc == 0 and not any(token in text for token in (
            '[ERROR]', 'HIT BAD TRAP', 'Assertion failed', 'ABORT')), log
        return text

    try:
        text = run('save', [f'--ckpt-save={snapshot}',
                           f'--ckpt-pc=0x{symbols["checkpoint_marker"]:x}', '--ckpt-save-exit'])
        meta = (snapshot / 'mem_pmem.bin.meta').read_text().splitlines()
        chunks = [int(line[6:], 0) for line in meta if line.startswith('chunk=')]
        data = (snapshot / 'mem_pmem.bin').read_bytes()
        width = 8 if args.kind == 'fp64' else args.xlen // 8
        value = 0x123456789abcdef if width == 8 else 0x789abcde
        for word in range(8):
            offset = symbols['checkpoint_data'] - 0x80000000 + word * width
            position = chunks.index(offset & ~4095) * 4096 + (offset & 4095)
            assert int.from_bytes(data[position:position + width], 'little') == value, word
        if args.kind == 'word':
            assert 'overlaid ' in text, 'test did not capture pending committed stores'
        result['snapshot_sha256'] = {p.name: sha(p) for p in snapshot.iterdir() if p.is_file()}
        text = run('load', [f'--ckpt-load={snapshot}'])
        assert 'HIT GOOD TRAP' in text and 'resynchronized difftest REF' in text
        result['passed'] = True
        print(f'PASS RV{args.xlen} {args.kind}: pending stores exported and restored')
    finally:
        (out / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
