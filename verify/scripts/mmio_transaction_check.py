#!/usr/bin/env python3
"""Check actual MMIO endpoint effects, not just the architecturally skipped loads/stores."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from svpbmt_axi_check import parse_trace


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('npc','reference','mrom','output'):ap.add_argument('--'+name,type=Path,required=True)
    ap.add_argument('--xlen',type=int,choices=(32,64),default=64)
    ap.add_argument('--uart-read',action='store_true',help='run byte-lane and read-to-clear endpoint checks')
    args=ap.parse_args();root=Path(__file__).resolve().parents[2]
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    report={'xlen':args.xlen,'inputs':{},'runs':[]}
    def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
    for name in ('npc','reference','mrom'):
        p=getattr(args,name).resolve();report['inputs'][name]={'path':str(p),'sha256':sha(p)}
    for name in (('mmio_uart_read',) if args.uart_read else ('mmio_finisher','mmio_litex_uart')):
        d=out/name;d.mkdir(exist_ok=True)
        cmd=['riscv64-elf-gcc',f'-march=rv{args.xlen}imac_zicsr_zifencei',
             '-mabi='+('lp64' if args.xlen==64 else 'ilp32'),'-nostdlib','-nostartfiles','-static',
             '-Wl,--no-relax','-T',str(root/'verify/scripts/fuzz_link.ld'),str(root/f'app/tests/baremetal/{name}.S'),'-o',str(d/'test.elf')]
        subprocess.run(cmd,check=True)
        subprocess.run(['riscv64-elf-objcopy','-O','binary',str(d/'test.elf'),str(d/'test.bin')],check=True)
        for delay in (0,7,63):
            for seed in (1,42):
                log=d/f'delay-{delay}-seed-{seed}.log';err=log.with_suffix('.stderr')
                command=[str(args.npc.resolve()),'-b','-n','--no-lightsss','-t','60',
                         f'--mem-random-delay={delay}',f'--mem-random-seed={seed}',
                         '-d',str(args.reference.resolve()),'-r',str(args.mrom.resolve()),str(d/'test.bin')]
                with log.open('w') as stdout,err.open('w') as stderr:
                    status=subprocess.run(command,cwd=root/'sim',stdout=stdout,stderr=stderr,timeout=90).returncode
                t=log.read_text();tx=err.read_bytes()
                assert status==0 and 'HIT GOOD TRAP' in t and '[ERROR]' not in t,(name,delay,seed,'core failure')
                if name=='mmio_finisher':
                    aw=[l.split() for l in t.splitlines() if l.startswith('AXI_OBS ') and l.split()[2]=='AW' and int(l.split()[4],16)==0x100000]
                    assert len(aw)==2 and [int(f[5],16) for f in aw]==[0,2], 'invalid byte command terminated before word write'
                    assert t.count('Finisher: poweroff (0x5555)')==1, 'missing/duplicate finisher command'
                    assert not tx, ('unexpected stderr',tx)
                elif name=='mmio_uart_read':
                    reads,writes=parse_trace(t)
                    rd=[r for r in reads if 0x10000000 <= (r['addr'] & 0xffffffff) < 0x10000100]
                    wr=[w for w in writes if 0x10000000 <= (w['addr'] & 0xffffffff) < 0x10000100]
                    assert [r['addr'] & 0xff for r in rd]==[7,3,1,5,2,2,7], 'UART read addresses/count/order'
                    assert [w['addr'] & 0xff for w in wr]==[3,2,1,7,0], 'UART write addresses/count/order'
                    assert all(r['size']==0 and r['length']==0 and r['cache']==0 for r in rd+wr), 'UART read/write transfer width/type'
                    assert tx==b'R', ('UART output count',tx)
                else:
                    reads,writes=parse_trace(t)
                    uart=[w for w in writes if 0xf0001000 <= w['addr'] < 0xf0001100]
                    assert len(uart)==2 and all(w['addr']==0xf0001000 and w['size']==2 and w['length']==0 and w['cache']==0 and w['beats'][0]['strb']==15 for w in uart), 'UART AXI transactions'
                    assert tx==b'BA', ('wrong UART side effect bytes',tx)
                report['runs'].append(dict(name=name,delay=delay,seed=seed,command=command,log=str(log),log_sha256=sha(log),stderr=str(err),stderr_sha256=sha(err),image_sha256=sha(d/'test.bin'),elf_sha256=sha(d/'test.elf')))
                print(f'PASS: {name} RV{args.xlen} delay={delay} seed={seed}',flush=True)
    (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
