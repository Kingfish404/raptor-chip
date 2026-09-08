#!/usr/bin/env python3
"""Audit selected completed VPU evidence; never infer complete ISA conformance."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[2]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fresh(path):
    data=json.loads(path.read_text())
    if not data.get('sources'):raise ValueError(f'No source manifest: {path}')
    stale=[s for s,h in data['sources'].items() if not (ROOT/s).is_file() or sha(ROOT/s)!=h]
    if stale:raise ValueError('Stale sources: '+', '.join(stale))
    return data


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build-dir',type=Path,default=ROOT/'verify/build/vpu')
    args=ap.parse_args();build=args.build_dir.resolve();results=[]

    def gate(name,fn):
        try:
            evidence=fn();results.append(dict(gate=name,status='PASS',evidence=evidence))
        except (ValueError,KeyError,FileNotFoundError,AssertionError) as error:
            results.append(dict(gate=name,status='FAIL',reason=str(error)))

    def top(xlen,elen,banks,suite,steps,vlen=128,bank_bits=64):
        suffix='' if suite=='full' else '-'+suite
        folder=build/f'core-top-{xlen}-{vlen}-{elen}-{bank_bits}-{banks}-opt1-spike{suffix}'
        data=fresh(folder/'sources.json')
        expected=dict(XLEN=xlen,VLEN=vlen,ELEN=elen,BankBits=bank_bits,Banks=banks,
                      OptimizeOperandReads=1,Spike=1,CoreAdapter=1)
        if data['configuration']!=expected or data['suite']!=suite:
            raise ValueError('Wrong top configuration/suite')
        reference=json.loads((folder/'reference.json').read_text())
        if reference['revision']!='770ce31f7543f57472b35e66600085ea81184bb2':
            raise ValueError('Wrong pinned Spike revision')
        libraries=reference['sha256']
        if set(libraries)!={'libriscv.a','libdisasm.a','libsoftfloat.a','libfesvr.a','libfdt.a','config.h'} or not all(re.fullmatch('[0-9a-f]{64}',h) for h in libraries.values()):
            raise ValueError('Incomplete reference build identity')
        log=(folder/'run.log').read_text()
        label='top' if suite=='full' else suite.replace('-','_')+'_top'
        lines=re.findall(r'^PASS '+label+r' (.+)$',log,re.M)
        if len(lines)!=1:raise ValueError('Missing unique completed PASS')
        fields=dict(item.split('=') for item in lines[0].split())
        if int(fields['spike_steps'])!=steps:raise ValueError('Incomplete Spike workload')
        for k,v in dict(XLEN=xlen,VLEN=vlen,ELEN=elen).items():
            if int(fields[k])!=v:raise ValueError('Run/manifest parameter mismatch')
        evidence=dict(manifest=str(folder/'sources.json'),run_sha256=sha(folder/'run.log'),
                      reference_sha256=sha(folder/'reference.json'),result=fields)
        if suite=='catalog':
            from check_catalog import audit
            catalog=audit(folder)
            evidence['catalog_totals']=catalog['totals']
            evidence['catalog_checker_sha256']=catalog['checker_sha256']
        return evidence

    for x,e,b in ((32,32,1),(64,64,2)):
        for suite,steps in (('full',219437 if x==32 else 344935),('context',1112),
                            ('store-completion',1330),('geometry',341110 if x==32 else 493389),
                            ('catalog',21402 if x==32 else 28536),
                            ('encoding',344064 if x==32 else 458752),
                            ('config-encoding',172464 if x==32 else 172848),
                            ('memory-encoding',163840)):
            gate(f'{x}-{suite}',lambda x=x,e=e,b=b,suite=suite,steps=steps:top(x,e,b,suite,steps))

    for x,v,bb,full_steps in ((32,256,64,345739),(64,512,128,349159)):
        for suite,steps in (('full',full_steps),('catalog',28536),
                            ('context',1112),('store-completion',1330)):
            gate(f'{x}-vlen{v}-{suite}',
                 lambda x=x,v=v,bb=bb,suite=suite,steps=steps:
                     top(x,64,4,suite,steps,vlen=v,bank_bits=bb))

    def induction(folder,mutations):
        path=build/folder/'summary.json';data=fresh(path)
        if len(data['proofs'])!=4 or not all(p['inductive_safety'] and len(p['witnesses'])==11 for p in data['proofs']):
            raise ValueError('Incomplete inductive proof/witness matrix')
        if len(data['mutations_detected'])!=mutations:raise ValueError('Missing mutation checks')
        return dict(summary=str(path),sha256=sha(path))
    gate('owner-induction',lambda:induction('formal-owner',4))
    gate('core-adapter-induction',lambda:induction('formal-core-adapter',6))

    def isolation():
        paths=[build/'formal-memory-isolation'/p for p in ('summary.json','ledger/summary.json')]
        a,b=map(fresh,paths)
        if len(a['configurations'])!=2 or len(a['detected_mutations'])!=2:
            raise ValueError('Incomplete memory isolation proof')
        if len(b['configurations'])!=2 or not all(c['inductive_safety'] for c in b['configurations']) or len(b['detected_mutations'])!=4:
            raise ValueError('Incomplete request ledger proof')
        return {str(p):sha(p) for p in paths}
    gate('memory-payload-isolation',isolation)

    def alu():
        path=build/'alu-optimization/summary.json';data=fresh(path)
        if not data['equivalent']:raise ValueError('Missing ALU equivalence')
        comparison=data['comparison']
        if comparison['optimized']['lut_cells']>=comparison['baseline']['lut_cells']:
            raise ValueError('No leaf LUT improvement')
        return dict(summary=str(path),sha256=sha(path))
    gate('alu-equivalence-optimization',alu)

    def mapping(x,e,b):
        folder=build/f'fpga-map-alu-opt/{x}-128-{e}-{b}-64-1-xcup'
        data=fresh(folder/'summary.json');netlist=folder/'mapped.json'
        if sha(netlist)!=data['netlist_sha256']:raise ValueError('Changed mapped netlist')
        design=json.loads(netlist.read_text())
        counts=Counter(c['type'] for c in design['modules']['rapt_vpu_core']['cells'].values())
        if dict(counts)!=data['primitives']:raise ValueError('Wrong primitive count')
        proof=json.loads((folder/'primitive-check.json').read_text())
        if proof['netlist_sha256']!=data['netlist_sha256'] or not proof['primitive_provenance_checked']:
            raise ValueError('Missing matching primitive audit')
        if sha(ROOT/'verify/vpu/check_fpga_map.py')!=proof['checker_sha256']:
            raise ValueError('Stale primitive checker')
        if any(sha(Path(s))!=h for s,h in proof['library_snapshots'].items()):
            raise ValueError('Changed primitive libraries')
        return dict(summary=str(folder/'summary.json'),sha256=sha(folder/'summary.json'))
    gate('rv32-fpga-map',lambda:mapping(32,32,1))
    gate('rv64-fpga-map',lambda:mapping(64,64,2))
    passed=all(r['status']=='PASS' for r in results)
    output=dict(scope='Selected source-current evidence only; not full-V compliance, full-VPU formal, scalar LSU integration or STA',
                passed=passed,checker_sha256=sha(Path(__file__)),gates=results)
    build.mkdir(parents=True,exist_ok=True)
    (build/'acceptance.json').write_text(json.dumps(output,indent=2)+'\n')
    for result in results:print(result['status'],result['gate'],result.get('reason',''))
    raise SystemExit(0 if passed else 1)


if __name__=='__main__':
    main()
