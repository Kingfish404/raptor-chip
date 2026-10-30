#!/usr/bin/env python3
"""Prove PRF history, unrestricted views, composition and byte partitions."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
from yosys_common import ROOT, run_bounded, run_yosys


FORMAL = ROOT / 'verification/formal'

HARNESS = FORMAL / 'formal_prf.sv'

DUT = ROOT / 'rtl/backend/rapt_prf.sv'

SMTIO = ROOT / 'third_party/oss-cad-suite/share/yosys/python3/smtio.py'


def snapshot_query(query, expanded):
    """Expand one unrestricted snapshot using the bundled Yosys SMT interface."""
    sys.path.insert(0, str(SMTIO.parent))
    from smtio import SmtIo, SmtOpts

    options = SmtOpts()
    options.solver = 'bitwuzla'
    options.unroll = True
    options.timeinfo = False
    with expanded.open('w') as stream:
        options.debug_file = stream
        solver = SmtIo(options)
        text = query.read_text()
        if text.splitlines().count('(check-sat)') != 1:
            raise ValueError('Expected exactly one unrestricted snapshot query')
        for line in text.splitlines():
            if line == '(check-sat)':
                print(solver.check_sat(), flush=True)
            else:
                solver.write(line)
        solver.write('(exit)')
        solver.wait()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def history_harness(text):
    """Replace only the five view assertions with their activation covers."""
    module = re.search(r'(?ms)^module formal_prf_contract\b.*?^endmodule\b', text)
    if not module:
        raise ValueError('Missing PRF history harness')
    text = '`include "rapt.svh"\n`include "rapt_if.svh"\n\n' + module[0] + '\n'
    start = '  for (genvar r = 1; r < ArchRegs; r++) begin : g_architectural\n'
    end = '  for (genvar p = 0; p < Ports; p++) begin : g_writer_cover\n'
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError('PRF view partition boundaries changed')
    before, fragment = text.split(start)
    fragment, after = fragment.split(end)
    pattern = r'\bassert\s*\([^;]+?\);'
    predicates = re.findall(pattern, fragment)
    expected = [
        'assert (rf[r] == 0 && rf_map[r] == 0);',
        "assert (rf[r][int'(watched_byte)*8+:8] == expected_byte);",
        "assert (rf_map[r][int'(watched_byte)*8+:8] == expected_byte);",
        'assert (rvfi_value[c] == 0);',
        "assert (rvfi_value[c][int'(watched_byte)*8+:8] == expected_byte);",
    ]
    if predicates != expected:
        raise ValueError('PRF view obligations changed; review the composition')
    fragment = re.sub(pattern, "cover (1'b1);", fragment)
    return before + start + fragment + end + after


def audit_frontend(text, expected_assertions):
    """Reject initial-state restrictions and time-dependent property sampling."""
    if re.search(r'^\s*attribute \\init\b', text, re.M):
        raise ValueError('Register initialization restricts the all-state lemma')
    cells = re.findall(r'^  cell (\S+) ([^\n]+)\n(.*?)^  end\n', text, re.M | re.S)
    assertions = covers = 0
    for kind, name, body in cells:
        if kind.startswith(('$meminit', '$any')) or kind in ('$initstate', '$assume'):
            raise ValueError('Restricted or abstract state in view lemma: ' + kind)
        if kind != '$check':
            continue
        trigger = re.search(r'^    parameter \\TRG_ENABLE (\d+)\s*$', body, re.M)
        flavor = re.search(r'^    parameter \\FLAVOR "([^"]+)"\s*$', body, re.M)
        if not trigger or trigger[1] != '0' or not flavor:
            raise ValueError('Clocked or unknown formal check: ' + name)
        if flavor[1] == 'assert':
            assertions += 1
        elif flavor[1] == 'cover':
            covers += 1
        else:
            raise ValueError('Environmental formal predicate in view lemma: ' + flavor[1])
    if assertions != expected_assertions or covers < 1:
        raise ValueError('Missing view assertions or activation covers')
    return {'assertions_before_optimization': assertions, 'covers_before_optimization': covers,
            'no_initializers': True, 'no_clocked_checks': True, 'no_abstract_state': True}


def audit_model(text, top='formal_prf_views'):
    """A shallow sequential proof with a nontrivial initial predicate is rejected."""
    result = {}
    for suffix in ('i', 'h', 'u'):
        prefix = '(define-fun |' + top + '_' + suffix + '| '
        lines = [line.strip() for line in text.splitlines() if line.startswith(prefix)]
        expected = prefix + '((state |' + top + '_s|)) Bool true)'
        if lines != [expected]:
            raise ValueError('View lemma restricts current state or inputs: ' + suffix)
        result[suffix] = 'true'
    return result


def composition_lemma(directory, lutram):
    """Prove byte-history substitution and reject missing essential premises."""
    directory.mkdir(parents=True, exist_ok=False)
    declarations = '''(set-logic QF_UF)
(declare-sort Address 0)
(declare-sort Word 0)
(declare-sort Byte 0)
(declare-sort Lane 0)
(declare-const a Address)
(declare-const mapped Address)
(declare-const lane Lane)
(declare-const expected Byte)
(declare-const observed Word)
(declare-const known Bool)
(declare-fun valid (Address) Bool)
(declare-fun live (Address) Bool)
(declare-fun shadow (Address) Word)
(declare-fun byte (Word Lane) Byte)
'''
    if lutram:
        declarations += '(declare-fun payload (Address Lane) Byte)\n'
    else:
        declarations += ('(define-fun payload ((x Address) (b Lane)) Byte '
                         '(byte (shadow x) b))\n')
    premises = {
        'address': '(valid a)',
        'history': '(=> known (= (payload a lane) expected))',
        'view': '(=> (valid mapped) (= observed (shadow mapped)))',
    }
    if lutram:
        premises['live-bank'] = '(=> known (live a))'
        premises['shadow'] = ('(=> (and (valid a) (live a)) '
                              '(= (byte (shadow a) lane) (payload a lane)))')
    goal = '(=> (and known (= mapped a)) (= (byte observed lane) expected))'
    cases = [('substitution', None, False, 'unsat'),
             ('activation', None, True, 'sat'),
             ('missing-history', 'history', False, 'sat'),
             ('missing-view', 'view', False, 'sat')]
    if lutram:
        cases += [('missing-shadow', 'shadow', False, 'sat'),
                  ('missing-live-bank', 'live-bank', False, 'sat')]
    cases += [('zero-substitution', None, False, 'unsat'),
              ('zero-activation', None, True, 'sat'),
              ('zero-missing-address', 'address', False, 'sat'),
              ('zero-missing-view', 'view', False, 'sat')]
    rows = []
    solver = ROOT / 'third_party/oss-cad-suite/bin/z3'
    for name, omitted, activation, expected in cases:
        zero = name.startswith('zero-')
        selected = ({'address': '(valid mapped)',
                     'view': '(=> (valid mapped) (= observed zero))'} if zero else premises)
        selected_goal = '(= observed zero)' if zero else goal
        text = declarations + ('(declare-const zero Word)\n' if zero else '')
        text += ''.join('(assert ' + value + ')\n' for key, value in selected.items()
                        if key != omitted)
        if activation:
            text += '(assert (valid mapped))\n' if zero else '(assert (and known (= mapped a)))\n'
        else:
            text += '(assert (not ' + selected_goal + '))\n'
        text += '(check-sat)\n'
        source = directory / (name + '.smt2')
        source.write_text(text)
        process = run_bounded([str(solver), '-smt2', str(source)],
                                 capture_output=True, text=True, timeout=30)
        log = directory / (name + '.log')
        log.write_text(process.stdout + process.stderr)
        status = process.stdout.strip()
        rows.append({'name': name, 'status': status, 'expected': expected,
                     'passed': process.returncode == 0 and status == expected,
                     'source_sha256': sha(source), 'log_sha256': sha(log)})
    result = {'complete': all(r['passed'] for r in rows), 'cases': rows,
              'scope': 'Unbounded byte history plus all-state shadow-byte and view identities '
                       'imply the original committed/speculative/RVFI byte assertions. '
                       'Zero-view clauses are proved directly by the view certificate.'}
    (directory / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def run_views(directory, *, preset, xlen, lutram, shape, synthesis, rvfi, dut=DUT, timeout=120):
    directory = directory.resolve()
    if directory.exists() and any(directory.iterdir()):
        raise ValueError('View output directory must be empty')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', preset):
        raise ValueError('Invalid view preset')
    for path in (ROOT, directory, dut):
        if any(c.isspace() or c in ';"' for c in str(path)):
            raise ValueError('Unsupported Yosys path')
    directory.mkdir(parents=True, exist_ok=True)
    options = f'-DRAPT_FPGA_LUTRAM={lutram} '
    options += '-DRAPT_RV64 ' if xlen == 64 else ''
    options += '-DSYNTHESIS ' if synthesis else '-USYNTHESIS '
    options += '-DRAPT_RVFI ' if rvfi else ''
    options += ' '.join(f'-G{k}={v}' for k, v in zip(
        ('ArchRegs', 'Entries', 'ReadPorts', 'RetirePorts', 'Ports', 'ExtraPorts'), shape))
    frontend = directory / 'frontend.il'
    model = directory / 'snapshot.smt2'
    script = ('read_slang --threads 1 --single-unit --top formal_prf_views -DRAPT_FORMAL_PRF_VIEWS ' + options
              + f' -I{ROOT}/rtl/configs/{preset} -I{ROOT}/rtl/include '
              + f'-I{ROOT}/rtl/include/npc -I{ROOT}/rtl/include/dpic_mock '
              + f'{ROOT}/rtl/rapt_pkg.sv {dut} {HARNESS}\n'
              + f'write_rtlil {frontend}\nchformal -lower\n'
              'prep -top formal_prf_views -flatten\ncheck -assert\n'
              'select -assert-none t:$assume t:$anyseq t:$anyconst t:$initstate A:blackbox=1\n'
              'select -assert-any t:$assert\nselect -assert-any t:$cover\n'
              + f'dffunmap\nwrite_rtlil {directory}/snapshot.il\nwrite_smt2 -wires {model}\n')
    (directory / 'views.ys').write_text(script)
    inputs = [dut, ROOT / 'rtl/rapt_pkg.sv', HARNESS, Path(__file__),
              Path(__file__).with_name('yosys_common.py'), FORMAL / 'yosys-rvfi-compat.sh', SMTIO]
    inputs += sorted((ROOT / 'rtl/include').rglob('*.svh'))
    inputs += sorted((ROOT / 'rtl/configs' / preset).rglob('*.svh'))
    sources = {str(p): sha(p) for p in inputs}
    tools = ROOT / 'third_party/oss-cad-suite/bin'
    real_yosys = shutil.which(os.environ.get('RAPTOR_YOSYS_REAL', 'yosys'))
    if not real_yosys:
        raise ValueError('Yosys executable is missing')
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
               RAPTOR_YOSYS_REAL=real_yosys)
    env.setdefault('MALLOC_ARENA_MAX', '2')
    with (directory / 'prepare.log').open('w') as stream:
        prepared = run_bounded(
            [real_yosys, '-Q', '-T', '-m', 'slang', '-s', str(directory / 'views.ys')],
            env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    statuses = {}
    processes = []
    for task in ('prove', 'cover'):
        folder = directory / ('views_' + task)
        (folder / 'engine_0').mkdir(parents=True)
        command = [str(tools / 'yosys-smtbmc'), '-s', 'bitwuzla', '--presat', '--unroll',
                   '--noprogress', '-t', '1', '--dump-vcd',
                   str(folder / 'engine_0/trace%.vcd')]
        if task == 'cover':
            command += ['-c']
        command += [str(model)]
        log = folder / 'run.log'
        with log.open('w') as stream:
            if prepared.returncode == 0:
                child = run_bounded(command, env=env, stdout=stream,
                                       stderr=subprocess.STDOUT, timeout=timeout)
                processes.append(child.returncode)
            else:
                stream.write('ERROR: View preparation failed; see prepare.log\n')
                processes.append(prepared.returncode)
        output = log.read_text().lower()
        status = 'ERROR'
        if processes[-1] == 124:
            status = 'TIMEOUT'
        elif processes[-1] == 0 and 'status: passed' in output:
            status = 'PASS'
        elif 'status: failed' in output and 'error:' not in output:
            status = 'FAIL'
        statuses[task] = status
        (folder / 'status').write_text(status + '\n')
    combined = ''.join((directory / ('views_' + t) / 'run.log').read_text()
                       for t in ('prove', 'cover'))
    (directory / 'run.log').write_text(combined)
    result = {'certified': False, 'whole_rtl_signoff': False, 'method': 'all-state view identity',
              'parameters': {'preset': preset, 'xlen': xlen, 'lutram': lutram, 'shape': shape,
                             'synthesis': synthesis, 'rvfi': rvfi},
              'sources': sources, 'statuses': statuses, 'exit': max(processes),
              'preparation_exit': prepared.returncode}
    full = not synthesis or not lutram
    expected = 2 * shape[0] + (shape[1] if lutram and full else 0)
    expected += 2 * shape[3] if rvfi else 0
    try:
        result['frontend_audit'] = audit_frontend(frontend.read_text(), expected)
        result['unrestricted_predicates'] = audit_model(model.read_text())
        result['smt_model_sha256'] = sha(model)
        # This query deliberately applies no initial, transition, hierarchy or
        # assumption predicates. It proves the assertion over every snapshot.
        query = directory / 'unrestricted.smt2'
        query.write_text(model.read_text() + '\n'
                         '(declare-fun arbitrary_snapshot () |formal_prf_views_s|)\n'
                         '(assert (not (|formal_prf_views_a| arbitrary_snapshot)))\n'
                         '(check-sat)\n')
        expanded = directory / 'unrestricted-expanded.smt2'
        direct = run_bounded([sys.executable, str(Path(__file__).resolve()), 'views',
                              '--snapshot-query', str(query), str(expanded)], env=env,
                             capture_output=True, text=True, timeout=timeout)
        (directory / 'unrestricted.log').write_text(direct.stdout + direct.stderr)
        result['unrestricted_query'] = direct.stdout.strip()
        result['unrestricted_query_exit'] = direct.returncode
        result['unrestricted_query_sha256'] = sha(query)
        result['unrestricted_expanded_sha256'] = sha(expanded)
        result['unrestricted_solver'] = 'bitwuzla via bundled Yosys SMT unroller'
    except (ValueError, FileNotFoundError) as error:
        result['audit_error'] = str(error)
    traces = sorted((directory / 'views_cover/engine_0').glob('trace*.vcd'))
    result['witnesses'] = {str(p.relative_to(directory)): sha(p) for p in traces}
    result['artifacts'] = {str(p.relative_to(directory)): sha(p) for p in directory.rglob('*')
                           if p.is_file() and p.suffix in ('.sby', '.log', '.ys', '.il', '.smt2')}
    if sources != {str(p): sha(p) for p in inputs}:
        raise RuntimeError('View lemma inputs changed during execution')
    result['certified'] = (prepared.returncode == 0 and all(code == 0 for code in processes)
                           and statuses == {'prove': 'PASS', 'cover': 'PASS'}
                           and 'audit_error' not in result and bool(traces)
                           and result.get('unrestricted_query') == 'unsat'
                           and result.get('unrestricted_query_exit') == 0)
    (directory / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def views_main():
    if sys.argv[1:2] == ['--snapshot-query']:
        parser = argparse.ArgumentParser(description='Evaluate one unrestricted snapshot query')
        parser.add_argument('--snapshot-query', nargs=2, type=Path, required=True)
        args = parser.parse_args()
        snapshot_query(*args.snapshot_query)
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--preset', default='formal')
    parser.add_argument('--xlen', type=int, choices=[32, 64], required=True)
    parser.add_argument('--lutram', type=int, choices=[0, 1], required=True)
    parser.add_argument('--shape', nargs=6, type=int, required=True)
    parser.add_argument('--synthesis', action='store_true')
    parser.add_argument('--rvfi', action='store_true')
    parser.add_argument('--timeout', type=int, default=120)
    args = parser.parse_args()
    result = run_views(args.output, preset=args.preset, xlen=args.xlen, lutram=args.lutram,
                       shape=args.shape, synthesis=args.synthesis, rvfi=args.rvfi,
                       timeout=args.timeout)
    print(json.dumps({k: result[k] for k in ('certified', 'statuses')}, indent=2))
    if not result['certified']:
        raise SystemExit('Uncertified PRF view lemma')


HARNESS = HARNESS


def counterexample(folder, log):
    path = folder / 'status'
    text = log.read_text()
    traces = sorted((folder / 'engine_0').glob('trace*.vcd'))
    return (path.exists() and path.read_text().split()[0] == 'FAIL'
            and 'Assert failed' in text and 'ERROR:' not in text
            and bool(traces) and all(p.stat().st_size for p in traces))


def run_composed(directory, *, preset, xlen, lutram, shape, synthesis, rvfi,
                 dut=DUT, timeout=300, negative=False, monolithic_reference=False,
                 history_proof=True):
    directory = directory.resolve()
    if negative and not history_proof:
        raise ValueError('Negative controls require their history check')
    if directory.exists() and any(directory.iterdir()):
        raise ValueError('Composed output must be empty')
    if (not re.fullmatch(r'[A-Za-z0-9_-]+', preset) or xlen not in (32, 64)
            or lutram not in (0, 1) or len(shape) != 6 or min(shape[:5]) < 1
            or shape[5] < 0 or timeout < 1):
        raise ValueError('Invalid composed PRF binding')
    for path in (ROOT, directory, dut):
        if any(c.isspace() or c in ';"' for c in str(path)):
            raise ValueError('Unsupported Yosys path')
    directory.mkdir(parents=True, exist_ok=True)
    inputs = [dut, ROOT / 'rtl/rapt_pkg.sv', HARNESS, Path(__file__),
              Path(__file__).with_name('yosys_common.py'), FORMAL / 'yosys-rvfi-compat.sh',
              FORMAL / 'abc-read-blif-compat.sh']
    inputs += sorted((ROOT / 'rtl/include').rglob('*.svh'))
    inputs += sorted((ROOT / 'rtl/configs' / preset).rglob('*.svh'))
    sources = {str(p): sha(p) for p in inputs}
    derived = directory / 'history.sv'
    derived.write_text(history_harness(HARNESS.read_text()))
    options = f'-DRAPT_FPGA_LUTRAM={lutram} '
    options += '-DRAPT_RV64 ' if xlen == 64 else ''
    options += '-DSYNTHESIS ' if synthesis else '-USYNTHESIS '
    options += '-DRAPT_RVFI ' if rvfi else ''
    options += ' '.join(f'-G{k}={v}' for k, v in zip(
        ('ArchRegs', 'Entries', 'ReadPorts', 'RetirePorts', 'Ports', 'ExtraPorts'), shape))
    read = ('read_slang --threads 1 --single-unit --top formal_prf_contract -DRAPT_FORMAL_PRF_CONTRACT ' + options
            + f' -I{ROOT}/rtl/configs/{preset} -I{ROOT}/rtl/include '
            + f'-I{ROOT}/rtl/include/npc -I{ROOT}/rtl/include/dpic_mock '
            + f'{ROOT}/rtl/rapt_pkg.sv {dut} {derived}\n')
    script = ('plugin -i slang\n' + read + 'prep -top formal_prf_contract -flatten\n'
              'async2sync\ncheck -assert\nselect -assert-count 6 t:$assume\n'
              'select -assert-none t:$anyseq t:$anyconst A:blackbox=1\n')
    if lutram:
        selection = 'formal_prf_contract/dut.g_lutram.lvt'
        count = '-assert-max' if negative else '-assert-count'
        script += f'select {count} 1 {selection}\nmemory_map {selection}\nopt\n'
        script += ('setundef -undriven -anyseq '
                   'formal_prf_contract/w:$memory*dut.g_lutram.lvt$rdmux*\n'
                   'check -assert\nselect -assert-none t:$anyconst A:blackbox=1\n')
        if not negative:
            copies = 2 * shape[2] + 1 + shape[5]
            script += f'select -assert-count {shape[4] * copies} t:$mem_v2\n'
            script += 'select -assert-none t:$mem_v2 r:WR_PORTS>1 %i\n'
    script += 'select -assert-any t:$assert\nselect -assert-any t:$cover\n'
    tasks = '[tasks]\nprove\n' + ('' if negative else 'cover\n')
    options = '[options]\nprove: mode ' + ('bmc\n' if negative else 'prove\n')
    options += f'prove: depth {6 if negative else 3}\n'
    if not negative:
        options += 'cover: mode cover\ncover: depth 6\n'
    engine = 'abc pdr' if not lutram and shape[1] >= 64 and not negative else 'smtbmc bitwuzla'
    config = tasks + options + f'timeout {timeout}\n[engines]\nprove: {engine}\n'
    if not negative:
        config += 'cover: smtbmc bitwuzla\n'
    config += '[script]\n' + script
    (directory / 'history.sby').write_text(config)
    tools = ROOT / 'third_party/oss-cad-suite/bin'
    real_yosys = shutil.which(os.environ.get('RAPTOR_YOSYS_REAL', 'yosys'))
    if not real_yosys:
        raise ValueError('Yosys executable is missing')
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
               RAPTOR_YOSYS_REAL=real_yosys)
    env.setdefault('MALLOC_ARENA_MAX', '2')
    command = [str(tools / 'sby'), '--yosys', str(FORMAL / 'yosys-rvfi-compat.sh')]
    log = directory / 'history.log'
    with log.open('w') as stream:
        selected_tasks = [] if history_proof else ['cover']
        process = run_bounded([*command, 'history.sby', *selected_tasks], cwd=directory, env=env,
                                 stdout=stream, stderr=subprocess.STDOUT, timeout=timeout + 120)
    statuses = {}
    for task in (('prove',) if negative else ('prove', 'cover')):
        path = directory / ('history_' + task) / 'status'
        statuses[task] = ('NOT_RUN' if task == 'prove' and not history_proof else
                          path.read_text().split()[0] if path.exists()
                          else 'TIMEOUT' if process.returncode == 124 else 'ERROR')
    views = run_views(directory / 'views', preset=preset, xlen=xlen, lutram=lutram,
                      shape=shape, synthesis=synthesis, rvfi=rvfi, dut=dut, timeout=timeout)
    derivation = composition_lemma(directory / 'composition', lutram)
    traces = sorted((directory / 'history_cover/engine_0').glob('trace*.vcd'))
    result = {'certified': False, 'negative_detected': False, 'whole_rtl_signoff': False,
              'method': 'uncut history induction plus unrestricted-state view identities',
              'parameters': views['parameters'], 'sources': sources,
              'history': {'exit': process.returncode, 'statuses': statuses, 'engine': engine,
                          'proof_requested': history_proof,
                          'original_harness_sha256': sha(HARNESS),
                          'derived_harness_sha256': sha(derived), 'replaced_assertions': 5,
                          'witnesses': {str(p.relative_to(directory)): sha(p) for p in traces}},
              'views': views, 'derivation': derivation}
    if negative:
        history_bad = counterexample(directory / 'history_prove', log)
        views_bad = counterexample(directory / 'views/views_prove', directory / 'views/run.log')
        audit_ok = 'audit_error' not in views
        result['negative_detected'] = (audit_ok and derivation['complete']
                                       and (history_bad or views_bad)
                                       and statuses['prove'] in ('PASS', 'FAIL')
                                       and views['statuses']['prove'] in ('PASS', 'FAIL')
                                       and views['statuses']['cover'] == 'PASS')
        if monolithic_reference:
            text = config.replace(str(derived), str(HARNESS))
            (directory / 'monolithic.sby').write_text(text)
            reference = directory / 'monolithic.log'
            with reference.open('w') as stream:
                run_bounded([*command, 'monolithic.sby'], cwd=directory, env=env,
                               stdout=stream, stderr=subprocess.STDOUT, timeout=timeout + 120)
            result['monolithic_negative_detected'] = counterexample(
                directory / 'monolithic_prove', reference)
            result['negative_detected'] &= result['monolithic_negative_detected']
    else:
        result['certified'] = (process.returncode == 0 and statuses == {'prove': 'PASS',
                              'cover': 'PASS'} and bool(traces) and views['certified']
                              and derivation['complete'])
    if sources != {str(p): sha(p) for p in inputs}:
        raise RuntimeError('Composed proof inputs changed during execution')
    result['artifacts'] = {str(p.relative_to(directory)): sha(p) for p in directory.rglob('*')
                           if p.is_file() and p.suffix in ('.sby', '.sv', '.json', '.log', '.smt2')}
    (directory / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def composed_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--preset', default='formal')
    parser.add_argument('--xlen', type=int, choices=[32, 64], required=True)
    parser.add_argument('--lutram', type=int, choices=[0, 1], required=True)
    parser.add_argument('--shape', nargs=6, type=int, required=True)
    parser.add_argument('--synthesis', action='store_true')
    parser.add_argument('--rvfi', action='store_true')
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('--history-cover-only', action='store_true',
                        help='Prepare a full activation reference for exhaustive byte recovery')
    args = parser.parse_args()
    result = run_composed(args.output, preset=args.preset, xlen=args.xlen, lutram=args.lutram,
                          shape=args.shape, synthesis=args.synthesis, rvfi=args.rvfi,
                          timeout=args.timeout, history_proof=not args.history_cover_only)
    print(json.dumps({'certified': result['certified'],
                      'history': result['history']['statuses'],
                      'views': result['views']['statuses']}, indent=2))
    if not result['certified']:
        raise SystemExit('Uncertified composed PRF contract')


def partition_history(text, lane, xlen):
    """Specialize only the ghost observer; split three whole-word zero checks."""
    if xlen not in (32, 64) or not 0 <= lane < xlen // 8:
        raise ValueError('Invalid observer byte partition')
    replacements = [
        ('    input logic [$clog2(Xlen/8)-1:0] watched_byte,\n', ''),
        ('  localparam int WriterBits = rapt_pkg::index_bits(Ports + 1);',
         f'  localparam logic [$clog2(Xlen/8)-1:0] watched_byte = {lane};\n'
         '  localparam int WriterBits = rapt_pkg::index_bits(Ports + 1);'),
        ('rf[0] == 0 && rf_map[0] == 0',
         "rf[0][int'(watched_byte)*8+:8] == 0 && rf_map[0][int'(watched_byte)*8+:8] == 0"),
        ('debug_value == 0', "debug_value[int'(watched_byte)*8+:8] == 0"),
        ('extra_value[r] == 0 && extra_valid[r]',
         "extra_value[r][int'(watched_byte)*8+:8] == 0 && extra_valid[r]"),
    ]
    for old, new in replacements:
        if text.count(old) != 1:
            raise ValueError('Observer partition anchor changed: ' + old)
        text = text.replace(old, new)
    return text


def byte_lemma(directory, xlen):
    """Check domain exhaustiveness and reconstruction, including every omitted lane."""
    directory.mkdir()
    rows = []
    width = (xlen // 8 - 1).bit_length()
    for domain in (False, True):
        for omitted in (None, *range(xlen // 8)):
            name = ('domain' if domain else 'word') + '-'
            name += 'complete' if omitted is None else f'missing-{omitted}'
            clauses = []
            for lane in range(xlen // 8):
                if lane == omitted:
                    continue
                if domain:
                    clauses.append(f'(= observer (_ bv{lane} {width}))')
                else:
                    clauses.append(f'(= ((_ extract {8*lane+7} {8*lane}) value) #x00)')
            text = '(set-logic QF_BV)\n'
            if domain:
                text += f'(declare-const observer (_ BitVec {width}))\n'
                text += '(assert (not (or ' + ' '.join(clauses) + ')))\n'
            else:
                text += f'(declare-const value (_ BitVec {xlen}))\n'
                text += ''.join('(assert ' + clause + ')\n' for clause in clauses)
                text += f'(assert (not (= value (_ bv0 {xlen}))))\n'
            text += '(check-sat)\n'
            source = directory / (name + '.smt2')
            source.write_text(text)
            process = run_bounded([str(ROOT / 'third_party/oss-cad-suite/bin/z3'),
                                   '-smt2', str(source)], capture_output=True, text=True,
                                  timeout=30)
            log = directory / (name + '.log')
            log.write_text(process.stdout + process.stderr)
            expected = 'unsat' if omitted is None else 'sat'
            rows.append(dict(name=name, expected=expected, status=process.stdout.strip(),
                             passed=process.returncode == 0 and process.stdout.strip() == expected,
                             query_sha256=sha(source), log_sha256=sha(log)))
    result = dict(complete=all(row['passed'] for row in rows), cases=rows)
    (directory / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def byte_partition_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True,
                        help='Existing prf_formal.py output with a complete history cover')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--timeout', type=int, default=900)
    parser.add_argument('--engine', choices=['reference', 'abc-pdr', 'smtbmc-bitwuzla'],
                        default='reference', help='Override only the unbounded safety engine')
    args = parser.parse_args()
    if min(args.jobs, args.timeout) < 1:
        parser.error('Jobs and timeout must be positive')
    reference, output = args.reference.resolve(), args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('Output must be empty')
    for path in (reference, output):
        if any(c.isspace() or c in ';"' for c in str(path)):
            parser.error('Unsupported formal path')
    evidence = json.loads((reference / 'results.json').read_text())
    parameters = evidence['parameters']
    if parameters['lutram'] != 0:
        parser.error('Byte decomposition currently supports flop history only')
    sources = evidence['sources']
    for name, value in sources.items():
        source = Path(name)
        if sha(source) != value:
            parser.error('Reference source changed: ' + name)
        # Bind every RTL/config/header and the original contract to this checkout.
        for marker in ('/rtl/', '/verification/formal/'):
            if marker in name:
                suffix = marker.lstrip('/') + name.split(marker, 1)[1]
                if sha(ROOT / suffix) != value:
                    parser.error('Reference differs from current inputs: ' + suffix)
    history = reference / 'history.sv'
    expected = history_harness((FORMAL / 'formal_prf.sv').read_text())
    if history.read_text() != expected:
        parser.error('Reference is not the exact reviewed history partition')
    if sha(history) != evidence['history']['derived_harness_sha256']:
        parser.error('Reference history fingerprint mismatch')
    config = reference / 'history.sby'
    if sha(config) != evidence['artifacts']['history.sby']:
        parser.error('Reference configuration changed')
    if 'prove: mode prove\n' not in config.read_text():
        parser.error('An unbounded history proof mode is required')
    cover_status = reference / 'history_cover/status'
    if (evidence['history']['statuses']['cover'] != 'PASS'
            or not cover_status.exists() or cover_status.read_text().split()[0] != 'PASS'):
        parser.error('Full unpartitioned activation cover is required')
    witnesses = evidence['history']['witnesses']
    if not witnesses or any(sha(reference / p) != value for p, value in witnesses.items()):
        parser.error('Missing or modified full activation witnesses')
    output.mkdir(parents=True, exist_ok=True)
    real_yosys = shutil.which(os.environ.get('RAPTOR_YOSYS_REAL', 'yosys'))
    if not real_yosys:
        parser.error('Yosys executable is missing')
    tools = ROOT / 'third_party/oss-cad-suite/bin'
    env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'],
               RAPTOR_YOSYS_REAL=real_yosys)
    env.setdefault('MALLOC_ARENA_MAX', '2')
    protected = [Path(__file__),
                 Path(__file__).with_name('yosys_common.py'), history, config,
                 reference / 'results.json', *map(Path, sources)]
    fingerprints = {str(p): sha(p) for p in protected}
    state = dict(certified=False, whole_rtl_signoff=False, parameters=parameters,
                 method='Exhaustive ghost-byte partitions with unchanged DUT and transitions',
                 engine_selection=args.engine,
                 sources=fingerprints, reference_report_sha256=sha(reference / 'results.json'),
                 full_activation_witnesses=witnesses, partitions=[])
    lock = threading.Lock()

    def save():
        temporary = output / 'results.tmp'
        temporary.write_text(json.dumps(state, indent=2) + '\n')
        temporary.replace(output / 'results.json')

    def execute(lane):
        directory = output / f'byte-{lane}'
        directory.mkdir()
        derived = directory / 'history.sv'
        derived.write_text(partition_history(expected, lane, parameters['xlen']))
        text = config.read_text()
        if text.count(str(history)) != 1:
            raise ValueError('Unexpected history read command')
        text = text.replace(str(history), str(derived))
        text, count = re.subn(r'^timeout \d+$', f'timeout {args.timeout}', text, flags=re.M)
        if count != 1:
            raise ValueError('Unexpected history timeout configuration')
        engines = re.findall(r'^prove: (abc pdr|smtbmc bitwuzla)$', text, re.M)
        if len(engines) != 1:
            raise ValueError('Unexpected history safety engine')
        engine = engines[0] if args.engine == 'reference' else args.engine.replace('-', ' ')
        text, count = re.subn(r'^prove: (abc pdr|smtbmc bitwuzla)$',
                             'prove: ' + engine, text, flags=re.M)
        if count != 1:
            raise ValueError('Missing history safety engine')
        candidate = directory / 'history.sby'
        candidate.write_text(text)
        log = directory / 'run.log'
        command = [str(tools / 'sby'), '--yosys', str(FORMAL / 'yosys-rvfi-compat.sh'),
                   str(candidate), 'prove']
        with log.open('w') as stream:
            child = run_bounded(command, cwd=directory, env=env, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=args.timeout + 120)
        path = directory / 'history_prove/status'
        status = (path.read_text().split()[0] if path.exists()
                  else 'TIMEOUT' if child.returncode == 124 else 'ERROR')
        row = dict(lane=lane, exit=child.returncode, status=status, engine=engine,
                   passed=child.returncode == 0 and status == 'PASS',
                   harness_sha256=sha(derived), configuration_sha256=sha(candidate),
                   log_sha256=sha(log))
        with lock:
            state['partitions'].append(row)
            save()
        print('byte', lane, status, flush=True)
        return row['passed']

    save()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        passed = list(pool.map(execute, range(parameters['xlen'] // 8)))
    state['byte_reconstruction'] = byte_lemma(output / 'byte-reconstruction', parameters['xlen'])
    state['views'] = run_views(output / 'views', **parameters, timeout=args.timeout)
    state['view_composition'] = composition_lemma(output / 'view-composition', 0)
    if fingerprints != {str(p): sha(p) for p in protected}:
        raise RuntimeError('Byte partition proof inputs changed')
    state['certified'] = (all(passed) and state['byte_reconstruction']['complete']
                          and state['views']['certified'] and state['view_composition']['complete'])
    save()
    if not state['certified']:
        raise SystemExit('Incomplete exhaustive PRF byte proof')


MUTATIONS = {
    'debug-zero': [("dbg_addr_i != 0 && int'(dbg_addr_i) < RNUM",
                    "int'(dbg_addr_i) < RNUM", 2)],
    'architectural-zero': [("r == 0 ? '0 : prf_arr[rat_snapshot[r]]",
                            'prf_arr[rat_snapshot[r]]', 1),
                           ("r == 0 ? '0 : prf_arr[map_snapshot[r]]",
                            'prf_arr[map_snapshot[r]]', 1)],
    'late-bypass': [('extra_value[r] = completion[w].result;',
                     'extra_value[r] = extra_stored[r];', 1)],
    'reclaim-priority': [('if (dealloc_prs_oh[i]) begin',
                         'if (dealloc_prs_oh[i] && !settle_prd_oh[i]) begin', 1)],
    'flush-data': [('if (!cmu_bcast.flush_pipe && wr_any_oh[i]) begin\n'
                    '            prf_arr[i] <= wr_mux_data[i];',
                    'if (wr_any_oh[i]) begin\n            prf_arr[i] <= wr_mux_data[i];', 1)],
    'live-bank': [("lvt[i] <= BankBits'(p);", "lvt[i] <= '0;", 1)],
    'read-copy': [('if (bank_we[p]) words[bank_addr[p]] <= bank_data[p];',
                   'if (bank_we[p] && r == 0) words[bank_addr[p]] <= bank_data[p];', 1)],
    'debug-target': [('assign dbg_write_index = dbg_read_index;',
                      "assign dbg_write_index = map_snapshot[ArchIndexBits'(dbg_addr_i)];", 1)],
    'view-rf-target': [("r == 0 ? '0 : prf_arr[rat_snapshot[r]]",
                        "r == 0 ? '0 : prf_arr[map_snapshot[r]]", 1)],
    'view-map-target': [("r == 0 ? '0 : prf_arr[map_snapshot[r]]",
                         "r == 0 ? '0 : prf_arr[rat_snapshot[r]]", 1)],
    'view-rvfi-target': [('prf_arr[rou_cmu.slot[c].prd]', 'prf_arr[map_snapshot[0]]', 1)],
    'view-rvfi-zero': [("rou_cmu.slot[c].rd != 0 ?", "1'b1 ?", 1)],
    'view-shadow-row': [('assign bank_word[p] = g_bank[p].g_copy[0].words[i];',
                         'assign bank_word[p] = g_bank[p].g_copy[0].words[(i+1)%PNUM];', 1)],
}


def discover(preset, xlen, directory):
    """Read actual CoreConfig values instead of inferring them from preset names."""
    directory.mkdir(parents=True)
    source = directory / 'geometry.sv'
    source.write_text('''`include "rapt.svh"
module formal_prf_geometry(output wire [31:0] xlen, arch_regs, entries,
    reads, retires, writers, address_bits);
  assign xlen = rapt_pkg::CoreConfig.xlen;
  assign arch_regs = rapt_pkg::CoreConfig.arch_regs;
  assign entries = rapt_pkg::CoreConfig.phys_regs;
  assign reads = rapt_pkg::CoreConfig.dispatch_width;
  assign retires = rapt_pkg::CoreConfig.commit_width;
  assign writers = rapt_pkg::CoreConfig.completion_ports;
  assign address_bits = rapt_pkg::PLENPkg;
endmodule
''')
    define = '-DRAPT_RV64 ' if xlen == 64 else ''
    model = directory / 'geometry.json'
    command = ('read_slang --threads 1 --single-unit --top formal_prf_geometry ' + define
               + f'-I{ROOT}/rtl/configs/{preset} -I{ROOT}/rtl/include '
               + f'{ROOT}/rtl/rapt_pkg.sv {source}; prep -top formal_prf_geometry; '
               + f'write_json {model}')
    run_yosys(command, directory / 'run.log', 60)
    ports = json.loads(model.read_text())['modules']['formal_prf_geometry']['ports']
    values = []
    for name in ('xlen', 'arch_regs', 'entries', 'reads', 'retires', 'writers', 'address_bits'):
        bits = ports[name]['bits']
        if not bits or any(b not in ('0', '1') for b in bits):
            raise ValueError('Nonconstant native PRF geometry: ' + name)
        values.append(int(''.join(reversed(bits)), 2))
    x, arch, entries, reads, retires, writers, address_bits = values
    if (x != xlen or not 1 <= arch <= 32 or entries < arch
            or min(reads, retires, writers) < 1
            or address_bits != max(1, (entries - 1).bit_length())):
        raise ValueError('Unsupported native PRF geometry: ' + repr(values))
    return {'preset': preset, 'xlen': xlen, 'shape': values[1:6],
            'address_bits': address_bits,
            'artifacts': {p.name: sha(p) for p in directory.iterdir() if p.is_file()}}


def prove_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--presets', nargs='+')
    parser.add_argument('--checks', choices=['all', 'zero'], default='all')
    parser.add_argument('--proof-style', choices=['composed', 'monolithic'], default='composed')
    parser.add_argument('--baseline', type=Path, help='Preserved pre-fix PRF for x0 counterexamples')
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--timeout', type=int, default=300)
    args = parser.parse_args()
    args.presets = args.presets or sorted(p.parent.name for p in
                                        (ROOT / 'rtl/configs').glob('*/rapt_config.svh'))
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('Output must be empty to preserve prior evidence')
    if min(args.jobs, args.timeout) < 1 or len(set(args.presets)) != len(args.presets):
        parser.error('Require positive jobs/timeout and distinct presets')
    for preset in args.presets:
        if not preset.replace('-', '').replace('_', '').isalnum():
            parser.error('Invalid preset name')
        if not (ROOT / 'rtl/configs' / preset / 'rapt_config.svh').is_file():
            parser.error('Unknown preset: ' + preset)
    for path in (ROOT, output):
        if any(c.isspace() or c in ';"' for c in str(path)):
            parser.error('Yosys paths cannot contain whitespace, quotes or semicolons')
    baseline = args.baseline.resolve() if args.baseline else None
    baseline_hash = sha(baseline) if baseline else None
    real_yosys = shutil.which(os.environ.get('RAPTOR_YOSYS_REAL', 'yosys'))
    if not real_yosys:
        parser.error('Yosys executable is missing')
    sources = [DUT, ROOT / 'rtl/rapt_pkg.sv', HARNESS, Path(__file__),
               Path(__file__).with_name('yosys_common.py'), FORMAL / 'yosys-rvfi-compat.sh',
               FORMAL / 'abc-read-blif-compat.sh']
    sources += sorted((ROOT / 'rtl/include').rglob('*.svh'))
    for preset in set(args.presets) | {'formal'}:
        sources += sorted((ROOT / 'rtl/configs' / preset).rglob('*.svh'))
    fingerprints = {str(p.relative_to(ROOT)): sha(p) for p in sources}
    output.mkdir(parents=True, exist_ok=True)
    result = {
        'complete': False, 'whole_rtl_signoff': False, 'sources': fingerprints,
        'checks': args.checks,
        'proof_style': args.proof_style,
        'proofs': [], 'negative_controls': [], 'native_bindings': [],
        'baseline': {'path': str(baseline), 'sha256': baseline_hash} if baseline else None,
        'scope': 'Uncut PRF: architectural/debug x0, arbitrary initial physical data, '
                 'byte history for every symbolic physical address, validity/transience '
                 'priorities, reset/flush, every LUTRAM copy and live-bank selector, '
                 'ordinary reads, late bypass, quiescent debug and available full views. '
                 'Reset forgets data knowledge; nonzero power-up contents are unspecified. '
                 'Producer/rename ownership and halt delivery require integration proofs.',
        'data_assumptions': ['First edge resets', 'Observer address/byte are stable',
                             'Observer and active addresses are in bounds',
                             'Accepted nonzero-rd writers have distinct physical destinations',
                             'Debug writes are quiescent, outside reset/flush'],
        'zero_assumptions': ['First edge resets; other DUT inputs are constant idle/reset maps'],
        'yosys': subprocess.check_output(
            [real_yosys, '-V'], text=True).strip(),
        'yosys_launcher': real_yosys,
        'engines': {'small_prove': 'smtbmc bitwuzla', 'production_flop_prove': 'abc pdr',
                    'lutram_prove': 'smtbmc bitwuzla with mapped LVT',
                    'cover': 'smtbmc bitwuzla', 'negative': 'smtbmc bitwuzla'},
        'memory_encoding': 'Standard memory_map of LVT only; payload memories remain native. '
                           'Only generated out-of-range LVT read-mux leaves receive anyseq. '
                           'No state, address or data bit is abstracted or restricted.',
    }
    lock = threading.Lock()

    def save():
        temporary = output / 'results.tmp'
        temporary.write_text(json.dumps(result, indent=2) + '\n')
        temporary.replace(output / 'results.json')

    def record(row, directory, mutation):
        row['artifacts'] = {p.name: sha(p) for p in directory.iterdir() if p.is_file()}
        with lock:
            result['negative_controls' if mutation else 'proofs'].append(row)
            save()
        print(directory.name, 'PASS' if row['passed'] else 'INCOMPLETE', flush=True)
        return row['passed']

    def run(case):
        preset, xlen, lutram, kind, shape, mutation, synthesis, rvfi = case
        suffix = f'{preset}-x{xlen}-lut{lutram}-{kind}'
        if shape:
            suffix += '-' + '-'.join(map(str, shape))
        if rvfi:
            suffix += '-rvfi'
        if not synthesis:
            suffix += '-simulation'
        name = 'negative-' + mutation if mutation else suffix
        directory = output / name
        directory.mkdir()
        source = DUT
        if mutation:
            source = directory / 'mutant.sv'
            if mutation.startswith('baseline-'):
                source.write_bytes(baseline.read_bytes())
            else:
                text = DUT.read_text()
                for old, new, count in MUTATIONS[mutation]:
                    if text.count(old) != count:
                        raise ValueError('Missing mutation anchor: ' + mutation + ': ' + old)
                    text = text.replace(old, new)
                source.write_text(text)
        if kind == 'data' and args.proof_style == 'composed':
            byte_first = not mutation and not lutram and shape[1] >= 128
            evidence = run_composed(
                directory / 'composed', preset=preset, xlen=xlen, lutram=lutram,
                shape=shape, synthesis=synthesis, rvfi=rvfi, dut=source,
                timeout=args.timeout, negative=bool(mutation),
                monolithic_reference=bool(mutation and mutation.startswith('view-')),
                history_proof=not byte_first)
            component_log = directory / 'composed/history.log'
            history = evidence['history']['statuses']
            recovered = False
            recovery_report = directory / 'byte-recovery/results.json'
            if (not mutation and not evidence['certified']
                    and history['prove'] in ('NOT_RUN', 'TIMEOUT', 'ERROR')
                    and history['cover'] == 'PASS' and evidence['views']['certified']
                    and evidence['derivation']['complete'] and not lutram):
                command = [sys.executable, str(Path(__file__).with_name('prf_formal.py')), 'byte-partition',
                           '--reference', str(directory / 'composed'),
                           '--output', str(directory / 'byte-recovery'), '--engine', 'abc-pdr',
                           '--jobs', '1', '--timeout', str(args.timeout)]
                limit = (xlen // 8) * (args.timeout + 120) + 4 * args.timeout + 120
                with (directory / 'byte-recovery.log').open('w') as stream:
                    process = run_bounded(command, cwd=ROOT, stdout=stream,
                                          stderr=subprocess.STDOUT, timeout=limit)
                if recovery_report.exists():
                    recovery = json.loads(recovery_report.read_text())
                    recovered = process.returncode == 0 and recovery['certified']
            certified = evidence['certified'] or recovered
            row = dict(preset=preset, xlen=xlen, lutram=lutram, kind=kind, shape=shape,
                       synthesis=synthesis, rvfi=rvfi, method=evidence['method'],
                       log=str(component_log.relative_to(output)),
                       log_sha256=sha(component_log), history=history,
                       prove='PASS' if certified else history['prove'],
                       cover=history.get('cover', 'NOT_RUN'),
                       passed=evidence['negative_detected'] if mutation else certified,
                       composition_report=str((directory / 'composed/results.json')
                                              .relative_to(output)),
                       composition_sha256=sha(directory / 'composed/results.json'))
            if recovered:
                row.update(method='Exhaustive byte induction plus all-state view composition',
                           byte_recovery_report=str(recovery_report.relative_to(output)),
                           byte_recovery_sha256=sha(recovery_report))
            if not mutation and not certified and row['prove'] == 'PASS':
                row['prove'] = 'INCOMPLETE_COMPOSITION'
            trace_dir = directory / 'composed' / ('history_prove' if mutation else 'history_cover')
            traces = list((trace_dir / 'engine_0').glob('trace*.vcd'))
            if mutation:
                row['name'] = mutation
                traces += list((directory / 'composed/views/views_prove/engine_0').glob('trace*.vcd'))
            row['witnesses'] = {str(p.relative_to(output)): sha(p) for p in traces}
            return record(row, directory, mutation)
        top = 'formal_prf_zero' if kind == 'zero' else 'formal_prf_contract'
        options = f'-DRAPT_FPGA_LUTRAM={lutram} '
        if xlen == 64:
            options += '-DRAPT_RV64 '
        if synthesis:
            options += '-DSYNTHESIS '
        else:
            # The slang frontend predefines SYNTHESIS even without -D.
            options += '-USYNTHESIS '
        if rvfi:
            options += '-DRAPT_RVFI '
        if shape:
            options += ' '.join(f'-G{k}={v}' for k, v in zip(
                ('ArchRegs', 'Entries', 'ReadPorts', 'RetirePorts', 'Ports', 'ExtraPorts'), shape))
            options += ' '
        read = ('read_slang --threads 1 --single-unit --top ' + top + ' -DRAPT_' + top.upper() + ' ' + options
                + f'-I{ROOT}/rtl/configs/{preset} -I{ROOT}/rtl/include '
                + f'-I{ROOT}/rtl/include/npc -I{ROOT}/rtl/include/dpic_mock '
                + f'{ROOT}/rtl/rapt_pkg.sv {source} {HARNESS}\n')
        tasks = '[tasks]\nprove\n' + ('' if mutation else 'cover\n')
        modes = '[options]\nprove: mode ' + ('bmc\n' if mutation else 'prove\n')
        modes += f'prove: depth {6 if mutation else 3}\n'
        if not mutation:
            modes += 'cover: mode cover\ncover: depth 6\n'
        large_flop = shape and shape[1] >= 64 and not lutram and not mutation
        engine = 'abc pdr' if large_flop else 'smtbmc bitwuzla'
        engines = 'prove: ' + engine + '\n'
        if not mutation:
            engines += 'cover: smtbmc bitwuzla\n'
        config = (tasks + modes + f'timeout {args.timeout}\n[engines]\n' + engines
                  + '[script]\nplugin -i slang\n' + read + f'prep -top {top} -flatten\n'
                  'async2sync\ncheck -assert\n'
                  + f'select -assert-count {1 if kind == "zero" else 6} t:$assume\n'
                  'select -assert-none t:$anyseq t:$anyconst A:blackbox=1\n')
        if kind == 'data' and lutram:
            # The per-entry RTL LVT becomes Entries*Ports SMT write ports.
            # Map only that table, retaining native arrays for all data copies.
            selection = top + '/dut.g_lutram.lvt'
            count_check = '-assert-max' if mutation else '-assert-count'
            config += f'select {count_check} 1 {selection}\n'
            config += f'memory_map {selection}\nopt\n'
            # Non-power-of-two tables create undriven mux leaves for illegal
            # rows. Constrain no values there; do not touch unrelated wires.
            config += ('setundef -undriven -anyseq '
                       + top + '/w:$memory*dut.g_lutram.lvt$rdmux*\ncheck -assert\n'
                       'select -assert-none t:$anyconst A:blackbox=1\n')
            if not mutation:
                copies = 2 * shape[2] + 1 + shape[5]
                config += f'select -assert-count {shape[4] * copies} t:$mem_v2\n'
                config += 'select -assert-none t:$mem_v2 r:WR_PORTS>1 %i\n'
        (directory / 'contract.sby').write_text(config)
        bundled = ROOT / 'third_party/oss-cad-suite/bin'
        env = dict(os.environ, PATH=str(bundled) + os.pathsep + os.environ['PATH'],
                   RAPTOR_YOSYS_REAL=real_yosys)
        log = directory / 'run.log'
        command = [str(bundled / 'sby'), '--yosys', str(FORMAL / 'yosys-rvfi-compat.sh'),
                   'contract.sby']
        with log.open('w') as stream:
            process = subprocess.run(command, cwd=directory, env=env, stdout=stream,
                                     stderr=subprocess.STDOUT, timeout=args.timeout + 120)
        row = dict(preset=preset, xlen=xlen, lutram=lutram, kind=kind, shape=shape,
                   synthesis=synthesis, rvfi=rvfi, engine=engine, exit=process.returncode,
                   log=str(log.relative_to(output)), log_sha256=sha(log))
        for task in (('prove',) if mutation else ('prove', 'cover')):
            status = directory / ('contract_' + task) / 'status'
            row[task] = status.read_text().split()[0] if status.exists() else 'ERROR'
        folder = directory / ('contract_prove' if mutation else 'contract_cover') / 'engine_0'
        traces = sorted(folder.glob('trace*.vcd'))
        row['witnesses'] = {str(p.relative_to(output)): sha(p) for p in traces}
        if mutation:
            row['name'] = mutation
            row['passed'] = (row['prove'] == 'FAIL' and 'Assert failed' in log.read_text()
                             and 'ERROR:' not in log.read_text() and bool(traces)
                             and all(p.stat().st_size for p in traces))
        else:
            row['passed'] = (process.returncode == 0 and row['prove'] == 'PASS'
                             and row['cover'] == 'PASS' and bool(traces)
                             and all(p.stat().st_size for p in traces))
        return record(row, directory, mutation)

    save()
    # Native preset reset/x0 bindings, then a parameter matrix covering dormant
    # and production late ports, odd writer counts and non-power-of-two storage.
    cases = [(p, x, l, 'zero', None, None, True, False)
             for p in args.presets for x in (32, 64) for l in (0, 1)]
    shapes = [(4, 8, 2, 2, 3, 3), (4, 8, 1, 1, 1, 0),
              (32, 64, 2, 2, 6, 3), (32, 96, 3, 3, 6, 3), (32, 96, 8, 8, 6, 3)]
    cases += [('formal', x, l, 'data', s, None, True, False)
              for s in shapes for x in (32, 64) for l in (0, 1)]
    cases += [('formal', x, 0, 'data', shapes[0], None, True, True) for x in (32, 64)]
    cases += [('formal', x, 1, 'data', shapes[0], None, False, True) for x in (32, 64)]
    controls = [('formal', 32, int(m in ('live-bank', 'read-copy') or m.startswith('view-')),
                 'data', shapes[0], m, not m.startswith('view-'), m.startswith('view-'))
                for m in MUTATIONS]
    if args.checks == 'zero':
        cases = [case for case in cases if case[3] == 'zero']
        controls = [('formal', 32, 0, 'zero', None, m, True, False)
                    for m in ('debug-zero', 'architectural-zero')]
        result['scope'] = ('Architectural/debug x0 after idle reset, with uninitialized physical '
                           'payload, both XLENs and both flop/LUTRAM storage. No general PRF '
                           'data/state history or integrated backend signoff is claimed.')
        result['data_assumptions'] = []
    else:
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            native = list(pool.map(lambda binding: discover(
                binding[0], binding[1], output / 'discovery'
                / f'{binding[0]}-rv{binding[1]}'),
                [(p, x) for p in args.presets for x in (32, 64)]))
        result['native_bindings'] = native
        # Compile every selected preset directly: equal dimensions do not
        # silently grant reuse across different configuration macros.
        cases += [(b['preset'], b['xlen'], l, 'data', tuple(b['shape']) + (e,),
                   None, True, False) for b in native for l in (0, 1) for e in (0, 3)]
        cases += [(b['preset'], b['xlen'], l, 'data', tuple(b['shape']) + (3,),
                   None, not l, True) for b in native for l in (0, 1)]
        cases = list(dict.fromkeys(cases))
    if baseline:
        controls += [('formal', x, l, 'zero', None, f'baseline-x{x}-lut{l}', True, False)
                     for x in (32, 64) for l in (0, 1)]
    result['required_positive_bindings'] = len(cases)
    result['required_negative_controls'] = len(controls)
    save()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        passed = list(pool.map(run, cases))
        passed += list(pool.map(run, controls))
    if fingerprints != {str(p.relative_to(ROOT)): sha(p) for p in sources}:
        raise RuntimeError('PRF proof inputs changed during execution')
    if baseline and sha(baseline) != baseline_hash:
        raise RuntimeError('Preserved pre-fix source changed during execution')
    result['complete'] = all(passed)
    save()
    if not all(passed):
        raise SystemExit('Incomplete PRF contract')
    label = ('architectural/debug x0 after idle reset' if args.checks == 'zero' else
             'architectural x0, PRF byte/state history and late forwarding')
    print('FORMAL COMPLETE: ' + label)


ENTRY_POINTS = {
    'views': views_main,
    'composed': composed_main,
    'byte-partition': byte_partition_main,
    'prove': prove_main,
}


def main():
    import sys

    command = sys.argv[1] if len(sys.argv) > 1 else ''
    if command not in ENTRY_POINTS:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('command', choices=ENTRY_POINTS)
        parser.parse_args()
    del sys.argv[1]
    return ENTRY_POINTS[command]()


if __name__ == '__main__':
    raise SystemExit(main())
