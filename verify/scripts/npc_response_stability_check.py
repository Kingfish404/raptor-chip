#!/usr/bin/env python3
"""Check actual NPC AXI response holds and watchdog ownership, both XLENs.

The mock returns arbitrary full memory words/delays. Host backing-memory
atomicity, AXI functional completeness and whole-core conformance are separate.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root, out = args.source_root.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    src = out / 'source'
    names = ['hdl/rapt_pkg.sv', 'sim/rtl/rapt_npc_soc.sv',
             'verify/formal/formal_npc_read_stability.sv',
             'verify/formal/npc_response_stability_main.cpp',
             'verify/scripts/npc_response_stability_check.py']
    names += [str(p.relative_to(root)) for directory in ('hdl/include', 'hdl/configs/default')
              for p in sorted((root / directory).rglob('*.svh'))]
    manifest = {}
    for name in names:
        data = (root / name).read_bytes()
        target = src / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        manifest[name] = hashlib.sha256(data).hexdigest()
    mock = src / 'mock'
    mock.mkdir()
    data = (src / 'hdl/include/dpic_mock/rapt_dpi_c.svh').read_text()
    data = data.replace('MEM_RANDOM_DELAY(rval) begin rval = \'0; end',
                        'MEM_RANDOM_DELAY(rval) begin rval = formal_npc_read_stability.delay_word; end')
    data = data.replace('PMEM_READ(pm_raddr, pm_rsize, pm_rdata) begin end',
                        'PMEM_READ(pm_raddr, pm_rsize, pm_rdata) begin pm_rdata = formal_npc_read_stability.memory_word; end')
    (mock / 'rapt_dpi_c.svh').write_text(data)
    result = {'complete': False, 'sources': manifest, 'cases': [],
              'scope': 'Reset-zero base; defined-state induction; arbitrary inputs and full-word mock; no fairness assumption'}
    def save():
        (out / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    def run(command, label):
        with (out / (label + '.log')).open('w') as log:
            proc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        result['cases'].append({'label': label, 'command': command, 'exit': proc.returncode})
        save()
        if proc.returncode:
            raise RuntimeError(f'{label} failed: inspect {out}/{label}.log')
    save()
    for tool, flag in [('yosys', '-V'), ('verilator', '--version')]:
        run([tool, flag], tool + '-version')
    for xlen in (32, 64):
        top = 'formal_npc_read_stability'
        flags = ['-DSYNTHESIS'] + (['-DRAPT_RV64'] if xlen == 64 else [])
        flags += [f'-I{src}/{p}' for p in ('mock', 'hdl/configs/default', 'hdl/include', 'hdl/include/npc')]
        files = [str(src / p) for p in names[:3]]
        for path in flags + files:
            if any(c.isspace() or c in ';"' for c in path):
                raise ValueError(f'Unsupported Yosys path: {path}')
        script = out / f'rv{xlen}.ys'
        script.write_text(';\n'.join([
            'read_slang --single-unit ' + ' '.join(flags) + f' --top {top} ' + ' '.join(files),
            f'prep -top {top} -flatten', 'opt',
            'select -assert-none t:$check t:$assert t:$assume t:$cover',
            # Only diagnostics are removed, never functional state or properties.
            'delete t:$print',
            'sat -verify -tempinduct-def -seq 4 -maxsteps 16 -set-init-zero -set-def-inputs -prove mismatch 0 -show-inputs -show-outputs']) + '\n')
        run(['yosys', '-Q', '-T', '-m', 'slang', '-s', str(script)], f'proof{xlen}')
        if 'Induction step proven: SUCCESS!' not in (out / f'proof{xlen}.log').read_text():
            raise RuntimeError('Missing induction success marker')
        obj = out / f'obj{xlen}'
        run(['verilator', '--cc', '--exe', '--build', '-j', '4', '--top-module', top,
             *flags, '--Mdir', str(obj), *files, str(src / names[3])], f'build{xlen}')
        for mode in ('r', 'b', 'aw'):
            run([str(obj / ('V' + top)), mode], f'hold{xlen}-{mode}')
            if 'PASS ' not in (out / f'hold{xlen}-{mode}.log').read_text():
                raise RuntimeError('Missing hold/drain success marker')
        print(f'PASS: RV{xlen} response induction and R/B/AW watchdog hold/drain', flush=True)
    for name, expected in manifest.items():
        if hashlib.sha256((src / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError(f'Frozen source drift: {name}')
    result['workspace_drift'] = [name for name, expected in manifest.items()
                                 if not (root / name).exists() or
                                 hashlib.sha256((root / name).read_bytes()).hexdigest() != expected]
    result['complete'] = True
    save()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
