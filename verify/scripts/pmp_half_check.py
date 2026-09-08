#!/usr/bin/env python3
"""Prove current/default PMP two-byte accesses against formal_pmp's byte model.

Uses binary-valued inputs, 16 entries, and the harness's legal mode/mask
assumptions. This is a combinational checker proof, not CSR or MMU sequencing.
"""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    source = args.source_root.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    files = sorted((source / 'hdl/include').rglob('*.svh')) + [
        source / name for name in (
            'hdl/configs/default/rapt_config.svh', 'hdl/memory/rapt_pmp.sv',
            'verify/formal/formal_pmp.sv', 'verify/formal/pmp_formal_if.sv')]
    hashes = {str(p.relative_to(source)): sha(p) for p in files}
    (output / 'source-manifest.json').write_text(json.dumps(hashes, indent=2) + '\n')
    (output / 'tool-version.txt').write_text(subprocess.check_output(['yosys', '-V'], text=True))

    def prove(xlen):
        def quoted(relative):
            # Fixed relative paths; cwd handles arbitrary source-root paths.
            return relative
        script = ('read_slang --single-unit --top formal_pmp '
                  + ('-DRAPT_RV64 ' if xlen == 64 else '')
                  + '-I' + quoted('hdl/include') + ' -I' + quoted('hdl/configs/default')
                  + ' ' + ' '.join(quoted(p) for p in (
                      'verify/formal/pmp_formal_if.sv', 'verify/formal/formal_pmp.sv',
                      'hdl/memory/rapt_pmp.sv'))
                  + '; chformal -assert -lower; chformal -assume -lower; '
                    'select -assert-count 2 t:$assert; select -assert-count 32 t:$assume; '
                    'select -assert-none t:$check t:$cover; '
                    'prep -top formal_pmp -flatten; delete -input w:size_m1; '
                    "connect -set size_m1 4'd1; opt; check -assert; "
                    'techmap; opt; abc -g AND; opt; check -assert; '
                    'sat -timeout 90 -verify -prove-asserts -set-assumes')
        command = ['yosys', '-Q', '-T', '-m', 'slang', '-p', script]
        log = output / f'rv{xlen}.log'
        with log.open('w') as stream:
            try:
                rc = subprocess.run(command, cwd=source, stdout=stream, stderr=subprocess.STDOUT,
                                    timeout=150).returncode
            except subprocess.TimeoutExpired:
                rc = 124
        passed = rc == 0 and 'SAT proof finished - no model found: SUCCESS!' in log.read_text()
        result = dict(xlen=xlen, command=command, cwd=str(source), returncode=rc, passed=passed,
                      log_sha256=sha(log))
        (output / f'rv{xlen}.json').write_text(json.dumps(result, indent=2) + '\n')
        print(f'RV{xlen}: {"PASS" if passed else "UNPROVEN"} (exit {rc})', flush=True)
        return result

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(prove, (32, 64)))
    unchanged = all(sha(source / p) == h for p, h in hashes.items())
    complete = unchanged and all(r['passed'] for r in results)
    (output / 'results.json').write_text(json.dumps(
        dict(complete=complete, source_unchanged=unchanged, cases=results), indent=2) + '\n')
    return 0 if complete else 1


if __name__ == '__main__':
    raise SystemExit(main())
