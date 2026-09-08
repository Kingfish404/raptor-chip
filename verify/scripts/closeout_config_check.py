#!/usr/bin/env python3
"""Compare preprocessed declared settings, not elaborated hardware equivalence."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

RESOURCES = '''XLEN MISA M_FAST PHT_SIZE BTB_SIZE BTB_WAYS RSB_SIZE RIQ_SIZE
IIQ_SIZE ROB_SIZE RS_SIZE IOQ_SIZE SQ_SIZE REG_SIZE PHY_SIZE CACHE_LINE_BYTES
L1I_LINE_LEN L1I_LEN L1I_N_WAYS L1I_REFILL_WORDS L1D_LINE_LEN L1D_LEN L1D_N_WAYS
ITLB_ENTRIES DTLB_ENTRIES L2_LEN L2_LINE_LEN L2_N_WAYS CACHE_SRAMLEN'''.split()
FEATURES = ['BPU_DIRP_TAGE', 'BPU_DIRP_GSHARE', 'BPU_DIRP_BIMODAL',
            'BPU_DIRP_STATIC', 'LSU_HUM', 'RVFI', 'USE_SRAM_MACRO']

def manifest(root, preset='default'):
    paths = [root / f'configs/{preset}/rapt_config.svh',
             *sorted((root / 'include').rglob('*.svh'))]
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}

def read_macros(root, xlen, preset='default', sram_macro=False, integer_ports=None):
    command = ['verilator', '-E', '-P', '--dump-defines',
               *(['-DRAPT_RV64'] if xlen == 64 else []),
               *(['-DRAPT_USE_SRAM_MACRO'] if sram_macro else []),
               *([f'-DRAPT_INTEGER_ISSUE_PORTS={integer_ports}'] if integer_ports is not None else []),
               f'-I{root}/configs/{preset}', f'-I{root}/include', str(root/'include/rapt.svh')]
    output = subprocess.check_output(command, text=True)
    macros = {}
    for line in output.splitlines():
        match = re.fullmatch(r'`define (RAPT_\w+)(?:\s+(.*))?', line)
        if match:
            macros[match[1]] = ' '.join((match[2] or '').split())
    return macros, command

def declared_settings(macros):
    optional = {'L2_LEN', 'L2_LINE_LEN', 'L2_N_WAYS', 'CACHE_SRAMLEN'}
    values = {k: (macros.get('RAPT_' + k) if k in optional else macros['RAPT_' + k])
              for k in RESOURCES}
    values.update({k: 'RAPT_' + k in macros for k in FEATURES})
    if 'RAPT_DECODE_WIDTH' in macros:
        for k in ('DECODE_WIDTH', 'RENAME_WIDTH', 'DISPATCH_WIDTH', 'COMMIT_WIDTH',
                  'INTEGER_ISSUE_PORTS', 'INTEGER_SYSTEM_PORT'):
            values[k] = macros['RAPT_' + k]
    else:
        # f82c2e86: DUAL_ISSUE controls ordered input width, not ALQ issue ports.
        width = '2' if 'RAPT_DUAL_ISSUE' in macros else '1'
        values.update({k: width for k in ('DECODE_WIDTH', 'RENAME_WIDTH', 'DISPATCH_WIDTH')})
        # rapt_ieu unconditionally instantiates ALU/ALU-CSR and HAS_ISS_B=1.
        values['INTEGER_ISSUE_PORTS'] = '2'
        values['COMMIT_WIDTH'] = '2' if 'RAPT_DUAL_COMMIT' in macros else '1'
        values['INTEGER_SYSTEM_PORT'] = '0'
    return values

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True, help='HDL directory')
    parser.add_argument('--candidate', type=Path, required=True, help='HDL directory')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--preset', choices=('default', 'small'), default='default')
    parser.add_argument('--sram-macro', action='store_true', help='match CI STA SRAM macro define')
    parser.add_argument('--candidate-integer-ports', type=int, choices=range(1, 9),
                        help='explicit candidate-only issue-port override (recorded in report)')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = args.output/'results.json'
    result = {'complete': False, 'scope': 'declared resource/width settings',
              'preset': args.preset, 'sram_macro': args.sram_macro,
              'candidate_integer_ports': args.candidate_integer_ports, 'cases': []}
    report.write_text(json.dumps(result, indent=2)+'\n')
    roots = [args.baseline.resolve(), args.candidate.resolve()]
    result['sources'] = [{'root': str(r), 'sha256': manifest(r, args.preset)} for r in roots]
    result['tool'] = subprocess.check_output(['verilator', '--version'], text=True).strip()
    for xlen in (32, 64):
        rows = []
        for index, root in enumerate(roots):
            ports = args.candidate_integer_ports if index == 1 else None
            macros, command = read_macros(root, xlen, args.preset, args.sram_macro, ports)
            rows.append({'command': command, 'macros': macros, 'settings': declared_settings(macros)})
        mismatches = {k: [rows[0]['settings'][k], rows[1]['settings'][k]]
                      for k in rows[0]['settings'] if rows[0]['settings'][k] != rows[1]['settings'][k]}
        all_names = rows[0]['macros'].keys() | rows[1]['macros'].keys()
        differences = {k: [r['macros'].get(k) for r in rows] for k in sorted(all_names)
                       if rows[0]['macros'].get(k) != rows[1]['macros'].get(k)}
        result['cases'].append({'xlen': xlen, 'inputs': rows, 'mismatches': mismatches,
                                'all_macro_differences_for_review': differences})
        report.write_text(json.dumps(result, indent=2)+'\n')
        if mismatches:
            raise RuntimeError(f'RV{xlen}: declared settings differ: {mismatches}')
    if any(manifest(r, args.preset) != s['sha256'] for r, s in zip(roots, result['sources'])):
        raise RuntimeError('headers changed during setting audit')
    result['complete'] = True
    report.write_text(json.dumps(result, indent=2)+'\n')
    print('PASS: RV32/RV64 declared settings match; new policies and macro differences require review')

if __name__ == '__main__':
    main()
