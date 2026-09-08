#!/usr/bin/env python3
"""Independent integer-math oracle for assembled Zba/Zbb/Zbs ALU vectors."""
import argparse,json,random,subprocess,hashlib
from pathlib import Path

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--xlen',type=int,choices=[32,64],required=True);ap.add_argument('--output',type=Path,required=True);a=ap.parse_args();x=a.xlen;p=a.output;p.mkdir(parents=True,exist_ok=True);mask=(1<<x)-1
 binary=['sh1add','sh2add','sh3add','andn','orn','xnor','min','max','minu','maxu','rol','ror','bset','bclr','binv','bext']
 unary=['clz','ctz','cpop','sext.b','sext.h','zext.h','orc.b','rev8']
 imm=['rori','bseti','bclri','binvi','bexti']
 if x==64:binary+=['add.uw','sh1add.uw','sh2add.uw','sh3add.uw','rolw','rorw'];unary+=['clzw','ctzw','cpopw'];imm+=['slli.uw','roriw']
 def signed(v,w):return (v&((1<<(w-1))-1))-(v&(1<<(w-1)))
 def oracle(op,u,v):
  width=32 if op in ['rolw','rorw','roriw','clzw','ctzw','cpopw'] else x
  val=u&((1<<width)-1);n=v%width
  if op.startswith('sh') and 'add' in op:return ((u&0xffffffff if '.uw' in op else u)<<int(op[2]))+v
  if op=='add.uw':return (u&0xffffffff)+v
  if op=='slli.uw':return (u&0xffffffff)<<v
  if op=='andn':return u&~v
  if op=='orn':return u|~v
  if op=='xnor':return ~(u^v)
  if op in ['min','max','minu','maxu']:
   aa,bb=(u,v) if op.endswith('u') else (signed(u,x),signed(v,x));return (min if op.startswith('min') else max)(aa,bb)
  if op.startswith(('rol','ror')):
   bits=[(val>>i)&1 for i in range(width)];result=sum(bits[(i-n)%width if op.startswith('rol') else (i+n)%width]<<i for i in range(width));return signed(result,32) if width==32 and x==64 else result
  if op.startswith('clz'):return width-val.bit_length()
  if op.startswith('ctz'):return width if val==0 else (val&-val).bit_length()-1
  if op.startswith('cpop'):return bin(val).count('1')
  if op=='sext.b':return signed(u&255,8)
  if op=='sext.h':return signed(u&65535,16)
  if op=='zext.h':return u&65535
  if op=='rev8':return int.from_bytes(u.to_bytes(x//8,'little'),'big')
  if op=='orc.b':return sum((255 if (u>>(i*8))&255 else 0)<<(i*8) for i in range(x//8))
  bit=1<<(v%x)
  if op.startswith('bset'):return u|bit
  if op.startswith('bclr'):return u&~bit
  if op.startswith('binv'):return u^bit
  if op.startswith('bext'):return int(bool(u&bit))
  raise ValueError(op)
 rng=random.Random(110+x);edges=[0,1,mask,1<<(x-1),(1<<(x-1))-1,0xffffffff,0x80000000,0x1234567880000001&mask,0x0100800000010080&mask]
 rows=[];asm=['.option norvc','.option norelax','.section .text','.globl vectors','vectors:']
 for op in binary+unary+imm:
  for i in range(96):
   u=edges[i%len(edges)] if i<32 else rng.getrandbits(x)
   v=([0,1,31,32,63,64,mask][i%7] if i<32 else rng.getrandbits(x))
   if op in imm:v%=32 if op=='roriw' else x
   inst=f'{op} t2,t0'+('' if op in unary else f',{v}' if op in imm else ',t1');asm.append(inst);rows.append({'op':op,'a':u,'b':v,'expected':oracle(op,u,v)&mask})
 (p/'vectors.S').write_text('\n'.join(asm)+'\n');c=['riscv64-elf-gcc',f'-march=rv{x}im_zba_zbb_zbs','-mabi='+('lp64' if x==64 else 'ilp32'),'-c',str(p/'vectors.S'),'-o',str(p/'vectors.o')];subprocess.run(c,check=True)
 c2=['riscv64-elf-objcopy','-O','binary','--only-section=.text',str(p/'vectors.o'),str(p/'instructions.bin')];subprocess.run(c2,check=True);code=(p/'instructions.bin').read_bytes();assert len(code)==4*len(rows)
 lines=[]
 for i,r in enumerate(rows):
  ins=int.from_bytes(code[4*i:4*i+4],'little');r['encoding']=f'{ins:08x}';lines.append(f'{ins:08x} {r["a"]:x} {r["b"]:x} {r["expected"]:x}')
 (p/'vectors.txt').write_text('\n'.join(lines)+'\n');(p/'manifest.json').write_text(json.dumps({'xlen':x,'seed':110+x,'commands':[c,c2],'scope':'assembled encodings with independent Python integer/bit-list expectations; not exhaustive operands','source_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'rows':rows},indent=2)+'\n');print('vectors',x,len(rows),'instructions',len(binary+unary+imm))
if __name__=='__main__':main()
