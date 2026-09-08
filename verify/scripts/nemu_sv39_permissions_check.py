#!/usr/bin/env python3
"""Sv39/Svade permission matrix using real reference instruction execution."""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
from nemu_reference import Reference


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--reference',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args()
    ref=Reference(a.reference,64);s=ref.state
    root,middle,leaf=0x82000000,0x82001000,0x82002000
    va,pa=0x41000000,0x81000000
    for table in (root,middle,leaf):ref.write(table,b'\0'*4096)
    rows=[]
    def put(address,value):ref.write(address,value.to_bytes(8,'little'))
    # Profile-required AD faults, U/S permissions, SUM/MXR, and all leaf sizes.
    for level,rwx,u,ad,priv,sum_,mxr,kind in itertools.product(range(3),range(8),range(2),range(4),(0,1),range(2),range(2),('fetch','load','store','cmo')):
        ref.reset()
        put(root+8,(middle>>12)<<10|1)
        put(middle+8*8,(leaf>>12)<<10|1)
        pte_pa=0x80000000 if level==2 else pa
        pte=(pte_pa>>12)<<10|1|(rwx<<1)|(u<<4)|(ad<<6)
        put((leaf,middle+8*8,root+8)[level],pte)
        put(pa,0x13)
        s.satp[0]=(8<<60)|(root>>12)
        s.mstatus[0]|=(sum_<<18)|(mxr<<19)
        s.gpr[1]=va
        read,write,execute=bool(rwx&1),bool(rwx&2),bool(rwx&4)
        valid=(read or execute) and (not write or read)
        permission=(bool(u) if priv==0 else (not u or (kind!='fetch' and sum_)))
        access={'fetch':execute,'load':read or (mxr and execute),'store':write,'cmo':read or write or (mxr and execute)}[kind]
        allowed=bool(valid and permission and access and (ad&1) and (kind!='store' or (ad&2)))
        if kind=='fetch':
            s.priv[0]=bytes([priv]);s.pc[0]=va;pc=va;ref.lib.difftest_exec(1)
        else:
            s.mstatus[0]|=(1<<17)|(priv<<11)
            insn={'load':0x0000b183,'store':0x0020b023,'cmo':0x0010a00f}[kind]
            pc=ref.run([insn])
        actual=[s.pc[0],s.mcause[0],s.mtval[0],s.minstret[0]]
        expected=[pc+4,0,0,101] if allowed else [0x80ff0000,{'fetch':12,'load':13,'store':15,'cmo':15}[kind],va,100]
        # Svade must leave every PTE byte unchanged, including on a store.
        observed_pte=int.from_bytes(ref.read((leaf,middle+8*8,root+8)[level],8),'little')
        passed=actual==expected and observed_pte==pte
        rows.append(dict(level=level,rwx=rwx,u=u,ad=ad,priv=priv,sum=sum_,mxr=mxr,kind=kind,actual=actual,expected=expected,pte_unchanged=observed_pte==pte,passed=passed))
    failures=[row for row in rows if not row['passed']]
    for row in failures[:10]:print('FAIL',row)
    report=dict(reference_sha256=hashlib.sha256(a.reference.read_bytes()).hexdigest(),
                checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                cases=rows,failures=len(failures))
    a.output.write_text(json.dumps(report,indent=2)+'\n')
    print(f'Sv39: {len(rows)} permission/AD cases, {len(failures)} failures')
    return bool(failures)


if __name__=='__main__':raise SystemExit(main())
