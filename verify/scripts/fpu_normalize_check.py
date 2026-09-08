#!/usr/bin/env python3
"""Prove FPU mantissa normalization against the original serial shifts."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path,
                        default=Path(__file__).resolve().parents[2])
    parser.add_argument('--dut', type=Path, help='Optional isolated divider under test')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.source_root.resolve()
    dut = (args.dut or root / 'hdl/backend/feu/fpu/rapt_fpu_divsqrt.sv').resolve()
    reference = root / 'verify/formal/formal_fpu_normalize_ref.sv'
    output = args.output.resolve()
    for path in (dut, reference, output):
        if any(char.isspace() or char in ';"' for char in str(path)):
            raise ValueError(f'Unsupported Yosys path: {path}')
    files = (dut, reference, Path(__file__).resolve())

    def hashes():
        return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}

    result = {'complete': False, 'source_sha256': hashes(),
              'scope': 'All fraction, exponent and precision inputs; exact 53-bit mantissa and 32-bit adjustment'}
    # The helper is private to the RTL module. Extract its actual definition;
    # missing/renamed helpers or new external dependencies must fail the proof.
    functions = re.findall(r'function\s+automatic\s+logic\s+\[52:0\]\s+norm_mant\b.*?endfunction',
                           dut.read_text(), flags=re.S)
    if len(functions) != 1:
        raise ValueError('Expected exactly one 53-bit norm_mant definition')
    output.mkdir(parents=True, exist_ok=True)
    gate = output / 'norm_gate.sv'
    gate.write_text('module norm_gate(input logic [51:0] frac, input logic [10:0] exp, '
                    'input logic dbl, output logic [52:0] mant, output int adj);\n'
                    + functions[0] + '\n'
                    'always_comb mant = norm_mant(frac, exp, dbl, adj);\nendmodule\n')
    script = output / 'equiv.ys'
    script.write_text('\n'.join([
        f'read_slang --single-unit --top norm_gold {reference}',
        f'read_slang --single-unit --top norm_gate {gate}',
        'proc', 'opt', 'equiv_make norm_gold norm_gate equiv',
        'hierarchy -top equiv', 'opt_clean', 'equiv_simple', 'equiv_status -assert']) + '\n')
    report = output / 'results.json'
    report.write_text(json.dumps(result, indent=2) + '\n')
    command = ['yosys', '-Q', '-T', '-m', 'slang', '-s', str(script)]
    log = output / 'equiv.log'
    with log.open('w') as stream:
        run = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=120)
    result['command'] = command
    result['exit'] = run.returncode
    result['proved'] = run.returncode == 0 and 'Equivalence successfully proven!' in log.read_text()
    if hashes() != result['source_sha256']:
        raise RuntimeError('Sources changed during proof')
    result['complete'] = True
    report.write_text(json.dumps(result, indent=2) + '\n')
    print(f'{"PASS" if result["proved"] else "FAIL"}: FPU normalization equivalence', flush=True)
    return 0 if result['proved'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
