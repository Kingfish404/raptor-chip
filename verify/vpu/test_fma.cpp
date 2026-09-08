#ifdef TEST_ARITH
#include "Vrapt_vpu_fp_arith.h"
using Dut = Vrapt_vpu_fp_arith;
#else
#include "Vrapt_vpu_fma.h"
using Dut = Vrapt_vpu_fma;
#endif
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>
static Dut d;
static uint64_t seed=0x452821e638d01377ULL,count;
static uint64_t random64(){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return seed;}
static void need(bool ok,const char*msg){if(!ok){std::fprintf(stderr,"FAIL %s case=%llu\n",msg,(unsigned long long)count);std::exit(1);}}
static void tick(){d.clock=0;d.eval();d.clock=1;d.eval();d.clock=0;d.eval();}
static void reset(){d.reset=1;tick();need(!d.req_ready&&!d.rsp_valid,"reset outputs");d.reset=0;d.req_valid=0;d.rsp_ready=0;tick();need(d.req_ready&&!d.rsp_valid,"reset drain");}
static void check(uint64_t a,uint64_t b,uint64_t c,unsigned signs,unsigned rm,unsigned operation=0){
    const uint64_t sign=uint64_t(1)<<(TEST_DOUBLE?63:31);
    softfloat_roundingMode=rm;softfloat_exceptionFlags=0;
    softfloat_detectTininess=softfloat_tininess_afterRounding;
    uint64_t expected=0;unsigned flags=0;
    if(rm<=4){
      if(TEST_DOUBLE)expected=f64_mulAdd(float64_t{a^((signs&2)?sign:0)},float64_t{b},float64_t{c^((signs&1)?sign:0)}).v;
      else expected=f32_mulAdd(float32_t{uint32_t(a^((signs&2)?sign:0))},float32_t{uint32_t(b)},float32_t{uint32_t(c^((signs&1)?sign:0))}).v;
#ifdef TEST_ARITH
      if(operation){
        softfloat_exceptionFlags=0;
        if(TEST_DOUBLE){
          const float64_t x{a},y{b};
          expected=operation==1?f64_add(x,y).v:operation==2?f64_sub(x,y).v:f64_mul(x,y).v;
        }else{
          const float32_t x{uint32_t(a)},y{uint32_t(b)};
          expected=operation==1?f32_add(x,y).v:operation==2?f32_sub(x,y).v:f32_mul(x,y).v;
        }
      }
#else
      (void)operation;
#endif
      flags=softfloat_exceptionFlags;
      // RVV requires the canonical NaN, while SoftFloat specializations may
      // propagate a payload. Numeric results and all exception flags stay exact.
      const uint64_t exp=TEST_DOUBLE?0x7ff0000000000000ULL:0x7f800000ULL;
      const uint64_t frac=TEST_DOUBLE?0xfffffffffffffULL:0x7fffffULL;
      if((expected&exp)==exp&&(expected&frac))expected=TEST_DOUBLE?0x7ff8000000000000ULL:0x7fc00000ULL;
    }
#ifdef TEST_ARITH
    d.operation=operation;
#endif
    need(d.req_ready,"request ready");d.a=a;d.b=b;d.c=c;d.negate_product=signs>>1;d.negate_addend=signs&1;d.rm=rm;d.req_valid=1;tick();
    // Present unrelated requests throughout execution: no second acceptance.
    d.a=~a;d.b=~b;d.c=~c;d.rm=7;d.negate_product=!(signs>>1);d.negate_addend=!(signs&1);
#ifdef TEST_ARITH
    d.operation=operation^3;
#endif
    unsigned n=0;while(!d.rsp_valid){need(!d.req_ready,"busy accepted");need(++n<20,"timeout");tick();}
    if(d.result!=expected||d.flags!=flags||d.illegal!=(rm>4)){
      std::fprintf(stderr,"a=%016llx b=%016llx c=%016llx signs=%u rm=%u got=%016llx/%x expected=%016llx/%x\n",(unsigned long long)a,(unsigned long long)b,(unsigned long long)c,signs,rm,(unsigned long long)d.result,d.flags,(unsigned long long)expected,flags);need(false,"result");
    }
    for(unsigned stall=0;stall<3;++stall){tick();need(d.rsp_valid&&!d.req_ready&&d.result==expected&&d.flags==flags&&d.illegal==(rm>4),"held response");}
    d.req_valid=0;d.rsp_ready=1;tick();d.rsp_ready=0;need(d.req_ready&&!d.rsp_valid,"retire");++count;
}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);reset();
    const std::vector<uint64_t> edges=TEST_DOUBLE?
      std::vector<uint64_t>{0,0x8000000000000000ULL,1,0xfffffffffffffULL,0x10000000000000ULL,0x3ff0000000000000ULL,0xbff0000000000000ULL,0x7fefffffffffffffULL,0x7ff0000000000000ULL,0xfff0000000000000ULL,0x7ff8000000000001ULL,0x7ff0000000000001ULL}:
      std::vector<uint64_t>{0,0x80000000,1,0x7fffff,0x800000,0x3f800000,0xbf800000,0x7f7fffff,0x7f800000,0xff800000,0x7fc00001,0x7f800001};
    for(auto a:edges)for(auto b:edges)for(auto c:edges)for(unsigned signs=0;signs<4;++signs)for(unsigned rm=0;rm<5;++rm)check(a,b,c,signs,rm);
    for(unsigned i=0;i<20000;++i){auto a=random64(),b=random64(),c=random64();check(a,b,c,i%4,i%5);}
    for(unsigned rm=5;rm<8;++rm)check(0,0,0,0,rm);
#ifdef TEST_ARITH
    for(unsigned operation=1;operation<=3;++operation){
      for(auto a:edges)for(auto b:edges)for(unsigned rm=0;rm<5;++rm)
        check(a,b,UINT64_MAX,3,rm,operation);
      for(unsigned i=0;i<20000;++i){auto a=random64(),b=random64();check(a,b,random64(),i%4,i%5,operation);}
      for(unsigned rm=5;rm<8;++rm)check(0,0,0,3,rm,operation);
    }
#endif
    for(unsigned age=0;age<10;++age){d.req_valid=1;d.rm=0;tick();d.req_valid=0;for(unsigned i=0;i<age;++i)tick();reset();for(unsigned i=0;i<10;++i){tick();need(!d.rsp_valid,"late reset result");}}
#ifdef TEST_ARITH
    const char* name="fp_arith";
#else
    const char* name="fma";
#endif
    std::printf("PASS %s Double=%u cases=%llu reset_boundaries=10 seed=452821e638d01377\n",name,TEST_DOUBLE,(unsigned long long)count);
}
