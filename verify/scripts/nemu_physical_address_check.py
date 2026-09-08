#!/usr/bin/env python3
"""Unmapped high physical addresses must fault, never alias low RAM."""
import argparse
import hashlib
import json
from pathlib import Path
from nemu_reference import Reference


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--xlen',type=int,choices=(32,64),required=True)
    p.add_argument('--reference',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();ref=Reference(a.reference,a.xlen);s=ref.state
    root,middle,leaf,pa,va=0x82000000,0x82001000,0x82002000,0x81000000,0x40000000
    width=a.xlen//8;high=1<<32;rows=[]
    def put(address,value):ref.write(address,value.to_bytes(width,'little'))
    locations=('root','pointer','leaf','bare') if a.xlen==64 else ('root','pointer','leaf')
    for location in locations:
        for kind in ('fetch','load','store'):
            ref.reset()
            for table in (root,middle,leaf):ref.write(table,b'\0'*4096)
            ref.write(pa,(0x13).to_bytes(width,'little'))
            root_pa=root+(high if location=='root' else 0)
            leaf_pa=pa+(high if location=='leaf' else 0)
            if a.xlen==64:
                put(root+8,((middle+(high if location=='pointer' else 0))>>12)<<10|1)
                put(middle,(leaf>>12)<<10|1)
                put(leaf,(leaf_pa>>12)<<10|0xcf)
                s.satp[0]=(8<<60)|(root_pa>>12)
            else:
                put(root+256*4,((leaf+(high if location=='pointer' else 0))>>12)<<10|1)
                put(leaf,(leaf_pa>>12)<<10|0xcf)
                s.satp[0]=(1<<31)|(root_pa>>12)
            operand=va
            if location=='bare':s.satp[0]=0;operand=pa+high
            if kind=='fetch':
                s.priv[0]=b'\x01';s.pc[0]=operand;pc=operand;ref.lib.difftest_exec(1)
            else:
                s.mstatus[0]|=(1<<17)|(1<<11);s.gpr[1]=operand;s.gpr[2]=123
                f=3 if a.xlen==64 else 2
                pc=ref.run([1<<15|f<<12|3<<7|3 if kind=='load' else 2<<20|1<<15|f<<12|0x23])
            actual=[s.mcause[0],s.mtval[0],s.mepc[0],int.from_bytes(ref.read(pa,width),'little')]
            expected=[{'fetch':1,'load':5,'store':7}[kind],operand,pc,0x13]
            rows.append(dict(location=location,kind=kind,actual=actual,expected=expected,passed=actual==expected))
    failures=[r for r in rows if not r['passed']]
    for row in failures:print('FAIL',row)
    a.output.write_text(json.dumps(dict(xlen=a.xlen,reference_sha256=hashlib.sha256(a.reference.read_bytes()).hexdigest(),cases=rows),indent=2)+'\n')
    print(f'RV{a.xlen}: {len(rows)} high-PA checks, {len(failures)} failures')
    return bool(failures)


if __name__=='__main__':raise SystemExit(main())
