#!/usr/bin/env python3
"""Independent functional regression for NEMU's RVA22 mandatory scalar paths.

This is a directed/random architectural regression, not profile certification.
Integer expectations use Python arithmetic; no RTL or NEMU semantic imports.
"""
import argparse
import hashlib
import json
import random
import struct
from pathlib import Path
from nemu_reference import Reference


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    p.add_argument('--reference', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--mcountinhibit', choices=('absent', 'zero'), default='zero',
                   help='Expected optional CSR policy: profile preset zero, legacy absent')
    a = p.parse_args()
    ref = Reference(a.reference, a.xlen)
    s, x, mask = ref.state, a.xlen, ref.mask
    rows = []
    def check(name, actual, expected):
        rows.append(dict(name=name, actual=actual, expected=expected, passed=actual == expected))
    def signed(v, bits=x):
        v &= (1 << bits) - 1
        return v - (1 << bits) if v >> (bits - 1) else v
    def r(f7, f3, op=0x33, rs2=2):
        return f7 << 25 | rs2 << 20 | 1 << 15 | f3 << 12 | 3 << 7 | op
    def rotate(v, n, bits=x):
        n %= bits
        return ((v >> n) | (v << ((bits - n) % bits))) & ((1 << bits) - 1)
    def div(v, w, bits=x):
        v, w = signed(v, bits), signed(w, bits)
        if w == 0: return -1
        q = abs(v) // abs(w)
        return -q if (v < 0) != (w < 0) else q
    def rem(v, w, bits=x):
        v, w = signed(v, bits), signed(w, bits)
        return v if w == 0 else v - div(v, w, bits) * w
    binary = [
        ('add', r(0,0), lambda v,w:v+w), ('sub',r(32,0),lambda v,w:v-w),
        ('sll',r(0,1),lambda v,w:v<<(w%(x))), ('srl',r(0,5),lambda v,w:v>>(w%x)),
        ('sra',r(32,5),lambda v,w:signed(v)>>(w%x)),
        ('slt',r(0,2),lambda v,w:int(signed(v)<signed(w))), ('sltu',r(0,3),lambda v,w:int(v<w)),
        ('xor',r(0,4),lambda v,w:v^w), ('or',r(0,6),lambda v,w:v|w), ('and',r(0,7),lambda v,w:v&w),
        ('mul',r(1,0),lambda v,w:v*w), ('mulh',r(1,1),lambda v,w:(signed(v)*signed(w))>>x),
        ('mulhsu',r(1,2),lambda v,w:(signed(v)*w)>>x), ('mulhu',r(1,3),lambda v,w:(v*w)>>x),
        ('div',r(1,4),div), ('divu',r(1,5),lambda v,w:v//w if w else mask),
        ('rem',r(1,6),rem), ('remu',r(1,7),lambda v,w:v%w if w else v),
        ('andn',r(32,7),lambda v,w:v&~w), ('orn',r(32,6),lambda v,w:v|~w), ('xnor',r(32,4),lambda v,w:~(v^w)),
        ('min',r(5,4),lambda v,w:min(signed(v),signed(w))), ('max',r(5,6),lambda v,w:max(signed(v),signed(w))),
        ('minu',r(5,5),min), ('maxu',r(5,7),max),
        ('rol',r(48,1),lambda v,w:rotate(v,-w)), ('ror',r(48,5),rotate),
        ('bclr',r(36,1),lambda v,w:v&~(1<<(w%x))), ('bext',r(36,5),lambda v,w:(v>>(w%x))&1),
        ('binv',r(52,1),lambda v,w:v^(1<<(w%x))), ('bset',r(20,1),lambda v,w:v|(1<<(w%x))),
    ]
    for shift, f in ((1,2),(2,4),(3,6)):
        binary.append((f'sh{shift}add',r(16,f),lambda v,w,n=shift:(v<<n)+w))
        if x == 64:
            binary.append((f'sh{shift}add.uw',r(16,f,0x3b),lambda v,w,n=shift:((v&0xffffffff)<<n)+w))
    if x == 64:
        binary += [('add.uw',r(4,0,0x3b),lambda v,w:(v&0xffffffff)+w),
                   ('addw',r(0,0,0x3b),lambda v,w:signed(v+w,32)),
                   ('subw',r(32,0,0x3b),lambda v,w:signed(v-w,32)),
                   ('mulw',r(1,0,0x3b),lambda v,w:signed(v*w,32)),
                   ('divw',r(1,4,0x3b),lambda v,w:signed(div(v,w,32),32)),
                   ('divuw',r(1,5,0x3b),lambda v,w:signed((v&0xffffffff)//(w&0xffffffff) if w&0xffffffff else -1,32)),
                   ('remw',r(1,6,0x3b),lambda v,w:signed(rem(v,w,32),32)),
                   ('remuw',r(1,7,0x3b),lambda v,w:signed((v&0xffffffff)%(w&0xffffffff) if w&0xffffffff else v,32)),
                   ('rolw',r(48,1,0x3b),lambda v,w:signed(rotate(v&0xffffffff,-w,32),32)),
                   ('rorw',r(48,5,0x3b),lambda v,w:signed(rotate(v&0xffffffff,w,32),32))]
    rng = random.Random(220064)
    edges = [0,1,mask,mask>>1,1<<(x-1),31,32,63,64,0x80000000,0xffffffff]
    pairs = [(v,w) for v in edges for w in edges] + [(rng.getrandbits(x),rng.getrandbits(x)) for _ in range(64)]
    ref.reset()
    for name, insn, oracle in binary:
        for v,w in pairs:
            s.gpr[1],s.gpr[2] = v,w
            pc = ref.run([insn])
            check(name,[s.gpr[3],s.pc[0]],[oracle(v,w)&mask,pc+4])
    unary = [('clz',0x60001013,lambda v:x-v.bit_length()),
             ('ctz',0x60101013,lambda v:(v&-v).bit_length()-1 if v else x),
             ('cpop',0x60201013,int.bit_count), ('sext.b',0x60401013,lambda v:signed(v,8)),
             ('sext.h',0x60501013,lambda v:signed(v,16)),
             ('orc.b',0x28705013,lambda v:sum((255 if (v>>(8*i))&255 else 0)<<(8*i) for i in range(x//8))),
             ('rev8',0x69805013 if x==32 else 0x6b805013,lambda v:int.from_bytes(v.to_bytes(x//8,'little'),'big'))]
    for name,base,oracle in unary:
        for v in edges + [rng.getrandbits(x) for _ in range(64)]:
            s.gpr[1]=v
            pc=ref.run([base|1<<15|3<<7])
            check(name,[s.gpr[3],s.pc[0]],[oracle(v)&mask,pc+4])
    # HINTs and instruction/translation fences must preserve registers.
    for insn in (0x0100000f,0x8330000f,0x0000100f,0x12000073,0x16000073,0x18000073,0x18100073,
                 0x0000e013,0x0010e013,0x0030e013):
        ref.reset();s.gpr[1]=mask;s.gpr[3]=123
        pc=ref.run([insn]);check('hint/fence',[s.pc[0],s.gpr[3]],[pc+4,123])
    # M/S/U CSR permissions, base-counter enable bits and HPM WARL-zero.
    for priv in (0,1,3):
        for men in (0,7):
            for sen in (0,7):
                for csr in (0xc00,0xc01,0xc02,0xc03,0xc1f,0xb03,0xb1f,0x323,0x33f,0x100,0x300):
                    ref.reset();s.mcounteren[0]=men;s.scounteren[0]=sen;s.priv[0]=bytes([priv])
                    insn=csr<<20|3<<7|0x2073
                    pc=ref.run([insn])
                    allowed=priv>=((csr>>8)&3)
                    if csr in (0xc00,0xc01,0xc02) and priv!=3: allowed=bool(men and (priv!=0 or sen))
                    if csr in (0xc03,0xc1f) and priv!=3: allowed=False
                    check('csr-access',[s.pc[0],s.mcause[0]],[pc+4,0] if allowed else [0x80ff0000,2])
                    if allowed and csr in (0xc03,0xc1f,0xb03,0xb1f,0x323,0x33f):check('hpm-zero',s.gpr[3],0)
    if x==64:
        ref.reset();s.gpr[1]=mask
        if a.mcountinhibit == 'zero':
            pc=ref.run([0x32009073,0x320021f3])
            check('profile-mcountinhibit-warl-zero',[s.gpr[3],s.pc[0],s.minstret[0]],[0,pc+8,102])
        else:
            pc=ref.run([0x32009073])
            check('legacy-mcountinhibit-absent',
                  [s.mcause[0],s.mtval[0],s.mepc[0],s.minstret[0]],
                  [2,0x32009073,pc,100])
    # Ordinary RAM misalignment and AMO arithmetic (aq/rl combinations).
    address=0x81000000
    for width in ((4,8) if x==64 else (4,)):
        bits=width*8;wm=(1<<bits)-1;f=2 if width==4 else 3
        for offset in range(16):
            ref.reset();s.gpr[1]=address+offset;s.gpr[2]=mask
            ref.run([2<<20|1<<15|f<<12|0x23,1<<15|f<<12|3<<7|3])
            check('misaligned-ram',[s.gpr[3],ref.read(address+offset,width).hex()],[mask,('ff'*width)])
        ops=[(0,lambda v,w:v+w),(1,lambda v,w:w),(4,lambda v,w:v^w),(8,lambda v,w:v|w),(12,lambda v,w:v&w),
             (16,lambda v,w:min(signed(v,bits),signed(w,bits))),(20,lambda v,w:max(signed(v,bits),signed(w,bits))),
             (24,min),(28,max)]
        for op,oracle in ops:
            for aqrl in range(4):
                for v,w in ((0,1),(wm,1),(1<<(bits-1),wm),(wm>>1,1<<(bits-1))):
                    ref.reset();s.gpr[1]=address;s.gpr[2]=w
                    ref.write(address,v.to_bytes(width,'little'))
                    insn=op<<27|aqrl<<25|2<<20|1<<15|f<<12|3<<7|0x2f
                    pc=ref.run([insn]);actual=int.from_bytes(ref.read(address,width),'little')
                    check('amo',[s.gpr[3],actual,s.pc[0]],[signed(v,bits)&mask,oracle(v,w)&wm,pc+4])
        ref.reset();s.gpr[1]=address;s.gpr[2]=42
        lr=2<<27|1<<15|f<<12|3<<7|0x2f;sc=3<<27|2<<20|1<<15|f<<12|3<<7|0x2f
        ref.run([lr,sc]);check('lr-sc-success',[s.gpr[3],int.from_bytes(ref.read(address,width),'little')],[0,42])
        ref.run([sc]);check('sc-consumes-reservation',s.gpr[3],1)
    if x==32:
        for op in (0,1,2,3,4,8,12,16,20,24,28):
            ref.reset();s.gpr[1]=address
            insn=op<<27|(0 if op==2 else 2<<20)|1<<15|3<<12|3<<7|0x2f
            ref.run([insn]);check('rv32-reject-amo.d',s.mcause[0],2)
    # CMO zero affects exactly one naturally aligned 64-byte block.
    for offset in (0,1,31,63):
        ref.reset();ref.write(address,b'\xa5'*192);s.gpr[1]=address+64+offset
        pc=ref.run([0x0040a00f])
        check('cbo.zero',[ref.read(address,192).hex(),s.pc[0]],[(b'\xa5'*64+b'\0'*64+b'\xa5'*64).hex(),pc+4])
    for priv in (0,1,3):
        for enable in (0,0xf0):
            for insn in (0x0000a00f,0x0010a00f,0x0020a00f,0x0040a00f):
                ref.reset();s.gpr[1]=address;s.menvcfg[0]=enable
                # senvcfg set via real CSR instruction, absent from NPCState.
                s.gpr[2]=enable;ref.run([0x10a11073]);s.priv[0]=bytes([priv])
                pc=ref.run([insn]);ok=priv==3 or bool(enable)
                check('cmo-permission',[s.pc[0],s.mcause[0]],[pc+4,0] if ok else [0x80ff0000,2])
    # Exact binary FP vectors across all five standard rounding modes.
    # Memory transport exercises FLW/FLD, NaN boxing and FSW/FSD on both XLENs.
    for fmt,pack,width in ((0,'f',4),(1,'d',8)):
        f=2+fmt
        for op,expected in ((0,3.5),(4,-0.5),(8,3.0),(12,0.75)):
            for rm in range(5):
                ref.reset();s.gpr[1]=address
                ref.write(address,struct.pack('<'+pack,1.5).ljust(8,b'\0')+struct.pack('<'+pack,2.0))
                insn=(op+fmt)<<25|2<<20|1<<15|rm<<12|3<<7|0x53
                seq=[0x00301073,1<<15|f<<12|1<<7|7,8<<20|1<<15|f<<12|2<<7|7,
                     insn,3<<20|1<<15|f<<12|16<<7|0x27,0x00102273]
                pc=ref.run(seq)
                check('fp-exact',[ref.read(address+16,width).hex(),s.gpr[4],s.pc[0]],
                      [struct.pack('<'+pack,expected).hex(),0,pc+4*len(seq)])
        # Signaling NaN arithmetic raises NV and produces canonical NaN.
        snan=0x7f800001 if fmt==0 else 0x7ff0000000000001
        canonical=0x7fc00000 if fmt==0 else 0x7ff8000000000000
        ref.reset();s.gpr[1]=address
        ref.write(address,snan.to_bytes(width,'little').ljust(8,b'\0')+struct.pack('<'+pack,1.0))
        ref.run([0x00301073,1<<15|f<<12|1<<7|7,8<<20|1<<15|f<<12|2<<7|7,
                 fmt<<25|2<<20|1<<15|3<<7|0x53,3<<20|1<<15|f<<12|16<<7|0x27,0x00102273])
        check('fp-snan',[int.from_bytes(ref.read(address+16,width),'little'),s.gpr[4]],[canonical,16])
    # Finite binary16 values convert exactly to binary32 and back.
    # A representative special/boundary set checks infinities, signed zero,
    # subnormals and NaN canonicalization without sharing SoftFloat code.
    for half in (0,0x8000,1,0x3ff,0x400,0x3c00,0x7bff,0x7c00,0xfc00,0x7e00,0x7c01):
        ref.reset();s.gpr[1]=address;ref.write(address,half.to_bytes(2,'little'))
        ref.run([0x00301073,0x00009087,0x40208153,0x440101d3,0x00309827,0x00102273])
        nan=(half&0x7c00)==0x7c00 and half&0x3ff
        expected=0x7e00 if nan else half
        flags=16 if nan and not half&0x200 else 0
        check('zfhmin-roundtrip',[int.from_bytes(ref.read(address+16,2),'little'),s.gpr[4]],[expected,flags])
    for insn in (0x00009087,0x0000a087,0x0000b087,0x002081d3,0x022081d3,0x40208153,0x00102273):
        ref.reset();s.mstatus[0]&=~0x6000;s.gpr[1]=address
        pc=ref.run([insn]);check('fp-fs-off',[s.mcause[0],s.mtval[0],s.minstret[0]],[2,insn,100])
    # A privilege-changing instruction must not refill its old fetch into
    # the new decode-cache epoch. MRET targets itself in U mode, where PMP
    # denies execute; reusing the M-mode decoded MRET would give cause 2.
    ref.reset();s.gpr[1]=11;ref.run([0x3a009073])
    s.mstatus[0]&=~(3<<11);s.mepc[0]=ref.next_pc
    pc=ref.run([0x30200073]);ref.lib.difftest_exec(1)
    check('xret-fetch-permission',[s.mcause[0],s.mtval[0],s.mepc[0]],[1,pc,pc])
    s.gpr[1]=15;ref.run([0x3a009073])
    if x == 64:
        # Translated CMO denied by PMP must report the *virtual* operand.
        ref.reset()
        root, middle, leaf, va = 0x82000000, 0x82001000, 0x82002000, 0x40000000
        for table in (root,middle,leaf):ref.write(table,b'\0'*4096)
        ref.write(root+8,((middle>>12)<<10|1).to_bytes(8,'little'))
        ref.write(middle,((leaf>>12)<<10|1).to_bytes(8,'little'))
        ref.write(leaf,((address>>12)<<10|0xcf).to_bytes(8,'little'))
        s.gpr[1]=address>>2;ref.run([0x3b009073])
        s.gpr[1]=mask;ref.run([0x3b109073])
        s.gpr[1]=0x0f10;ref.run([0x3a009073])
        s.satp[0]=(8<<60)|(root>>12)
        s.mstatus[0]|=(1<<17)|(1<<11)
        s.gpr[1]=va
        pc=ref.run([0x0010a00f])
        check('cmo-pmp-virtual-tval',[s.mcause[0],s.mtval[0],s.mepc[0]],[7,va,pc])
    failures=[row for row in rows if not row['passed']]
    report=dict(xlen=x,seed=220064,mcountinhibit=a.mcountinhibit,
                reference_sha256=hashlib.sha256(a.reference.read_bytes()).hexdigest(),
                checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                adapter_sha256=hashlib.sha256(Path(__file__).with_name('nemu_reference.py').read_bytes()).hexdigest(),
                cases=rows,failures=len(failures))
    a.output.write_text(json.dumps(report,indent=2)+'\n')
    for row in failures[:20]:print('FAIL',row)
    print(f'RV{x}: {len(rows)} scalar/profile checks, {len(failures)} failures')
    return bool(failures)


if __name__=='__main__':raise SystemExit(main())
