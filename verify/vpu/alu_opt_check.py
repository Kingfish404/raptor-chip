#!/usr/bin/env python3
"""Prove ALU equivalence and compare identically mapped leaf resources."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'verify/build/vpu/alu-optimization'
SOURCES=[ROOT/p for p in ('hdl/backend/vpu/rapt_vpu_alu.sv',
    'verify/vpu/rapt_vpu_alu_baseline.sv','verify/vpu/formal_alu_equivalence.sv')]+[Path(__file__)]


def run(name,script):
    path=OUT/f'{name}.ys';path.write_text(script+'\n')
    with (OUT/f'{name}.log').open('w') as log:
        subprocess.run(['yosys','-Q','-T','-m','slang','-s',str(path)],cwd=ROOT,
                       stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
    return (OUT/f'{name}.log').read_text()


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    (OUT/'summary.json').unlink(missing_ok=True)
    hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
    proof=run('equivalence','read_slang --top formal_alu_equivalence '
        +' '.join(str(p.relative_to(ROOT)) for p in SOURCES[:3])
        +'; prep -top formal_alu_equivalence; flatten; opt; sat -verify -prove correct 1')
    if 'SAT proof finished - no model found: SUCCESS!' not in proof:
        raise RuntimeError('Missing successful equivalence result')
    records={}
    for label,top,source in (('baseline','rapt_vpu_alu_baseline',SOURCES[1]),
                             ('optimized','rapt_vpu_alu',SOURCES[0])):
        mapped=OUT/f'{label}.json'
        run(label,f'read_slang --top {top} {source}; '
            +f'synth_xilinx -family xcup -top {top} -flatten -noiopad -noclkbuf; '
            +'check -assert; write_json '+json.dumps(str(mapped)))
        design=json.loads(mapped.read_text())
        counts=Counter(c['type'] for c in design['modules'][top]['cells'].values())
        if any(k.startswith('$') for k in counts):
            raise RuntimeError('Unmapped generic cell')
        records[label]=dict(primitives=dict(counts),
            lut_cells=sum(v for k,v in counts.items() if k.startswith('LUT')),
            netlist_sha256=hashlib.sha256(mapped.read_bytes()).hexdigest())
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(ROOT))] for p in SOURCES):
        raise RuntimeError('Inputs changed during verification')
    report=dict(scope='Combinational equivalence for all binary inputs and xcup ALU leaf mapping; no STA',
        equivalent=True,yosys=subprocess.check_output(['yosys','-V'],text=True).strip(),
        comparison=records,sources=hashes)
    (OUT/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(records,indent=2))


if __name__=='__main__':
    main()
