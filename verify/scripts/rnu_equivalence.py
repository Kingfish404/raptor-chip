#!/usr/bin/env python3
"""Compare full RNU sources at independent D/R/C widths with native undef checks.

Only the RNU source differs; package, headers and submodules are shared inputs.
No equivalence point is waived. This is not a whole-core ISA proof.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DEPENDENCIES = ('rapt_pkg.sv', 'common/rapt_stream_queue.sv',
                'common/rapt_rank_select.sv', 'frontend/rapt_rename_checkpoint.sv',
                'frontend/rapt_rename_admit.sv')
REQUIRED = {'free_q', 'map_snapshot', 'rat_snapshot', 'checkpoint_allocate_map',
            'checkpoint_allocate_free', 'checkpoints.valid_q', 'idu_rnu.ready',
            'rnu_rou.slot', 'rnu_rou.valid', 'rnu_rou.empty',
            'rnu_rou.checkpoint', 'rnu_rou.checkpoint_valid',
            'rnq.head', 'rnq.tail', 'rename_pipe.head', 'rename_pipe.tail'}
STATE_FAMILIES = ('map_q', 'rat_q', 'rnq.storage', 'rename_pipe.storage',
                  'checkpoints.map_q', 'checkpoints.free_q', 'checkpoints.older_q')


def audit(log):
    final = log.rsplit('Executing EQUIV_STATUS pass.', 1)
    if len(final) != 2 or 'ERROR:' in log:
        raise ValueError('missing final status or tool error')
    match = re.search(r'Found (\d+) \$equiv cells in equiv:\s*'
                      r'Of those cells (\d+) are proven and (\d+) are unproven\.', final[1])
    if not match or 'Equivalence successfully proven!' not in final[1]:
        raise ValueError('incomplete equivalence status')
    total, proven, remaining = map(int, match.groups())
    if total == 0 or proven != total or remaining:
        raise ValueError('vacuous or unproven equivalence points')
    points = set(re.findall(r'^Presumably equivalent wires:.* -> (\S+)$', log, re.M))
    if not REQUIRED <= points:
        raise ValueError(f'missing RNU observations: {sorted(REQUIRED - points)}')
    families = {}
    for family in STATE_FAMILIES:
        indices = sorted(int(m.group(1)) for p in points
                         if (m := re.fullmatch(re.escape(family) + r'\[(\d+)\]', p)))
        if not indices:
            raise ValueError(f'missing RNU state family: {family}')
        families[family] = indices
    return dict(proven_cells=proven, unproven_cells=remaining,
                required_observations=sorted(REQUIRED), state_indices=families)


def script(baseline, xlen, decode_width=4, rename_width=3, commit_width=4):
    if min(decode_width, rename_width, commit_width) < 1:
        raise ValueError('decode, rename and commit widths must be positive')
    commands = []
    for label, source in (('gold', baseline), ('gate', ROOT / 'hdl/frontend/rapt_rnu.sv')):
        commands += [
            'read_slang --single-unit --allow-toplevel-iface-ports -DSYNTHESIS '
            + ('-DRAPT_RV64 ' if xlen == 64 else '')
            + f'-DRAPT_DECODE_WIDTH={decode_width} -DRAPT_RENAME_WIDTH={rename_width} '
            + f'-DRAPT_COMMIT_WIDTH={commit_width} '
            + f'-I{ROOT}/hdl/configs/default -I{ROOT}/hdl/include --top rapt_rnu '
            + ' '.join(str(ROOT / 'hdl' / f) for f in DEPENDENCIES) + f' {source}',
            'select -assert-none t:$check t:$assert t:$assume t:$cover',
            'prep -top rapt_rnu -flatten', 'check -assert', 'memory_map', 'opt',
            f'rename rapt_rnu {label}', f'design -stash {label}']
    commands += ['design -copy-from gold -as gold gold',
                 'design -copy-from gate -as gate gate',
                 'equiv_make gold gate equiv', 'hierarchy -top equiv',
                 'opt_merge', 'equiv_simple -undef -short', 'equiv_status -assert']
    return ';\n'.join(commands) + '\n'


def manifest(baseline):
    files = {baseline, ROOT / 'hdl/frontend/rapt_rnu.sv', Path(__file__).resolve()}
    files.update(ROOT / 'hdl' / f for f in DEPENDENCIES)
    for directory in ('hdl/include', 'hdl/configs/default'):
        files.update((ROOT / directory).rglob('*.svh'))
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-rnu', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('--decode-width', type=int, default=4)
    parser.add_argument('--rename-width', type=int, default=3)
    parser.add_argument('--commit-width', type=int, default=4)
    args = parser.parse_args()
    baseline = args.baseline_rnu.resolve()
    if any(c.isspace() or c in ';"' for p in (baseline, ROOT) for c in str(p)):
        raise ValueError('source paths must not contain whitespace, quotes or semicolons')
    args.output.mkdir(parents=True, exist_ok=True)
    report = args.output / 'results.json'
    widths = dict(decode_width=args.decode_width, rename_width=args.rename_width,
                  commit_width=args.commit_width)
    result = dict(complete=False, scope='RNU source-only comparison', widths=widths, cases=[])

    def save():
        report.write_text(json.dumps(result, indent=2) + '\n')

    save()
    if min(widths.values()) < 1 or args.timeout < 1:
        raise ValueError('widths and timeout must be positive')
    result['source_sha256'] = manifest(baseline)
    save()
    for xlen in (32, 64):
        ys = args.output / f'rv{xlen}.ys'
        ys.write_text(script(baseline, xlen, **widths))
        row = dict(xlen=xlen, proven=False)
        result['cases'].append(row)
        save()
        with (args.output / f'rv{xlen}.log').open('w') as stream:
            try:
                run = subprocess.run(['yosys', '-Q', '-T', '-m', 'slang', '-s', str(ys)],
                                     cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                                     timeout=args.timeout)
            except subprocess.TimeoutExpired:
                row['timeout'] = True
                save()
                raise
        row['returncode'] = run.returncode
        save()
        if run.returncode:
            raise RuntimeError(f'RV{xlen} equivalence tool failed')
        row['audit'] = audit((args.output / f'rv{xlen}.log').read_text())
        if manifest(baseline) != result['source_sha256']:
            raise RuntimeError('proof sources changed during run')
        row['proven'] = True
        save()
        print(f'PASS: RV{xlen} D/R/C={args.decode_width}/{args.rename_width}/{args.commit_width} '
              f'{row["audit"]["proven_cells"]} equivalence points', flush=True)
    result['complete'] = True
    save()


if __name__ == '__main__':
    main()
