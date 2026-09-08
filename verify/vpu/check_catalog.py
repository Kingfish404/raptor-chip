#!/usr/bin/env python3
"""Audit per-entry differential witnesses; does not certify full V semantics."""
import argparse
import json
from pathlib import Path
import re

from check_acceptance import ROOT, fresh, sha
from generate_catalog import generate
from reference_manifest import PIN


def audit(folder):
    if (ROOT/'verify/vpu/catalog_entries.h').read_text()!=generate():
        raise ValueError('Stale generated instruction catalog')
    manifest=fresh(folder/'sources.json')
    cfg=manifest['configuration']
    if manifest['suite']!='catalog' or cfg['Spike']!=1 or cfg['CoreAdapter']!=1:
        raise ValueError('Not a core-facing differential catalog run')
    reference=json.loads((folder/'reference.json').read_text())
    if reference['revision']!=PIN:
        raise ValueError('Wrong pinned reference identity')
    expected={}
    widths=cfg['ELEN'].bit_length()-3
    for raw in (ROOT/'verify/vpu/vendor/riscv-opcodes/rv_v').read_text().splitlines():
        tokens=raw.split('#')[0].split()
        if not tokens:continue
        for nf in range(8 if 'nf' in tokens else 1):
            expected[tokens[0],nf]=widths*(2 if 'vm' in tokens else 1)
    log=(folder/'run.log').read_text();records={}
    for name,nf,accepted,illegal in re.findall(
            r'^CATALOG name=(\S+) nf=(\d+) accepted=(\d+) illegal=(\d+)$',log,re.M):
        key=name,int(nf)
        if key in records:raise ValueError('Duplicate catalog witness '+str(key))
        a,b=int(accepted),int(illegal)
        if key not in expected or a+b!=expected[key]:
            raise ValueError('Incorrect variant workload '+str(key))
        records[key]=dict(name=name,nf=int(nf),accepted=a,illegal=b)
    if records.keys()!=expected.keys():raise ValueError('Incomplete catalog variant set')
    missing=[r for r in records.values() if not r['accepted']]
    if cfg['XLEN']==64 and cfg['ELEN']==64 and missing:
        raise ValueError('Baseline has unexecuted variants: '+str(missing))
    summary=re.findall(r'^PASS vector_catalog entries=(\d+) variants=(\d+) cases=(\d+) accepted=(\d+) illegal=(\d+) unexecuted=(\d+)$',log,re.M)
    totals=(375,len(records),sum(expected.values()),sum(r['accepted'] for r in records.values()),
            sum(r['illegal'] for r in records.values()),len(missing))
    if len(summary)!=1 or tuple(map(int,summary[0]))!=totals:
        raise ValueError('Missing or inconsistent completed catalog result')
    completed=re.findall(r'^PASS catalog_top (.+)$',log,re.M)
    if len(completed)!=1:raise ValueError('Missing completed top result')
    fields=dict(item.split('=') for item in completed[0].split())
    if any(int(fields[k])!=cfg[k] for k in ('XLEN','ELEN','VLEN')):
        raise ValueError('Top/manifest parameter mismatch')
    if int(fields['spike_steps'])!=6*totals[2] or int(fields['commands'])!=6*totals[2]:
        raise ValueError('Incomplete catalog/CSR differential steps')
    return dict(scope='Per-encoding execution witnesses and tested effects; not full ISA conformance',
                configuration=cfg,checker_sha256=sha(Path(__file__)),
                reference_manifest_sha256=sha(folder/'reference.json'),
                source_manifest_sha256=sha(folder/'sources.json'),run_sha256=sha(folder/'run.log'),
                totals=dict(zip(('entries','variants','cases','accepted','illegal','unexecuted'),totals)),
                unexecuted=missing,variants=list(records.values()))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path);args=parser.parse_args()
    result=audit(args.directory.resolve())
    (args.directory/'catalog.json').write_text(json.dumps(result,indent=2)+'\n')
    print('PASS catalog audit',json.dumps(result['totals'],sort_keys=True))
