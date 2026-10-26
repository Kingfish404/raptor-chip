#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include "Vrapt_fpu_half_to_fp.h"
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
static Vrapt_fpu_half_to_fp dut;
static int total=0, failures=0;
static void tick(){dut.clock=0;dut.eval();dut.clock=1;dut.eval();}
static void check(uint64_t operand, bool target_double){
 const bool boxed=(operand>>16)==0xffffffffffffULL;
 const uint16_t input=boxed?uint16_t(operand):0x7e00;
 softfloat_exceptionFlags=0;
 uint64_t expected;
 if(target_double){
  expected=f16_to_f64(float16_t{input}).v;
  if((expected&0x7ff0000000000000ULL)==0x7ff0000000000000ULL && (expected&0xfffffffffffffULL))expected=0x7ff8000000000000ULL;
 }else{
  uint32_t value=f16_to_f32(float16_t{input}).v;
  if((value&0x7f800000)==0x7f800000 && (value&0x7fffff))value=0x7fc00000;
  expected=0xffffffff00000000ULL|value;
 }
 const unsigned flags=softfloat_exceptionFlags;
 if(!dut.ready){std::fprintf(stderr,"not ready\n");std::exit(2);}
 dut.target_double=target_double;dut.operand=operand;dut.valid=1;tick();dut.valid=0;
 int cycles=0;while(!dut.result_valid && cycles++<200)tick();++total;
 if(!dut.result_valid || dut.result!=expected || dut.flags!=flags){
  ++failures;std::printf("FAIL d=%d operand=%016llx expected=%016llx/%02x actual=%016llx/%02x valid=%d\n",target_double,(unsigned long long)operand,(unsigned long long)expected,flags,(unsigned long long)dut.result,unsigned(dut.flags),int(dut.result_valid));
 }
 tick();
}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);dut.reset=1;dut.flush=0;dut.valid=0;
 for(int i=0;i<4;i++)tick();dut.reset=0;tick();
 softfloat_roundingMode=softfloat_round_near_even;
 softfloat_detectTininess=softfloat_tininess_afterRounding;
 const uint16_t edges[]={0,0x8000,1,0x8001,0x3ff,0x400,0x3c00,0xbc00,0x4000,0x3bff,0x7bff,0xfbff,0x7c00,0xfc00,0x7c01,0x7e00};
 for(int d=0;d<2;d++){
  for(unsigned h=0;h<65536;h++)check(0xffffffffffff0000ULL|h,d);
  std::printf("BUCKET d=%d valid_boxes=65536\n",d);
  for(unsigned h=0;h<65536;h++)check(h,d);
  for(auto h:edges)for(int bit=16;bit<64;bit++)check((0xffffffffffff0000ULL|h)&~(1ULL<<bit),d);
  std::printf("BUCKET d=%d invalid_boxes=66304\n",d);
 }
 std::printf("SoftFloat half_to_fp TOTAL=%d FAILS=%d\n",total,failures);
 dut.final();return failures?1:0;
}
