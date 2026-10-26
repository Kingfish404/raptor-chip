#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include "Vrapt_fpu_fma_tb.h"
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
static Vrapt_fpu_fma_tb dut;
static uint64_t seed=0x243f6a8885a308d3ULL;
static uint64_t random64(){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return seed;}
static void tick(){dut.clock=0;dut.eval();dut.clock=1;dut.eval();}
static uint64_t canonical(uint64_t v,bool d){
 if(d) return (v&0x7ff0000000000000ULL)==0x7ff0000000000000ULL && (v&0xfffffffffffffULL) ? 0x7ff8000000000000ULL:v;
 uint32_t u=v;if((u&0x7f800000)==0x7f800000 && (u&0x7fffff))u=0x7fc00000;
 return 0xffffffff00000000ULL|u;
}
static int total=0,fail=0;
static void check(uint64_t a,uint64_t b,uint64_t c,bool d,int variant,int rm){
 softfloat_roundingMode=rm;softfloat_detectTininess=softfloat_tininess_afterRounding;softfloat_exceptionFlags=0;
 uint64_t expected;
 uint64_t aa=a,cc=c;uint64_t sign=uint64_t(1)<<(d?63:31);
 if(variant>=2)aa^=sign;if(variant==1 || variant==3)cc^=sign;
 if(d){float64_t x{aa},y{b},z{cc};expected=f64_mulAdd(x,y,z).v;}
 else{float32_t x{uint32_t(aa)},y{uint32_t(b)},z{uint32_t(cc)};expected=f32_mulAdd(x,y,z).v;}
 expected=canonical(expected,d);unsigned flags=softfloat_exceptionFlags;
 if(!dut.ready){std::fprintf(stderr,"not ready before launch\n");std::exit(2);}
 dut.operand_a=d?a:0xffffffff00000000ULL|uint32_t(a);dut.operand_b=d?b:0xffffffff00000000ULL|uint32_t(b);
 dut.operand_c=d?c:0xffffffff00000000ULL|uint32_t(c);dut.is_double=d;dut.op=51+int(d)+variant*2;dut.rounding_mode=rm;dut.valid=1;tick();dut.valid=0;
 int cycles=0;while(!dut.dut_valid && cycles++<200)tick();
 total++;
 if(!dut.dut_valid || dut.dut_result!=expected || dut.dut_flags!=flags){
  ++fail;std::printf("FAIL d=%d variant=%d rm=%d a=%016llx b=%016llx c=%016llx expected=%016llx/%02x actual=%016llx/%02x valid=%d\n",d,variant,rm,(unsigned long long)a,(unsigned long long)b,(unsigned long long)c,(unsigned long long)expected,flags,(unsigned long long)dut.dut_result,unsigned(dut.dut_flags),int(dut.dut_valid));
 }
 tick();
}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);dut.reset=1;dut.valid=0;dut.flush=0;for(int i=0;i<4;i++)tick();dut.reset=0;tick();
 const uint64_t edges64[]={0,0x8000000000000000ULL,1,0x8000000000000001ULL,0xfffffffffffffULL,0x10000000000000ULL,0x3ff0000000000000ULL,0xbff0000000000000ULL,0x4000000000000000ULL,0x3fefffffffffffffULL,0x7fefffffffffffffULL,0xffefffffffffffffULL,0x7ff0000000000000ULL,0xfff0000000000000ULL,0x7ff0000000000001ULL,0x7ff8000000000000ULL};
 const uint64_t edges32[]={0,0x80000000,1,0x80000001,0x7fffff,0x800000,0x3f800000,0xbf800000,0x40000000,0x3f7fffff,0x7f7fffff,0xff7fffff,0x7f800000,0xff800000,0x7f800001,0x7fc00000};
 for(int d=0;d<2;d++)for(int variant=0;variant<4;variant++)for(int rm=0;rm<5;rm++){
  auto e=d?edges64:edges32;int before=total;
  for(int a=0;a<16;a++)for(int b=0;b<16;b++)for(int c=0;c<16;c++)check(e[a],e[b],e[c],d,variant,rm);
  for(int da=-8;da<=8;da++)for(int db=-8;db<=8;db++)for(int sign=0;sign<2;sign++)for(int c=0;c<3;c++){
   uint64_t a=uint64_t(int64_t(d?0x0010000000000000ULL:0x00800000ULL)+da);
   uint64_t b=uint64_t(int64_t(d?0x3ff0000000000000ULL:0x3f800000ULL)+db);
   uint64_t cc=c==0?0:c==1?1:(uint64_t(1)<<(d?63:31))|1;
   check(a|(uint64_t(sign)<<(d?63:31)),b,cc,d,variant,rm);
  }
  for(int i=0;i<5000;i++){
   uint64_t a=random64(),b=random64(),c=random64();
   if(i%4==0){a&=d?0x800fffffffffffffULL:0x807fffffULL;c&=d?0x800fffffffffffffULL:0x807fffffULL;}
   check(a,b,c,d,variant,rm);
  }
  std::printf("BUCKET d=%d variant=%d rm=%d cases=%d\n",d,variant,rm,total-before);
 }
 std::printf("SoftFloat FMA TOTAL=%d FAILS=%d seed=243f6a8885a308d3\n",total,fail);dut.final();return fail?1:0;
}
