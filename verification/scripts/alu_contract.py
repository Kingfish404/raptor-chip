#!/usr/bin/env python3
"""Prove unrestricted ALU behavior and qualify the resulting proof receipts."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import gzip
import hashlib
import itertools
import json
import os
import re
import shutil
import subprocess
import sys
from formal_scope import (
    audit_combinational_snapshot,
    audit_receipt,
    binding_key,
    canonical_rtlil,
    inventory,
)
from prf_formal import audit_frontend, audit_model
from yosys_common import ROOT, run_bounded


TOP = 'formal_ieu_alu'

HARNESS = ROOT / 'verification/formal/formal_ieu_alu.sv'

DUT = ROOT / 'rtl/backend/ieu/rapt_ieu_alu.sv'

TOOLS = ROOT / 'third_party/oss-cad-suite/bin'

CERTIFICATE = 'UNRESTRICTED COMBINATIONAL PROOF COMPLETE'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot_result(output):
    """Accept one solver answer and known SMT interface progress messages only."""
    lines = output.splitlines()
    if not lines or lines[-1] not in ('sat', 'unsat'):
        raise ValueError('Missing unique unrestricted solver answer')
    progress = r'##\s+\d+:\d{2}:\d{2}\s+waiting for solver \(\d+ (?:minute|hour)s?\)'
    if any(not re.fullmatch(progress, line) for line in lines[:-1]):
        raise ValueError('Unexpected unrestricted solver output')
    return lines[-1]


def read_command(case, dut=DUT, harness=HARNESS, baseline=False):
    flags = f'-GXLEN={case["xlen"]} '
    if not baseline:
        flags += f'-GEnableRareOps={case["rare"]} '
    flags += '-DRAPT_RV64 ' if case['xlen'] == 64 else '-URAPT_RV64 '
    flags += '-DSYNTHESIS ' if case['synthesis'] else '-USYNTHESIS '
    flags += f'-DRAPT_FPGA_LUTRAM={case["lutram"]} '
    flags += '-DRAPT_USE_SRAM_MACRO ' if case['memory'] == 'sram' else '-URAPT_USE_SRAM_MACRO '
    if baseline:
        flags += '-DFORMAL_ALU_CLMUL -DFORMAL_ALU_CLMULH '
    return (f'read_slang --threads 1 --unroll-limit 20000 --single-unit --top {TOP} {flags}'
            + f'-I{ROOT}/rtl/configs/{case["preset"]} -I{ROOT}/rtl/include '
            + f'-I{ROOT}/rtl/include/npc -I{ROOT}/rtl/include/dpic_mock {harness} {dut}')


def parameters(case):
    return dict(XLEN=case['xlen'], EnableRareOps=case['rare'], defines={
        'RAPT_RV64': case['xlen'] == 64, 'RAPT_USE_SRAM_MACRO': case['memory'] == 'sram',
        'RAPT_FPGA_LUTRAM': case['lutram'], 'SYNTHESIS': case['synthesis']})


def activation_map(text, directory):
    pending, found = [], {}
    for line in text.splitlines():
        matched = re.search(r'Reached cover statement in step \d+ at (.+)$', line)
        if matched:
            pending.append(matched[1])
        matched = re.search(r'Writing trace to VCD file: (.+)$', line)
        if matched:
            path = Path(matched[1])
            if not path.is_relative_to(directory):
                raise ValueError('Activation witness escapes output')
            if not path.is_file() or not path.stat().st_size:
                raise ValueError('Empty activation witness')
            for name in pending:
                found[name] = str(path.relative_to(directory))
            pending = []
    if pending:
        raise ValueError('Activation is missing its waveform')
    return found


def prove(directory, case, timeout, yosys, *, dut=DUT, negative=False, model_hash=None):
    directory.mkdir(parents=True)
    sources = [DUT, HARNESS, dut, Path(__file__),
               Path(__file__).with_name('prf_formal.py'), Path(__file__).with_name('yosys_common.py')]
    sources += list((ROOT / 'rtl/include').rglob('*.svh'))
    sources += list((ROOT / 'rtl/configs' / case['preset']).rglob('*.svh'))
    sources += [ROOT / 'third_party/oss-cad-suite/share/yosys/python3/smtio.py']
    fingerprints = {str(p): sha(p) for p in sources}
    env = dict(os.environ, PATH=str(TOOLS) + ':' + os.environ['PATH'])
    script = directory / 'read.ys'
    script.write_text(read_command(case, dut) + f'\nhierarchy -check -top {TOP}\n'
                      + f'write_rtlil {directory}/frontend.il\n'
                      'chformal -lower\n' + f'prep -top {TOP} -flatten\ncheck -assert\n'
                      'select -assert-none t:$assume t:$anyseq t:$anyconst t:$initstate '
                      'A:blackbox=1 t:$dff t:$dffe t:$adff t:$sdff t:$dlatch t:$mem_v2\n'
                      'select -assert-count 1 t:$assert\nselect -assert-any t:$cover\n'
                      + f'write_smt2 -wires {directory}/model.smt2\n')
    with (directory / 'prepare.log').open('w') as stream:
        prepared = run_bounded([yosys, '-Q', '-T', '-m', 'slang', '-s', str(script)],
                               stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    result = dict(certified=False, negative_detected=False, whole_rtl_signoff=False,
                  case=case, sources=fingerprints, preparation_exit=prepared.returncode,
                  method='Unrestricted combinational equivalence; no temporal bound or assumptions')
    statuses = {}
    for task in ('prove', 'cover'):
        folder = directory / task
        folder.mkdir()
        if task == 'cover' and negative:
            statuses[task] = 'NOT_RUN'
            (folder / 'run.log').write_text('Counterexample control; activation is not a proof.\n')
            (folder / 'status').write_text('NOT_RUN\n')
            continue
        command = [str(TOOLS / 'yosys-smtbmc'), '-s', 'bitwuzla', '--presat', '--noprogress',
                   '-t', '1', '--dump-vcd', str(folder / 'trace%.vcd')]
        if task == 'cover':
            command += ['-c']
        command += [str(directory / 'model.smt2')]
        with (folder / 'run.log').open('w') as stream:
            if prepared.returncode == 0:
                child = run_bounded(command, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                    timeout=timeout)
                output = (folder / 'run.log').read_text()
                value = 'PASS' if child.returncode == 0 and 'Status: PASSED' in output else 'ERROR'
                if 'Assert failed' in output and 'Status: FAILED' in output:
                    value = 'FAIL'
                if child.returncode == 124:
                    value = 'TIMEOUT'
            else:
                stream.write('ERROR: Preparation failed\n')
                value = 'ERROR'
        statuses[task] = value
        (folder / 'status').write_text(value + '\n')
    result['statuses'] = statuses
    try:
        expected_covers = 138 + 6 * case['rare']
        result['frontend'] = audit_frontend((directory / 'frontend.il').read_text(), 1)
        actual_hash = hashlib.sha256(canonical_rtlil(
            (directory / 'frontend.il').read_text()).encode()).hexdigest()
        result['full_model_sha256'] = actual_hash
        if model_hash is not None and actual_hash != model_hash:
            raise ValueError('Proof model differs from the classified full model')
        if result['frontend']['covers_before_optimization'] != expected_covers:
            raise ValueError('Missing opcode, word or operand activation conditions')
        model = (directory / 'model.smt2').read_text()
        result['unrestricted_predicates'] = audit_model(model, TOP)
        transition = f'(define-fun |{TOP}_t| ((state |{TOP}_s|) (next_state |{TOP}_s|)) Bool true)'
        actual = [line.split(';', 1)[0].rstrip() for line in model.splitlines()
                  if line.startswith(f'(define-fun |{TOP}_t| ')]
        if actual != [transition]:
            raise ValueError('ALU model contains sequential transitions')
        query = directory / 'unrestricted.smt2'
        query.write_text(model + '\n' + f'(declare-fun arbitrary_snapshot () |{TOP}_s|)\n'
                         + f'(assert (not (|{TOP}_a| arbitrary_snapshot)))\n(check-sat)\n')
        direct = run_bounded([sys.executable, str(Path(__file__).with_name('prf_formal.py')), 'views',
                              '--snapshot-query', str(query),
                              str(directory / 'unrestricted-expanded.smt2')], env=env,
                             capture_output=True, text=True, timeout=timeout)
        (directory / 'unrestricted-transcript.log').write_text(direct.stdout + direct.stderr)
        if direct.stderr:
            raise ValueError('Unrestricted solver emitted diagnostics')
        result['unrestricted_query'] = snapshot_result(direct.stdout)
        (directory / 'unrestricted.log').write_text(result['unrestricted_query'] + '\n')
        result['unrestricted_exit'] = direct.returncode
        result['activation'] = {} if negative else activation_map(
            (directory / 'cover/run.log').read_text(), directory)
        if not negative and len(result['activation']) != expected_covers:
            raise ValueError('Not every raw activation condition has a witness')
    except (ValueError, FileNotFoundError) as error:
        result['audit_error'] = str(error)
    passed = (prepared.returncode == 0 and 'audit_error' not in result
              and result.get('unrestricted_exit') == 0)
    result['certified'] = (passed and statuses['prove'] == 'PASS' and statuses['cover'] == 'PASS'
                            and result.get('unrestricted_query') == 'unsat')
    traces = list((directory / 'prove').glob('trace*.vcd'))
    result['negative_detected'] = (passed and statuses['prove'] == 'FAIL'
                                   and result.get('unrestricted_query') == 'sat'
                                   and bool(traces) and all(p.stat().st_size for p in traces))
    if fingerprints != {str(p): sha(p) for p in sources}:
        raise RuntimeError('ALU proof inputs changed')
    (directory / 'certificate.log').write_text(
        (CERTIFICATE if result['certified'] else 'UNRESTRICTED COMBINATIONAL PROOF INCOMPLETE')
        + '\n' + f'Unrestricted result: {result.get("unrestricted_query", "NOT_PROVED")}\n')
    result['artifacts'] = {str(p.relative_to(directory)): sha(p) for p in directory.rglob('*')
                           if p.is_file()}
    (directory / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def mutant_source(name):
    text = DUT.read_text()
    if name == 'multibit-clmulh':
        if text.count('assign out_r =') != 2 or text.count('endmodule') != 1:
            raise ValueError('ALU result mutation anchors changed')
        text = text.replace('  logic [XLEN-1:0] alu_r;',
                            '  logic [XLEN-1:0] raw_result;\n  logic [XLEN-1:0] alu_r;')
        text = text.replace('assign out_r =', 'assign raw_result =')
        return text.replace('endmodule', '''  assign out_r = raw_result ^ (
      (op == `RAPT_ALU_CLMULH && (s2 & (s2 - XLEN'(1))) != 0) ? XLEN'(1) : '0);
endmodule''')
    changes = {
        'clmulh-slice': ('clmul_tree[1][2*XLEN-1:XLEN]', 'clmul_tree[1][2*XLEN-2-:XLEN]'),
        'rare-count-leak': ("EnableRareOps ? XLEN'(pop_count[1]) : '0", "XLEN'(pop_count[1])"),
        'uw-sign-extension': ('|| (op == `RAPT_ALU_SLLI_UW)', ''),
        'bext-word-shift': (' && op != `RAPT_ALU_BEXT', ''),
        'signed-compare': ('s1[XLEN-1] != s2[XLEN-1] ? s1[XLEN-1] : less_unsigned',
                           'less_unsigned'),
    }
    old, new = changes[name]
    if text.count(old) != 1:
        raise ValueError('ALU mutation anchor changed: ' + name)
    return text.replace(old, new)


def controls(output, timeout, yosys):
    settings = [('multibit-clmulh', 64, 1), ('clmulh-slice', 32, 1),
                ('rare-count-leak', 64, 0), ('uw-sign-extension', 64, 0),
                ('bext-word-shift', 64, 0), ('signed-compare', 32, 0)]
    rows = []
    for name, xlen, rare in settings:
        source = output / (name + '.sv')
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(mutant_source(name))
        case = dict(preset='formal', xlen=xlen, memory='dff', rare=rare,
                    lutram=0, synthesis=True)
        result = prove(output / name, case, timeout, yosys, dut=source, negative=True)
        rows.append(dict(name=name, detected=result['negative_detected'],
                         report=str((output / name / 'results.json').relative_to(output.parent)),
                         report_sha256=sha(output / name / 'results.json')))
    return rows


def limited_baseline(directory, harness, timeout, yosys):
    """Demonstrate the old domain restriction; never issue a positive certificate."""
    directory.mkdir(parents=True)
    source = directory / 'multibit-fault.sv'
    source.write_text(mutant_source('multibit-clmulh'))
    rows = []
    for xlen in (32, 64):
        folder = directory / str(xlen)
        folder.mkdir()
        case = dict(preset='formal', xlen=xlen, memory='dff', rare=1, lutram=0, synthesis=True)
        script = folder / 'read.ys'
        script.write_text(read_command(case, source, harness, baseline=True)
                          + f'\nchformal -lower\nprep -top {TOP} -flatten\ncheck -assert\n'
                          + f'write_smt2 -wires {folder}/model.smt2\n')
        with (folder / 'prepare.log').open('w') as stream:
            prepared = run_bounded([yosys, '-Q', '-T', '-m', 'slang', '-s', str(script)],
                                   stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
        env = dict(os.environ, PATH=str(TOOLS) + ':' + os.environ['PATH'])
        with (folder / 'run.log').open('w') as stream:
            child = run_bounded([str(TOOLS / 'yosys-smtbmc'), '-s', 'bitwuzla', '--noprogress',
                                 '-t', '1', str(folder / 'model.smt2')], env=env, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=timeout)
        rows.append(dict(xlen=xlen, limited_baseline_only=True, whole_rtl_signoff=False,
                         blindspot_demonstrated=prepared.returncode == 0 and child.returncode == 0
                         and 'Status: PASSED' in (folder / 'run.log').read_text(),
                         harness_sha256=sha(harness), mutant_sha256=sha(source)))
    return rows


def prove_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--presets', nargs='+')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('--controls-only', action='store_true')
    parser.add_argument('--baseline-harness', type=Path,
                        help='Optional preserved one-hot harness for the blind-spot demonstration')
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('Output must be empty')
    if min(args.jobs, args.timeout) < 1:
        parser.error('Jobs and timeout must be positive')
    presets = args.presets or sorted(p.parent.name for p in
                                    (ROOT / 'rtl/configs').glob('*/rapt_config.svh'))
    if len(set(presets)) != len(presets) or any(not re.fullmatch(r'[\w-]+', p) for p in presets):
        parser.error('Require distinct valid preset names')
    if any(not (ROOT / 'rtl/configs' / p / 'rapt_config.svh').is_file() for p in presets):
        parser.error('Unknown preset')
    for path in (ROOT, output):
        if any(c.isspace() or c in ';"' for c in str(path)):
            parser.error('Unsupported formal path')
    output.mkdir(parents=True)
    protected = [Path(__file__), HARNESS, Path(__file__).with_name('formal_scope.py'),
                 Path(__file__).with_name('yosys_common.py'),
                 Path(__file__).with_name('prf_formal.py')]
    fingerprints = {str(p): sha(p) for p in protected}
    yosys = shutil.which(os.environ.get('RAPTOR_YOSYS_REAL', 'yosys'))
    if not yosys:
        parser.error('Yosys executable is missing')
    if args.controls_only:
        rows = controls(output / 'controls', args.timeout, yosys)
        result = dict(complete=all(r['detected'] for r in rows), whole_rtl_signoff=False,
                      scope='Mutation sensitivity only; no positive ALU signoff.', controls=rows)
        (output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
        if fingerprints != {str(p): sha(p) for p in protected}:
            raise RuntimeError('ALU control inputs changed')
        if not result['complete']:
            raise SystemExit('Undetected ALU mutation')
        return
    cases = []
    for index, values in enumerate(itertools.product(presets, (32, 64), ('dff', 'sram'),
                                                      (0, 1), (0, 1), (False, True))):
        p, x, memory, rare, lutram, synthesis = values
        cases.append(dict(id=f'alu-{index:04d}', preset=p, xlen=x, memory=memory,
                          rare=rare, lutram=lutram, synthesis=synthesis))
    manifest = output / 'commands.json'
    commands = [dict(id=c['id'], top=TOP, read=read_command(c).replace(str(ROOT), '@ROOT@'))
                for c in cases]
    manifest.write_text(json.dumps(dict(cases=commands), indent=2) + '\n')
    env = dict(os.environ, RAPTOR_YOSYS_REAL=yosys)
    with (output / 'classify.log').open('w') as stream:
        classified = run_bounded([sys.executable, str(Path(__file__).with_name(
                                   'formal_scope.py')), 'model-classes', '--commands', str(manifest),
                                   '--output', str(output / 'models'), '--jobs', str(args.jobs)],
                                  env=env, stdout=stream, stderr=subprocess.STDOUT,
                                  timeout=max(300, len(cases) * 10))
    if classified.returncode:
        raise SystemExit('ALU model inventory incomplete')
    models = json.loads((output / 'models/results.json').read_text())
    assert models['complete_model_inventory']
    byid = {case['id']: case for case in cases}
    representatives = [(h, ids[0]) for h, ids in models['groups'].items()]
    result = dict(complete=False, whole_rtl_signoff=False, cases=cases, proofs=[],
                  required_bindings=len(cases), model_classes=len(representatives),
                  models_sha256=sha(output / 'models/results.json'),
                  scope='Combinational ALU values for all 64 internal opcodes, both word flags '
                        'and arbitrary operands; both rare-operation settings. Instruction '
                        'decode legality, dispatch routing and execution-port transport are separate.')
    def run(entry):
        model_hash, identifier = entry
        evidence = prove(output / 'proofs' / model_hash, byid[identifier], args.timeout, yosys,
                         model_hash=model_hash)
        return dict(model_sha256=model_hash, representative=identifier,
                    certified=evidence['certified'], report_sha256=sha(
                        output / 'proofs' / model_hash / 'results.json'))
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        result['proofs'] = list(pool.map(run, representatives))
    result['controls'] = controls(output / 'controls', args.timeout, yosys)
    if args.baseline_harness:
        result['limited_baseline'] = limited_baseline(
            output / 'limited-baseline', args.baseline_harness.resolve(), args.timeout, yosys)
        if not all(row['blindspot_demonstrated'] for row in result['limited_baseline']):
            raise RuntimeError('Preserved baseline did not demonstrate its limited domain')
    result['complete'] = (all(row['certified'] for row in result['proofs'])
                          and all(row['detected'] for row in result['controls']))
    if models['sources'] != {n: sha(ROOT / n) for n in models['sources']}:
        raise RuntimeError('ALU matrix RTL/configuration sources changed')
    if models['read_inputs'] != {n: sha(ROOT / n) for n in models['read_inputs']}:
        raise RuntimeError('ALU matrix harness/include inputs changed')
    if fingerprints != {str(p): sha(p) for p in protected}:
        raise RuntimeError('ALU matrix verifier inputs changed')
    (output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'ALU bindings={len(cases)}, exact models={len(representatives)}, '
          f'qualified={sum(r["certified"] for r in result["proofs"])}', flush=True)
    if not result['complete']:
        raise SystemExit('Incomplete unrestricted ALU proof')


def receipts_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    output = args.evidence.resolve()
    report = json.loads((output / 'results.json').read_text())
    if not report['complete'] or not all(r['detected'] for r in report['controls']):
        raise SystemExit('Incomplete ALU matrix or mutation controls')
    model_path = output / 'models/results.json'
    if sha(model_path) != report['models_sha256']:
        raise SystemExit('Model inventory changed')
    models = json.loads(model_path.read_text())
    scope = inventory(ROOT)
    if scope['sources'] != models['sources']:
        raise SystemExit('ALU matrix RTL/configuration fingerprint is stale')
    unit = str(DUT.relative_to(ROOT)) + ':rapt_ieu_alu'
    profile_bindings = {}
    for profile in scope['profiles']:
        preset, architecture, memory = profile.split('/')
        profile_bindings[profile] = [parameters(dict(preset=preset, xlen=int(architecture[2:]),
            memory=memory, rare=rare, lutram=lutram, synthesis=synthesis))
            for rare, lutram, synthesis in itertools.product((0, 1), (0, 1), (False, True))]
    cases = {case['id']: case for case in report['cases']}
    rows = {row['id']: row for row in models['cases']}
    proofs = {row['model_sha256']: row for row in report['proofs']}
    if len(cases) != report['required_bindings'] or set(cases) != set(rows):
        raise SystemExit('Missing or duplicate ALU binding')
    receipts, audited = [], {}
    for identifier, case in cases.items():
        model = rows[identifier]
        group = model['canonical_sha256']
        proof = proofs[group]
        folder = output / 'proofs' / group
        evidence = json.loads((folder / 'results.json').read_text())
        if not evidence['certified'] or sha(folder / 'results.json') != proof['report_sha256']:
            raise SystemExit('Unqualified ALU representative')
        if group not in audited:
            suffix = '/' + str(DUT.relative_to(ROOT))
            old_roots = [Path(name.removesuffix(suffix)) for name in evidence['sources']
                         if name.endswith(suffix)]
            if len(old_roots) != 1:
                raise SystemExit('Missing unique proof source root')
            old_root = old_roots[0]
            for name, digest in evidence['sources'].items():
                original = Path(name)
                current = ROOT / original.relative_to(old_root) if original.is_relative_to(
                    old_root) else original
                if sha(current) != digest:
                    raise SystemExit('ALU proof input changed: ' + name)
            for name, digest in evidence['artifacts'].items():
                if sha(folder / name) != digest:
                    raise SystemExit('ALU proof artifact changed: ' + name)
            audited[group] = True
        archive = output / 'models' / identifier / 'raw.il.gz'
        if sha(archive) != model['archive_sha256']:
            raise SystemExit('ALU binding model changed')
        original = gzip.decompress(archive.read_bytes()).decode()
        if hashlib.sha256(canonical_rtlil(original).encode()).hexdigest() != group:
            raise SystemExit('ALU binding model identity mismatch')
        prefix = str(folder.relative_to(output)) + '/'
        artifacts = {prefix + name: digest for name, digest in evidence['artifacts'].items()}
        artifacts[prefix + 'results.json'] = sha(folder / 'results.json')
        artifacts[f'models/{identifier}/raw.il.gz'] = sha(archive)
        script = output / 'models' / identifier / 'read.ys'
        artifacts[f'models/{identifier}/read.ys'] = sha(script)
        inputs = dict(scope['sources'])
        suffix = '/' + str(DUT.relative_to(ROOT))
        old_root = Path(next(name.removesuffix(suffix) for name in evidence['sources']
                             if name.endswith(suffix)))
        for name, digest in evidence['sources'].items():
            path = Path(name)
            if path.is_relative_to(old_root):
                relative = path.relative_to(old_root)
                # A shared tool installation can legitimately resolve outside the checkout.
                # Its verified fingerprint remains in the archived raw proof report.
                if relative.parts[0] != 'third_party':
                    inputs[str(relative)] = digest
        input_harness = str(HARNESS.relative_to(ROOT))
        profile = f'{case["preset"]}/rv{case["xlen"]}/{case["memory"]}'
        binding = parameters(case)
        if binding_key(binding) not in {binding_key(p) for p in profile_bindings[profile]}:
            raise SystemExit('Unexpected binding outside the reviewed ALU interface')
        receipt = dict(status='PASS', unit=unit, obligation='functional', profile=profile,
                       method='combinational-smt', harness=input_harness, inputs=inputs,
                       parameters=binding, assumptions=[], log=prefix + 'certificate.log',
                       artifacts=artifacts, snapshot=dict(frontend=prefix + 'frontend.il',
                       model=prefix + 'model.smt2', query=prefix + 'unrestricted.smt2',
                       expanded=prefix + 'unrestricted-expanded.smt2',
                       result=prefix + 'unrestricted.log', top=TOP, assertions=1,
                       covers=138 + 6 * case['rare']),
                       elaboration=dict(model=f'models/{identifier}/raw.il.gz',
                                        script=f'models/{identifier}/read.ys'),
                       property_activation=[dict(property=name, log=prefix + 'cover/run.log',
                                                 witness=prefix + witness)
                                            for name, witness in evidence['activation'].items()])
        if (folder / 'certificate.log').read_text().splitlines()[0] != CERTIFICATE:
            raise SystemExit('Missing qualified combinational certificate')
        audit_combinational_snapshot(receipt, output)
        receipts.append((output / f'receipt-{identifier}.json', receipt))
    review = dict(sources=scope['sources'], units={unit: dict(
        rationale='Combinational operator contract for all internal 6-bit opcodes and both word '
                  'flags over arbitrary operands. GF(2) coefficients define carry-less products. '
                  'Rare-disabled ports return zero for the six documented rare operators. '
                  'Decode legality, routing, port transport and instruction retirement are '
                  'separate unit/composition obligations.',
        obligations=['functional'], profiles=scope['profiles'], parameter_bindings=profile_bindings)})
    from formal_scope import apply_contract_review
    apply_contract_review(scope, review)
    for path, receipt in receipts:
        audit_receipt(receipt, scope, ROOT, output)
        path.write_text(json.dumps(receipt, indent=2) + '\n')
    (output / 'contract-review.json').write_text(json.dumps(review, indent=2) + '\n')
    result = dict(complete_selected_alu_matrix=True, whole_rtl_signoff=False,
                  all_supported_profiles_elaborated={r['profile'] for _, r in receipts}
                  == set(scope['profiles']), receipts=len(receipts),
                  exact_model_classes=len(proofs), assumptions=[],
                  receipt_files={p.name: sha(p) for p, _ in receipts},
                  review_sha256=sha(output / 'contract-review.json'),
                  bindings=sorted({binding_key(r['parameters']) for _, r in receipts}))
    (output / 'qualified.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'ALU qualified receipts={len(receipts)}, exact models={len(proofs)}')


ENTRY_POINTS = {
    'prove': prove_main,
    'receipts': receipts_main,
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
