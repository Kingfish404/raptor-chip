#include <cstdint>
#include <cstdio>
#include <vector>
#include "Vrapt_fpu_fp_to_int_tb.h"
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
static Vrapt_fpu_fp_to_int_tb dut;
static unsigned total=0,failures=0;
static void tick(){dut.clock=0;dut.eval();dut.clock=1;dut.eval();}
static void check(uint64_t raw,bool d,bool l,bool u,unsigned rm){
  // RISC-V unboxed S operands are canonical quiet NaNs.
  uint64_t v=d?raw:((raw>>32)==0xffffffffULL?uint32_t(raw):0x7fc00000);
  softfloat_exceptionFlags=0;
  uint64_t expected;
  if(d){float64_t x{v};
    if(l)expected=u?f64_to_ui64(x,rm,true):uint64_t(f64_to_i64(x,rm,true));
    else expected=u?f64_to_ui32(x,rm,true):uint64_t(f64_to_i32(x,rm,true));
  }else{float32_t x{uint32_t(v)};
    if(l)expected=u?f32_to_ui64(x,rm,true):uint64_t(f32_to_i64(x,rm,true));
    else expected=u?f32_to_ui32(x,rm,true):uint64_t(f32_to_i32(x,rm,true));
  }
  unsigned flags=softfloat_exceptionFlags;
  // SoftFloat specializations can differ in invalid-result constants.
  // Keep its independent range/rounding/NV decision; apply RISC-V clipping only.
  if(flags&softfloat_flag_invalid){
    bool negative=d?(v>>63):(v>>31);
    bool nan=d?((v&0x7fffffffffffffffULL)>0x7ff0000000000000ULL):((v&0x7fffffff)>0x7f800000);
    if(u)expected=negative&&!nan?0:(l?UINT64_MAX:UINT32_MAX);
    else if(negative&&!nan)expected=l?0x8000000000000000ULL:0x80000000ULL;
    else expected=l?0x7fffffffffffffffULL:0x7fffffffULL;
  }
  // All W/WU results sign-extend to XLEN=64, including unsigned conversion.
  if(!l)expected=uint64_t(int64_t(int32_t(expected)));
  dut.source_double=d;dut.int64_target=l;dut.unsigned_result=u;
  dut.operand=raw;dut.rounding_mode=rm;dut.eval();++total;
  if(!dut.ready){++failures;std::printf("FAIL not ready\n");return;}
  dut.valid=1;tick();dut.valid=0;unsigned cycles=0;
  while(!dut.dut_valid&&cycles++<12)tick();
  if(!dut.dut_valid||dut.dut_result!=expected||dut.dut_flags!=flags){
    if(++failures<=20)std::printf("FAIL d=%u l=%u u=%u rm=%u op=%016llx expected=%016llx/%02x got=%016llx/%02x valid=%u\n",d,l,u,rm,(unsigned long long)raw,(unsigned long long)expected,flags,(unsigned long long)dut.dut_result,dut.dut_flags,dut.dut_valid);
  }
  tick();if(dut.dut_valid){++failures;std::printf("FAIL repeated valid\n");}
}
int main(int argc,char**argv){
  Verilated::commandArgs(argc,argv);dut.reset=1;dut.flush=0;dut.valid=0;
  for(int i=0;i<4;i++)tick();dut.reset=0;tick();
  struct Input{uint64_t v;bool d;};std::vector<Input> inputs;
  for(unsigned d=0;d<2;d++){
    unsigned frac=d?52:23,exps=d?2048:256;
    uint64_t half=uint64_t(1)<<(frac-1),mask=(uint64_t(1)<<frac)-1;
    for(unsigned e=0;e<exps;e++)for(uint64_t f:{uint64_t(0),uint64_t(1),half-1,half,mask})for(unsigned s=0;s<2;s++){
      uint64_t v=(uint64_t(s)<<(d?63:31))|(uint64_t(e)<<frac)|f;
      inputs.push_back({d?v:(0xffffffff00000000ULL|v),bool(d)});
    }
  }
  uint64_t seed=0x243f6a8885a308d3ULL;
  for(unsigned i=0;i<4096;i++){
    seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;
    inputs.push_back({seed,true});inputs.push_back({0xffffffff00000000ULL|uint32_t(seed),false});
  }
  const uint32_t boxcases[]={0,1,0x80000000,0x80000001,0x3f000000,0xbf000000,0x3f800000,0xbf800000,0x4f000000,0xcf000000,0x5f000000,0xdf000000,0x7f800000,0xff800000,0x7f800001,0xffc12345};
  for(uint32_t v:boxcases)for(unsigned b=32;b<64;b++)inputs.push_back({(0xffffffff00000000ULL|v)&~(uint64_t(1)<<b),false});
  for(auto x:inputs)for(unsigned l=0;l<2;l++)for(unsigned u=0;u<2;u++)for(unsigned rm=0;rm<5;rm++)check(x.v,x.d,l,u,rm);
  std::printf("%s fp_to_int SoftFloat inputs=%zu checks=%u failures=%u\n",failures?"FAIL":"PASS",inputs.size(),total,failures);
  dut.final();return failures?1:0;
}
