#include "Vrapt_vpu_fp_convert.h"
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
static Vrapt_vpu_fp_convert d;
static uint64_t count,seed=0x3f84d5b5b5470917ULL;
static uint64_t random64(){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return seed;}
static void need(bool b,const char*m){if(!b){std::fprintf(stderr,"FAIL convert %s case=%llu\n",m,(unsigned long long)count);std::exit(1);}}
static void tick(){d.clock=0;d.eval();d.clock=1;d.eval();d.clock=0;d.eval();}
static void reset(){d.reset=1;tick();need(!d.req_ready&&!d.rsp_valid,"reset outputs");d.reset=0;d.req_valid=0;d.rsp_ready=0;tick();need(d.req_ready&&!d.rsp_valid,"reset drain");}
static void check(uint64_t value,bool widen,unsigned rm){
 const bool bad=rm>4&&(rm!=6||widen);uint64_t expected=0;unsigned flags=0;
 softfloat_roundingMode=rm==6?softfloat_round_odd:rm;softfloat_exceptionFlags=0;softfloat_detectTininess=softfloat_tininess_afterRounding;
 if(!bad){
  expected=widen?f32_to_f64(float32_t{uint32_t(value)}).v:f64_to_f32(float64_t{value}).v;
  flags=softfloat_exceptionFlags;
  if(widen){if((expected&0x7ff0000000000000ULL)==0x7ff0000000000000ULL&&(expected&0xfffffffffffffULL))expected=0x7ff8000000000000ULL;}
  else if((expected&0x7f800000)==0x7f800000&&(expected&0x7fffff))expected=0x7fc00000;
 }
 d.req_valid=1;d.rsp_ready=0;d.operand=value;d.req_widen=widen;d.rm=rm;d.eval();need(d.req_ready,"request ready");tick();
 d.operand=~value;d.req_widen=!widen;d.rm=rm^7;unsigned age=0;
 while(!d.rsp_valid){need(!d.req_ready,"busy accepts request");tick();need(++age<12,"timeout");}
 if(d.result!=expected||d.flags!=flags||d.illegal!=bad){std::fprintf(stderr,"input=%016llx widen=%u rm=%u got=%016llx/%u expected=%016llx/%u\n",(unsigned long long)value,widen,rm,(unsigned long long)d.result,d.flags,(unsigned long long)expected,flags);need(false,"result");}
 for(unsigned i=0;i<3;++i){tick();need(d.rsp_valid&&!d.req_ready&&d.result==expected&&d.flags==flags&&d.illegal==bad,"held response");}
 d.req_valid=0;d.rsp_ready=1;tick();d.rsp_ready=0;tick();need(d.req_ready&&!d.rsp_valid,"drained");++count;
}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);reset();
 // Every FP64 exponent at fraction endpoints and around rounding guards,
 // with both signs and every RM selector including odd and illegal values.
 for(unsigned exp=0;exp<2048;++exp)for(uint64_t frac:{0ULL,1ULL,0xfffffffffffffULL,0x10000000ULL,0x10000001ULL,0xffffff0000000ULL,0xffffff0000001ULL})
  for(unsigned sign=0;sign<2;++sign)for(unsigned rm=0;rm<8;++rm)check((uint64_t(sign)<<63)|(uint64_t(exp)<<52)|frac,false,rm);
 // FP32 normal/subnormal and NaN conversion boundaries, arbitrary upper bits.
 for(unsigned exp=0;exp<256;++exp)for(uint32_t frac:{0u,1u,0x3fffffu,0x400000u,0x7fffffu})
  for(unsigned sign=0;sign<2;++sign)for(unsigned rm=0;rm<8;++rm)check(0xabcdef0100000000ULL|(sign<<31)|(exp<<23)|frac,true,rm);
 for(unsigned i=0;i<60000;++i)check(random64(),i&1,(i/2)%8);
 for(unsigned dir=0;dir<2;++dir)for(unsigned age=0;age<10;++age){reset();d.req_valid=1;d.req_widen=dir;d.rm=dir?0:6;d.operand=0x3ff0000010000001ULL;tick();d.req_valid=0;for(unsigned j=0;j<age;++j)tick();reset();for(unsigned j=0;j<15;++j){tick();need(!d.rsp_valid,"late result after reset");}}
 std::printf("PASS fp_convert cases=%llu reset_boundaries=20 seed=3f84d5b5b5470917\n",(unsigned long long)count);
}
