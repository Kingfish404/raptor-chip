#include "Vrapt_vpu_divsqrt.h"
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>
static Vrapt_vpu_divsqrt d;
static uint64_t seed=0x082efa98ec4e6c89ULL,count;
static uint64_t random64(){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return seed;}
static void need(bool ok,const char*msg){if(!ok){std::fprintf(stderr,"FAIL %s case=%llu\n",msg,(unsigned long long)count);std::exit(1);}}
static void tick(){d.clock=0;d.eval();d.clock=1;d.eval();d.clock=0;d.eval();}
static void reset(){d.reset=1;tick();need(!d.req_ready&&!d.rsp_valid,"reset outputs");d.reset=0;d.req_valid=0;d.rsp_ready=0;tick();need(d.req_ready&&!d.rsp_valid,"reset drain");}
static void check(uint64_t a,uint64_t b,bool dp,bool sq,unsigned rm){
    softfloat_roundingMode=rm;softfloat_exceptionFlags=0;softfloat_detectTininess=softfloat_tininess_afterRounding;
    const bool illegal=rm>4||(dp&&TEST_ELEN<64);uint64_t expected=0;unsigned flags=0;
    if(!illegal){
      if(dp)expected=sq?f64_sqrt(float64_t{a}).v:f64_div(float64_t{a},float64_t{b}).v;
      else expected=sq?f32_sqrt(float32_t{uint32_t(a)}).v:f32_div(float32_t{uint32_t(a)},float32_t{uint32_t(b)}).v;
      flags=softfloat_exceptionFlags;
      const uint64_t exp=dp?0x7ff0000000000000ULL:0x7f800000ULL,frac=dp?0xfffffffffffffULL:0x7fffffULL;
      if((expected&exp)==exp&&(expected&frac))expected=dp?0x7ff8000000000000ULL:0x7fc00000ULL;
    }
    need(d.req_ready,"request ready");d.a=a;d.b=b;d.req_double=dp;d.req_sqrt=sq;d.rm=rm;d.req_valid=1;tick();
    d.a=~a;d.b=~b;d.req_double=!dp;d.req_sqrt=!sq;d.rm=7;
    unsigned latency=0;while(!d.rsp_valid){need(!d.req_ready,"second request accepted");need(++latency<100,"timeout");tick();}
    if(d.result!=expected||d.flags!=flags||d.illegal!=illegal){
      std::fprintf(stderr,"a=%016llx b=%016llx dp=%d sqrt=%d rm=%u got=%016llx/%x expected=%016llx/%x\n",(unsigned long long)a,(unsigned long long)b,dp,sq,rm,(unsigned long long)d.result,d.flags,(unsigned long long)expected,flags);need(false,"result/flags");
    }
    for(unsigned i=0;i<3;++i){tick();need(d.rsp_valid&&!d.req_ready&&d.result==expected&&d.flags==flags&&d.illegal==illegal,"held response");}
    d.req_valid=0;d.rsp_ready=1;tick();d.rsp_ready=0;need(d.req_ready&&!d.rsp_valid,"retire");++count;
}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);reset();
    for(unsigned dp=0;dp<(TEST_ELEN==64?2u:1u);++dp){
      const std::vector<uint64_t> edges=dp?
        std::vector<uint64_t>{0,0x8000000000000000ULL,1,0xfffffffffffffULL,0x10000000000000ULL,0x3ff0000000000000ULL,0xbff0000000000000ULL,0x7fefffffffffffffULL,0x7ff0000000000000ULL,0xfff0000000000000ULL,0x7ff8000000000001ULL,0x7ff0000000000001ULL,0x4000000000000000ULL,0x3fe0000000000000ULL,0x4008000000000000ULL,0x8000000000000001ULL,0xffefffffffffffffULL}:
        std::vector<uint64_t>{0,0x80000000,1,0x7fffff,0x800000,0x3f800000,0xbf800000,0x7f7fffff,0x7f800000,0xff800000,0x7fc00001,0x7f800001,0x40000000,0x3f000000,0x40400000,0x80000001,0xff7fffff};
      for(auto a:edges)for(auto b:edges)for(unsigned sq=0;sq<2;++sq)for(unsigned rm=0;rm<5;++rm)check(a,b,dp,sq,rm);
    }
    for(unsigned i=0;i<40000;++i){auto a=random64(),b=random64();check(a,b,TEST_ELEN==64&&(i&1),(i>>1)&1,i%5);}
    for(unsigned dp=0;dp<2;++dp)for(unsigned sq=0;sq<2;++sq)for(unsigned rm=0;rm<8;++rm)check(0,0,dp,sq,rm);
    unsigned resets=0;
    for(unsigned dp=0;dp<(TEST_ELEN==64?2u:1u);++dp)for(unsigned sq=0;sq<2;++sq)for(unsigned age=0;age<64;++age){
      d.a=dp?0x4000000000000000ULL:0x40000000;d.b=dp?0x4008000000000000ULL:0x40400000;
      d.req_double=dp;d.req_sqrt=sq;d.req_valid=1;d.rm=0;tick();d.req_valid=0;
      for(unsigned i=0;i<age;++i)tick();reset();for(unsigned i=0;i<70;++i){tick();need(!d.rsp_valid,"late reset result");}++resets;
    }
    std::printf("PASS divsqrt ELEN=%u cases=%llu reset_boundaries=%u seed=082efa98ec4e6c89\n",TEST_ELEN,(unsigned long long)count,resets);
}
