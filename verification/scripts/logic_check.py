#!/usr/bin/env python3
"""Named small-module proofs and generic logic estimates, not physical PPA."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

from yosys_common import run_yosys

ROOT = Path(__file__).resolve().parents[2]
MAPPING = "synth -noabc; abc -g simple; clean; stat; ltp -noff (no technology library)"
NO_CHECKS = "select -assert-none t:$check t:$assert t:$assume t:$cover; "
SAT_SUCCESS = "SAT proof finished - no model found: SUCCESS!"
INDUCT_SUCCESS = "Induction step proven: SUCCESS!"
CONFIGS = {
    'rank-select': ('rtl/common/rapt_rank_select.sv', 'formal_rank_select'),
    'rob-age-mask': ('rtl/backend/rapt_rob_age_mask.sv', 'formal_rob_age_mask'),
    'rob-dispatch-select': ('rtl/backend/rapt_rob_dispatch_select.sv', 'formal_rob_dispatch_select'),
    'issue-select': ('rtl/common/rapt_issue_select.sv', 'formal_issue_select'),
    'ras': ('rtl/frontend/branch_predictor/rapt_ras.sv', 'formal_ras'),
    'predict-history': ('rtl/frontend/branch_predictor/rapt_predict_history.sv', 'formal_predict_history'),
    'dispatch-admit': ('rtl/backend/rapt_dispatch_admit.sv', 'formal_dispatch_admit'),
}


def sources(kind):
    dut, top = CONFIGS[kind]
    paths = [ROOT / dut, ROOT / 'verification/formal' / (top + '.sv')]
    if kind == 'rob-dispatch-select':
        paths[:0] = [ROOT / 'rtl/rapt_pkg.sv', ROOT / 'rtl/common/rapt_rank_select.sv']
    elif kind == 'dispatch-admit':
        paths.insert(0, ROOT / 'rtl/rapt_pkg.sv')
    elif kind == 'issue-select':
        paths.append(ROOT / 'verification/formal/formal_issue_select_uniform.sv')
    return paths


def read_design(kind, top, paths, parameters='', synthesis=False):
    includes = (f'-I{ROOT}/rtl/configs/default -I{ROOT}/rtl/include -I{ROOT}/rtl/include/npc '
                if kind in ('rob-dispatch-select', 'dispatch-admit') else '')
    return (f'read_slang --single-unit {"-DSYNTHESIS " if synthesis else ""}--top {top} '
            f'{parameters} {includes}{" ".join(map(str, paths))}; ')


def matrices(args):
    """Yield (phase, log stem, exact tool contract, report row) in execution order."""
    kind = args.check
    paths = sources(kind)
    top = CONFIGS[kind][1]
    if args.mode in ('prove', 'all'):
        if kind == 'rank-select':
            cases = [(1, 1), (3, 4), (13, 3), (128, 1), (128, 2), (128, 3), (128, 4)]
        elif kind == 'rob-age-mask':
            cases = [(n,) for n in (1, 7, 8, 64, 127, 128)]
        elif kind == 'rob-dispatch-select':
            cases = [(1, 1, 1), (3, 2, 2), (7, 3, 3), (7, 2, 4), (16, 4, 4), (16, 2, 8)]
            if args.extended_proof:
                cases.append((64, 4, 4))
        elif kind == 'issue-select':
            cases = ([(1, 1, 0), (4, 2, 0), (4, 2, 1), (5, 3, 2)] + [(8, 4, n) for n in range(4)]
                     if args.matrix == 'uniform' else [(1, 1, 0), (4, 2, 0), (4, 3, 0), (4, 3, 1), (7, 4, 0)])
            if args.matrix == 'uniform':
                top = 'formal_issue_select_uniform'
        elif kind == 'ras':
            cases = [(n,) for n in (1, 3, 4, 16)]
        elif kind == 'predict-history':
            cases = [(1, 1), (7, 3), (64, 8), (128, 16)]
        else:
            cases = [(n,) for n in (1, 2, 3, 4, 8)]
        for values in cases:
            name = 'prove-' + '-'.join(map(str, values))
            goal = 'correct'
            if kind == 'rank-select':
                n, w = values
                parameters = f'-GEntries={n} -GNumSelect={w}'
                row = dict(entries=n, width=w, equivalent=True)
                goal = 'equivalent'
            elif kind == 'rob-age-mask':
                parameters = f'-GEntries={values[0]}'
                row = dict(name=name, equivalent=True)
            elif kind == 'rob-dispatch-select':
                n, w, scan = values
                parameters = f'-GEntries={n} -GWidth={w} -GScanEntries={scan}'
                row = dict(entries=n, width=w, scan_entries=scan, equivalent=True)
            elif kind == 'issue-select':
                n, ports, setting = values
                uniform = args.matrix == 'uniform'
                option = 'LastPort' if uniform else 'InOrder'
                parameters = f'-GEntries={n} -GPorts={ports} -G{option}={setting}'
                if uniform:
                    name = f'prove-uniform-{n}-{ports}-last{setting}'
                row = dict(entries=n, ports=ports, uniform_simple_ports=uniform, contracts_proven=True)
                row['last_port' if uniform else 'in_order'] = setting
            elif kind == 'ras':
                parameters = f'-GDepth={values[0]} -GXlen=32'
                row = dict(depth=values[0], address_bits=32, inductive=True, passed=True)
            elif kind == 'predict-history':
                ghr, phr = values
                parameters = f'-GGhrBits={ghr} -GPhrBits={phr}'
                row = dict(ghr_bits=ghr, phr_bits=phr, passed=True)
            else:
                parameters = f'-GWidth={values[0]}'
                row = dict(width=values[0], contracts_proven=True)
            command = read_design(kind, top, paths, parameters)
            if kind == 'rob-age-mask':
                command += (f'chformal -assume -lower; prep -top {top} -flatten; opt; '
                            'sat -verify -set-assumes -prove correct 1')
            else:
                temporal = kind in ('ras', 'predict-history')
                command += '' if temporal else NO_CHECKS
                command += f'prep -top {top}; flatten; memory_map; opt; '
                command += (f'sat -verify -tempinduct -seq 2 -maxsteps {8 if kind == "ras" else 4} '
                            '-set-at 1 reset 1 -prove correct 1' if temporal else
                            f'sat -verify -prove {goal} 1 -set-def-inputs')
            yield 'proofs', name, command, row
    if args.mode not in ('synth', 'all') or kind == 'dispatch-admit':
        return
    if kind == 'rank-select':
        cases = [(w, t) for w in (1, 2, 3, 4) for t in ('rank_select_reference', 'rapt_rank_select')]
    elif kind == 'rob-age-mask':
        cases = [(n, t) for n in (7, 64, 127, 128) for t in ('rob_age_mask_reference', 'rapt_rob_age_mask')]
    elif kind == 'rob-dispatch-select':
        sizes = [(n, w, w) for n in (16, 32, 64, 128) for w in (2, 4)] + [(64, 2, 4), (64, 2, 8)]
        cases = [(*size, impl, t) for size in sizes for impl, t in
                 (('flat_reference', 'rob_dispatch_select_reference'), ('hierarchical', 'rapt_rob_dispatch_select'))]
    elif kind == 'issue-select':
        sizes = ([(16, p) for p in (1, 2, 3, 4, 6, 8)] if args.matrix == 'port-scaling'
                 else [(8, 1), (8, 2), (8, 3), (16, 4)])
        cases = [(n, p, r) for n, p in sizes for r in (0, 1)]
    elif kind == 'ras':
        cases = [(n,) for n in (1, 3, 4, 16)]
    else:
        cases = [(64, 8)]
    for values in cases:
        inputs = paths
        if kind == 'rank-select':
            w, top = values
            parameters = f'-GEntries=128 -GNumSelect={w}'
            inputs = [paths[1] if top == 'rank_select_reference' else paths[0]]
            name = f'synth-{top}-128-{w}'
            row = dict(implementation=top, entries=128, width=w)
        elif kind == 'rob-age-mask':
            n, top = values
            parameters = f'-GEntries={n}'
            name = f'synth-{n}-{top}'
            row = dict(name=name, entries=n, top=top)
        elif kind == 'rob-dispatch-select':
            n, w, scan, impl, top = values
            parameters = f'-GEntries={n} -GWidth={w} -GScanEntries={scan}'
            name = f'synth-{impl}-{n}-{w}-{scan}'
            row = dict(implementation=impl, entries=n, width=w, scan_entries=scan)
        elif kind == 'issue-select':
            n, p, r = values
            top = 'rapt_issue_select'
            parameters = f'-GEntries={n} -GPorts={p} -GRebalance={r}'
            inputs = paths[:1]
            name = f'synth-{n}-{p}-{r}'
            row = dict(entries=n, ports=p, rebalance=r)
        elif kind == 'ras':
            top = 'rapt_ras'
            parameters = f'-GDepth={values[0]} -GXlen=32'
            inputs = paths[:1]
            name = f'synth-{values[0]}'
            row = dict(depth=values[0], xlen=32)
        else:
            top, parameters, inputs = 'rapt_predict_history', '', paths[:1]
            name = 'synth-64-8'
            row = dict(ghr_bits=64, phr_bits=8, state_bits=216,
                       mapping='abc -g simple; no technology library or physical timing')
        temporal = kind in ('ras', 'predict-history')
        command = read_design(kind, top, inputs, parameters, synthesis=not temporal)
        command += '' if temporal else NO_CHECKS
        command += f'synth -top {top} -noabc; abc -g simple; clean; stat; ltp -noff'
        yield 'generic_synthesis', name, command, row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='check', required=True)
    for kind in CONFIGS:
        p = commands.add_parser(kind)
        p.add_argument('--mode', choices=('prove',) if kind == 'dispatch-admit' else ('prove', 'synth', 'all'),
                       default='prove' if kind == 'dispatch-admit' else 'all')
        default_dir = {'ras': 'ras-check', 'predict-history': 'predict-history'}.get(kind, kind)
        p.add_argument('--output', type=Path, default=ROOT / 'verification/build' / default_dir)
        p.add_argument('--timeout', type=int, default=120 if kind == 'predict-history' else 300)
        if kind == 'issue-select':
            p.add_argument('--matrix', choices=('baseline', 'port-scaling', 'uniform'), default='baseline')
        if kind == 'rob-dispatch-select':
            p.add_argument('--extended-proof', action='store_true')
    args = parser.parse_args()
    if args.check == 'issue-select' and args.matrix == 'uniform' and args.mode != 'prove':
        parser.error('the uniform matrix requires --mode prove')
    args.output.mkdir(parents=True, exist_ok=True)
    report = args.output / 'results.json'
    result = dict(complete=False, mode=args.mode, proofs=[], generic_synthesis=[])
    def save():
        report.write_text(json.dumps(result, indent=2) + '\n')
    save()  # Invalidate old success before reading sources or launching a tool.
    paths = sources(args.check)
    if args.check == 'rob-age-mask':
        paths.append(Path(__file__).resolve())
        result['cases'] = []
    def hashes():
        return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    result.update(source_sha256=hashes(), yosys_version=subprocess.check_output(['yosys', '-V'], text=True).strip())
    if args.check in ('ras', 'predict-history'):
        result['proof_kind'] = ('two-state temporal induction of live-entry relation, reset at step 1'
                                if args.check == 'ras' else 'two-state temporal induction from reset, arbitrary boundary events')
    elif args.check != 'dispatch-admit':
        result['mapping'] = MAPPING
    if args.check == 'issue-select':
        result['matrix'] = args.matrix
    if args.check == 'rob-dispatch-select':
        result.update(schema_version=1, comparisons=[])
    save()
    for phase, name, command, row in matrices(args):
        if args.check == 'rob-age-mask':
            (args.output / (name + '.ys')).write_text(command + '\n')
        output = run_yosys(command, args.output / (name + '.log'), args.timeout)
        if phase == 'proofs':
            success = INDUCT_SUCCESS if args.check in ('ras', 'predict-history') else SAT_SUCCESS
            if success not in output:
                raise RuntimeError(f'{name}: missing proof success marker')
            print(f'PASS: {name}', flush=True)
        else:
            row.update(generic_cells=int(re.findall(r'^\s*(\d+) cells\s*$', output, re.M)[-1]),
                       topological_depth=int(re.findall(r'Longest topological path .*\(length=(\d+)\)', output)[-1]))
            print(json.dumps(row), flush=True)
        result['cases' if args.check == 'rob-age-mask' else phase].append(row)
        save()
    if args.check == 'rob-dispatch-select' and args.mode in ('synth', 'all'):
        rows = result['generic_synthesis']
        for flat, tree in zip(rows[::2], rows[1::2]):
            comparison = {key: flat[key] for key in ('entries', 'width', 'scan_entries')}
            for field, output in [('generic_cells', 'generic_cell_reduction_percent'),
                                  ('topological_depth', 'topological_depth_reduction_percent')]:
                comparison[output] = (flat[field] - tree[field]) / flat[field] * 100.0
            result['comparisons'].append(comparison)
            print('COMPARE: ' + json.dumps(comparison), flush=True)
    if hashes() != result['source_sha256']:
        raise RuntimeError('source changed during logic evaluation')
    result['complete'] = True
    save()


if __name__ == '__main__':
    main()
