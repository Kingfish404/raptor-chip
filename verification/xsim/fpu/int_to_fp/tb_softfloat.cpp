#include <cstdint>
#include <cstdio>
#include <vector>
#include "Vrapt_fpu_int_to_fp_tb.h"
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
static Vrapt_fpu_int_to_fp_tb dut;
static unsigned total=0, failures=0;
static void tick(){dut.clock=0;dut.eval();dut.clock=1;dut.eval();}
static void check(uint64_t v, bool d, bool l, bool u, unsigned rm){
  softfloat_roundingMode=rm;
  softfloat_exceptionFlags=0;
  uint64_t expected;
  if(d){
    if(l) expected=u?ui64_to_f64(v).v:i64_to_f64(int64_t(v)).v;
    else expected=u?ui32_to_f64(uint32_t(v)).v:i32_to_f64(int32_t(v)).v;
  }else{
    uint32_t bits;
    if(l) bits=u?ui64_to_f32(v).v:i64_to_f32(int64_t(v)).v;
    else bits=u?ui32_to_f32(uint32_t(v)).v:i32_to_f32(int32_t(v)).v;
    expected=0xffffffff00000000ULL|bits;
  }
  unsigned flags=softfloat_exceptionFlags;
  dut.target_double=d;dut.int64_input=l;dut.unsigned_input=u;
  dut.operand=v;dut.rounding_mode=rm;dut.eval();
  ++total;
  if(!dut.ready){++failures;std::printf("FAIL not ready\n");return;}
  dut.valid=1;tick();dut.valid=0;
  unsigned cycles=0;
  while(!dut.dut_valid && cycles++<12)tick();
  if(!dut.dut_valid || dut.dut_result!=expected || dut.dut_flags!=flags){
    if(++failures<=16)std::printf("FAIL d=%u l=%u u=%u rm=%u op=%016llx expected=%016llx/%02x got=%016llx/%02x valid=%u\n",d,l,u,rm,(unsigned long long)v,(unsigned long long)expected,flags,(unsigned long long)dut.dut_result,dut.dut_flags,dut.dut_valid);
  }
  tick();
  if(dut.dut_valid){++failures;std::printf("FAIL duplicate result\n");}
}
int main(int argc,char** argv){
  Verilated::commandArgs(argc,argv);
  dut.reset=1;dut.flush=0;dut.valid=0;for(int i=0;i<4;i++)tick();
  dut.reset=0;tick();
  std::vector<uint64_t> inputs={0,1,~0ULL,0x7fffffff,0x80000000,0xffffffff,0x7fffffffffffffffULL,0x8000000000000000ULL};
  for(unsigned b=0;b<64;b++){
    uint64_t p=uint64_t(1)<<b;
    for(int delta=-2;delta<=2;delta++){
      uint64_t v=p+uint64_t(delta);inputs.push_back(v);inputs.push_back(0-v);
    }
  }
  // Below/tie/above points at both S and D precision; both retained parities.
  for(unsigned precision : {24u,53u})for(unsigned b=precision;b<64;b++){
    uint64_t p=uint64_t(1)<<b,half=uint64_t(1)<<(b-precision);
    for(unsigned parity=0;parity<2;parity++)for(int delta=-1;delta<=1;delta++){
      uint64_t v=p+(1+2*parity)*half+uint64_t(delta);
      inputs.push_back(v);inputs.push_back(0-v);
    }
  }
  uint64_t seed=0x13198a2e03707344ULL;
  for(unsigned i=0;i<4096;i++){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;inputs.push_back(seed);}
  for(uint64_t v:inputs)for(unsigned d=0;d<2;d++)for(unsigned l=0;l<2;l++)for(unsigned u=0;u<2;u++)for(unsigned rm=0;rm<5;rm++)check(v,d,l,u,rm);
  std::printf("%s int_to_fp SoftFloat inputs=%zu checks=%u failures=%u\n",failures?"FAIL":"PASS",inputs.size(),total,failures);
  dut.final();return failures?1:0;
}
