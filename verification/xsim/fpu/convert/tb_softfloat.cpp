#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
#include "Vrapt_fpu_convert_tb.h"
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
static Vrapt_fpu_convert_tb dut;
static uint64_t seed=0x243f6a8885a308d3ULL;
static uint64_t random64(){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return seed;}
static void tick(){dut.clock=0;dut.eval();dut.clock=1;dut.eval();}
static uint64_t canonical(uint64_t v,bool d){
 if(d) return (v&0x7ff0000000000000ULL)==0x7ff0000000000000ULL && (v&0xfffffffffffffULL) ? 0x7ff8000000000000ULL:v;
 uint32_t u=v;if((u&0x7f800000)==0x7f800000 && (u&0x7fffff))u=0x7fc00000;
 return 0xffffffff00000000ULL|u;
}
static int total=0,fail=0;
static void check(uint64_t a,bool narrow,int rm){
 softfloat_roundingMode=rm;softfloat_detectTininess=softfloat_tininess_afterRounding;softfloat_exceptionFlags=0;
 uint64_t expected=narrow?uint64_t(f64_to_f32(float64_t{a}).v):f32_to_f64(float32_t{uint32_t(a)}).v;
 expected=canonical(expected,!narrow);unsigned flags=softfloat_exceptionFlags;
 if(!dut.ready){std::fprintf(stderr,"not ready\n");std::exit(2);}
 dut.narrow=narrow;dut.operand=narrow?a:0xffffffff00000000ULL|uint32_t(a);dut.rounding_mode=rm;dut.valid=1;tick();dut.valid=0;
 int cycles=0;while(!dut.dut_valid && cycles++<200)tick();total++;
 if(!dut.dut_valid || dut.dut_result!=expected || dut.dut_flags!=flags){
  ++fail;std::printf("FAIL narrow=%d rm=%d a=%016llx expected=%016llx/%02x actual=%016llx/%02x valid=%d\n",narrow,rm,(unsigned long long)a,(unsigned long long)expected,flags,(unsigned long long)dut.dut_result,unsigned(dut.dut_flags),int(dut.dut_valid));
 }
 tick();
}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);dut.reset=1;dut.valid=0;dut.flush=0;for(int i=0;i<4;i++)tick();dut.reset=0;tick();
 const uint64_t edges64[]={0,0x8000000000000000ULL,1,0x8000000000000001ULL,0xfffffffffffffULL,0x10000000000000ULL,0x3ff0000000000000ULL,0xbff0000000000000ULL,0x4000000000000000ULL,0x3fefffffffffffffULL,0x7fefffffffffffffULL,0xffefffffffffffffULL,0x7ff0000000000000ULL,0xfff0000000000000ULL,0x7ff0000000000001ULL,0x7ff8000000000000ULL};
 const uint64_t edges32[]={0,0x80000000,1,0x80000001,0x7fffff,0x800000,0x3f800000,0xbf800000,0x40000000,0x3f7fffff,0x7f7fffff,0xff7fffff,0x7f800000,0xff800000,0x7f800001,0x7fc00000};
 for(int narrow=0;narrow<2;narrow++)for(int rm=0;rm<5;rm++){
  int before=total;auto e=narrow?edges64:edges32;
  for(int a=0;a<16;a++)check(e[a],narrow,rm);
  const uint64_t centers64[]={0x3810000000000000ULL,0x380fffffe0000000ULL,0x47efffffe0000000ULL,0x3690000000000000ULL};
  const uint64_t centers32[]={0,0x00800000,0x7f7fffff,0x80000000};
  for(int c=0;c<4;c++)for(int delta=-32;delta<=32;delta++)check(uint64_t(int64_t((narrow?centers64:centers32)[c])+delta),narrow,rm);
  for(int i=0;i<5000;i++)check(random64(),narrow,rm);
  std::printf("BUCKET narrow=%d rm=%d cases=%d\n",narrow,rm,total-before);
 }
 std::printf("SoftFloat convert TOTAL=%d FAILS=%d seed=243f6a8885a308d3\n",total,fail);dut.final();return fail?1:0;
}
