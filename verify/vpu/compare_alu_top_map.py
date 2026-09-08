#!/usr/bin/env python3
"""Compare whole-VPU maps with exactly the frozen ALU as the sole RTL change."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
ALU='hdl/backend/vpu/rapt_vpu_alu.sv'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('baseline',type=Path)
    ap.add_argument('optimized',type=Path)
    args=ap.parse_args()
    reports=[]
    for directory in (args.baseline,args.optimized):
        report=json.loads((directory/'summary.json').read_text())
        if digest(directory/'mapped.json')!=report['netlist_sha256']:
            raise ValueError('Mapped artifact changed')
        design=json.loads((directory/'mapped.json').read_text())
        counts=Counter(c['type'] for c in design['modules']['rapt_vpu_core']['cells'].values())
        if dict(counts)!=report['primitives']:
            raise ValueError('Resource summary differs from netlist')
        reports.append(report)
    a,b=reports
    for key in ('parameters','family','yosys','scope'):
        if a[key]!=b[key]:raise ValueError(f'Different mapping {key}')
    if a['sources'].keys()!=b['sources'].keys():raise ValueError('Different source sets')
    frozen=(ROOT/'verify/vpu/rapt_vpu_alu_baseline.sv').read_text().split('\n',1)[1]
    frozen=frozen.replace('module rapt_vpu_alu_baseline (','module rapt_vpu_alu (')
    if hashlib.sha256(frozen.encode()).hexdigest()!=a['sources'][ALU]:
        raise ValueError('Baseline ALU is not the frozen equivalence reference')
    for source,value in b['sources'].items():
        if digest(ROOT/source)!=value:raise ValueError(f'Stale optimized source {source}')
        if source!=ALU and a['sources'][source]!=value:
            raise ValueError(f'Uncontrolled change in {source}')
    proof_path=ROOT/'verify/build/vpu/alu-optimization/summary.json'
    proof=json.loads(proof_path.read_text())
    if not proof['equivalent']:raise ValueError('No equivalence proof')
    for source,value in proof['sources'].items():
        if digest(ROOT/source)!=value:raise ValueError(f'Stale equivalence source {source}')
    metrics={}
    for metric,predicate in (
        ('lut_cells',lambda k:k.startswith('LUT')),
        ('flip_flops',lambda k:k.startswith('FD')),
        ('carry_cells',lambda k:k.startswith('CARRY')),
        ('wide_muxes',lambda k:k.startswith('MUXF')),
        ('dsp_cells',lambda k:k.startswith('DSP'))):
        before=sum(v for k,v in a['primitives'].items() if predicate(k))
        after=sum(v for k,v in b['primitives'].items() if predicate(k))
        metrics[metric]=dict(baseline=before,optimized=after,
            reduction_percent=100*(before-after)/before if before else None)
    result=dict(scope='Same-flow primitive comparison; only ALU RTL changed; not P&R or STA',
        parameters=b['parameters'],metrics=metrics,
        baseline_netlist=a['netlist_sha256'],optimized_netlist=b['netlist_sha256'],
        proof_summary_sha256=digest(proof_path),checker_sha256=digest(Path(__file__)))
    (args.optimized/'alu-comparison.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':
    main()
