"""Run small formal contracts with native models and scoped proof evidence."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from formal_scope import (
    audit_native_binding, binding_key, canonical_rtlil, inventory, member, native_sat_command,
    native_smtbmc_config,
)
from yosys_common import (
    activation_witnesses, copy_native_artifact, run_bounded, run_sby, run_yosys_check, sha,
)


CONTRACTS = {
    'ioq-overlap': dict(
        description='Prove shared IOQ short-range overlap against circular subtraction.',
        top='formal_ioq_overlap', source='rtl/backend/lsu/rapt_ioq_overlap.sv', option='rtl',
        option_help='Optional isolated overlap module under test',
        scope='Combinational pair matrix; all RV32/RV64 addresses, spans 0..3, full/page wrap',
        label='IOQ circular overlap equivalence'),
    'pma-capabilities': dict(
        description='Prove the platform storage-region capability contract for all addresses.',
        top='formal_pma_capabilities', source='rtl/rapt_pkg.sv', option='package',
        option_help='Optional isolated package under test',
        scope='All-address storage PMA capability logic; no bus/coherence/progress claim',
        label='storage PMA capability proof'),
    'pma-span': dict(
        description='Prove scalar PMA span checks equivalent to bytewise address decoding.',
        top='formal_pma_span', source='rtl/rapt_pkg.sv', option='package',
        option_help='Optional isolated package under test',
        scope='All addresses, transfer sizes and read/write modes; exact first-fault offset',
        label='bytewise PMA span equivalence'),
    'ifetch-word-atomic': dict(
        description='Prove aligned instruction-word assembly integrity under arbitrary backpressure.',
        top='formal_ifetch_word_atomic', source='rtl/memory/icache/rapt_ifetch_word.sv', option='rtl',
        option_help='Optional isolated instruction-word module under test',
        scope='Aligned word assembly safety; reset state and explicit responder protocol; '
              'no bus/cache/fairness claim',
        label='aligned instruction-word integrity proof',
        proof='sat -verify -tempinduct -seq 8 -maxsteps 32 -set-init-zero -set-def-inputs '
              '-prove mismatch 0 -show-inputs -show-outputs',
        success='Induction step proven: SUCCESS!', timeout=180),
}


def add_options(parser, option=None, option_help=None):
    parser.add_argument('--source-root', type=Path,
                        default=Path(__file__).resolve().parents[2])
    if option:
        parser.add_argument('--' + option, type=Path, help=option_help)
    parser.add_argument('--output', type=Path, required=True)


def run_contract(args, *, description, top, source, option, option_help, scope, label,
                 proof='sat -verify -prove mismatch 0 -set-def-inputs -show-inputs -show-outputs',
                 success='SAT proof finished - no model found: SUCCESS!', timeout=120):
    root = args.source_root.resolve()
    dut = (getattr(args, option) or root / source).resolve()
    harness = root / 'verification/formal' / (top + '.sv')
    files = [dut, harness]
    files += sorted((root / 'rtl/include').rglob('*.svh'))
    files += sorted((root / 'rtl/configs/default').rglob('*.svh'))
    for path in files:
        if any(char.isspace() or char in ';"' for char in str(path)):
            raise ValueError(f'Unsupported Yosys source path: {path}')
    def hashes():
        return {str(path): sha(path) for path in files}
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    result = {'complete': False, 'source_sha256': hashes(), 'cases': [],
              'scope': scope}
    report = output / 'results.json'
    report.write_text(json.dumps(result, indent=2) + '\n')
    for xlen in (32, 64):
        commands = [
            f'read_slang --single-unit -DSYNTHESIS {"-DRAPT_RV64" if xlen == 64 else ""} '
            f'-I{root}/rtl/include -I{root}/rtl/configs/default '
            f'--top {top} {dut} {harness}',
            'select -assert-none t:$check t:$assert t:$assume t:$cover',
            f'prep -top {top} -flatten', 'opt',
            proof]
        script = output / f'rv{xlen}.ys'
        script.write_text(';\n'.join(commands) + '\n')
        command = [os.environ.get('RAPTOR_YOSYS_REAL', 'yosys'),
                   '-Q', '-T', '-m', 'slang', '-s', str(script)]
        log = output / f'rv{xlen}.log'
        with log.open('w') as stream:
            run = run_bounded(command, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
        text = log.read_text()
        proved = run.returncode == 0 and success in text and 'ERROR:' not in text
        result['cases'].append({'xlen': xlen, 'command': command,
                                'exit': run.returncode, 'proved': proved})
        report.write_text(json.dumps(result, indent=2) + '\n')
        print(f'{"PASS" if proved else "FAIL"}: RV{xlen} {label}', flush=True)
        if not proved:
            return 1
    if hashes() != result['source_sha256']:
        raise RuntimeError('Sources changed during proof')
    result['complete'] = True
    report.write_text(json.dumps(result, indent=2) + '\n')
    return 0


def native_contract(name, *, dividers=None):
    if name == 'completion-guard':
        shapes = [(1, 1, 1, 1), (7, 3, 6, 5), (8, 4, 7, 5), (32, 4, 6, 5),
                  (32, 4, 7, 5), (64, 4, 7, 5), (96, 4, 7, 5), (127, 4, 8, 6),
                  (128, 4, 8, 5)]
        variants = [dict(Entries=entries, GenerationBits=generation, PhysBits=physical,
                         ArchBits=architectural, EnforcePayload=enforce)
                    for entries, generation, physical, architectural in shapes
                    for enforce in (0, 1)]
        variants += [dict(Entries=32, IndexBits=6, GenerationBits=4, PhysBits=7,
                          ArchBits=5, EnforcePayload=enforce) for enforce in (0, 1)]
        return dict(name=name, label='completion ownership guard',
            top='formal_completion_guard', timeout=120, method='smtbmc-induction',
            xlen_parameter=False, depth=6, solver='yices',
            source='rtl/backend/rapt_completion_guard.sv',
            harness='verification/formal/formal_completion_guard.sv',
            unit='rtl/backend/rapt_completion_guard.sv:rapt_completion_guard',
            variants=[(parameters, dict(RAPT_FORMAL_NATIVE=True)) for parameters in variants],
            assumptions=[],
            property_map={
                'functional': 'All three outputs equal an independent one-hot owner-table walk',
                'owner-generation': 'Identity requires a live slot and exact generation match',
                'executing-only': 'Acceptance requires the authoritative executing bit',
                'payload-policy': 'Both destination fields are compared; EnforcePayload selects '
                                  'whether mismatches reject acceptance',
                'invalid-index': 'Unused and over-wide index encodings keep all outputs inactive',
                'candidate-valid': 'Inactive producers cannot publish any guard output',
            },
            rationale='Unrestricted combinational inputs, no reset, initialization or producer '
                      'assumptions. Both payload policies, singleton/non-power-of-two/power-of-two '
                      'tables, over-wide indexes and explicit identity widths are reviewed for '
                      'every legal preset/XLEN/storage profile and synthesis context. Every '
                      'cover has a waveform. Other parameter overrides and authoritative ROB '
                      'allocation/generation lifetime remain separate review/composition work.',
            scope='Complete candidate validity, owner identity, execution admission and immutable '
                  'payload policy for the listed table/index/identity widths. No claim that '
                  'producer or ROB allocation histories themselves are correct.',
            mutations=[
                ('generation', 'owner_generation[candidate_index] == candidate_generation',
                 "1'b1", {}, {}, None),
                ('executing', ' && executing[candidate_index]', '', {}, {}, None),
                ('payload', '(!EnforcePayload || payload_match)', "1'b1",
                 dict(EnforcePayload=1), {}, None),
                ('live', 'live[candidate_index]', "1'b1", {}, {}, None),
                ('valid', "candidate_valid && int'(candidate_index) < Entries",
                 "int'(candidate_index) < Entries", {}, {}, None),
            ])
    if name == 'clint':
        dividers = tuple(dividers) if dividers is not None else (1, 3, 5, 10, 20, 25, 50, 100)
        if (not dividers or any(value < 1 for value in dividers)
                or len(set(dividers)) != len(dividers)):
            raise ValueError('CLINT dividers must be positive and distinct')
        divider_list = ', '.join(map(str, dividers))
        return dict(
            name=name, label='CLINT', top='formal_clint', timeout=900,
            source='rtl/perip/rapt_clint.sv', harness='verification/formal/formal_clint.sv',
            unit='rtl/perip/rapt_clint.sv:rapt_clint',
            variants=[(dict(MTIME_DIV=divider),
                       dict(FORMAL=True, RAPT_FORMAL_NATIVE=True))
                      for divider in dividers],
            property_map=dict(
                functional='Independent byte-address register model, divider phase and ticks, '
                           'and interrupt levels',
                ownership='All byte strobes, unaligned register offsets and unmapped reads; '
                          'time writes preserve untouched pre-edge bytes when a tick coincides',
                reset='Time, compare, software interrupt and divider reset together; '
                      'reset wins simultaneous writes'),
            scope='Complete production CLINT and production bus interface. Arbitrary addresses, '
                  f'data and strobes; explicit divider bindings {divider_list}.',
            rationale='The complete register, read-data, timer and interrupt relation '
                      'is checked against independent byte-address histories. Both XLENs, all '
                      'presets/storage/synthesis contexts are '
                      f'elaborated. Reviewed divider values are {divider_list}; other explicit '
                      'divider overrides require additional bindings. The default set includes '
                      'bypass, non-power-of-two counters, native FPGA clocks and documented '
                      'clock/timebase examples. The first sampled edge resets; later reset '
                      'and writes remain arbitrary. Interconnect routing and hart interrupt '
                      'delivery are composition obligations.',
            mutations=[
                ('byte-offset',
                 "assign register_wdata = 64'(clint_bus.wdata) << {clint_bus.awaddr[2:0],3'b000};",
                 "assign register_wdata = 64'(clint_bus.wdata);", {}, {}, 6),
                ('timer-boundary', 'assign clint_bus.timer_int = (mtime >= mtimecmp);',
                 'assign clint_bus.timer_int = (mtime > mtimecmp);', {}, {}, 5),
                ('software-strobe', ' && clint_bus.wstrb[0])', ')', {}, {}, 3),
            ])
    property_map = {
        'functional': 'The complete correct conjunction and every active producer assertion',
        'ordering': 'Independent accepted-beat shift history, including the hidden second beat',
        'ownership': 'All output ID/data/response/last bits belong to their accepted input beat',
        'reset': 'Buffered count resets on the sampled edge; bypass remains transparent',
        'channel-passthrough': 'requests_match on all AR/AW/W/B fields and reverse flow control',
        'elastic-order': 'first/second history and resident_order without state cuts',
        'capacity': 'Registered count <= 2 and input ready iff space exists outside reset',
        'registered-latency': 'Output valid iff the registered accepted-beat count is nonzero',
        'stall-preservation': 'held_stable, or transparent preservation of a stable source',
        'bypass': 'Unconditional R payload, valid and reverse-ready equality when disabled',
        'conditional-drain': 'Each ready sink pop removes exactly one queued beat without reset',
    }
    if name != 'axi-r-buffer':
        raise ValueError('Unknown native contract: ' + name)
    return dict(name=name, label='AXI R buffer', top='formal_axi_r_buffer', timeout=120,
        source='rtl/uncore/rapt_axi_r_buffer.sv', harness='verification/formal/formal_uncore.sv',
        unit='rtl/uncore/rapt_axi_r_buffer.sv:rapt_axi_r_buffer', property_map=property_map,
        variants=[(dict(ID_W=4, Enable=enable), {}) for enable in (0, 1)],
        rationale='Production rapt_l2_subsystem uses the default four-bit AXI IDs. '
                  'Review covers both Enable branches and synthesis contexts for all current '
                  'preset/XLEN/storage profiles. Enabled stability needs no source assumption; '
                  'bypass preserves the source protocol. Only the first sampled edge resets. '
                  'AR/R transaction allocation, cache data correctness and memory atomicity '
                  'belong to their owning modules and remain separate obligations.',
        scope='Complete AXI R buffer transfer relation and request/B passthrough; '
              'registered occupancy, ordered full payloads, capacity, latency, '
              'stall preservation, reset discard and transparent bypass. '
              'No memory correctness, source AXI compliance or cache atomicity claim.',
        mutations=[
            ('response-data', 'data: downstream.rdata,', "data: downstream.rdata ^ XLEN'(1),",
             dict(Enable=1), {}, 10),
            ('capacity', "count != 2'd2", "1'b1", dict(Enable=1), {}, 5),
            ('write-mask', 'downstream.wstrb = upstream.wstrb;',
             'downstream.wstrb = ~upstream.wstrb;', dict(Enable=1), {}, 2),
            ('bypass-data', 'upstream.rdata = downstream.rdata;',
             "upstream.rdata = downstream.rdata ^ XLEN'(1);", dict(Enable=0), {}, 4),
        ])


def native_cases(contract, profiles):
    cases = []
    for profile in profiles:
        preset, isa, memory = profile.split('/')
        xlen = int(isa.removeprefix('rv'))
        for synthesis, (parameters, defines) in itertools.product(
                (False, True), contract['variants']):
            parameters = dict(parameters)
            if contract.get('xlen_parameter', True):
                parameters = dict(XLEN=xlen, **parameters)
            cases.append(dict(id=f'{contract["name"]}-{len(cases):04d}', preset=preset,
                xlen=xlen, memory=memory, parameters=parameters,
                defines=dict(RAPT_RV64=xlen == 64, RAPT_USE_SRAM_MACRO=memory == 'sram',
                             SYNTHESIS=synthesis, **defines)))
    return cases


def native_cover_command(base, contract, case, event, witness):
    depth, stimulus = 8, ''
    if contract['name'] == 'clint' and event in (0, 6):
        divider = case['parameters']['MTIME_DIV']
        depth = max(depth, divider + 5)
        # Reachability may choose a concrete primary-input schedule. Safety
        # remains unrestricted after its initial reset; no DUT state is forced.
        stimulus = '-set reset 0 -set wvalid 0 '
        if event == 6:
            stimulus += f'-set-at {divider + 1} wvalid 1 '
    return (base + f'sat -seq {depth} -set-def-inputs {stimulus}-set-at 1 reset 1 '
            + f'-set-at {depth} activated[{event}] 1 -show-inputs -show-outputs '
            + f'-dump_vcd {witness}')


def native_events(contract, case):
    if contract['name'] == 'clint':
        return range(10)
    return range(12 if case['parameters']['Enable'] else 6)


def reuse_native_proof(directory, binding, *, output, previous, contract, expected_report):
    """Reuse complete solver evidence only after binding the full current frontend graph."""
    cached = previous / 'proofs' / binding['model_sha256']
    data = (cached / 'results.json').read_bytes()
    if hashlib.sha256(data).hexdigest() != expected_report:
        raise ValueError('Cached native proof report changed')
    report = json.loads(data)
    if not report['certified'] or report['model_sha256'] != binding['model_sha256']:
        raise ValueError('Cached native proof is incomplete or belongs to another model')
    directory.mkdir(parents=True)
    artifacts = {name: copy_native_artifact(member(cached, name), directory, name, digest)
                 for name, digest in report['artifacts'].items()}
    for name in ('frontend.il', 'read.ys'):
        source = output / binding['directory'] / name
        digest = binding['frontend_sha256' if name == 'frontend.il' else 'read_sha256']
        target = 'current-binding/' + name
        artifacts[target] = copy_native_artifact(source, directory, target, digest)
    case = binding['case']
    origin = report.get('proof_origin', str(cached))
    proof = report['proof']
    log = member(directory, proof['log']).read_text()
    if proof['exit'] != 0 or 'Induction step proven: SUCCESS!' not in log or 'ERROR:' in log:
        raise ValueError('Cached native induction did not finish successfully')
    audit_native_binding(dict(
        method='induction', log=proof['log'], artifacts=artifacts,
        parameters=dict(case['parameters'], defines=case['defines']),
        profile=f'{case["preset"]}/rv{case["xlen"]}/{case["memory"]}',
        model_binding=dict(top=contract['top'], canonical_sha256=binding['model_sha256'],
            proved_model='frontend.il', bound_model='current-binding/frontend.il',
            read_script='current-binding/read.ys', proof_script=proof['script'],
            proof_root=origin)), directory)
    expected = {f'activated[{event}]' for event in native_events(contract, case)}
    if (len(report['activation']) != len(expected)
            or {row['property'] for row in report['activation']} != expected):
        raise ValueError('Cached native activation coverage is incomplete')
    for row in report['activation']:
        if any(row[name] not in artifacts for name in ('script', 'log', 'witness')):
            raise ValueError('Cached activation artifacts are not fingerprinted')
        event = int(row['property'][10:-1])
        witness = member(directory, row['witness'])
        command = native_cover_command(
            native_sat_command(contract['top'], Path(origin) / 'frontend.il'),
            contract, case, event, Path(origin) / row['witness'])
        text = member(directory, row['log']).read_text()
        executed = re.findall(r"^-- Running command `(.*)' --$", text, re.M)
        imported = re.findall(r"^Input filename: (.*)$", text, re.M)
        if (row['exit'] != 0 or member(directory, row['script']).read_text().strip() != command
                or executed != [command] or imported != [str(Path(origin) / 'frontend.il')]
                or 'SAT solving finished - model found:' not in text or 'ERROR:' in text
                or not witness.stat().st_size):
            raise ValueError('Cached native activation query or witness is invalid')
    report.update(proof_origin=origin, reused_from=str(cached), artifacts=artifacts)
    return report


def write_native_receipts(output, result, scope, contract):
    """Publish current per-binding receipts without qualifying unrelated RTL units."""
    unit_id = contract['unit']
    unit = next(u for u in scope['units'] if u['id'] == unit_id)
    property_map = contract['property_map']
    if not set(unit['obligations']) <= set(property_map):
        raise ValueError('Native property mapping removes required obligations')
    parameters = {profile: [] for profile in scope['profiles']}
    for case in native_cases(contract, scope['profiles']):
        profile = f'{case["preset"]}/rv{case["xlen"]}/{case["memory"]}'
        parameters[profile].append(dict(case['parameters'], defines=case['defines']))
    review = dict(sources=scope['sources'], units={unit_id: dict(
        rationale=contract['rationale'],
        obligations=sorted(property_map), profiles=scope['profiles'],
        parameter_bindings=parameters, property_map=property_map)})
    (output / 'contract-review.json').write_text(json.dumps(review, indent=2) + '\n')
    reports = {}
    for proof in result['proofs']:
        directory = output / 'proofs' / proof['model_sha256']
        report_path = directory / 'results.json'
        report = json.loads(report_path.read_text())
        if sha(report_path) != proof['report_sha256'] or not report['certified']:
            raise ValueError('Missing or changed native proof report')
        reports[proof['model_sha256']] = report
    receipts = []
    for binding in result['bindings']:
        case = binding['case']
        directory = output / 'proofs' / binding['model_sha256']
        report = reports[binding['model_sha256']]
        artifacts = dict(report['artifacts'])
        for name in ('frontend.il', 'read.ys'):
            origin = output / binding['directory'] / name
            expected = binding['frontend_sha256' if name == 'frontend.il' else 'read_sha256']
            target = f'bindings/{case["id"]}/{name}'
            artifacts[target] = copy_native_artifact(origin, directory, target, expected)
        params = dict(case['parameters'], defines=case['defines'])
        profile = f'{case["preset"]}/rv{case["xlen"]}/{case["memory"]}'
        if binding_key(params) not in {binding_key(p) for p in parameters[profile]}:
            raise ValueError('Native parameter binding was not reviewed')
        for obligation in property_map:
            receipt = dict(status='PASS', unit=unit_id, obligation=obligation, profile=profile,
                           method=contract.get('method', 'induction'), parameters=params,
                           assumptions=list(result['assumptions']), inputs=result['sources'],
                           harness=contract['harness'],
                           log=report['proof']['log'], artifacts=artifacts,
                           property_activation=[dict(property=row['property'], log=row['log'],
                                                     witness=row['witness'])
                                                for row in report['activation']],
                           model_binding=dict(top=contract['top'],
                               canonical_sha256=binding['model_sha256'],
                               proved_model='frontend.il',
                               bound_model=f'bindings/{case["id"]}/frontend.il',
                               read_script=f'bindings/{case["id"]}/read.ys',
                               proof_script=report['proof']['script'],
                               proof_root=report.get('proof_origin', str(directory))))
            if receipt['method'] == 'smtbmc-induction':
                receipt['model_binding'].update(depth=contract['depth'],
                    timeout=result['timeout'], solver=contract['solver'])
            path = directory / f'receipt-{case["id"]}-{obligation}.json'
            path.write_text(json.dumps(receipt, indent=2) + '\n')
            receipts.append(str(path.relative_to(output)))
    (output / 'receipts.json').write_text(json.dumps(receipts, indent=2) + '\n')
    return len(receipts)


def qualify_native_contract(args):
    """Qualify complete production models with native induction and activation witnesses."""
    contract = native_contract(args.contract, dividers=getattr(args, 'dividers', None))
    root, output = args.source_root.resolve(), args.output.resolve()
    if min(args.jobs, args.timeout) < 1:
        raise ValueError('Jobs and timeout must be positive')
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise ValueError('Output must be an empty directory')
    presets = args.presets or sorted(p.parent.name for p in
                                    (root / 'rtl/configs').glob('*/rapt_config.svh'))
    if not presets or len(set(presets)) != len(presets):
        raise ValueError('Presets must be nonempty and distinct')
    for preset in presets:
        if not re.fullmatch(r'[\w-]+', preset) or not (
            root / 'rtl/configs' / preset / 'rapt_config.svh').is_file():
            raise ValueError('Unknown or invalid preset: ' + preset)
    for path in (root, output):
        if any(c.isspace() or c in ';"' for c in str(path)):
            raise ValueError('Unsupported Yosys path: ' + str(path))
    yosys = shutil.which(os.environ.get('RAPTOR_YOSYS_REAL', 'yosys'))
    if not yosys:
        raise ValueError('Native Yosys is missing')
    output.mkdir(parents=True, exist_ok=True)
    dut, harness = root / contract['source'], root / contract['harness']
    top = contract['top']
    scope = inventory(root)
    inputs = dict(scope['sources'])
    for path in (harness, Path(__file__), Path(__file__).with_name('yosys_common.py'),
                 Path(__file__).with_name('formal_scope.py')):
        inputs[str(path.relative_to(root))] = sha(path)
    result = dict(complete=False, whole_rtl_signoff=False, sources=inputs,
                  bindings=[], proofs=[], negative_controls=[],
                  assumptions=contract.get('assumptions', [
                      'First sampled edge resets; all other safety inputs remain free']),
                  coverage_stimuli=('All primary inputs remain free.' if contract.get('method')
                                   == 'smtbmc-induction' else
                                   'CLINT tick witnesses hold reset and writes inactive except '
                                   'for the requested tick/write collision. Other cover events '
                                   'use free primary inputs. No internal state is forced.'),
                  scope=contract['scope'],
                  timeout=args.timeout,
                  yosys=subprocess.check_output([yosys, '-V'], text=True).strip())
    previous, cached = None, {}
    if args.reuse_evidence:
        if contract.get('method') == 'smtbmc-induction':
            raise ValueError('This SMTBMC contract requires fresh solver evidence')
        previous = args.reuse_evidence.resolve()
        data = (previous / 'results.json').read_bytes()
        prior = json.loads(data)
        if not prior['complete'] or prior['yosys'] != result['yosys']:
            raise ValueError('Reuse requires a complete native contract and the same Yosys build')
        cached = {row['model_sha256']: row['report_sha256'] for row in prior['proofs']}
        if len(cached) != len(prior['proofs']):
            raise ValueError('Duplicate cached native proof class')
        result['reuse'] = dict(directory=str(previous),
                               matrix_sha256=hashlib.sha256(data).hexdigest())
    def save():
        (output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    def compile_model(directory, case, source=dut):
        directory.mkdir(parents=True)
        flags = ' '.join(('-D' if value else '-U') + name
                         for name, value in case['defines'].items())
        parameters = ' '.join(f'-G{name}={value}' for name, value in case['parameters'].items())
        read = (f'read_slang --threads 1 --single-unit --allow-toplevel-iface-ports {flags} '
                f'-I{root}/rtl/configs/{case["preset"]} -I{root}/rtl/include '
                f'-I{root}/rtl/include/npc -I{root}/rtl/include/dpic_mock '
                f'--top {top} {parameters} '
                f'{root}/rtl/rapt_pkg.sv {source} {harness}')
        raw = directory / 'frontend.il'
        script = directory / 'read.ys'
        prepare = ''
        if contract.get('method') == 'smtbmc-induction':
            prepare = f'prep -top {top} -flatten\nasync2sync\nchformal -lower\ncheck -assert\n'
        script.write_text(read + f'\nhierarchy -check -top {top}\n' + prepare
                          + f'write_rtlil {raw}\n')
        with (directory / 'compile.log').open('w') as stream:
            child = run_bounded([yosys, '-Q', '-T', '-m', 'slang', '-s', str(script)],
                                 stdout=stream, stderr=subprocess.STDOUT, timeout=args.timeout)
        child.check_returncode()
        text = raw.read_text()
        if re.search(r'cell \$(?:anyseq|anyconst|initstate|meminit)', text) or (
            'attribute \\blackbox 1' in text):
            raise ValueError('Unexpected abstraction or memory initialization')
        model_hash = hashlib.sha256(canonical_rtlil(text).encode()).hexdigest()
        return dict(case=case, model_sha256=model_hash, frontend_sha256=sha(raw),
                    read_sha256=sha(script), directory=str(directory.relative_to(output)))
    def check_model(directory, binding, *, negative=False, event=None):
        directory.mkdir(parents=True)
        original = output / binding['directory'] / 'frontend.il'
        model = directory / 'frontend.il'
        copy_native_artifact(original, directory, model.name, binding['frontend_sha256'])
        if contract.get('method') == 'smtbmc-induction':
            config = native_smtbmc_config(top, model, depth=contract['depth'],
                timeout=args.timeout, solver=contract['solver'], negative=negative)
            (directory / 'contract.sby').write_text(config)
            check, _ = run_sby(directory, args.timeout, yosys=yosys, negative=negative)
            if not check['passed']:
                raise RuntimeError('Incomplete native SMTBMC contract: ' + str(directory))
            if negative:
                return dict(detected=True, **check)
            log = 'contract_cover/engine_0/logfile.txt'
            activation = activation_witnesses((directory / log).read_text(), directory)
            smt = (directory / 'contract_cover/model/design_smt2.smt2').read_text()
            expected = {top + ': ' + name for name in re.findall(
                r'^; yosys-smt2-cover \d+ (.+)$', smt, re.M)}
            if not expected or set(activation) != expected:
                raise ValueError('Native SMTBMC contract is missing a cover waveform')
            return dict(certified=True, proof=dict(script='contract.sby', log='run.log', exit=0),
                activation=[dict(property=name, log=log, witness=witness)
                            for name, witness in activation.items()])
        base = native_sat_command(top, model)
        if negative:
            witness = directory / 'counterexample.vcd'
            row = run_yosys_check(base + 'sat -seq 8 -set-def-inputs -set-at 1 reset 1 '
                                  f'-set-at 8 activated[{event}] 1 '
                                  f'-prove correct 1 -show-outputs -dump_vcd {witness}',
                                  directory, 'negative', args.timeout,
                                  'SAT proof finished - model found: FAIL!', witness)
            return dict(detected=True, **row)
        proof = run_yosys_check(native_sat_command(top, model, proof=True),
                               directory, 'proof', args.timeout,
                               'Induction step proven: SUCCESS!')
        case = binding['case']
        covers = []
        for event in native_events(contract, case):
            witness = directory / f'event{event}.vcd'
            row = run_yosys_check(native_cover_command(base, contract, case, event, witness),
                                  directory, f'event{event}', args.timeout,
                                  'SAT solving finished - model found:', witness)
            covers.append(dict(property=f'activated[{event}]', **row))
        return dict(certified=True, proof=proof, activation=covers)
    save()
    profiles = [profile for profile in scope['profiles'] if profile.split('/')[0] in presets]
    cases = native_cases(contract, profiles)
    def compile_case(case):
        return compile_model(output / 'models' / case['id'], case)
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for row in pool.map(compile_case, cases):
            result['bindings'].append(row)
            save()
    groups = {}
    for row in result['bindings']:
        groups.setdefault(row['model_sha256'], []).append(row)
    result['groups'] = {key: [r['case']['id'] for r in rows] for key, rows in groups.items()}
    save()
    def prove_group(item):
        key, rows = item
        directory = output / 'proofs' / key
        if key in cached:
            row = reuse_native_proof(directory, rows[0], output=output, previous=previous,
                                     contract=contract, expected_report=cached[key])
        else:
            row = check_model(directory, rows[0])
        row.update(model_sha256=key, representative=rows[0]['case']['id'],
                   artifacts={str(p.relative_to(directory)): sha(p)
                              for p in directory.rglob('*') if p.is_file()})
        (directory / 'results.json').write_text(json.dumps(row, indent=2) + '\n')
        print(f'PASS: {contract["label"]} model {key[:12]}', flush=True)
        return dict(model_sha256=key, certified=True, reused='reused_from' in row,
                    report_sha256=sha(directory / 'results.json'))
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for row in pool.map(prove_group, groups.items()):
            result['proofs'].append(row)
            save()
    for name, old, new, parameters, defines, event in contract['mutations']:
        directory = output / 'controls' / name
        directory.mkdir(parents=True)
        source = directory / 'mutant.sv'
        text = dut.read_text()
        if text.count(old) != 1:
            raise ValueError('Missing unique native mutation point: ' + name)
        source.write_text(text.replace(old, new))
        case = dict(cases[0], parameters=dict(cases[0]['parameters'], **parameters),
                    defines=dict(cases[0]['defines'], **defines))
        binding = compile_model(directory / 'model', case, source)
        row = check_model(directory / 'proof', binding, negative=True, event=event)
        result['negative_controls'].append(dict(name=name,
            directory=str(directory.relative_to(output)), **row))
        save()
    if inputs != {name: sha(root / name) for name in inputs}:
        raise RuntimeError('Native proof input epoch changed')
    if previous and sha(previous / 'results.json') != result['reuse']['matrix_sha256']:
        raise RuntimeError('Cached native matrix changed during qualification')
    qualified = (len(result['bindings']) == len(cases)
                 and len(result['proofs']) == len(groups)
                 and all(p['certified'] for p in result['proofs'])
                 and len(result['negative_controls']) == len(contract['mutations'])
                 and all(p['detected'] for p in result['negative_controls']))
    if not qualified:
        raise SystemExit('Native contract qualification remains incomplete')
    result['receipts'] = write_native_receipts(output, result, scope, contract)
    if inputs != {name: sha(root / name) for name in inputs}:
        raise RuntimeError('Native proof input epoch changed during receipt generation')
    result['complete'] = True
    save()
    print(f'{contract["label"]} qualified: {len(cases)} bindings, {len(groups)} full models, '
          f'{result["receipts"]} receipts', flush=True)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='contract', required=True)
    for name, config in CONTRACTS.items():
        command = commands.add_parser(name, description=config['description'])
        add_options(command, config['option'], config['option_help'])
    native_names = ('axi-r-buffer', 'clint', 'completion-guard')
    for name in native_names:
        config = native_contract(name)
        command = commands.add_parser(name, help='Qualify the complete ' + config['label'],
                                      description=qualify_native_contract.__doc__)
        add_options(command)
        command.add_argument('--presets', nargs='+')
        command.add_argument('--jobs', type=int, default=8)
        command.add_argument('--timeout', type=int, default=config['timeout'])
        command.add_argument('--reuse-evidence', type=Path,
                             help='Rebind complete native proofs to freshly elaborated full models')
        if name == 'clint':
            command.add_argument('--dividers', type=int, nargs='+',
                                 help='Explicit positive MTIME_DIV bindings to qualify')
    args = parser.parse_args(argv)
    if args.contract in native_names:
        return qualify_native_contract(args)
    config = CONTRACTS[args.contract]
    return run_contract(args, **config)


if __name__ == '__main__':
    raise SystemExit(main())
