#!/usr/bin/env python3
"""Validate completed FPGA artifacts and vendor-primitive provenance."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('directory',type=Path)
    args=ap.parse_args()
    directory=args.directory.resolve()
    report=json.loads((directory/'summary.json').read_text())
    for source,digest in report['sources'].items():
        if hashlib.sha256((ROOT/source).read_bytes()).hexdigest()!=digest:
            raise ValueError(f'Stale source: {source}')
    netlist=directory/'mapped.json'
    if hashlib.sha256(netlist.read_bytes()).hexdigest()!=report['netlist_sha256']:
        raise ValueError('Mapped netlist differs from recorded artifact')
    design=json.loads(netlist.read_text())
    libraries={}
    counts={}
    for cell in design['modules']['rapt_vpu_core']['cells'].values():
        kind=cell['type']
        counts[kind]=counts.get(kind,0)+1
        if kind.startswith('$') or kind not in design['modules']:
            raise ValueError(f'Unmapped cell: {kind}')
        attrs=design['modules'][kind].get('attributes',{})
        source=Path(attrs.get('src','').split(':')[0]).resolve()
        if source.parent.name!='xilinx' or source.name not in ('cells_sim.v','cells_xtra.v'):
            raise ValueError(f'Nonvendor primitive/blackbox: {kind} from {source}')
        if not int(attrs.get('blackbox','0'),2):
            raise ValueError(f'Primitive model was not finalized: {kind}')
        if str(source) not in libraries:
            libraries[str(source)]=hashlib.sha256(source.read_bytes()).hexdigest()
    if counts!=report['primitives']:
        raise ValueError('Primitive counts differ from summary')
    result=dict(primitive_provenance_checked=True, netlist_sha256=report['netlist_sha256'],
                library_snapshots=libraries,
                checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    (directory/'primitive-check.json').write_text(json.dumps(result,indent=2)+'\n')
    print('PASS primitive provenance',directory.name)


if __name__=='__main__':
    main()
