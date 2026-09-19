#!/usr/bin/env python3
"""Build/run the bare-metal pipeline suite using an existing NPC executable."""
import argparse
import csv
import hashlib
import io
import json
from pathlib import Path
import re
import statistics
import subprocess


def positive(value):
    n = int(value)
    if n <= 0:
        raise argparse.ArgumentTypeError('must be positive')
    return n


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clean_log(text):
    text = re.sub(r'\x1b\[[0-9;]*m', '', text)
    # NPC progress messages share stdout with UART and may split a CSV row.
    # Remove only the recognized diagnostic, retaining both UART fragments.
    return re.sub(r'cpu_exec\.cc:\d+ cpu_exec progress:[^\n]*\n', '', text)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    for name in ('npc', 'mrom', 'output'):
        ap.add_argument('--' + name, type=Path, required=True)
    ap.add_argument('--cross-compile', default='riscv64-elf-')
    ap.add_argument('--rounds', type=positive, default=16)
    ap.add_argument('--samples', type=positive, default=3)
    ap.add_argument('--delay', type=int, default=0)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--timeout', type=positive, default=180)
    ap.add_argument('--label', default='unspecified-existing-simulator')
    args = ap.parse_args()
    if args.rounds > 4096 or args.samples > 32 or args.delay < 0:
        ap.error('require rounds <= 4096, samples <= 32, delay >= 0')
    here = Path(__file__).resolve().parent
    root = here.parents[2]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    # Refuse overwriting completed evidence; each experiment gets its own path.
    if (out / 'run.log').exists():
        ap.error('output already contains run.log; choose a new output directory')
    npc, mrom = args.npc.resolve(strict=True), args.mrom.resolve(strict=True)
    build = ['make', '-C', str(here), 'build', f'XLEN={args.xlen}',
             f'BUILD_DIR={out}', f'CROSS_COMPILE={args.cross_compile}',
             f'ROUNDS={args.rounds}', f'SAMPLES={args.samples}']
    subprocess.run(build, check=True)
    binary = out / 'pipeline.bin'
    cmd = [str(npc), '-b', '-n', '--no-lightsss', '-t', str(args.timeout),
           f'--mem-random-delay={args.delay}', f'--mem-random-seed={args.seed}',
           '-r', str(mrom), str(binary)]
    manifest = {'label': args.label, 'xlen': args.xlen, 'rounds': args.rounds,
                'samples': args.samples, 'delay': args.delay, 'seed': args.seed,
                'difftest': False, 'build_command': build, 'run_command': cmd,
                'inputs_sha256': {str(p): sha(p) for p in (npc, mrom, binary)},
                'benchmark_sha256': {p.name: sha(p) for p in here.iterdir()
                                    if p.is_file()},
                'workspace_head': subprocess.check_output(
                    ['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(),
                'note': 'Existing simulator provenance is supplied by label and executable hash; workspace HEAD is not proof of its RTL source.'}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    with (out / 'run.log').open('w') as log:
        result = subprocess.run(cmd, cwd=out, stdout=log, stderr=subprocess.STDOUT,
                                timeout=args.timeout + 30)
    text = clean_log((out / 'run.log').read_text())
    if f'PIPELINE_BEGIN xlen={args.xlen} rounds={args.rounds} samples={args.samples}' not in text:
        raise SystemExit('FAIL: benchmark configuration header mismatch')
    header = 'case,sample,ops,cycles,instructions,checksum,expected,ok'
    match = re.search(re.escape(header) + r'\r?\n(.*?)PIPELINE_END failures=(\d+)', text, re.S)
    if result.returncode or not match or 'HIT GOOD TRAP' not in text or int(match[2]):
        raise SystemExit(f'FAIL: inspect {out / "run.log"}')
    rows = list(csv.DictReader(io.StringIO(header + '\n' + match[1])))
    names = ('empty add_dep add_8 xor_dep xor_8 mul_dep mul_8 rename_waw '
             'rename_war load_dep load_8_hot load_8_cold load_chain_cold '
             'load_miss_first load_miss_last store_same store_words store_lines store_load').split()
    expected = {(n, str(s)) for n in names for s in range(args.samples)}
    if len(rows) != len(expected) or {(r['case'], r['sample']) for r in rows} != expected:
        raise SystemExit('FAIL: missing or duplicate measurement rows')
    for r in rows:
        for k in header.split(',')[1:]:
            r[k] = int(r[k])
        short = r['case'] in ('empty', 'load_8_cold', 'load_chain_cold', 'load_miss_first', 'load_miss_last')
        expected_ops = (0 if r['case'] == 'empty' else 7 if r['case'].startswith('load_miss_') else 8) if short else 64*args.rounds
        expected_instructions = expected_ops + 2 + (0 if short else 2*args.rounds)
        if r['ops'] != expected_ops or r['instructions'] != expected_instructions:
            raise SystemExit(f'FAIL: unexpected instruction count {r}')
        if r['ok'] != 1 or r['checksum'] != r['expected'] or r['cycles'] <= 0:
            raise SystemExit(f'FAIL: invalid measurement {r}')
    (out / 'measurements.csv').write_text(header + '\n' + match[1])
    baseline = statistics.median(r['cycles'] for r in rows if r['case'] == 'empty')
    summary = []
    for name in names:
        group = [r for r in rows if r['case'] == name]
        cycles = statistics.median(r['cycles'] for r in group)
        ops = group[0]['ops']
        summary.append({'case': name, 'median_cycles': cycles,
                        'min_cycles': min(r['cycles'] for r in group),
                        'max_cycles': max(r['cycles'] for r in group),
                        'median_instructions': statistics.median(r['instructions'] for r in group),
                        'ops': ops,
                        'raw_cycles_per_op': cycles / ops if ops else None,
                        'empty_adjusted_cycles_per_op': (cycles-baseline) / ops if ops else None})
        print(f'{name:20} cycles={cycles:8g} ops={ops:5} '
              f'raw_C/op={cycles/ops if ops else 0:.3f}')
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f'PASS: {len(rows)} checked samples; results in {out}')


if __name__ == '__main__':
    main()
