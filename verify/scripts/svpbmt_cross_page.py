#!/usr/bin/env python3
"""Build/run all PMA/NC/IO cross-page pairs and check actual AXI transactions."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from svpbmt_axi_check import parse_trace


def check_case(text, first, second, a, b):
    reads, writes = parse_trace(text)
    selected_r = [r for r in reads if first <= r['addr'] < second+4096]
    selected_w = [r for r in writes if first <= r['addr'] < second+4096]
    assert second == first+8192, 'fixture must have a physical gap'
    for r in selected_r+selected_w:
        assert r['addr'] in (first+4088, second), 'wrong physical fragment / accessed gap'
        assert r['length'] == 0 and r['size'] == 3 and 'done' in r, 'fragment burst/size/completion'
        attr = a if r['addr'] == first+4088 else b
        assert attr != 2, 'misaligned access reached IO memory'
        assert r['cache'] == (15 if attr == 0 else 2), 'fragment lost PBMT'
    if 2 in (a,b):
        assert not selected_w, 'faulting store partially wrote memory'
        # The first non-IO fragment of a load may be read before discovering
        # the second-page access fault. Do not require rollback of that read.
        assert all(r['addr'] == first+4088 for r in selected_r), 'faulting load read second page'
        assert len(selected_r) <= 1, 'faulting load repeated first fragment'
    else:
        assert Counter(r['addr'] for r in selected_w) == Counter({first+4088:1, second:1}), 'split store count'
        for r in selected_w:
            low = r['addr'] == first+4088
            mask = 0xe0 if low else 0x1f
            data = 0xabcdef0000000000 if low else 0x123456789
            bitmask = 0xffffff0000000000 if low else 0xffffffffff
            beat = r['beats'][0]
            assert beat['strb'] == mask and beat['data'] & bitmask == data, 'split store lanes/data'
        # Initial load is cold. The second load may hit PMA, but NC must issue
        # again; check both per-fragment properties instead of global counts.
        for addr, attr in [(first+4088,a),(second,b)]:
            n = sum(r['addr']==addr for r in selected_r)
            assert n in ((2,) if attr == 1 else (1,2)), 'split load cache/bypass count'
    return dict(data_reads=len(selected_r), data_writes=len(selected_w))


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('npc','reference','mrom','output'):
        ap.add_argument('--'+name,type=Path,required=True)
    ap.add_argument('--cc',default='riscv64-elf-gcc')
    ap.add_argument('--objcopy',default='riscv64-elf-objcopy')
    ap.add_argument('--nm',default='riscv64-elf-nm')
    args=ap.parse_args()
    root=Path(__file__).resolve().parents[2]
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    report={'name':'svpbmt-cross-page','cases':[], 'sources':{}}
    for name in ('app/tests/baremetal/svpbmt_cross_page.S','verify/scripts/svpbmt_cross_page.py',
                 'verify/scripts/svpbmt_axi_check.py','verify/scripts/fuzz_link.ld'):
        report['sources'][name]=hashlib.sha256((root/name).read_bytes()).hexdigest()
    for a in range(3):
        for b in range(3):
            d=out/f'type-{a}-{b}';d.mkdir(exist_ok=True)
            compile_command=[args.cc,'-march=rv64imac_zicsr_zifencei','-mabi=lp64',
                             '-nostdlib','-nostartfiles','-static','-Wl,--no-relax','-T',
                             str(root/'verify/scripts/fuzz_link.ld'),f'-DPBMT_FIRST={a}',
                             f'-DPBMT_SECOND={b}',str(root/'app/tests/baremetal/svpbmt_cross_page.S'),'-o',str(d/'test.elf')]
            subprocess.run(compile_command,check=True)
            subprocess.run([args.objcopy,'-O','binary',str(d/'test.elf'),str(d/'test.bin')],check=True)
            subprocess.run([sys.executable,str(root/'verify/scripts/rva22s64_privileged.py'),
                            '--name','svpbmt-cross-page','--npc',str(args.npc.resolve()),
                            '--reference',str(args.reference.resolve()),'--mrom',str(args.mrom.resolve()),
                            '--image',str(d/'test.bin'),'--output',str(d/'runs')],check=True)
            symbols={}
            for line in subprocess.check_output([args.nm,'-n',str(d/'test.elf')],text=True).splitlines():
                f=line.split()
                if len(f)==3 and f[2] in ('payload_first','payload_second'):symbols[f[2]]=int(f[0],16)
            summary=json.loads((d/'runs/summary.json').read_text())
            assert len(summary['runs'])==6 and all(r['passed'] for r in summary['runs'])
            for x in summary['inputs'].values():
                assert hashlib.sha256(Path(x['path']).read_bytes()).hexdigest()==x['sha256'], 'input drift'
            case={'first':a,'second':b,'compile_command':compile_command,'symbols':symbols,
                  'inputs':summary['inputs'],'elf_sha256':hashlib.sha256((d/'test.elf').read_bytes()).hexdigest(),'runs':[]}
            for run in summary['runs']:
                log=Path(run['log']);t=log.read_text()
                assert 'HIT GOOD TRAP' in t and '[ERROR]' not in t
                counts=check_case(t,symbols['payload_first'],symbols['payload_second'],a,b)
                case['runs'].append(dict(delay=run['delay'],seed=run['seed'],log=str(log),
                                        sha256=hashlib.sha256(log.read_bytes()).hexdigest(),**counts))
            report['cases'].append(case)
            print(f'PASS: PBMT {a}/{b} architecture and external transactions',flush=True)
    (out/'matrix-summary.json').write_text(json.dumps(report,indent=2)+'\n')
    print('PASS: 9 type pairs, 54 whole-core runs with AXI checks')


if __name__=='__main__':
    main()
