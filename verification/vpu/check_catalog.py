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
    if (ROOT/'verification/vpu/catalog_entries.h').read_text()!=generate():
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
    for raw in (ROOT/'verification/vpu/vendor/riscv-opcodes/rv_v').read_text().splitlines():
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
    if cfg['ELEN']==64:
        actual={(r['name'],r['nf']) for r in missing}
        index64=('vluxei64.v','vsuxei64.v','vloxei64.v','vsoxei64.v')
        allowed={(name,nf) for name in index64 for nf in range(8)} if cfg['XLEN']==32 else set()
        if actual!=allowed:
            raise ValueError('Unexpected unexecuted V variants: '+str(sorted(actual^allowed)))
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


def audit_matrix(folder):
    """Audit every variant and shard of the expanded differential matrix."""
    if (ROOT / 'verification/vpu/catalog_entries.h').read_text() != generate():
        raise ValueError('Stale generated instruction catalog')
    manifest = fresh(folder / 'sources.json')
    cfg = manifest['configuration']
    if manifest['suite'] != 'catalog-matrix' or cfg['Spike'] != 1 or cfg['CoreAdapter'] != 1:
        raise ValueError('Not a core-facing differential catalog matrix')
    reference = json.loads((folder / 'reference.json').read_text())
    if reference['revision'] != PIN:
        raise ValueError('Wrong pinned reference identity')
    logs = sorted(folder.glob('matrix-shard-*.log'))
    if not logs:
        raise ValueError('No catalog matrix shards')

    instructions = []
    for raw in (ROOT / 'verification/vpu/vendor/riscv-opcodes/rv_v').read_text().splitlines():
        tokens = raw.split('#')[0].split()
        if tokens:
            instructions.append(tokens)
    shards = len(logs)
    seen_shards, records, summaries, seeds, policies = set(), {}, [], set(), set()
    widths = cfg['ELEN'].bit_length() - 3
    index64 = {'vluxei64.v', 'vsuxei64.v', 'vloxei64.v', 'vsoxei64.v'}
    for log_path in logs:
        log = log_path.read_text()
        completion = re.findall(r'^PASS catalog_matrix (.+)$', log, re.M)
        if len(completion) != 1:
            raise ValueError('Missing unique matrix completion: ' + str(log_path))
        fields = dict(item.split('=') for item in completion[0].split())
        if not re.fullmatch(r'[0-9a-f]{16}', fields.get('seed', '')):
            raise ValueError('Missing or invalid matrix seed')
        if not re.fullmatch(r'[0-9a-f]{16}', fields.get('workload_hash', '')):
            raise ValueError('Missing or invalid matrix workload hash')
        seeds.add(fields['seed'])
        if not re.fullmatch(r'[0-3]', fields.get('policy', '')):
            raise ValueError('Missing or invalid matrix policy')
        policies.add(int(fields['policy']))
        shard = int(fields['shard'])
        if int(fields['shards']) != shards or not 0 <= shard < shards or shard in seen_shards:
            raise ValueError('Invalid or duplicated matrix shard')
        seen_shards.add(shard)
        for key in ('XLEN', 'VLEN', 'ELEN'):
            if int(fields[key]) != cfg[key]:
                raise ValueError('Matrix run/manifest parameter mismatch')
        expected = {}
        shard_entries = 0
        for index, tokens in enumerate(instructions):
            if index % shards != shard:
                continue
            shard_entries += 1
            count = widths * 7 * (2 if 'vm' in tokens else 1) * 5
            for nf in range(8 if 'nf' in tokens else 1):
                expected[tokens[0], nf] = count
        current = {}
        pattern = r'^MATRIX name=(\S+) nf=(\d+) cases=(\d+) accepted=(\d+) illegal=(\d+)$'
        for name, nf, cases, accepted, illegal in re.findall(pattern, log, re.M):
            key = name, int(nf)
            cases, accepted, illegal = int(cases), int(accepted), int(illegal)
            if key in current or key not in expected or cases != expected[key]:
                raise ValueError('Incorrect matrix variant workload: ' + str(key))
            if accepted + illegal != cases:
                raise ValueError('Incorrect matrix variant result count: ' + str(key))
            optional = cfg['XLEN'] == 32 and cfg['ELEN'] == 64 and name in index64
            if cfg['ELEN'] == 64 and (accepted == 0) != optional:
                raise ValueError('Missing or unexpected legal matrix witness: ' + str(key))
            current[key] = {'cases': cases, 'accepted': accepted, 'illegal': illegal}
        if current.keys() != expected.keys() or records.keys() & current.keys():
            raise ValueError('Incomplete or duplicated matrix variant set')
        totals = {key: sum(row[key] for row in current.values())
                  for key in ('cases', 'accepted', 'illegal')}
        if any(int(fields[key]) != value for key, value in totals.items()):
            raise ValueError('Incorrect matrix shard totals')
        if int(fields['entries']) != shard_entries or int(fields['commands']) != 7 * totals['cases']:
            raise ValueError('Incomplete matrix execution')
        if int(fields['spike_steps']) != int(fields['commands']):
            raise ValueError('Incomplete Spike matrix execution')
        records.update(current)
        summaries.append({'shard': shard, 'run_sha256': sha(log_path), **totals})
    if seen_shards != set(range(shards)):
        raise ValueError('Missing matrix shard')
    if len(seeds) != 1:
        raise ValueError('Matrix shards use different seeds')
    if len(policies) != 1:
        raise ValueError('Matrix shards use different policies')
    return {
        'scope': 'Encoding/configuration differential matrix; not full ISA conformance',
        'configuration': cfg,
        'checker_sha256': sha(Path(__file__)),
        'source_manifest_sha256': sha(folder / 'sources.json'),
        'reference_manifest_sha256': sha(folder / 'reference.json'),
        'seed': seeds.pop(),
        'policy': policies.pop(),
        'totals': {'entries': len(instructions), 'variants': len(records),
                   **{key: sum(row[key] for row in records.values())
                      for key in ('cases', 'accepted', 'illegal')}},
        'shards': sorted(summaries, key=lambda row: row['shard']),
    }


def audit_indexed_geometry(folder):
    """Audit the exhaustive zero-VL indexed register geometry sweep."""
    manifest = fresh(folder / 'sources.json')
    cfg = manifest['configuration']
    if manifest['suite'] != 'indexed-geometry' or cfg['Spike'] != 1 or cfg['CoreAdapter'] != 1:
        raise ValueError('Not a core-facing indexed geometry run')
    reference = json.loads((folder / 'reference.json').read_text())
    if reference['revision'] != PIN:
        raise ValueError('Wrong pinned reference identity')
    logs = sorted(folder.glob('indexed-geometry-shard-*.log'))
    shards = len(logs)
    if not 1 <= shards <= 32:
        raise ValueError('Invalid indexed geometry shard count')
    summaries, seen = [], set()
    widths = cfg['ELEN'].bit_length() - 3
    for log_path in logs:
        completion = re.findall(r'^PASS indexed_geometry (.+)$', log_path.read_text(), re.M)
        if len(completion) != 1:
            raise ValueError('Missing unique indexed geometry completion')
        fields = dict(item.split('=') for item in completion[0].split())
        shard = int(fields['shard'])
        if int(fields['shards']) != shards or not 0 <= shard < shards or shard in seen:
            raise ValueError('Invalid or duplicated indexed geometry shard')
        seen.add(shard)
        for key in ('XLEN', 'VLEN', 'ELEN'):
            if int(fields[key]) != cfg[key]:
                raise ValueError('Indexed geometry run/manifest parameter mismatch')
        destinations = len(range(shard, 32, shards))
        expected = widths * 7 * 4 * 8 * 2 * 2 * 2 * destinations * 32
        cases = int(fields['cases'])
        accepted, illegal = int(fields['accepted']), int(fields['illegal'])
        if cases != expected or accepted + illegal != cases:
            raise ValueError('Incomplete indexed geometry workload')
        if int(fields['commands']) != cases + widths * 7:
            raise ValueError('Incorrect indexed geometry command count')
        if int(fields['spike_steps']) != int(fields['commands']):
            raise ValueError('Incomplete Spike indexed geometry execution')
        if not re.fullmatch(r'[0-9a-f]{16}', fields.get('workload_hash', '')):
            raise ValueError('Missing or invalid indexed geometry workload hash')
        summaries.append({'shard': shard, 'cases': cases, 'accepted': accepted, 'illegal': illegal,
                          'run_sha256': sha(log_path)})
    if seen != set(range(shards)):
        raise ValueError('Missing indexed geometry shard')
    return {
        'scope': 'Zero-VL indexed register legality; not data execution or full ISA conformance',
        'configuration': cfg,
        'checker_sha256': sha(Path(__file__)),
        'source_manifest_sha256': sha(folder / 'sources.json'),
        'reference_manifest_sha256': sha(folder / 'reference.json'),
        'totals': {key: sum(row[key] for row in summaries)
                   for key in ('cases', 'accepted', 'illegal')},
        'shards': sorted(summaries, key=lambda row: row['shard']),
    }


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--matrix', action='store_true')
    group.add_argument('--indexed-geometry', action='store_true')
    args=parser.parse_args()
    if args.matrix:
        result, output = audit_matrix(args.directory.resolve()), 'catalog-matrix.json'
    elif args.indexed_geometry:
        result, output = audit_indexed_geometry(args.directory.resolve()), 'indexed-geometry.json'
    else:
        result, output = audit(args.directory.resolve()), 'catalog.json'
    (args.directory/output).write_text(json.dumps(result,indent=2)+'\n')
    print('PASS catalog audit',json.dumps(result['totals'],sort_keys=True))
