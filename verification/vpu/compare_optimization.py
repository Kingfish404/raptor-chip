#!/usr/bin/env python3
"""Compare matching VPU test runs with an optimization disabled and enabled."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]


def read_fields(directory, prefix):
    lines = (directory / 'run.log').read_text().splitlines()
    matches = [line for line in lines if line.startswith(prefix)]
    if len(matches) != 1:
        raise ValueError(f'Missing unique completed {prefix} in {directory}')
    return dict(re.findall(r'(\w+)=([0-9a-f]+)', matches[0]))


def require_equal(before, after, keys):
    for key in keys:
        if before[key] != after[key]:
            raise ValueError(f'Workload or coverage differs: {key}')


def read_manifests(baseline, optimized):
    old = json.loads((baseline / 'sources.json').read_text())
    new = json.loads((optimized / 'sources.json').read_text())
    if old['sources'] != new['sources'] or old['verilator'] != new['verilator']:
        raise ValueError('Different source snapshot or simulator')
    for name, digest in old['sources'].items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f'Stale source: {name}')
    return old, new


def compare_leaf(baseline, optimized, kind):
    old, new = read_manifests(baseline, optimized)
    name, parameter, prefix = {
        'muldiv': ('rapt_vpu_muldiv', 'EarlyOut', 'PASS muldiv '),
        'fp-reduce-cache': ('rapt_vpu_fp_reduce_engine', 'CacheMask', 'PASS fp_reduce_engine '),
    }[kind]
    old_params, new_params = dict(old['parameters']), dict(new['parameters'])
    if old['top'] != name or new['top'] != name:
        raise ValueError(f'Expected {name} leaf')
    if old_params.pop(parameter) != 0 or new_params.pop(parameter) != 1:
        raise ValueError(f'Expected disabled then enabled {parameter}')
    if old_params != new_params:
        raise ValueError('Different leaf parameters')
    before, after = read_fields(baseline, prefix), read_fields(optimized, prefix)
    if kind == 'muldiv':
        require_equal(before, after, ('checks', 'seed', 'exhaustive_e8', 'workload_hash'))
        if int(before['exhaustive_e8']) != 524288:
            raise ValueError('Incomplete exhaustive e8 workload')
        metrics = ('cycles',)
        scope = 'Whole leaf simulation cycles with reset and response stalls'
    else:
        require_equal(before, after, ('fingerprint', 'seed', 'cases', 'reset_boundaries'))
        if int(before['cases']) != 4450 or int(before['reset_boundaries']) != 64:
            raise ValueError('Incomplete reduction workload')
        for key, value in old_params.items():
            if int(before[key]) != value or int(after[key]) != value:
                raise ValueError(f'Wrong reduction run parameter: {key}')
        if int(before['cache']) != 0 or int(after['cache']) != 1:
            raise ValueError('Wrong reduction cache setting')
        metrics = ('cycles', 'reads')
        scope = 'Mock-service reduction sequencer workload'
    result = dict(parameters=old_params, baseline=before, optimized=after,
                  sources=old['sources'], verilator=old['verilator'],
                  scope=scope + '; not application throughput or physical PPA')
    for metric in metrics:
        first, second = int(before[metric]), int(after[metric])
        if not 0 < second < first:
            raise ValueError(f'No improvement in {metric}')
        result[metric] = dict(baseline=first, optimized=second,
                              reduction_percent=100 * (first - second) / first)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kind', choices=('operand-reads', 'predicate-cache', 'int-fp-sharing',
                                           'muldiv', 'fp-reduce-cache-matrix'),
                        default='operand-reads')
    parser.add_argument('--build-dir', type=Path, default=ROOT / 'verification/build/vpu')
    parser.add_argument('baseline', type=Path, nargs='?')
    parser.add_argument('optimized', type=Path, nargs='?')
    parser.add_argument('output', type=Path, nargs='?')
    args = parser.parse_args()
    if args.kind == 'fp-reduce-cache-matrix':
        rows = []
        for xlen, vlen, elen in ((64, 128, 64), (32, 128, 32),
                                 (32, 256, 64), (64, 512, 64)):
            prefix = args.build_dir / f'fp-reduce-engine-{xlen}-{vlen}-{elen}-cache'
            rows.append(compare_leaf(Path(str(prefix) + '0'), Path(str(prefix) + '1'),
                                     'fp-reduce-cache'))
        print(json.dumps(dict(configurations=rows), indent=2))
        return
    if args.baseline is None or args.optimized is None or args.output is None:
        parser.error('baseline, optimized and output are required')
    if args.kind == 'muldiv':
        result = compare_leaf(args.baseline, args.optimized, args.kind)
        result['reduction_percent'] = result['cycles']['reduction_percent']
        args.output.write_text(json.dumps(result, indent=2) + '\n')
        print(f"PASS muldiv: {result['cycles']['baseline']} -> "
              f"{result['cycles']['optimized']} cycles")
        return
    before, after = read_manifests(args.baseline, args.optimized)

    setting, suite, prefix = {
        'operand-reads': ('OptimizeOperandReads', 'full', 'PASS top '),
        'predicate-cache': ('CachePredicate', 'predicate-cache', 'PASS predicate_cache '),
        'int-fp-sharing': ('ShareIntFpConverters', 'int-fp', 'PASS int_fp_top '),
    }[args.kind]
    old_config, new_config = dict(before['configuration']), dict(after['configuration'])
    if old_config.pop(setting) != 0 or new_config.pop(setting) != 1:
        raise ValueError(f'Expected disabled then enabled {setting}')
    if old_config != new_config or before.get('suite', 'full') != suite or after['suite'] != suite:
        raise ValueError('Different hardware configuration or workload suite')
    old, new = read_fields(args.baseline, prefix), read_fields(args.optimized, prefix)
    require_equal(old, new, ('commands', 'spike_steps', 'workload_hash'))
    if old_config['Spike']:
        old_reference = json.loads((args.baseline / 'reference.json').read_text())
        new_reference = json.loads((args.optimized / 'reference.json').read_text())
        if old_reference != new_reference or int(old['spike_steps']) == 0:
            raise ValueError('Different or empty Spike reference workload')

    result = dict(configuration=old_config, workload_hash=old['workload_hash'],
                  source_manifest=before['sources'], verilator=before['verilator'])
    if args.kind == 'operand-reads':
        require_equal(old, new, ('arithmetic', 'active_elements', 'seed'))
        old_cycles = int(old['command_latency_cycles'])
        new_cycles = int(new['command_latency_cycles'])
        result.update(arithmetic_instructions=int(old['arithmetic']),
                      scope='Arithmetic command latency including authorization delays; '
                            'not application throughput or physical PPA')
    elif args.kind == 'predicate-cache':
        require_equal(old, new, ('cases', 'elements'))
        old_cycles, new_cycles = int(old['latency']), int(new['latency'])
        result.update(cases=int(old['cases']), elements=int(old['elements']),
                      scope='Masked e8,m4 add/merge command latency including authorization '
                            'delays; not application throughput, physical timing, or power')
    else:
        old_work = read_fields(args.baseline, 'PASS vector_int_fp ')
        new_work = read_fields(args.optimized, 'PASS vector_int_fp ')
        require_equal(old, new, ('seed',))
        require_equal(old_work, new_work, ('cases', 'negative', 'latency'))
        old_cycles, new_cycles = int(old_work['latency']), int(new_work['latency'])
        result.update(cases=int(old_work['cases']), illegal_cases=int(old_work['negative']),
                      scope='Encoded conversion command latency including authorization delays; '
                            'not application throughput or physical timing')

    if args.kind == 'int-fp-sharing' and new_cycles != old_cycles:
        raise ValueError('Shared conversion changed command latency')
    if args.kind != 'int-fp-sharing' and new_cycles >= old_cycles:
        raise ValueError('Optimization did not reduce command latency')
    result.update(baseline_cycles=old_cycles, optimized_cycles=new_cycles,
                  reduction_percent=100 * (old_cycles - new_cycles) / old_cycles)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(f"PASS {args.kind}: {old_cycles} -> {new_cycles} cycles "
          f"({result['reduction_percent']:.3f}% reduction)")


if __name__ == '__main__':
    main()
