#!/usr/bin/env python3
"""Check device natural-alignment PMA in Bare and translated mappings."""
import argparse,hashlib,json,subprocess,sys
from pathlib import Path


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('npc','reference','mrom','output'):ap.add_argument('--'+name,type=Path,required=True)
    ap.add_argument('--xlen',type=int,choices=(32,64),default=64)
    args=ap.parse_args();root=Path(__file__).resolve().parents[2]
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    report={'xlen':args.xlen,'cases':[]}
    cases=[(0,0),(1,0)]+([(1,1),(1,2)] if args.xlen==64 else [])
    cases=[(m,a,w) for m,a in cases for w in ((2,4,8) if args.xlen==64 else (2,4))]
    for translated,attr,width in cases:
        d=out/f'mmu-{translated}-pbmt-{attr}-bytes-{width}';d.mkdir(exist_ok=True)
        cmd=['riscv64-elf-gcc',f'-march=rv{args.xlen}imac_zicsr_zifencei',
             '-mabi='+('lp64' if args.xlen==64 else 'ilp32'),'-nostdlib','-nostartfiles','-static',
             '-Wl,--no-relax','-T',str(root/'verify/scripts/fuzz_link.ld'),
             f'-DTRANSLATED={translated}',f'-DPAGE_TYPE={attr}',f'-DACCESS_BYTES={width}',str(root/'app/tests/baremetal/mmio_alignment.S'),'-o',str(d/'test.elf')]
        subprocess.run(cmd,check=True)
        subprocess.run(['riscv64-elf-objcopy','-O','binary',str(d/'test.elf'),str(d/'test.bin')],check=True)
        subprocess.run([sys.executable,str(root/'verify/scripts/rva22s64_privileged.py'),
                        '--name','mmio-alignment','--npc',str(args.npc.resolve()),'--reference',str(args.reference.resolve()),
                        '--mrom',str(args.mrom.resolve()),'--image',str(d/'test.bin'),'--output',str(d/'runs')],check=True)
        summary=json.loads((d/'runs/summary.json').read_text())
        assert len(summary['runs'])==6 and all(r['passed'] for r in summary['runs'])
        for x in summary['inputs'].values():assert hashlib.sha256(Path(x['path']).read_bytes()).hexdigest()==x['sha256']
        evidence=[]
        for r in summary['runs']:
            log=Path(r['log']);events=0
            for line in log.read_text().splitlines():
                f=line.split()
                if len(f)==9 and f[0]=='AXI_OBS' and f[2] in ('AR','AW'):
                    events+=1
                    assert not 0xf0001000 <= (int(f[4],16)&0xffffffff) < 0xf0001100, 'faulting access reached device'
            assert events, 'missing AXI observation'
            evidence.append(dict(delay=r['delay'],seed=r['seed'],log=str(log),sha256=hashlib.sha256(log.read_bytes()).hexdigest()))
        report['cases'].append(dict(translated=translated,pbmt=attr,width=width,command=cmd,inputs=summary['inputs'],runs=evidence))
    (out/'alignment-summary.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f'PASS: RV{args.xlen} {len(cases)*6} alignment runs; no device AR/AW')


if __name__=='__main__':main()
