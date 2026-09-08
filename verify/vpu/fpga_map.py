#!/usr/bin/env python3
"""Map the independent core-facing VPU to Xilinx primitives, without board I/O.

Resource mapping only: no placement, routing, timing signoff or board operation.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--xlen', type=int, choices=(32, 64), default=64)
    ap.add_argument('--vlen', type=int, default=128)
    ap.add_argument('--elen', type=int, choices=(32, 64), default=64)
    ap.add_argument('--banks', type=int, default=2)
    ap.add_argument('--bank-bits', type=int, default=64)
    ap.add_argument('--family', choices=('xcup', 'xc7'), default='xcup')
    ap.add_argument('--build-dir', type=Path, default=ROOT/'verify/build/vpu/fpga-map')
    ap.add_argument('--timeout', type=int, default=900)
    args = ap.parse_args()
    params = dict(XLEN=args.xlen, VLEN=args.vlen, ELEN=args.elen,
                  Banks=args.banks, BankBits=args.bank_bits, OptimizeOperandReads=1)
    out = args.build_dir.resolve()/('-'.join(map(str,params.values()))+'-'+args.family)
    out.mkdir(parents=True, exist_ok=True)
    summary = out/'summary.json'
    summary.unlink(missing_ok=True)
    sources = [ROOT/'hdl/memory/rapt_sram_1rw.sv']
    sources += [ROOT/f'hdl/backend/feu/fpu/rapt_fpu_{name}.sv' for name in (
        'fma','divsqrt','convert_narrow','int_to_fp','single_to_int_w')]
    sources += sorted((ROOT/'hdl/backend/vpu').glob('*.sv'))
    inputs = sources+[ROOT/'hdl/include/rapt_sva.svh',ROOT/'hdl/include/rapt_fp_ops.svh',Path(__file__)]
    hashes = {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    (out/'sources.json').write_text(json.dumps(hashes,indent=2)+'\n')
    script = '\n'.join([
        'read_slang --top rapt_vpu_core -Ihdl/include '
        +' '.join(f'-G{k}={v}' for k,v in params.items())+' '
        +' '.join(str(p.relative_to(ROOT)) for p in sources),
        'hierarchy -check -top rapt_vpu_core',
        'select -assert-none t:$check t:$assert t:$assume t:$cover',
        f'synth_xilinx -family {args.family} -top rapt_vpu_core -flatten -noiopad -noclkbuf',
        'check -assert',
        'write_json '+json.dumps(str(out/'mapped.json')),
        'write_verilog -noattr '+json.dumps(str(out/'mapped.v')),
    ])
    (out/'run.ys').write_text(script+'\n')
    started=time.monotonic()
    with (out/'run.log').open('w') as log:
        subprocess.run(['yosys','-Q','-T','-m','slang','-s',str(out/'run.ys')],
                       cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,
                       timeout=args.timeout,check=True)
    elapsed=time.monotonic()-started
    design=json.loads((out/'mapped.json').read_text())
    cells=design['modules']['rapt_vpu_core']['cells']
    counts=Counter(c['type'] for c in cells.values())
    for kind in counts:
        if kind.startswith('$') or kind not in design['modules']:
            raise RuntimeError(f'Unmapped or unknown cell {kind}')
        attrs=design['modules'][kind].get('attributes',{})
        if not any(int(attrs.get(a,'0'),2) for a in ('blackbox','whitebox')):
            raise RuntimeError(f'Unflattened nonprimitive {kind}')
    vrf=Counter(c['type'] for name,c in cells.items() if 'u_vrf' in name)
    if not any(k.startswith('RAM') for k in vrf):
        raise RuntimeError('VRF did not map to RAM primitives')
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(ROOT))] for p in inputs):
        raise RuntimeError('Inputs changed during mapping')
    report=dict(scope='Xilinx primitive resource mapping; no IO/clock buffers, P&R or STA',
                family=args.family,parameters=params,
                yosys=subprocess.check_output(['yosys','-V'],text=True).strip(),
                elapsed_seconds=elapsed,primitives=dict(sorted(counts.items())),
                vrf_primitives=dict(sorted(vrf.items())),sources=hashes,
                netlist_sha256=hashlib.sha256((out/'mapped.json').read_bytes()).hexdigest())
    summary.write_text(json.dumps(report,indent=2)+'\n')
    print('PASS FPGA map',params,args.family,dict(counts),flush=True)


if __name__ == '__main__':
    main()
