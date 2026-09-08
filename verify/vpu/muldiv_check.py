#!/usr/bin/env python3
"""Verify and measure identical muldiv inputs with early completion off/on."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build-dir', type=Path, required=True)
args = parser.parse_args()
build = args.build_dir.resolve()
files = ['hdl/backend/vpu/rapt_vpu_muldiv.sv', 'hdl/include/rapt_sva.svh',
         'verify/vpu/test_muldiv.cpp', 'verify/vpu/muldiv_reference.h',
         'verify/vpu/Makefile', 'verify/vpu/muldiv_check.py', 'verify/vpu/record_leaf.py']
def fingerprints():
    return {p: hashlib.sha256((root/p).read_bytes()).hexdigest() for p in files}
sources = fingerprints()
runs = []
for opt in (0, 1):
    subprocess.run(['make', '-C', str(root/'verify/vpu'), 'muldiv',
                    f'BUILD_DIR={build}', f'MULDIV_EARLY_OUT={opt}'], check=True)
    lines = (build/f'muldiv-{opt}'/'run.log').read_text().splitlines()
    passed = [s for s in lines if s.startswith('PASS muldiv ')]
    assert len(passed) == 1
    runs.append(dict(re.findall(r'(\w+)=([0-9a-f]+)', passed[0])))
assert fingerprints() == sources, 'Sources changed during comparison'
for key in ('checks', 'seed', 'exhaustive_e8', 'workload_hash'):
    assert runs[0][key] == runs[1][key], key
before, after = (int(r['cycles']) for r in runs)
assert after < before
result = dict(sources=sources, verilator=subprocess.check_output(['verilator','--version'],text=True).strip(),
              baseline=runs[0], optimized=runs[1], reduction_percent=100*(before-after)/before,
              scope='Whole leaf simulation cycles including identical reset and response stalls; not application IPC or physical PPA')
(build/'muldiv-optimization.json').write_text(json.dumps(result,indent=2)+'\n')
print(f'PASS muldiv optimization {before} -> {after} cycles ({result["reduction_percent"]:.3f}% reduction)')
