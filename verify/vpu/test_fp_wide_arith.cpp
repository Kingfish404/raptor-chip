#include "Vrapt_vpu_fp_wide_arith.h"
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
#include <cstdint>
#include <cstdio>
#include <cstdlib>
static Vrapt_vpu_fp_wide_arith d;
static uint64_t count,seed=0xc0ac29b7c97c50ddULL;
static uint64_t random64(){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return seed;}
static void need(bool b,const char*m){if(!b){std::fprintf(stderr,"FAIL wide %s case=%llu\n",m,(unsigned long long)count);std::exit(1);}}
static void tick(){d.clock=0;d.eval();d.clock=1;d.eval();d.clock=0;d.eval();}
static void reset(){d.reset=1;tick();need(!d.req_ready&&!d.rsp_valid,"reset outputs");d.reset=0;d.req_valid=0;d.rsp_ready=0;tick();need(d.req_ready&&!d.rsp_valid,"reset drain");}
static void check(uint64_t a,uint32_t b,uint64_t c,unsigned op,unsigned wide,unsigned signs,unsigned rm){
 const bool bad=rm>4||(wide&&op!=1&&op!=2);uint64_t expected=0;unsigned flags=0;
 softfloat_roundingMode=rm;softfloat_exceptionFlags=0;softfloat_detectTininess=softfloat_tininess_afterRounding;
 if(!bad){
  // Reference conversion quiets signaling NaNs and accumulates their NV before
  // arithmetic; DUT preserves signaling status until arithmetic itself.
  float64_t x=wide?float64_t{a}:f32_to_f64(float32_t{uint32_t(a)});
  float64_t y=f32_to_f64(float32_t{b}),z{c};
  if(op==0){x.v^=(signs&2)?1ULL<<63:0;z.v^=(signs&1)?1ULL<<63:0;expected=f64_mulAdd(x,y,z).v;}
  else expected=op==1?f64_add(x,y).v:op==2?f64_sub(x,y).v:f64_mul(x,y).v;
  flags=softfloat_exceptionFlags;
  if((expected&0x7ff0000000000000ULL)==0x7ff0000000000000ULL&&(expected&0xfffffffffffffULL))expected=0x7ff8000000000000ULL;
 }
 d.req_valid=1;d.rsp_ready=0;d.a=a;d.b=b;d.c=c;d.operation=op;d.a_is_wide=wide;d.negate_product=signs>>1;d.negate_addend=signs&1;d.rm=rm;d.eval();need(d.req_ready,"request ready");tick();
 d.a=~a;d.b=~b;d.c=~c;d.operation=op^3;d.a_is_wide=!wide;d.negate_product=!d.negate_product;d.negate_addend=!d.negate_addend;d.rm=rm^7;
 unsigned age=0;while(!d.rsp_valid){need(!d.req_ready,"busy accepts second request");tick();need(++age<20,"timeout");}
 need(d.result==expected&&d.flags==flags&&d.illegal==bad,"result/flags/illegal");
 for(unsigned stall=0;stall<3;++stall){tick();need(d.rsp_valid&&!d.req_ready&&d.result==expected&&d.flags==flags&&d.illegal==bad,"held response");}
 d.req_valid=0;d.rsp_ready=1;tick();d.rsp_ready=0;tick();need(d.req_ready&&!d.rsp_valid,"drained");++count;
}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);reset();
 const uint32_t narrow[]={0,0x80000000,1,0x807fffff,0x00800000,0x3f800000,0xbf800000,0x7f7fffff,0x7f800000,0xff800000,0x7f800001,0x7fc00000};
 const uint64_t wide_values[]={0,0x8000000000000000ULL,1,0x800fffffffffffffULL,0x0010000000000000ULL,0x3ff0000000000000ULL,0xbff0000000000000ULL,0x7fefffffffffffffULL,0x7ff0000000000000ULL,0xfff0000000000000ULL,0x7ff0000000000001ULL,0x7ff8000000000000ULL};
 for(unsigned op=0;op<4;++op)for(unsigned wide=0;wide<2;++wide){
  if(wide&&(op==0||op==3))continue;
  for(unsigned rm=0;rm<5;++rm)for(unsigned signs=0;signs<4;++signs)
   for(unsigned i=0;i<12;++i)for(auto b:narrow)for(auto c:wide_values)
    check(wide?wide_values[i]:narrow[i],b,c,op,wide,signs,rm);
 }
 for(unsigned i=0;i<60000;++i){auto a=random64(),b=random64(),c=random64();check(a,uint32_t(b),c,i%4,(i/4)%2,(i/8)%4,(i/32)%8);}
 for(unsigned age=0;age<12;++age){reset();d.req_valid=1;d.operation=0;d.a_is_wide=0;d.a=0x3f800001;d.b=0x3f800001;d.c=0xbff0000000000000ULL;d.rm=0;d.negate_product=0;d.negate_addend=0;tick();d.req_valid=0;for(unsigned i=0;i<age;++i)tick();reset();for(unsigned i=0;i<20;++i){tick();need(!d.rsp_valid,"late result after reset");}}
 std::printf("PASS fp_wide_arith cases=%llu reset_boundaries=12 seed=c0ac29b7c97c50dd\n",(unsigned long long)count);
}
