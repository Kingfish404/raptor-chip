#!/usr/bin/env python3
"""Check debug safety, activation witnesses and isolated RTL fault controls."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import subprocess

from formal_scope import preset_xlens
from yosys_common import ROOT, activation_witnesses, read_status, run_sby_task, sha


FORMAL = ROOT / 'verification/formal'
TARGETS = {
    'dm': ('formal_dm_debug', 'rtl/uncore/debug/rapt_dm.sv'),
    'arbiter': ('formal_debug_arbiter', 'rtl/uncore/debug/rapt_debug_arbiter.sv'),
    'step': ('formal_rou_retire', 'rtl/core/backend/rob/rapt_rou.sv'),
    'reset': ('formal_debug_reset', 'rtl/rapt.sv'),
}
MUTATIONS = {
    'dm': [
        ('halt', 'haltreq_q | dm_halt_state_q | reset_halt_q | resume_pending_q',
         'dm_halt_state_q | reset_halt_q | resume_pending_q'),
        ('dpc', 'dpc_q <= halt_pc_i[XLEN-1:1];', "dpc_q <= '0;"),
        ('drain', 'reset || (!dmactive_q && !sb_busy)', 'reset || !dmactive_q'),
        ('busy', "if (sb_busy && (sb_address_write || sb_data_access)) sbbusyerror_q <= 1'b1;",
         "if (1'b0) sbbusyerror_q <= 1'b1;"),
        ('error', "== 2'b11 ? 3'd2 : 3'd7;", "== 2'b11 ? 3'd7 : 3'd2;"),
        ('increment', "sbaddress_q + (PAddrBits'(1) << sbaccess_q)",
         "sbaddress_q + PAddrBits'(1)"),
        ('mask', 'sb_byte_mask << sbaddress_q[ByteOffBits-1:0]', 'sb_byte_mask'),
    ],
    'arbiter': [
        ('read-lock', 'read_lock_q ? read_owner_q', "1'b0 ? read_owner_q"),
        ('write-lock', 'write_lock_q ? write_owner_q', "1'b0 ? write_owner_q"),
        ('route', 'merged_axi.rid == SbaId', 'merged_axi.rid != SbaId'),
        ('block', '!core_block_i || (read_lock_q && !read_owner_q)', "1'b1"),
        ('idle', 'core_reads_q == 0 && core_writes_q == 0', "1'b1"),
    ],
    'step': [
        ('token', "if (debug.step && enq_fire[0]) debug_step_issued_q <= 1'b1;",
         "if (1'b0) debug_step_issued_q <= 1'b1;"),
        ('lane', 'enq_fire[s-1] && !debug.step', 'enq_fire[s-1]'),
        ('gate', '&& !debug_step_issued_q;', ';'),
    ],
    'reset': [
        ('early', 'if (core_bus_idle) ndmreset_active_q', "if (1'b1) ndmreset_active_q"),
        ('pulse', 'dm_ndmreset || ndmreset_pending_q) begin', 'dm_ndmreset) begin'),
    ],
}
ASSUMPTIONS = {
    'dm': ['First sampled edge resets', 'Hart reset implies unavailable',
           'Availability returns only after reset', 'A pending resume retains the halted hart'],
    'arbiter': ['First sampled edge resets', 'AXI sources preserve stalled requests',
                'Core addresses reserve ID 15 for SBA', 'Core responses have accepted addresses',
                'Core outstanding requests stay within the selected credit limits'],
    'step': ['First sampled edge resets', 'DM step implies enable',
             'Completion inputs pass the same ownership guard as the retirement harness'],
}
ASSUMPTIONS['reset'] = ASSUMPTIONS['arbiter']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--blocks', nargs='+', choices=TARGETS, default=list(TARGETS))
    parser.add_argument('--presets', nargs='+', default=['formal'])
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--timeout', type=int, default=180)
    parser.add_argument('--depth', type=int, default=24)
    parser.add_argument('--controls', choices=['run', 'skip'], default='run')
    args = parser.parse_args()
    if min(args.jobs, args.timeout, args.depth) < 1:
        parser.error('Jobs, timeout and depth must be positive')
    if len(set(args.blocks)) != len(args.blocks) or len(set(args.presets)) != len(args.presets):
        parser.error('Duplicate blocks or presets')
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('Output must be empty to preserve evidence')
    for preset in args.presets:
        if not re.fullmatch(r'[A-Za-z0-9_-]+', preset):
            parser.error('Invalid preset')
        if not (ROOT / 'rtl/configs' / preset / 'rapt_config.svh').is_file():
            parser.error('Unknown preset: ' + preset)
    if any(c.isspace() or c in ';"' for c in str(output)):
        parser.error('Yosys output paths cannot contain whitespace, quotes or semicolons')
    output.mkdir(parents=True, exist_ok=True)
    sources = sorted((ROOT / 'rtl').rglob('*.sv'))
    sources += sorted((ROOT / 'rtl').rglob('*.svh'))
    sources += [FORMAL / (top + '.sv') for block, (top, _) in TARGETS.items() if block != 'step']
    sources += [FORMAL / 'formal_rou.sv', FORMAL / 'formal_debug_step.svh']
    sources += [Path(__file__),
                ROOT / 'verification/scripts/yosys_common.py',
                ROOT / 'verification/scripts/formal_scope.py', FORMAL / 'yosys-rvfi-compat.sh']
    fingerprints = {str(p.relative_to(ROOT)): sha(p) for p in sources if p.is_file()}
    result = dict(complete=False, whole_rtl_signoff=False, sources=fingerprints,
                  scope='Debug safety only; no whole-unit or system signoff receipts.',
                  assumptions={name: ASSUMPTIONS[name] for name in args.blocks},
                  fairness_assumptions=[],
                  reset_scope='Verbatim inline reset controller composed with the production '
                              'arbiter; top-level wiring and upstream core/L2 quiescence '
                              'remain open.',
                  controls=args.controls, cases=[],
                  yosys=subprocess.check_output(
                      [os.environ.get('RAPTOR_YOSYS_REAL', 'yosys'), '-V'], text=True).strip())

    def save():
        temporary = output / 'results.tmp'
        temporary.write_text(json.dumps(result, indent=2) + '\n')
        temporary.replace(output / 'results.json')

    def run(case):
        block, preset, xlen, capacity, physical, mutation = case
        top, dut_name = TARGETS[block]
        reads, writes = capacity
        label = f'{block}-{preset}-rv{xlen}-r{reads}-w{writes}'
        if block == 'dm':
            label += f'-pa{physical}'
        if mutation:
            label += '-' + mutation[0]
        directory = output / label
        directory.mkdir()
        dut = ROOT / dut_name
        if mutation:
            name, old, new = mutation
            text = dut.read_text()
            if text.count(old) != 1:
                raise ValueError('Mutation anchor is not unique: ' + name)
            dut = directory / 'mutant.sv'
            dut.write_text(text.replace(old, new))
        harness = FORMAL / ('formal_rou.sv' if block == 'step' else top + '.sv')
        defines = '-DRAPT_RV64 ' if xlen == 64 else '-URAPT_RV64 '
        defines += ('-DSYNTHESIS ' if block == 'step'
                    else '-USYNTHESIS -DRAPT_ASSERT_EN -DRAPT_FORMAL_NATIVE ')
        parameters = (f'-GCapacity={reads} -GWriteCapacity={writes} '
                      if block in ('arbiter', 'reset') else '')
        if block == 'dm':
            parameters += f'-GPAddrBits={physical} '
        if block == 'step':
            defines += '-DRAPT_FORMAL_ROU_DEBUG '
            rtl = [ROOT / 'rtl/rapt_pkg.sv']
            rtl += sorted(p for p in (ROOT / 'rtl').rglob('*.sv') if p not in rtl)
            rtl[rtl.index(ROOT / dut_name)] = dut
        elif block == 'reset':
            text = dut.read_text()
            first = text.index('  assign core_block = dm_ndmreset')
            last = text.index('\n\n\n  assign io_master_arburst', first)
            fragment = text[first:last]
            cone = directory / 'debug_reset_cone.sv'
            cone.write_text('module debug_reset_cone(\n'
                'input logic clock, reset, dm_ndmreset, core_bus_idle,\n'
                'output logic core_block, core_reset);\n'
                'logic ndmreset_pending_q, ndmreset_active_q;\n'
                + fragment + '\nendmodule\n')
            provenance = dict(source=dut_name, source_sha256=sha(ROOT / dut_name),
                              selected_source_sha256=sha(dut), first_byte=first,
                              last_byte=last, fragment=fragment)
            (directory / 'source-fragment.json').write_text(json.dumps(provenance, indent=2) + '\n')
            rtl = [ROOT / 'rtl/uncore/debug/rapt_debug_arbiter.sv', cone,
                   FORMAL / 'formal_debug_arbiter.sv']
        else:
            rtl = [dut]
        read = ('plugin -i slang\nread_slang --threads 1 --single-unit '
                '--allow-toplevel-iface-ports ' + defines + parameters
                + f'-I{directory} -I{ROOT}/rtl/configs/{preset} -I{ROOT}/rtl/include '
                + f'-I{ROOT}/rtl/include/npc -I{ROOT}/rtl/include/dpic_mock '
                + f'--top {top} ' + ' '.join(map(str, rtl + [harness])))
        script = (read + f'\nprep -top {top} -flatten\nasync2sync\nchformal -lower\n'
                  'check -assert\nselect -assert-any t:$assert\n'
                  'select -assert-any t:$cover\nselect -assert-none A:blackbox=1\n')
        proof_depth = 4 if block == 'step' and not mutation else args.depth
        config = ('[tasks]\nprove\n' + ('' if mutation else 'cover\n')
                  + '[options]\nprove: mode ' + ('bmc\n' if mutation else 'prove\n')
                  + ('' if mutation else f'cover: mode cover\ncover: depth {args.depth}\n')
                  + f'prove: depth {proof_depth}\ntimeout {args.timeout}\n'
                  + '[engines]\nsmtbmc yices\n[script]\n' + script)
        (directory / 'contract.sby').write_text(config)
        child = run_sby_task(directory, args.timeout, os.environ.get('RAPTOR_YOSYS_REAL'))
        log = (directory / 'run.log').read_text()
        proof = read_status(directory / 'contract_prove/status')
        activation = {}
        if mutation:
            traces = list((directory / 'contract_prove/engine_0').glob('trace*.vcd'))
            passed = child.returncode == 2 and proof == 'FAIL' and 'Assert failed' in log
            passed &= bool(traces) and all(p.stat().st_size for p in traces)
        else:
            cover = read_status(directory / 'contract_cover/status')
            path = directory / 'contract_cover/engine_0/logfile.txt'
            activation = activation_witnesses(path.read_text(), directory) if path.exists() else {}
            model = directory / 'contract_cover/model/design_smt2.smt2'
            model_text = model.read_text() if model.exists() else ''
            cover_names = re.findall(r'^; yosys-smt2-cover \d+ (.+)$', model_text, re.M)
            expected = {top + ': ' + name for name in cover_names}
            passed = (child.returncode == 0 and proof == cover == 'PASS'
                      and 'successful proof by k-induction' in log
                      and bool(expected) and set(activation) == expected)
        passed &= 'ERROR:' not in log
        row = dict(block=block, preset=preset, xlen=xlen, capacity=capacity,
                   paddr_bits=physical if block == 'dm' else None,
                   mutation=mutation[0] if mutation else None, passed=bool(passed),
                   exit=child.returncode, proof=proof, activation=activation,
                   failures=[line for line in log.splitlines() if 'Assert failed in ' in line],
                   artifacts={str(p.relative_to(directory)): sha(p)
                              for p in directory.rglob('*') if p.is_file()})
        (directory / 'results.json').write_text(json.dumps(row, indent=2) + '\n')
        print(label, 'PASS' if passed else 'INCOMPLETE', flush=True)
        return {key: value for key, value in row.items() if key not in ('activation', 'artifacts')}

    capacities = {'arbiter': [(1, 1), (2, 2), (32, 1), (32, 4)],
                  'reset': [(32, 1), (32, 4)]}
    cases = [(block, preset, xlen, capacity, physical, None)
             for block in args.blocks for preset in args.presets
             for xlen in preset_xlens(ROOT / 'rtl/configs' / preset / 'rapt_config.svh')
             for capacity in capacities.get(block, [(1, 1)])
             for physical in ((32, 38) if block == 'dm' and xlen == 64 else (32,))]
    if args.controls == 'run':
        cases += [(block, args.presets[0], xlen, (2, 2),
                   38 if block == 'dm' and xlen == 64 else 32, mutation)
                  for block in args.blocks
                  for xlen in preset_xlens(
                      ROOT / 'rtl/configs' / args.presets[0] / 'rapt_config.svh')
                  for mutation in MUTATIONS[block]]
    save()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for row in pool.map(run, cases):
            result['cases'].append(row)
            save()
    result['source_epoch_unchanged'] = all(sha(ROOT / name) == digest
                                           for name, digest in fingerprints.items())
    result['complete'] = all(row['passed'] for row in result['cases'])
    result['complete'] &= result['source_epoch_unchanged']
    save()
    return 0 if result['complete'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
