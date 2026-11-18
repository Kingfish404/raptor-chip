#!/usr/bin/env python3
"""Negative checks against isolated catalog evidence copies."""
import argparse
import json
from pathlib import Path
import re
import shutil
import tempfile
from check_catalog import audit, audit_indexed_geometry, audit_matrix, ROOT

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--directory',type=Path,
                    default=ROOT/'verification/build/vpu/core-top-64-128-64-64-2-opt1-spike-catalog')
group = parser.add_mutually_exclusive_group()
group.add_argument('--matrix', action='store_true')
group.add_argument('--indexed-geometry', action='store_true')
args = parser.parse_args()
source=args.directory.resolve()
if args.indexed_geometry:
    audit_indexed_geometry(source)
    for mutation in ('missing_shard', 'wrong_total', 'missing_completion'):
        with tempfile.TemporaryDirectory(prefix='vpu-indexed-', dir='/tmp') as temp:
            directory = Path(temp)
            for name in ('sources.json', 'reference.json'):
                shutil.copyfile(source / name, directory / name)
            for log in source.glob('indexed-geometry-shard-*.log'):
                shutil.copyfile(log, directory / log.name)
            logs = sorted(directory.glob('indexed-geometry-shard-*.log'))
            if mutation == 'missing_shard':
                logs[-1].unlink()
            else:
                log = logs[0].read_text()
                if mutation == 'wrong_total':
                    log = re.sub(r'(^PASS indexed_geometry .+ cases=)(\d+)',
                                 lambda match: match[1] + str(int(match[2]) + 1),
                                 log, count=1, flags=re.M)
                else:
                    log = re.sub(r'^PASS indexed_geometry .+\n', '', log, flags=re.M)
                logs[0].write_text(log)
            try:
                audit_indexed_geometry(directory)
            except ValueError as error:
                print('PASS rejected', mutation, ':', error)
            else:
                raise RuntimeError('Accepted invalid indexed geometry evidence: ' + mutation)
    raise SystemExit(0)
if args.matrix:
    audit_matrix(source)
    mutations = ['missing_variant', 'missing_shard', 'wrong_total', 'missing_completion']
    if len(list(source.glob('matrix-shard-*.log'))) > 1:
        mutations.append('wrong_policy')
    for mutation in mutations:
        with tempfile.TemporaryDirectory(prefix='vpu-matrix-', dir='/tmp') as temp:
            directory = Path(temp)
            for name in ('sources.json', 'reference.json'):
                shutil.copyfile(source / name, directory / name)
            for log in source.glob('matrix-shard-*.log'):
                shutil.copyfile(log, directory / log.name)
            logs = sorted(directory.glob('matrix-shard-*.log'))
            if mutation == 'missing_shard':
                logs[-1].unlink()
            else:
                log = logs[0].read_text()
                if mutation == 'missing_variant':
                    log = re.sub(r'^MATRIX .+\n', '', log, count=1, flags=re.M)
                elif mutation == 'wrong_total':
                    log = re.sub(r'(^PASS catalog_matrix .+ cases=)(\d+)',
                                 lambda match: match[1] + str(int(match[2]) + 1),
                                 log, count=1, flags=re.M)
                elif mutation == 'wrong_policy':
                    log = re.sub(r'(^PASS catalog_matrix .+ policy=)([0-3])$',
                                 lambda match: match[1] + str((int(match[2]) + 1) % 4),
                                 log, count=1, flags=re.M)
                else:
                    log = re.sub(r'^PASS catalog_matrix .+\n', '', log, flags=re.M)
                logs[0].write_text(log)
            try:
                audit_matrix(directory)
            except ValueError as error:
                print('PASS rejected', mutation, ':', error)
            else:
                raise RuntimeError('Accepted invalid matrix evidence: ' + mutation)
    raise SystemExit(0)
audit(source)
config=json.loads((source/'sources.json').read_text())['configuration']
mutations=['missing_variant','no_execution','missing_completion']
if config['XLEN']==32 and config['ELEN']==64:
    mutations.append('unsupported_index_accepted')
for mutation in mutations:
    with tempfile.TemporaryDirectory(prefix='vpu-catalog-',dir='/tmp') as temp:
        directory=Path(temp)
        shutil.copyfile(source/'sources.json',directory/'sources.json')
        shutil.copyfile(source/'reference.json',directory/'reference.json')
        log=(source/'run.log').read_text()
        if mutation=='missing_variant':
            log=re.sub(r'^CATALOG .+\n','',log,count=1,flags=re.M)
        elif mutation=='no_execution':
            def replace(match):
                return match[1]+'0 illegal='+str(int(match[2])+int(match[3]))
            log=re.sub(r'(^CATALOG name=\S+ nf=\d+ accepted=)(\d+) illegal=(\d+)',
                       replace,log,count=1,flags=re.M)
        elif mutation=='missing_completion':
            log=re.sub(r'^PASS catalog_top .+\n','',log,flags=re.M)
        else:
            pattern=r'(^CATALOG name=vluxei64\.v nf=0 accepted=)0 illegal=(\d+)'
            log,count=re.subn(pattern,lambda match:match[1]+'1 illegal='+str(int(match[2])-1),
                              log,count=1,flags=re.M)
            if count!=1:raise RuntimeError('Missing RV32 64-bit-index witness')
        (directory/'run.log').write_text(log)
        try:audit(directory)
        except ValueError as error:print('PASS rejected',mutation,':',error)
        else:raise RuntimeError('Accepted invalid catalog evidence: '+mutation)
