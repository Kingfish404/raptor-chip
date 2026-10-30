#!/usr/bin/env python3
"""Cross-check the actual recovery selector with Pono IC3 and replayable witnesses."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

from yosys_common import ROOT

DUT = ROOT / 'rtl/backend/rapt_recovery_pending.sv'
REFERENCE = ROOT / 'verification/formal/formal_recovery_pending.sv'
OSS = ROOT / 'third_party/oss-cad-suite'
MUTATIONS = {
    'port-mask': ('localparam int Port = active_port(leaf - 1);',
                  'localparam int Port = leaf - 1;'),
    'held-tie': ('tree_age[2*node] <= tree_age[2*node+1]',
                 'tree_age[2*node] < tree_age[2*node+1]'),
    'owner-generation': ('owner_generation[owner] == generation', "1'b1"),
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(command, directory, label, timeout):
    log = directory / (label + '.log')
    started = time.time()
    with log.open('w') as stream:
        try:
            process = subprocess.run(list(map(str, command)), cwd=ROOT, stdout=stream,
                                     stderr=subprocess.STDOUT, timeout=timeout)
            code = process.returncode
        except subprocess.TimeoutExpired:
            code = 'timeout'
    return dict(command=list(map(str, command)), exit=code, seconds=time.time() - started,
                log=str(log), log_sha256=sha(log))


def outcome(record):
    text = Path(record['log']).read_text(errors='replace')
    decisions = re.findall(r'^(sat|unsat|unknown)\s*$', text, re.MULTILINE)
    if len(decisions) != 1 or 'ERROR' in text:
        return 'error'
    expected_exit = {'sat': 0, 'unsat': 1, 'unknown': 2}[decisions[0]]
    if record['exit'] != expected_exit:
        return 'error'
    return decisions[0]


def monitor_source(required_events):
    text = REFERENCE.read_text()
    anchor = '  logic past_valid = 0;'
    if text.count(anchor) != 1:
        raise ValueError('Recovery reference monitor anchor changed')
    monitor = f'''
  logic [6:0] pono_seen_events = 0;
  always_ff @(posedge clock) begin
    if (!past_valid) assume (reset);
    assert (correct);
    pono_seen_events <= pono_seen_events | activated;
    cover ((pono_seen_events & 7'd{required_events}) == 7'd{required_events});
  end
'''
    return text.replace(anchor, anchor + monitor)


def tool_path(value):
    candidate = shutil.which(value) if '/' not in value else value
    if not candidate or not Path(candidate).is_file():
        raise ValueError('Missing tool: ' + value)
    return Path(candidate).resolve()


def dimensions(value):
    try:
        entries, ports, mask, width, generation = [int(field, 0) for field in value.split(':')]
    except ValueError as error:
        raise argparse.ArgumentTypeError('Use Entries:Ports:Mask:TargetBits:GenerationBits') from error
    if (min(entries, ports, width, generation) < 1 or ports > 64
            or not 0 <= mask < 2**ports):
        raise argparse.ArgumentTypeError('Invalid recovery dimensions or port mask')
    return entries, ports, mask, width, generation


def run_case(args, entries, ports, mask, width, mutation=None, generation_bits=4):
    name = mutation or f'e{entries}-p{ports}-m{mask:x}-x{width}-g{generation_bits}'
    directory = args.output / name
    directory.mkdir()
    source = DUT
    if mutation:
        old, new = MUTATIONS[mutation]
        text = DUT.read_text()
        if text.count(old) != 1:
            raise ValueError('Recovery mutation anchor changed: ' + mutation)
        source = directory / 'mutant.sv'
        source.write_text(text.replace(old, new))
    events = [0] + ([1, 2, 3, 4, 6] if mask else [])
    if mask != (1 << ports) - 1:
        events.append(5)
    required = sum(1 << event for event in events)
    reference = directory / 'reference-with-monitor.sv'
    reference.write_text(monitor_source(required))
    safety, cover = directory / 'safety.btor2', directory / 'cover.btor2'
    script = directory / 'model.ys'
    script.write_text(
        'read_slang --threads 1 --single-unit -DFORMAL --top formal_recovery_pending '
        f'-GEntries={entries} -GPorts={ports} -GPortMask={mask} -GXlen={width} '
        f'-GGenerationBits={generation_bits} '
        f'{source} {reference}\n'
        'async2sync\nchformal -lower\nprep -top formal_recovery_pending -flatten\n'
        'memory_map\nopt\ndffunmap\n'
        'select -assert-count 1 t:$assert\nselect -assert-count 2 t:$assume\n'
        'select -assert-count 1 t:$cover\nselect -assert-none A:blackbox=1\n'
        'setundef -undriven -anyseq\ncheck -assert\n'
        f'write_btor -s {safety}\nwrite_btor -c {cover}\n')
    model = execute([args.yosys, '-Q', '-T', '-m', 'slang', '-s', script], directory,
                    'model', args.timeout)
    engine = 'bmc' if mutation else 'ic3bits'
    row = dict(name=name, entries=entries, ports=ports, port_mask=mask, target_bits=width,
               generation_bits=generation_bits, engine=engine, required_events=events,
               stages={'model': model}, passed=False)
    if model['exit'] != 0:
        return row
    for path in (safety, cover):
        if len(re.findall(r'^\d+ bad ', path.read_text(), re.MULTILINE)) != 1:
            raise ValueError('Expected exactly one aggregate BTOR property: ' + str(path))
    command = [args.pono, '--engine', engine, '--smt-solver', 'btor', '--bound', str(args.bound)]
    if mutation:
        command += ['--witness', '--vcd', str(directory / 'counterexample.vcd')]
    else:
        command += ['--check-invar']
    proof = execute(command + [safety], directory, 'safety', args.timeout)
    row['stages']['safety'] = proof
    expected = 'sat' if mutation else 'unsat'
    if outcome(proof) != expected:
        return row
    if mutation:
        replay = execute([args.btorsim, '-c', safety, proof['log']], directory,
                         'counterexample-replay', args.timeout)
        row['stages']['counterexample_replay'] = replay
        row['passed'] = (replay['exit'] == 0
                         and (directory / 'counterexample.vcd').stat().st_size > 0)
    else:
        if 'Invariant Check PASSED' not in Path(proof['log']).read_text():
            return row
        witness = execute([args.pono, '--engine', 'bmc', '--bound', str(args.bound),
                           '--witness', '--vcd', str(directory / 'reachability.vcd'), cover],
                          directory, 'reachability', args.timeout)
        row['stages']['reachability'] = witness
        if outcome(witness) != 'sat':
            return row
        replay = execute([args.btorsim, '-c', cover, witness['log']], directory,
                         'reachability-replay', args.timeout)
        row['stages']['reachability_replay'] = replay
        row['passed'] = replay['exit'] == 0 and (directory / 'reachability.vcd').stat().st_size > 0
    row['artifacts'] = {p.name: sha(p) for p in directory.iterdir() if p.is_file()}
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--pono', default=str(OSS / 'bin/pono'))
    parser.add_argument('--btorsim', default=str(OSS / 'bin/btorsim'))
    parser.add_argument('--yosys', default=os.environ.get('RAPTOR_YOSYS_REAL', 'yosys'))
    parser.add_argument('--bound', type=int, default=32)
    parser.add_argument('--timeout', type=int, default=180)
    parser.add_argument('--case', type=dimensions, action='append', dest='dimensions',
                        help='Entries:Ports:Mask:TargetBits:GenerationBits; repeat for a matrix')
    args = parser.parse_args()
    if args.bound < 1 or args.timeout < 1:
        parser.error('Bound and timeout must be positive')
    args.output = args.output.resolve()
    if args.output.exists() and any(args.output.iterdir()):
        parser.error('Output must be empty to preserve previous evidence')
    for path in (ROOT, args.output):
        if any(c.isspace() or c in ';"' for c in str(path)):
            parser.error('Yosys paths cannot contain whitespace, quotes or semicolons')
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(complete=False, passed=False, whole_rtl_signoff=False, cases=[],
                  scope='Full recovery selector/reference relation, without internal proof cuts',
                  assumptions=['First sampled edge resets', 'ROB head is below Entries'])
    result = args.output / 'report.json'

    def save():
        result.write_text(json.dumps(report, indent=2) + '\n')

    save()
    for name in ('pono', 'btorsim', 'yosys'):
        setattr(args, name, tool_path(getattr(args, name)))
    inputs = [DUT, REFERENCE, Path(__file__), Path(__file__).with_name('yosys_common.py')]
    hashes = {str(p.relative_to(ROOT)): sha(p) for p in inputs}
    report.update(sources=hashes, tools={name: dict(path=str(getattr(args, name)),
                  sha256=sha(getattr(args, name))) for name in ('pono', 'btorsim', 'yosys')})
    for name in ('pono', 'btorsim'):
        payload = getattr(args, name).parent.parent / 'libexec' / name
        if payload.is_file():
            report['tools'][name]['payload_sha256'] = sha(payload)
    try:
        if args.dimensions:
            cases = [(e, p, m, x, None, g) for e, p, m, x, g in dict.fromkeys(args.dimensions)]
        else:
            cases = [(3, 3, 5, 8, None), (7, 3, 7, 32, None), (16, 5, 21, 64, None)]
        cases += [(7, 3, 5, 32, name) for name in MUTATIONS]
        for case in cases:
            row = run_case(args, *case)
            report['cases'].append(row)
            print(row['name'], 'PASS' if row['passed'] else 'INCOMPLETE', flush=True)
            save()
        report['inputs_unchanged'] = all(
            sha(ROOT / name) == value for name, value in hashes.items())
        report['complete'] = True
        report['passed'] = (report['inputs_unchanged']
                            and all(row['passed'] for row in report['cases']))
    finally:
        save()
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
