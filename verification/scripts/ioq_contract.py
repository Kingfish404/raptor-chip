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
from formal_scope import preset_xlens
from yosys_common import ROOT, activation_witnesses, run_bounded, run_sby_task, sha, task_status


TOP = 'formal_ioq_owner'

HARNESS = ROOT / 'verification/formal/formal_ioq.sv'

DUT = ROOT / 'rtl/core/backend/lsu/rapt_lsu_ioq.sv'

SCOPE = ('Full production IOQ + actual DPU and capacity adapter; independent dispatch '
         'and response histories prove admission, queue ownership, request hold, A/B '
         'response attribution, integer/FP completion provenance and at-most-once '
         'completion per accepted allocation. ROB lifetime composition, memory contents, '
         'address translation, exception classification and store-data semantics remain open.')


def select_solver(solver, frontend):
    if solver != 'auto':
        return solver
    return 'bitwuzla' if frontend['geometry']['dispatch_width'] >= 8 else 'yices'


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
    prefix = '' if top == TOP else 'base.'
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
    read_bits = len(netnames[prefix + 'dut.operand_read_address']['bits'])
    physical_bits = counts['geometry']['physical_index_bits']
    if read_bits % physical_bits:
        raise ValueError('Native IOQ operand read ports have an invalid width')
    counts['geometry'].update(
        late_operands=prefix + 'dut.g_late_operands.operands.addr_ready' in netnames,
        operand_read_ports=read_bits // physical_bits)
    return counts


def read_command(case, rtl, *, dut=DUT):
    profile = contract_profile(case.get('contract', 'owner'))
    top = profile['top']
    flags = '-DRAPT_RV64 ' if case['xlen'] == 64 else '-URAPT_RV64 '
    if profile['define']:
        flags += '-D' + profile['define'] + ' '
    flags += '-DRAPT_FORMAL_IOQ_LATE ' if case.get('late_operands') else '-URAPT_FORMAL_IOQ_LATE '
    flags += f'-DRAPT_FORMAL_IOQ_READ_PORTS={case.get("operand_read_ports", 1)} '
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
            + ' '.join(map(str, files + [HARNESS])))


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
        geometry = row['frontend']['geometry']
        if (geometry['late_operands'] != bool(case.get('late_operands', False))
                or geometry['operand_read_ports'] != case.get('operand_read_ports', 1)):
            raise ValueError('Native operand implementation differs from selected parameters')
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


def load_primary_replay(model, specification, expected_hash, depth):
    """Accept only concrete primary-input assignments for bounded negative BMC."""
    if (not isinstance(specification, dict)
            or set(specification) != {'model_sha256', 'inputs'}
            or specification['model_sha256'] != expected_hash):
        raise ValueError('Negative replay does not bind the current complete mutant model')
    source = Path(specification['inputs'])
    data = source.read_bytes()
    module = next(iter(model['modules'].values()))
    ports = {name: len(port['bits']) for name, port in module['ports'].items()
             if port['direction'] == 'input'}
    lines, state, assignments = [], -1, 0
    for number, line in enumerate(data.decode().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        frame = re.fullmatch(r'state (0|[1-9][0-9]*)', line)
        if frame:
            selected = int(frame[1])
            if selected != state + 1 or selected >= depth:
                raise ValueError('Replay frames must be consecutive and within the BMC bound')
            state = selected
            lines.append(line)
            continue
        vector = re.fullmatch(r'assume \(= \[(.+)\] #b([01]+)\)', line)
        scalar = re.fullmatch(r'assume (?:\[([^\]]+)\]|\(not \[([^\]]+)\]\))', line)
        if state < 0 or not (vector or scalar):
            raise ValueError(f'Unsupported primary-input replay statement at line {number}')
        name = vector[1] if vector else scalar[1] or scalar[2]
        value = vector[2] if vector else ('1' if scalar[1] else '0')
        if name not in ports or len(value) != ports[name]:
            raise ValueError('Replay must match a primary input and its width: ' + name)
        if ports[name] == 1:
            line = f'assume [{name}]' if value == '1' else f'assume (not [{name}])'
        lines.append(line)
        assignments += 1
    if not assignments:
        raise ValueError('Negative replay contains no primary-input assignments')
    return '\n'.join(lines) + '\n', dict(model_sha256=expected_hash,
        source=str(source), source_sha256=hashlib.sha256(data).hexdigest(),
        frames=state + 1, primary_input_assignments=assignments, internal_state_constraints=0)


def prove(directory, compiled, model_directory, timeout, depth, cover_depth, yosys,
          *, negative=False, solver='auto'):
    top = contract_profile(compiled['case'].get('contract', 'owner'))['top']
    directory.mkdir(parents=True)
    raw = directory / 'frontend.json'
    raw.write_bytes(gzip.decompress((model_directory / 'frontend.json.gz').read_bytes()))
    if sha(raw) != compiled['original_sha256']:
        raise ValueError('Archived full frontend changed')
    model = json.loads(raw.read_text())
    frontend = audit_frontend(model)
    if hashlib.sha256(canonical_model(model).encode()).hexdigest() != (
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
    replay = None
    if negative:
        specification = compiled['case'].get('negative_replay')
        if specification is not None:
            inputs, replay = load_primary_replay(model, specification,
                                                compiled['canonical_sha256'], depth)
            (directory / 'negative-inputs.smtc').write_text(inputs)
            options += 'prove: smtc negative-inputs.smtc\n'
        else:
            # Search a reachable failure at the end of the complete transition prefix.
            # Earlier assertions are neither checked nor assumed in mutation queries.
            options += f'prove: skip {depth - 1}\n'
    else:
        options += f'cover: mode cover\ncover: depth {cover_depth}\n'
    chosen_solver = select_solver(solver, frontend)
    config = tasks + options + f'[engines]\nsmtbmc {chosen_solver}\n[script]\n' + script
    if replay:
        config += '[files]\nnegative-inputs.smtc\n'
    (directory / 'contract.sby').write_text(config)
    child = run_sby_task(directory, timeout, yosys)
    result = dict(case=compiled['case'], full_model_sha256=compiled['canonical_sha256'],
                  frontend=frontend, exit=child.returncode, statuses={}, activation={},
                  certified=False, negative_detected=False, whole_rtl_signoff=False,
                  solver=chosen_solver)
    for task in (('prove',) if negative else ('prove', 'cover')):
        result['statuses'][task] = task_status(directory, task)
    if negative:
        result.update(counterexample_frame=depth - 1, prefix_assertions_assumed=False)
        if replay:
            result.update(primary_input_replay=replay,
                          checked_frames=list(range(depth)), counterexample_frame=None)
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


def compile_worker(arguments):
    return compile_case(*arguments)


def checked_proof(directory, expected_report, expected_model):
    """Check the same safety and witness evidence before reuse or guard activation."""
    report_path = directory / 'results.json'
    if sha(report_path) != expected_report:
        raise ValueError('Cached IOQ proof report changed')
    report = json.loads(report_path.read_text())
    if (not report['certified'] or report['statuses'] != dict(prove='PASS', cover='PASS')
            or report['exit'] != 0 or report['full_model_sha256'] != expected_model):
        raise ValueError('Cached IOQ proof is incomplete or belongs to another full model')
    required = {'frontend.json', 'contract.sby', 'run.log', 'contract_prove/status',
                'contract_cover/status', 'contract_cover/engine_0/logfile.txt'}
    if not required <= report['artifacts'].keys():
        raise ValueError('IOQ proof artifact inventory is incomplete')
    for name, digest in report['artifacts'].items():
        member = (directory / name).resolve()
        if (Path(name).is_absolute() or not member.is_relative_to(directory.resolve())
                or not member.is_file() or sha(member) != digest):
            raise ValueError('Cached IOQ proof artifact changed: ' + name)
    for task in ('prove', 'cover'):
        if task_status(directory, task) != 'PASS':
            raise ValueError('Cached IOQ task is not PASS')
    activation = activation_witnesses(
        (directory / 'contract_cover/engine_0/logfile.txt').read_text(), directory)
    if (set(activation) != set(report['frontend']['cover_names'])
            or activation != report['activation']
            or not set(activation.values()) <= report['artifacts'].keys()):
        raise ValueError('Cached IOQ proof lacks original activation witnesses')
    return report


def reuse_proof(directory, compiled, model_directory, previous, expected_report):
    """Transfer only a fully checked proof of the identical complete native graph."""
    group = compiled['canonical_sha256']
    report = checked_proof(previous, expected_report, group)
    current = gzip.decompress((model_directory / 'frontend.json.gz').read_bytes())
    if hashlib.sha256(current).hexdigest() != compiled['original_sha256']:
        raise ValueError('Current classified IOQ model changed')
    model = json.loads(current)
    canonical = canonical_model(model)
    previous_model = json.loads((previous / 'frontend.json').read_text())
    frontend = audit_frontend(model)
    if (canonical != canonical_model(previous_model)
            or hashlib.sha256(canonical.encode()).hexdigest() != group
            or frontend != audit_frontend(previous_model)
            or any(frontend[key] != report['frontend'][key]
                   for key in ('assertions', 'covers', 'assumptions', 'cover_names'))):
        raise ValueError('Current and cached IOQ state, init or predicates differ')
    shutil.copytree(previous, directory)
    report['frontend'] = frontend
    report['reused_evidence'] = dict(source=str(previous), report_sha256=expected_report,
        current_case=compiled['case'], current_frontend_sha256=compiled['original_sha256'],
        canonical_sha256=group,
        identity='Only source locations removed from both full unoptimized graphs')
    (directory / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


def proof_worker(arguments):
    group, row, output, timeout, depth, cover_depth, yosys, solver, cached = arguments
    directory = output / 'proofs' / group
    model = output / 'models' / row['case']['id']
    if cached:
        previous, expected_report = cached
        evidence = reuse_proof(directory, row, model, previous, expected_report)
    else:
        evidence = prove(directory, row, model, timeout, depth, cover_depth, yosys, solver=solver)
    return dict(model_sha256=group, representative=row['case']['id'],
                certified=evidence['certified'], reused=bool(cached),
                report_sha256=sha(directory / 'results.json'))


def negative_worker(arguments):
    name, mutation, case, output, rtl, timeout, depth, cover_depth, yosys, solver = arguments
    directory = output / 'controls' / name
    directory.mkdir(parents=True)
    old, new = mutation
    text = DUT.read_text()
    if text.count(old) != 1:
        raise ValueError('IOQ mutation anchor changed: ' + name)
    dut = directory / 'mutant.sv'
    dut.write_text(text.replace(old, new))
    compiled = compile_case(directory / 'model', case, rtl, timeout, yosys, dut=dut)
    evidence = prove(directory / 'proof', compiled, directory / 'model', timeout,
                     max(8, depth), cover_depth, yosys, negative=True, solver=solver)
    return dict(name=name, detected=evidence['negative_detected'],
                report_sha256=sha(directory / 'proof/results.json'))


MUTATIONS = {
    'generation': ('generation: dispatch[s].generation,',
                   "generation: dispatch[s].generation ^ GenBits'(1),"),
    'completion-bank': ('completion_head_lane[ioq_payload_lane[ioq_head]]',
                        'completion_head_lane[0]'),
    'destination': ('assign ioq_completion_result.dest = completion_control.destination;',
                    "assign ioq_completion_result.dest = completion_control.destination ^ 1'b1;"),
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
        'assign alloc_vk[s] = wake_val(dispatch[s].pr2, dispatch[s].op2);',
        'assign alloc_vk[s] = wake_val(dispatch[s].pr2, dispatch[s].op1);'),
    'integer-wake': ('ioq_vk[i] <= ioq_fwd2_val[i];',
                     "ioq_vk[i] <= ioq_fwd2_val[i] ^ XLEN'(1);"),
    'fp-allocation': (
        'alloc_fp_value[s] = dispatch[s].fp_value[1] & {64{!(|hit)}};',
        'alloc_fp_value[s] = dispatch[s].fp_value[0] & {64{!(|hit)}};'),
    'fp-local-wake': (
        'assign fp_wake_data[2*p+1] = local_fp_wake[p].fp_result;',
        "assign fp_wake_data[2*p+1] = local_fp_wake[p].fp_result ^ 64'(1);"),
    'amo-add': ('head_amo_wdata = head_store_data + ioq_rdata[ioq_head];',
                'head_amo_wdata = head_store_data - ioq_rdata[ioq_head];'),
    'amo-word-compare': ('assign head_amo_less_unsigned = ioq_word[ioq_head]',
                        "assign head_amo_less_unsigned = 1'b0"),
    'sc-result': ('? (reservation_match ? 0 : 1)', '? (reservation_match ? 1 : 0)'),
    'sc-notification': ('&& (exu_l1d.reservation_blocked || !sc_decision_ready))',
                        '&& (!sc_decision_ready))'),
}


def contract_profile(name):
    """Select a contract without modifying shared runner state."""
    if name == 'owner':
        return dict(top=TOP, scope=SCOPE, mutations=MUTATIONS, define=None)
    if name == 'store':
        return dict(top='formal_ioq_store', scope=STORE_SCOPE, mutations=STORE_MUTATIONS,
                    define='RAPT_FORMAL_IOQ_STORE')
    raise ValueError('Unknown IOQ contract: ' + name)


def prove_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--contract', choices=('owner', 'store'), default='owner')
    parser.add_argument('--late-operands', action='store_true')
    parser.add_argument('--operand-read-ports', type=int, choices=(1, 2), default=1)
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
    parser.add_argument('--negative-replays', type=Path,
                        help='JSON index of model-bound primary-input stimuli for negative BMC')
    parser.add_argument('--reuse-evidence', type=Path,
                        help='Audit and reuse only identical complete native models from this run')
    args = parser.parse_args()
    profile = contract_profile(args.contract)
    mutations = dict(profile['mutations'])
    if args.late_operands and args.contract == 'store':
        mutations['integer-allocation'] = (
            'assign late_alloc_sources[s][1] = int_source_regs[s][1];',
            'assign late_alloc_sources[s][1] = int_source_regs[s][0];')
        mutations['integer-wake'] = (
            'assign late_read_data[p] = operand_read_value[p];',
            "assign late_read_data[p] = operand_read_value[p] ^ XLEN'(1);")
    replays = {}
    if args.negative_replays:
        if args.negative_controls != 'run':
            parser.error('Negative replays require negative controls to run')
        index = args.negative_replays.resolve()
        replays = json.loads(index.read_text())
        if not isinstance(replays, dict) or set(replays) - set(mutations):
            parser.error('Replay index must map selected mutation names to input specifications')
        for specification in replays.values():
            if (not isinstance(specification, dict)
                    or set(specification) != {'model_sha256', 'inputs'}
                    or not isinstance(specification['inputs'], str)):
                parser.error('Replay specifications require model_sha256 and inputs')
            path = (index.parent / specification['inputs']).resolve()
            if Path(specification['inputs']).is_absolute() or not path.is_relative_to(index.parent):
                parser.error('Replay inputs must stay within their index directory')
            specification['inputs'] = str(path)
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
    xlens = {preset: preset_xlens(ROOT / 'rtl/configs' / preset / 'rapt_config.svh')
             for preset in presets}
    if not any(set(args.xlens) & set(values) for values in xlens.values()):
        parser.error('No supported preset/XLEN combination selected')
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('Output must be empty')
    for path in (ROOT, output):
        if any(c.isspace() or c in ';"' for c in str(path)):
            parser.error('Unsupported formal path')
    output.mkdir(parents=True, exist_ok=True)
    yosys = shutil.which(os.environ.get('RAPTOR_YOSYS_REAL', 'yosys'))
    if not yosys:
        parser.error('Native Yosys is missing')
    rtl = [ROOT / 'rtl/rapt_pkg.sv']
    rtl += sorted(p for p in (ROOT / 'rtl').rglob('*.sv') if p not in rtl)
    sources = sorted(set(rtl + list((ROOT / 'rtl').rglob('*.svh'))
        + [HARNESS, Path(__file__), Path(__file__).with_name('yosys_common.py'),
           Path(__file__).with_name('formal_scope.py'),
           ROOT / 'verification/formal/yosys-rvfi-compat.sh']))
    fingerprints = {str(p.relative_to(ROOT)): sha(p) for p in sources}
    result = dict(complete=False, whole_rtl_signoff=False, sources=fingerprints, bindings=[],
        proofs=[], negative_controls=[],
        scope=profile['scope'] + (
            ' PRF reads bind accepted consumer source versions; physical bank and source '
            'lifetime remain separate composition obligations.' if args.late_operands else ''),
        assumptions=['First sampled edge resets'],
        normalization='Original unoptimized JSON, removing only source-location attributes; '
                      'all memory, initialization, logic and clocked formal checks remain.',
        yosys_version=subprocess.check_output([yosys, '-V'], text=True).strip())
    def save():
        (output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    save()
    if not args.controls_only:
        cached = {}
        if args.reuse_evidence:
            previous = args.reuse_evidence.resolve()
            prior = json.loads((previous / 'results.json').read_text())
            if prior['yosys_version'] != result['yosys_version']:
                parser.error('Cached IOQ proofs use a different native Yosys version')
            cached = {row['model_sha256']: (previous / 'proofs' / row['model_sha256'],
                                           row['report_sha256'])
                      for row in prior['proofs'] if row['certified']}
        cases = []
        for index, values in enumerate(itertools.product(presets, args.xlens, args.memory,
                args.response_stages, args.lutram, args.synthesis, args.metadata)):
            p, x, memory, stage, lutram, synthesis, metadata = values
            if x not in xlens[p]:
                continue
            cases.append(dict(id=f'ioq-{index:05d}', preset=p, xlen=x, memory=memory,
                response_stage=stage, lutram=lutram, synthesis=bool(synthesis),
                metadata=metadata, contract=args.contract, late_operands=args.late_operands,
                operand_read_ports=args.operand_read_ports))
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
        work = [(group, rows[0], output, args.timeout, args.depth, args.cover_depth, yosys,
                 args.solver, cached.get(group))
                for group, rows in groups.items()]
        with ProcessPoolExecutor(max_workers=args.jobs, mp_context=get_context('spawn')) as pool:
            for row in pool.map(proof_worker, work):
                result['proofs'].append(row)
                save()
    if args.negative_controls == 'run':
        work = []
        for name, mutation in mutations.items():
            case = dict(id=name, preset='formal', xlen=64, memory='dff', lutram=0,
                        synthesis=True, response_stage=0, metadata='functional',
                        contract=args.contract, late_operands=args.late_operands,
                        operand_read_ports=args.operand_read_ports)
            if name in replays:
                case['negative_replay'] = replays[name]
            work.append((name, mutation, case, output, rtl, args.timeout, args.depth,
                         args.cover_depth, yosys, args.solver))
        with ProcessPoolExecutor(max_workers=args.jobs, mp_context=get_context('spawn')) as pool:
            for row in pool.map(negative_worker, work):
                result['negative_controls'].append(row)
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
    top = next(iter(model['modules']))
    module = model['modules'][top]
    cells = module['cells']
    if any(name.startswith(PREFIX) for name in cells):
        raise ValueError('Observer namespace already exists')
    geometry = information['geometry']
    prefix = '' if top == TOP else 'base.'
    expected = {f'{prefix}g_resident[{e}].g_bank[{s}].resident_metadata'
                for e in range(geometry['ioq_entries'])
                for s in range(geometry['dispatch_width'])}
    expected |= {f'{prefix}g_resident[{e}].{name}' for e in range(geometry['ioq_entries'])
                 for name in HISTORY}
    if not expected <= set(cells):
        raise ValueError('Missing original bank/history assertion guard')
    prototype = next(c for c in cells.values()
                     if c['type'] == '$check' and c['parameters']['FLAVOR'] == 'cover')
    names = {}
    assertions = {name for name, cell in cells.items()
                  if cell['type'] == '$check' and cell['parameters']['FLAVOR'] == 'assert'}
    for name in sorted(assertions):
        original = cells[name]
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
        names[top + ': ' + PREFIX + name] = name
    audit_extension(model, expected_hash)
    return names


def audit_extension(model, expected_hash):
    """No old cell, port, memory, init, assertion or assumption may change."""
    module = next(iter(model['modules'].values()))
    added = {n: c for n, c in module['cells'].items() if n.startswith(PREFIX)}
    if not added:
        raise ValueError('Missing read-only activation observers')
    expected = {PREFIX + name for name, cell in module['cells'].items()
                if cell['type'] == '$check' and cell['parameters']['FLAVOR'] == 'assert'}
    if set(added) != expected:
        raise ValueError('Observer inventory differs from the complete assertion inventory')
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


def activate(directory, model_path, expected_hash, timeout, depth, yosys, solver='auto'):
    directory.mkdir(parents=True)
    fingerprint = sha(model_path)
    model = json.loads(model_path.read_text())
    selected = augment(model, expected_hash)
    frontend = audit_frontend(model)
    top = next(iter(model['modules']))
    solver = select_solver(solver, frontend)
    augmented = directory / 'augmented.json'
    augmented.write_text(json.dumps(model, separators=(',', ':')) + '\n')
    script = (f'read_json {augmented}\nhierarchy -check -top {top}\n'
        'setattr -set keep 1 t:$check\n' + f'prep -top {top} -flatten\n'
        'async2sync\nchformal -lower\nmemory_map\nopt\ncheck -assert\n'
        'select -assert-count 1 t:$assume\nselect -assert-any t:$cover\n')
    config = ('[tasks]\ncover\n[options]\nmode cover\n'
        + f'depth {depth}\ntimeout {timeout}\n[engines]\nsmtbmc {solver}\n[script]\n' + script)
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
    child = run_sby_task(directory, timeout, yosys, smtbmc=wrapper)
    result = dict(complete_guard_activation=False, whole_rtl_signoff=False,
        original_model_sha256=fingerprint, full_class_sha256=expected_hash,
        source_model=str(model_path), selected_assertion_guards=selected,
        witness_formats=['vcd'],
        solver=solver,
        status=task_status(directory, 'cover'),
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
    parser.add_argument('--solver', choices=('auto', 'yices', 'bitwuzla'), default='auto')
    args = parser.parse_args()
    if min(args.jobs, args.timeout, args.depth) < 1:
        parser.error('Jobs, timeout and depth must be positive')
    evidence = args.evidence.resolve()
    report = json.loads((evidence / 'results.json').read_text())
    if not report['complete'] or not report['proofs']:
        parser.error('Original selected IOQ matrix is not qualified')
    output = evidence / 'guard-activation'
    if output.exists() and any(output.iterdir()):
        parser.error('Activation output must be empty')
    output.mkdir(parents=True, exist_ok=True)
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
        checked_proof(path.parent, proof['report_sha256'], group)
        model = path.parent / 'frontend.json'
        work.append((output / group, model, group, args.timeout, args.depth, yosys, args.solver))
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
        raise SystemExit('IOQ assertion guards lack nonempty activation witnesses')
    print(f'IOQ assertion-guard activation models={len(results)}, guards={final["guards"]}')


ENTRY_POINTS = {
    'prove': prove_main,
    'activate': activate_main,
}


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ''
    if command not in ENTRY_POINTS:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('command', choices=ENTRY_POINTS)
        parser.parse_args()
    del sys.argv[1]
    return ENTRY_POINTS[command]()


if __name__ == '__main__':
    raise SystemExit(main())
