#!/usr/bin/env python3
"""Compare completed reduction cache runs; reject stale or mismatched evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=root/'verify/build/vpu')
    args = parser.parse_args()
    rows = []
    for xlen, vlen, elen in ((64, 128, 64), (32, 128, 32),
                              (32, 256, 64), (64, 512, 64)):
        pair = []
        for cache in (0, 1):
            folder = args.build_dir/f'fp-reduce-engine-{xlen}-{vlen}-{elen}-cache{cache}'
            manifest = json.loads((folder/'sources.json').read_text())
            expected = dict(XLEN=xlen, VLEN=vlen, ELEN=elen, CacheMask=cache)
            if manifest['top'] != 'rapt_vpu_fp_reduce_engine' or manifest['parameters'] != expected:
                raise ValueError(f'{folder}: wrong module or parameters')
            for source, digest in manifest['sources'].items():
                if hashlib.sha256((root/source).read_bytes()).hexdigest() != digest:
                    raise ValueError(f'{folder}: stale source {source}')
            matches = re.findall(r'^PASS fp_reduce_engine (.+)$',
                                 (folder/'run.log').read_text(), re.M)
            if len(matches) != 1:
                raise ValueError(f'{folder}: expected one completed PASS record')
            fields = dict(item.split('=') for item in matches[0].split())
            for key, value in dict(XLEN=xlen, VLEN=vlen, ELEN=elen, cache=cache).items():
                if int(fields[key]) != value:
                    raise ValueError(f'{folder}: wrong run parameter {key}')
            if int(fields['cases']) != 4450 or int(fields['reset_boundaries']) != 64:
                raise ValueError(f'{folder}: incomplete workload')
            pair.append(dict(fields=fields, manifest=manifest))
        a, b = [entry['fields'] for entry in pair]
        for key in ('fingerprint', 'seed', 'cases', 'reset_boundaries'):
            if a[key] != b[key]:
                raise ValueError(f'{xlen}/{vlen}/{elen}: different {key}')
        if pair[0]['manifest']['sources'] != pair[1]['manifest']['sources']:
            raise ValueError('Baseline and optimized runs used different sources')
        if pair[0]['manifest']['verilator'] != pair[1]['manifest']['verilator']:
            raise ValueError('Baseline and optimized runs used different Verilator versions')
        row = dict(XLEN=xlen, VLEN=vlen, ELEN=elen, fingerprint=a['fingerprint'])
        for metric in ('cycles', 'reads'):
            baseline, optimized = int(a[metric]), int(b[metric])
            if not 0 < optimized < baseline:
                raise ValueError(f'{xlen}/{vlen}/{elen}: no {metric} improvement')
            row[metric] = dict(baseline=baseline, optimized=optimized,
                               reduction_percent=100*(baseline-optimized)/baseline)
        rows.append(row)
    print(json.dumps(dict(scope='Mock-service reduction sequencer workload; not full-VPU speedup',
                          configurations=rows), indent=2))


if __name__ == '__main__':
    main()
