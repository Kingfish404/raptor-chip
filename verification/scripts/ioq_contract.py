#!/usr/bin/env python3
"""Prove IOQ ownership and store data, and audit assertion activation."""
from concurrent.futures import ProcessPoolExecutor
from multiprocessing import get_context
from pathlib import Path
import argparse
import copy
import gzip
import hashlib
import itertools
import json
import os
import re
import shutil
import subprocess
import sys
from yosys_common import ROOT, run_bounded


TOP = 'formal_ioq_owner'

HARNESS = ROOT / 'verification/formal/formal_ioq.sv'

DUT = ROOT / 'rtl/backend/lsu/rapt_lsu_ioq.sv'

TOOLS = ROOT / 'third_party/oss-cad-suite/bin'

SCOPE = ('Full production IOQ + actual DPU and capacity adapter; independent dispatch '
         'and response histories prove admission, queue ownership, request hold, A/B '
         'response attribution, integer/FP completion provenance and at-most-once '
         'completion per accepted allocation. ROB lifetime composition, memory contents, '
         'address translation, exception classification and store-data semantics remain open.')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical_model(model):
    """Drop source locations only; preserve memory, init and clocked checks."""
    def visit(value):
        if isinstance(value, dict):
            return {key: ({k: visit(v) for k, v in item.items() if k != 'src'}
                          if key == 'attributes' else visit(item))
                    for key, item in value.items()}
        if isinstance(value, list):
            return [visit(item) for item in value]
        return value
    return json.dumps(visit(model), sort_keys=True, separators=(',', ':'))


def audit_frontend(model):
    if len(model['modules']) != 1:
        raise ValueError('Expected one complete native IOQ model')
    top = next(iter(model['modules']))
    if top not in ('formal_ioq_owner', 'formal_ioq_store'):
        raise ValueError('Expected a fully elaborated production IOQ/dispatch composition')
    module = model['modules'][top]
    prefix = 'base.' if top == 'formal_ioq_store' else ''
    counts = dict(assertions=0, covers=0, assumptions=0)
    covers = []
    for name, cell in module['cells'].items():
        kind = cell['type']
        if (kind.startswith(('$any', '$meminit')) or kind == '$initstate'
                or cell.get('attributes', {}).get('blackbox')):
            raise ValueError('Abstract or initialized DUT state: ' + name)
        if kind == '$check':
            flavor = cell['parameters']['FLAVOR']
            key = dict(assert_='assertions', cover='covers', assume='assumptions').get(
                'assert_' if flavor == 'assert' else flavor)
            if key is None:
                raise ValueError('Unknown formal predicate: ' + flavor)
            counts[key] += 1
            if flavor == 'cover':
                covers.append(top + ': ' + name)
    if counts['assumptions'] != 1 or not counts['assertions'] or not counts['covers']:
        raise ValueError('Missing producer contract or extra environmental assumptions')
    netnames = module['netnames']
    memories = module['memories']
    allowed_init = {prefix + 'past_valid'}
    for name, net in netnames.items():
        if 'init' in net.get('attributes', {}) and name not in allowed_init:
            raise ValueError('Unexpected initial-state restriction: ' + name)
    counts['cover_names'] = sorted(covers)
    counts['geometry'] = dict(
        ioq_entries=len(netnames[prefix + 'live']['bits']),
        dispatch_width=len(netnames[prefix + 'selected_valid']['bits']),
        scan_entries=len(netnames['candidate_valid']['bits']),
        completion_ports=len(netnames[prefix + 'dut.wb_valid']['bits']),
        xlen=memories[prefix + 'dut.ioq_rdata']['width'],
        pc_bits=memories[prefix + 'pc']['width'], rob_index_bits=memories[prefix + 'owner']['width'],
        generation_bits=memories[prefix + 'generation']['width'],
        physical_index_bits=memories[prefix + 'prd']['width'],
        arch_index_bits=memories[prefix + 'rd']['width'])
    return counts


def read_command(case, rtl, *, dut=DUT):
    profile = contract_profile(case.get('contract', 'owner'))
    top, harness = profile['top'], profile['harness']
    flags = '-DRAPT_RV64 ' if case['xlen'] == 64 else '-URAPT_RV64 '
    if profile['top'] == 'formal_ioq_store':
        flags += '-DRAPT_FORMAL_IOQ_STORE '
    flags += '-DSYNTHESIS ' if case['synthesis'] else '-USYNTHESIS '
    flags += '-URAPT_ASSERT_EN -URAPT_SVA_ACTIVE '
    flags += '-DRAPT_USE_SRAM_MACRO ' if case['memory'] == 'sram' else '-URAPT_USE_SRAM_MACRO '
    flags += f'-DRAPT_FPGA_LUTRAM={case["lutram"]} '
    flags += f'-DRAPT_IOQ_LOAD_RESPONSE_STAGE={case["response_stage"]} '
    flags += '-DRAPT_RVFI ' if case['metadata'] == 'rvfi' else '-URAPT_RVFI '
    flags += '-DRAPT_KEEP_UOP_INST ' if case['metadata'] == 'instruction' else '-URAPT_KEEP_UOP_INST '
    files = [dut if path == DUT else path for path in rtl]
    return ('read_slang --threads 1 --single-unit '
            '--allow-toplevel-iface-ports ' + flags
            + f'-I{ROOT}/rtl/configs/{case["preset"]} -I{ROOT}/rtl/include '
            + f'-I{ROOT}/rtl/include/npc -I{ROOT}/rtl/include/dpic_mock --top {top} '
            + ' '.join(map(str, files + [harness])))


def compile_case(directory, case, rtl, timeout, yosys, *, dut=DUT):
    top = contract_profile(case.get('contract', 'owner'))['top']
    directory.mkdir(parents=True)
    raw = directory / 'frontend.json'
    script = directory / 'read.ys'
    script.write_text(read_command(case, rtl, dut=dut) + f'\nhierarchy -check -top {top}\n'
                      + f'write_json {raw}\n')
    with (directory / 'compile.log').open('w') as stream:
        child = run_bounded([yosys, '-Q', '-T', '-m', 'slang', '-s', str(script)],
                             stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    row = dict(case=case, compile_exit=child.returncode, complete=False)
    if child.returncode == 0:
        model = json.loads(raw.read_text())
        row['frontend'] = audit_frontend(model)
        canonical = canonical_model(model)
        row['canonical_sha256'] = hashlib.sha256(canonical.encode()).hexdigest()
        row['original_sha256'] = sha(raw)
        archive = directory / 'frontend.json.gz'
        with raw.open('rb') as src, gzip.open(archive, 'wb', compresslevel=1) as dst:
            shutil.copyfileobj(src, dst)
        row['archive_sha256'] = sha(archive)
        raw.unlink()
        row['complete'] = True
    row['read_sha256'] = sha(script)
    row['compile_log_sha256'] = sha(directory / 'compile.log')
    (directory / 'results.json').write_text(json.dumps(row, indent=2) + '\n')
    return row


def prove(directory, compiled, model_directory, timeout, depth, cover_depth, yosys,
          *, negative=False, solver='auto'):
    top = contract_profile(compiled['case'].get('contract', 'owner'))['top']
    directory.mkdir(parents=True)
    raw = directory / 'frontend.json'
    raw.write_bytes(gzip.decompress((model_directory / 'frontend.json.gz').read_bytes()))
    if sha(raw) != compiled['original_sha256']:
        raise ValueError('Archived full frontend changed')
    frontend = audit_frontend(json.loads(raw.read_text()))
    if hashlib.sha256(canonical_model(json.loads(raw.read_text())).encode()).hexdigest() != (
            compiled['canonical_sha256']):
        raise ValueError('Proof differs from its complete classified model')
    script = (f'read_json {raw}\nhierarchy -check -top {top}\n'
              'select -assert-none t:$anyseq t:$anyconst t:$initstate A:blackbox=1\n'
              'setattr -set keep 1 t:$check\n'
              + f'prep -top {top} -flatten\nasync2sync\nchformal -lower\n'
              'memory_map\nopt\ncheck -assert\n'
              'select -assert-count 1 t:$assume\nselect -assert-any t:$assert\n'
              'select -assert-any t:$cover\n')
    tasks = '[tasks]\nprove\n' if negative else '[tasks]\nprove\ncover\n'
    options = (f'[options]\nprove: mode {"bmc" if negative else "prove"}\n'
               + f'prove: depth {depth}\ntimeout {timeout}\n')
    if not negative:
        options += f'cover: mode cover\ncover: depth {cover_depth}\n'
    chosen_solver = solver
    if chosen_solver == 'auto':
        chosen_solver = 'bitwuzla' if frontend['geometry']['dispatch_width'] >= 8 else 'yices'
    config = tasks + options + f'[engines]\nsmtbmc {chosen_solver}\n[script]\n' + script
    (directory / 'contract.sby').write_text(config)
    env = dict(os.environ, PATH=str(TOOLS) + ':' + os.environ['PATH'], RAPTOR_YOSYS_REAL=yosys)
    with (directory / 'run.log').open('w') as stream:
        child = run_bounded([str(TOOLS / 'sby'), '--yosys',
            str(ROOT / 'verification/formal/yosys-rvfi-compat.sh'), 'contract.sby'],
            cwd=directory, env=env, stdout=stream, stderr=subprocess.STDOUT,
            timeout=timeout + 120)
    result = dict(case=compiled['case'], full_model_sha256=compiled['canonical_sha256'],
                  frontend=frontend, exit=child.returncode, statuses={}, activation={},
                  certified=False, negative_detected=False, whole_rtl_signoff=False,
                  solver=chosen_solver)
    for task in (('prove',) if negative else ('prove', 'cover')):
        status = directory / ('contract_' + task) / 'status'
        result['statuses'][task] = status.read_text().split()[0] if status.exists() else 'ERROR'
    if negative:
        traces = sorted((directory / 'contract_prove/engine_0').glob('trace*.vcd'))
        text = (directory / 'run.log').read_text()
        result['negative_detected'] = (result['statuses']['prove'] == 'FAIL'
            and 'Assert failed' in text and 'ERROR:' not in text
            and bool(traces) and all(p.stat().st_size for p in traces))
    elif child.returncode == 0 and result['statuses'] == dict(prove='PASS', cover='PASS'):
        log = directory / 'contract_cover/engine_0/logfile.txt'
        result['activation'] = activation_witnesses(log.read_text(), directory)
        if set(result['activation']) != set(frontend['cover_names']):
            raise ValueError('Not every original cover has its own activation witness')
        result['certified'] = True
    result['artifacts'] = {str(p.relative_to(directory)): sha(p)
                           for p in directory.rglob('*') if p.is_file()}
    (directory / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def activation_witnesses(log, directory):
    """Resolve SBY engine paths against their real working directory."""
    pending, found = [], {}
    for line in log.splitlines():
        match = re.search(r'Reached cover statement in step \d+ at (.+)$', line)
        if match:
            pending.append(match[1])
        match = re.search(r'Writing trace to VCD file: (.+)$', line)
        if match:
            path = Path(match[1])
            if not path.is_absolute():
                path = directory / 'contract_cover' / path
            path = path.resolve()
            if not path.is_relative_to(directory.resolve()) or not path.is_file():
                raise ValueError('Activation witness escapes output or is missing')
            if not path.stat().st_size:
                raise ValueError('Activation waveform is empty')
            for name in pending:
                if name in found:
                    raise ValueError('Duplicate activation property')
                found[name] = str(path.relative_to(directory))
            pending = []
    if pending:
        raise ValueError('Activation property is missing its waveform')
    return found


def compile_worker(arguments):
    return compile_case(*arguments)


def proof_worker(arguments):
    group, row, output, timeout, depth, cover_depth, yosys, solver = arguments
    evidence = prove(output / 'proofs' / group, row,
        output / 'models' / row['case']['id'], timeout, depth, cover_depth, yosys, solver=solver)
    return dict(model_sha256=group, representative=row['case']['id'],
                certified=evidence['certified'],
                report_sha256=sha(output / 'proofs' / group / 'results.json'))


MUTATIONS = {
    'generation': ('generation: dispatch[s].generation,',
                   "generation: dispatch[s].generation ^ GenBits'(1),"),
    'completion-bank': ('completion_head_lane[ioq_payload_lane[ioq_head]]',
                        'completion_head_lane[0]'),
    'destination': ('assign ioq_completion_result.dest = `RAPT_IOQ_BCAST_PICK(ioq_dest);',
                    "assign ioq_completion_result.dest = `RAPT_IOQ_BCAST_PICK(ioq_dest) ^ 1'b1;"),
    'early-duplicate': ("ioq_early_bcasted[early_bcast_idx] <= 1'b1;",
                        "ioq_early_bcasted[early_bcast_idx] <= 1'b0;"),
    'flush-completion': ('wire completion_kill = reset || cmu_bcast.flush_pipe;',
                         'wire completion_kill = reset;'),
    'response-data': ('ioq_rdata[i] <= exu_lsu.rdata;',
                       "ioq_rdata[i] <= exu_lsu.rdata ^ XLEN'(1);"),
    'fp-boxing': ("{32'hffff_ffff, ioq_completion_result.result[31:0]}",
                  "{32'h0000_0000, ioq_completion_result.result[31:0]}"),
}

STORE_SCOPE = (
    'Full production IOQ + actual dispatch composition, retaining all producer assertions. '
    'Independent accepted-dispatch and wake histories check integer/FP store operand '
    'ownership, SQ payload bytes, AMO arithmetic/selection at native width, old-value '
    'provenance, and sampled SC decisions with notification cancellation. Only the first '
    'edge resets; all other inputs remain arbitrary. ROB producer lifetime, cache/bus '
    'atomicity, LR reservation creation/invalidation, address translation, exception '
    'classification and architectural memory ordering remain open.')

STORE_MUTATIONS = {
    'integer-allocation': (
        'ioq_vk[i] <= wake_val(dispatch[alloc_slot[i]].pr2, dispatch[alloc_slot[i]].op2);',
        'ioq_vk[i] <= wake_val(dispatch[alloc_slot[i]].pr2, dispatch[alloc_slot[i]].op1);'),
    'integer-wake': ('ioq_vk[i]  <= ioq_fwd2_val[i];',
                     "ioq_vk[i]  <= ioq_fwd2_val[i] ^ XLEN'(1);"),
    'fp-allocation': ('ioq_fp_store_data[e] <= dispatch[alloc_slot[e]].fp_value[1];',
                      'ioq_fp_store_data[e] <= dispatch[alloc_slot[e]].fp_value[0];'),
    'fp-local-wake': ('ioq_fp_store_data[e] <= local_fp_wake[p].fp_result;',
                     "ioq_fp_store_data[e] <= local_fp_wake[p].fp_result ^ 64'(1);"),
    'amo-add': ('head_amo_wdata = ioq_vk[ioq_head] + ioq_rdata[ioq_head];',
                'head_amo_wdata = ioq_vk[ioq_head] - ioq_rdata[ioq_head];'),
    'amo-word-compare': ('assign head_amo_less_unsigned = ioq_word[ioq_head]',
                        "assign head_amo_less_unsigned = 1'b0"),
    'sc-result': ('? (reservation_match ? 0 : 1)', '? (reservation_match ? 1 : 0)'),
    'sc-notification': ('&& (exu_l1d.reservation_blocked || !sc_decision_ready))',
                        '&& (!sc_decision_ready))'),
}


def contract_profile(name):
    """Select a contract without modifying shared runner state."""
    if name == 'owner':
        return dict(top=TOP, harness=HARNESS, scope=SCOPE, mutations=MUTATIONS,
                    extra_sources=())
    if name == 'store':
        return dict(top='formal_ioq_store',
                    harness=ROOT / 'verification/formal/formal_ioq.sv',
                    scope=STORE_SCOPE, mutations=STORE_MUTATIONS, extra_sources=())
    raise ValueError('Unknown IOQ contract: ' + name)


def prove_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--contract', choices=('owner', 'store'), default='owner')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--presets', nargs='+')
    parser.add_argument('--xlens', nargs='+', type=int, choices=(32, 64), default=[32, 64])
    parser.add_argument('--memory', nargs='+', choices=('dff', 'sram'), default=['dff', 'sram'])
    parser.add_argument('--response-stages', nargs='+', type=int, choices=(0, 1), default=[0, 1])
    parser.add_argument('--lutram', nargs='+', type=int, choices=(0, 1), default=[0, 1])
    parser.add_argument('--synthesis', nargs='+', type=int, choices=(0, 1), default=[0, 1])
    parser.add_argument('--metadata', nargs='+', choices=('functional', 'instruction', 'rvfi'),
                        default=['functional', 'instruction', 'rvfi'])
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--timeout', type=int, default=1800)
    parser.add_argument('--depth', type=int, default=4)
    parser.add_argument('--solver', choices=('auto', 'yices', 'bitwuzla'), default='auto')
    parser.add_argument('--cover-depth', type=int, default=96)
    parser.add_argument('--negative-controls', choices=('run', 'skip'), default='run')
    parser.add_argument('--controls-only', action='store_true')
    args = parser.parse_args()
    profile = contract_profile(args.contract)
    mutations = profile['mutations']
    presets = args.presets or sorted(p.parent.name for p in
                                    (ROOT / 'rtl/configs').glob('*/rapt_config.svh'))
    for values in (presets, args.xlens, args.memory, args.response_stages, args.lutram,
                   args.synthesis, args.metadata):
        if not values or len(set(values)) != len(values):
            parser.error('Require nonempty, distinct matrix dimensions')
    if any(not re.fullmatch(r'[\w-]+', p) or not (ROOT / 'rtl/configs' / p
               / 'rapt_config.svh').is_file() for p in presets):
        parser.error('Unknown or invalid preset')
    if min(args.jobs, args.timeout, args.depth, args.cover_depth) < 1:
        parser.error('Jobs, timeout and depths must be positive')
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('Output must be empty')
    for path in (ROOT, output):
        if any(c.isspace() or c in ';"' for c in str(path)):
            parser.error('Unsupported formal path')
    output.mkdir(parents=True)
    yosys = shutil.which(os.environ.get('RAPTOR_YOSYS_REAL', 'yosys'))
    if not yosys:
        parser.error('Native Yosys is missing')
    rtl = [ROOT / 'rtl/rapt_pkg.sv']
    rtl += sorted(p for p in (ROOT / 'rtl').rglob('*.sv') if p not in rtl)
    sources = sorted(set(rtl + list((ROOT / 'rtl').rglob('*.svh'))
        + [profile['harness'], Path(__file__), Path(__file__).with_name('yosys_common.py'),
           ROOT / 'verification/formal/yosys-rvfi-compat.sh'] + list(profile['extra_sources'])))
    fingerprints = {str(p.relative_to(ROOT)): sha(p) for p in sources}
    result = dict(complete=False, whole_rtl_signoff=False, sources=fingerprints, bindings=[],
        proofs=[], negative_controls=[],
        scope=profile['scope'],
        assumptions=['First sampled edge resets'],
        normalization='Original unoptimized JSON, removing only source-location attributes; '
                      'all memory, initialization, logic and clocked formal checks remain.',
        yosys_version=subprocess.check_output([yosys, '-V'], text=True).strip())
    def save():
        (output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    save()
    if not args.controls_only:
        cases = []
        for index, values in enumerate(itertools.product(presets, args.xlens, args.memory,
                args.response_stages, args.lutram, args.synthesis, args.metadata)):
            p, x, memory, stage, lutram, synthesis, metadata = values
            cases.append(dict(id=f'ioq-{index:05d}', preset=p, xlen=x, memory=memory,
                response_stage=stage, lutram=lutram, synthesis=bool(synthesis),
                metadata=metadata, contract=args.contract))
        work = [(output / 'models' / c['id'], c, rtl, args.timeout, yosys) for c in cases]
        with ProcessPoolExecutor(max_workers=args.jobs, mp_context=get_context('spawn')) as pool:
            for row in pool.map(compile_worker, work):
                result['bindings'].append(row)
                save()
        if not all(row['complete'] for row in result['bindings']):
            raise SystemExit('Incomplete native model inventory')
        groups = {}
        for row in result['bindings']:
            groups.setdefault(row['canonical_sha256'], []).append(row)
        result['groups'] = {h: [r['case']['id'] for r in rows] for h, rows in groups.items()}
        save()
        print(f'IOQ bindings={len(cases)}, exact models={len(groups)}', flush=True)
        work = [(group, rows[0], output, args.timeout, args.depth, args.cover_depth, yosys, args.solver)
                for group, rows in groups.items()]
        with ProcessPoolExecutor(max_workers=args.jobs, mp_context=get_context('spawn')) as pool:
            for row in pool.map(proof_worker, work):
                result['proofs'].append(row)
                save()
    if args.negative_controls == 'run':
        for name, (old, new) in mutations.items():
            directory = output / 'controls' / name
            directory.mkdir(parents=True)
            text = DUT.read_text()
            if text.count(old) != 1:
                raise ValueError('IOQ mutation anchor changed: ' + name)
            dut = directory / 'mutant.sv'
            dut.write_text(text.replace(old, new))
            case = dict(id=name, preset='formal', xlen=64, memory='dff', lutram=0,
                        synthesis=True, response_stage=0, metadata='functional', contract=args.contract)
            compiled = compile_case(directory / 'model', case, rtl, args.timeout, yosys, dut=dut)
            evidence = prove(directory / 'proof', compiled, directory / 'model', args.timeout,
                max(8, args.depth), args.cover_depth, yosys, negative=True, solver=args.solver)
            result['negative_controls'].append(dict(name=name, detected=evidence['negative_detected'],
                report_sha256=sha(directory / 'proof/results.json')))
            save()
    if fingerprints != {str(p.relative_to(ROOT)): sha(p) for p in sources}:
        raise RuntimeError('IOQ verification source epoch changed')
    result['complete'] = (bool(result['proofs']) and all(p['certified'] for p in result['proofs'])
        and len(result['negative_controls']) == len(mutations)
        and all(p['detected'] for p in result['negative_controls']))
    if args.controls_only:
        result['controls_complete'] = (len(result['negative_controls']) == len(mutations)
            and all(p['detected'] for p in result['negative_controls']))
    save()
    print('Qualified IOQ models=' + str(sum(p['certified'] for p in result['proofs'])), flush=True)
    if not result.get('controls_complete' if args.controls_only else 'complete'):
        raise SystemExit('IOQ producer ownership remains incomplete')


PREFIX = 'guard_activation__'

HISTORY = ('stored_response_data', 'stored_fp_data', 'early_response_owner', 'prechecked_owner')


def augment(model, expected_hash):
    """Add sink-only cover cells; deleting them must recover the entire old graph."""
    actual = hashlib.sha256(canonical_model(model).encode()).hexdigest()
    if actual != expected_hash:
        raise ValueError('Full input model differs from its qualified model class')
    information = audit_frontend(model)
    module = model['modules'][TOP]
    cells = module['cells']
    if any(name.startswith(PREFIX) for name in cells):
        raise ValueError('Observer namespace already exists')
    geometry = information['geometry']
    expected = {f'g_resident[{e}].g_bank[{s}].resident_metadata'
                for e in range(geometry['ioq_entries'])
                for s in range(geometry['dispatch_width'])}
    expected |= {f'g_resident[{e}].{name}' for e in range(geometry['ioq_entries'])
                 for name in HISTORY}
    if not expected <= set(cells):
        raise ValueError('Missing original bank/history assertion guard')
    prototype = next(c for c in cells.values()
                     if c['type'] == '$check' and c['parameters']['FLAVOR'] == 'cover')
    names = {}
    for name in sorted(expected):
        original = cells[name]
        if original['type'] != '$check' or original['parameters']['FLAVOR'] != 'assert':
            raise ValueError('Guard does not belong to an original assertion')
        if original['parameters']['TRG_ENABLE'] != format(1, '032b'):
            raise ValueError('Expected original clocked assertion sampling')
        observer = copy.deepcopy(prototype)
        observer['hide_name'] = 0
        observer['parameters']['PRIORITY'] = format(0, '032b')
        for key in ('TRG_ENABLE', 'TRG_POLARITY', 'TRG_WIDTH'):
            observer['parameters'][key] = original['parameters'][key]
        observer['connections']['A'] = list(original['connections']['EN'])
        observer['connections']['EN'] = ['1']
        observer['connections']['TRG'] = list(original['connections']['TRG'])
        observer['attributes'] = dict(original.get('attributes', {}))
        cells[PREFIX + name] = observer
        names[TOP + ': ' + PREFIX + name] = name
    audit_extension(model, expected_hash)
    return names


def audit_extension(model, expected_hash):
    """No old cell, port, memory, init, assertion or assumption may change."""
    module = model['modules'][TOP]
    added = {n: c for n, c in module['cells'].items() if n.startswith(PREFIX)}
    if not added:
        raise ValueError('Missing read-only activation observers')
    for name, cell in added.items():
        if (cell['type'] != '$check' or cell['parameters']['FLAVOR'] != 'cover'
                or any(v != 'input' for v in cell['port_directions'].values())):
            raise ValueError('Observer drives state or adds a non-cover predicate')
        original = module['cells'].get(name.removeprefix(PREFIX))
        if original is None or cell['connections']['A'] != original['connections']['EN']:
            raise ValueError('Activation differs from the original assertion guard')
        if (cell['connections']['EN'] != ['1']
                or cell['connections']['TRG'] != original['connections']['TRG']):
            raise ValueError('Activation sampling differs from the original assertion')
        for key in ('TRG_ENABLE', 'TRG_POLARITY', 'TRG_WIDTH'):
            if cell['parameters'][key] != original['parameters'][key]:
                raise ValueError('Activation sampling differs from the original assertion')
        if cell['connections']['ARGS'] or int(cell['parameters']['ARGS_WIDTH'], 2):
            raise ValueError('Activation observer has unexpected argument inputs')
    saved = module['cells']
    try:
        module['cells'] = {n: c for n, c in saved.items() if n not in added}
        digest = hashlib.sha256(canonical_model(model).encode()).hexdigest()
    finally:
        module['cells'] = saved
    if digest != expected_hash:
        raise ValueError('Observer projection changed original state, logic or formal predicates')


def activate(directory, model_path, expected_hash, timeout, depth, yosys):
    directory.mkdir(parents=True)
    fingerprint = sha(model_path)
    model = json.loads(model_path.read_text())
    selected = augment(model, expected_hash)
    frontend = audit_frontend(model)
    augmented = directory / 'augmented.json'
    augmented.write_text(json.dumps(model, separators=(',', ':')) + '\n')
    script = (f'read_json {augmented}\nhierarchy -check -top {TOP}\n'
        'setattr -set keep 1 t:$check\n' + f'prep -top {TOP} -flatten\n'
        'async2sync\nchformal -lower\nmemory_map\nopt\ncheck -assert\n'
        'select -assert-count 1 t:$assume\nselect -assert-any t:$cover\n')
    config = ('[tasks]\ncover\n[options]\nmode cover\n'
        + f'depth {depth}\ntimeout {timeout}\n[engines]\nsmtbmc yices\n[script]\n' + script)
    (directory / 'contract.sby').write_text(config)
    # SBY normally exports three additional formats for every cover witness. Keep
    # the complete VCD while avoiding repeated full-design value extraction for
    # formats this checker never consumes. No model or solver argument changes.
    wrapper = directory / 'smtbmc-vcd-only.sh'
    wrapper.write_text('''#!/usr/bin/env bash
set -euo pipefail
selected=()
while (($#)); do
  case "$1" in
    --dump-yw|--dump-vlogtb|--dump-smtc) shift; shift ;;
    *) selected+=("$1"); shift ;;
  esac
done
exec "$RAPTOR_SMTBMC_REAL" "${selected[@]}"
''')
    wrapper.chmod(0o755)
    env = dict(os.environ, PATH=str(TOOLS) + ':' + os.environ['PATH'], RAPTOR_YOSYS_REAL=yosys,
               RAPTOR_SMTBMC_REAL=str(TOOLS / 'yosys-smtbmc'))
    with (directory / 'run.log').open('w') as stream:
        child = run_bounded([str(TOOLS / 'sby'), '--yosys',
            str(ROOT / 'verification/formal/yosys-rvfi-compat.sh'),
            '--smtbmc', str(wrapper), 'contract.sby'],
            cwd=directory, env=env, stdout=stream, stderr=subprocess.STDOUT,
            timeout=timeout + 120)
    status = directory / 'contract_cover/status'
    result = dict(complete_guard_activation=False, whole_rtl_signoff=False,
        original_model_sha256=fingerprint, full_class_sha256=expected_hash,
        source_model=str(model_path), selected_assertion_guards=selected,
        witness_formats=['vcd'],
        status=status.read_text().split()[0] if status.exists() else 'ERROR',
        original_state_and_assertions_unchanged=True, activation={})
    if child.returncode == 0 and result['status'] == 'PASS':
        result['activation'] = activation_witnesses(
            (directory / 'contract_cover/engine_0/logfile.txt').read_text(), directory)
        if set(result['activation']) != set(frontend['cover_names']):
            raise ValueError('An original or observer cover is missing its reached waveform')
        result['complete_guard_activation'] = True
    if sha(model_path) != fingerprint:
        raise RuntimeError('Original proof model changed during activation')
    audit_extension(json.loads(augmented.read_text()), expected_hash)
    result['artifacts'] = {str(p.relative_to(directory)): sha(p)
                           for p in directory.rglob('*') if p.is_file()}
    (directory / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def worker(arguments):
    return activate(*arguments)


def activate_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--timeout', type=int, default=1800)
    parser.add_argument('--depth', type=int, default=96)
    args = parser.parse_args()
    if min(args.jobs, args.timeout, args.depth) < 1:
        parser.error('Jobs, timeout and depth must be positive')
    evidence = args.evidence.resolve()
    report = json.loads((evidence / 'results.json').read_text())
    if not report['complete']:
        parser.error('Original selected IOQ matrix is not qualified')
    output = evidence / 'guard-activation'
    if output.exists() and any(output.iterdir()):
        parser.error('Activation output must be empty')
    output.mkdir(parents=True)
    for name, digest in report['sources'].items():
        if sha(ROOT / name) != digest:
            parser.error('Original IOQ source fingerprint is stale: ' + name)
    sources = [Path(__file__), HARNESS,
               Path(__file__).with_name('yosys_common.py')]
    fingerprints = {str(p): sha(p) for p in sources}
    yosys = shutil.which(os.environ.get('RAPTOR_YOSYS_REAL', 'yosys'))
    if not yosys:
        parser.error('Native Yosys is missing')
    work = []
    for proof in report['proofs']:
        group = proof['model_sha256']
        path = evidence / 'proofs' / group / 'results.json'
        positive = json.loads(path.read_text())
        if not positive['certified'] or sha(path) != proof['report_sha256']:
            parser.error('Original full safety proof is stale or incomplete')
        model = path.parent / 'frontend.json'
        if sha(model) != positive['artifacts']['frontend.json']:
            parser.error('Original full frontend changed')
        work.append((output / group, model, group, args.timeout, args.depth, yosys))
    results = []
    with ProcessPoolExecutor(max_workers=args.jobs, mp_context=get_context('spawn')) as pool:
        for result in pool.map(worker, work):
            results.append(result)
    if fingerprints != {str(p): sha(p) for p in sources}:
        raise RuntimeError('Activation checker or original harness changed')
    for name, digest in report['sources'].items():
        if sha(ROOT / name) != digest:
            raise RuntimeError('Original IOQ source fingerprint changed: ' + name)
    final = dict(complete_guard_activation=all(r['complete_guard_activation'] for r in results),
        whole_rtl_signoff=False, models=len(results),
        guards=sum(len(r['selected_assertion_guards']) for r in results), sources=fingerprints)
    (output / 'results.json').write_text(json.dumps(final, indent=2) + '\n')
    if not final['complete_guard_activation']:
        raise SystemExit('IOQ bank/history guards lack nonempty activation witnesses')
    print(f'IOQ assertion-guard activation models={len(results)}, guards={final["guards"]}')


ENTRY_POINTS = {
    'prove': prove_main,
    'activate': activate_main,
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
