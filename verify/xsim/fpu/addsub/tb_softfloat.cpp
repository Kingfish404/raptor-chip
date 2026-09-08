#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
#include "Vrapt_fpu_addsub_tb.h"
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
static Vrapt_fpu_addsub_tb dut;
static uint64_t seed=0x243f6a8885a308d3ULL;
static uint64_t random64(){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return seed;}
static void tick(){dut.clock=0;dut.eval();dut.clock=1;dut.eval();}
static uint64_t canonical(uint64_t v,bool d){
 if(d) return (v&0x7ff0000000000000ULL)==0x7ff0000000000000ULL && (v&0xfffffffffffffULL) ? 0x7ff8000000000000ULL:v;
 uint32_t u=v;if((u&0x7f800000)==0x7f800000 && (u&0x7fffff))u=0x7fc00000;
 return 0xffffffff00000000ULL|u;
}
static int total=0,fail=0;
static void check(uint64_t a,uint64_t b,bool d,bool sub,int rm){
 softfloat_roundingMode=rm;softfloat_detectTininess=softfloat_tininess_afterRounding;softfloat_exceptionFlags=0;
 uint64_t expected;
 if(d){float64_t x{a},y{b};expected=(sub?f64_sub(x,y):f64_add(x,y)).v;}
 else{float32_t x{uint32_t(a)},y{uint32_t(b)};expected=(sub?f32_sub(x,y):f32_add(x,y)).v;}
 expected=canonical(expected,d);unsigned flags=softfloat_exceptionFlags;
 if(!dut.ready){std::fprintf(stderr,"not ready before launch\n");std::exit(2);}
 dut.operand_a=d?a:0xffffffff00000000ULL|uint32_t(a);dut.operand_b=d?b:0xffffffff00000000ULL|uint32_t(b);
 dut.is_double=d;dut.op=15+2*int(d)+int(sub);dut.rounding_mode=rm;dut.valid=1;tick();dut.valid=0;
 int cycles=0;while(!dut.dut_valid && cycles++<200)tick();
 total++;
 if(!dut.dut_valid || dut.dut_result!=expected || dut.dut_flags!=flags){
  ++fail;std::printf("FAIL d=%d sub=%d rm=%d a=%016llx b=%016llx expected=%016llx/%02x actual=%016llx/%02x valid=%d\n",d,sub,rm,(unsigned long long)a,(unsigned long long)b,(unsigned long long)expected,flags,(unsigned long long)dut.dut_result,unsigned(dut.dut_flags),int(dut.dut_valid));
 }
 tick();
}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);dut.reset=1;dut.valid=0;dut.flush=0;for(int i=0;i<4;i++)tick();dut.reset=0;tick();
 const uint64_t edges64[]={0,0x8000000000000000ULL,1,0x8000000000000001ULL,0xfffffffffffffULL,0x10000000000000ULL,0x3ff0000000000000ULL,0xbff0000000000000ULL,0x4000000000000000ULL,0x3fefffffffffffffULL,0x7fefffffffffffffULL,0xffefffffffffffffULL,0x7ff0000000000000ULL,0xfff0000000000000ULL,0x7ff0000000000001ULL,0x7ff8000000000000ULL};
 const uint64_t edges32[]={0,0x80000000,1,0x80000001,0x7fffff,0x800000,0x3f800000,0xbf800000,0x40000000,0x3f7fffff,0x7f7fffff,0xff7fffff,0x7f800000,0xff800000,0x7f800001,0x7fc00000};
 for(int d=0;d<2;d++)for(int sub=0;sub<2;sub++)for(int rm=0;rm<5;rm++){
  auto e=d?edges64:edges32;int before=total;
  for(int a=0;a<16;a++)for(int b=0;b<16;b++)check(e[a],e[b],d,sub,rm);
  // Close cancellation around min-normal and 1, including signed zeros.
  for(uint64_t base : {uint64_t(d?0x0010000000000000ULL:0x00800000ULL),uint64_t(d?0x3ff0000000000000ULL:0x3f800000ULL)})
   for(int da=-16;da<=16;da++)for(int db=-16;db<=16;db++)for(int sign=0;sign<2;sign++){
    uint64_t a=uint64_t(int64_t(base)+da),b=uint64_t(int64_t(base)+db);
    check(a|(uint64_t(sign)<<(d?63:31)),b|(uint64_t(!sign)<<(d?63:31)),d,sub,rm);
   }
  for(int i=0;i<5000;i++){
   uint64_t a=random64(),b=random64();if(i%4==0){a&=d?0x800fffffffffffffULL:0x807fffffULL;b&=d?0x800fffffffffffffULL:0x807fffffULL;}
   check(a,b,d,sub,rm);
  }
  std::printf("BUCKET d=%d sub=%d rm=%d cases=%d\n",d,sub,rm,total-before);
 }
 std::printf("SoftFloat addsub TOTAL=%d FAILS=%d seed=243f6a8885a308d3\n",total,fail);dut.final();return fail?1:0;
}
