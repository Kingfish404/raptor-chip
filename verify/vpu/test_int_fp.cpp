#include "Vrapt_vpu_int_fp.h"
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
static Vrapt_vpu_int_fp d;
static uint64_t count,seed=0x9216d5d98979fb1bULL;
static constexpr uint64_t imask=UINT64_MAX>>(64-TEST_INT_BITS);
static uint64_t random64(){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return seed;}
static void need(bool b,const char*m){if(!b){std::fprintf(stderr,"FAIL int_fp %s case=%llu\n",m,(unsigned long long)count);std::exit(1);}}
static void tick(){d.clock=0;d.eval();d.clock=1;d.eval();d.clock=0;d.eval();}
static void reset(){d.reset=1;tick();need(!d.req_ready&&!d.rsp_valid,"reset outputs");d.reset=0;d.req_valid=0;d.rsp_ready=0;tick();need(d.req_ready&&!d.rsp_valid,"reset drain");}
static void check(uint64_t value,bool tofp,bool uns,unsigned rm){
 uint64_t expected=0;unsigned flags=0;
 softfloat_roundingMode=rm;softfloat_exceptionFlags=0;softfloat_detectTininess=softfloat_tininess_afterRounding;
 if(rm<5){
  if(tofp){uint64_t u=value&imask;int64_t i=int64_t(u);
   if(TEST_INT_BITS<64&&(u&(1ULL<<(TEST_INT_BITS-1))))i=int64_t(u|~imask);
   expected=TEST_DOUBLE?(uns?ui64_to_f64(u).v:i64_to_f64(i).v):(uns?ui64_to_f32(u).v:i64_to_f32(i).v);
  }else{
   const float32_t x{uint32_t(value)};const float64_t y{value};
   if(TEST_INT_BITS==64)expected=TEST_DOUBLE?(uns?f64_to_ui64(y,rm,true):uint64_t(f64_to_i64(y,rm,true))):(uns?f32_to_ui64(x,rm,true):uint64_t(f32_to_i64(x,rm,true)));
   else if(TEST_INT_BITS==32)expected=TEST_DOUBLE?(uns?f64_to_ui32(y,rm,true):uint32_t(f64_to_i32(y,rm,true))):(uns?f32_to_ui32(x,rm,true):uint32_t(f32_to_i32(x,rm,true)));
   else if(!TEST_DOUBLE)expected=uns?f32_to_ui16(x,rm,true):uint16_t(f32_to_i16(x,rm,true));
   else { // Independent 64-bit SoftFloat conversion, then mathematical 16-bit range.
    if(uns){expected=f64_to_ui64(y,rm,true);if(expected>65535){expected=65535;softfloat_exceptionFlags=softfloat_flag_invalid;}}
    else {int64_t v=f64_to_i64(y,rm,true);if(v>32767){v=32767;softfloat_exceptionFlags=softfloat_flag_invalid;}if(v< -32768){v=-32768;softfloat_exceptionFlags=softfloat_flag_invalid;}expected=uint16_t(v);}
   }
   expected&=imask;
  }
  flags=softfloat_exceptionFlags;
 }
 d.req_valid=1;d.rsp_ready=0;d.operand=value;d.to_float=tofp;d.unsigned_integer=uns;d.rm=rm;d.eval();need(d.req_ready,"request ready");tick();
 d.operand=~value;d.to_float=!tofp;d.unsigned_integer=!uns;d.rm=rm^7;unsigned age=0;
 while(!d.rsp_valid){need(!d.req_ready,"busy accepts");tick();need(++age<12,"timeout");}
 if(d.result!=expected||d.flags!=flags||d.illegal!=(rm>4)){std::fprintf(stderr,"double=%u intbits=%u value=%016llx tofp=%u unsigned=%u rm=%u got=%016llx/%u expected=%016llx/%u\n",TEST_DOUBLE,TEST_INT_BITS,(unsigned long long)value,tofp,uns,rm,(unsigned long long)d.result,d.flags,(unsigned long long)expected,flags);need(false,"result");}
 for(unsigned i=0;i<3;++i){tick();need(d.rsp_valid&&!d.req_ready&&d.result==expected&&d.flags==flags&&d.illegal==(rm>4),"held response");}
 d.req_valid=0;d.rsp_ready=1;tick();d.rsp_ready=0;tick();need(d.req_ready&&!d.rsp_valid,"drained");++count;
}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);reset();
 // Every exponent with endpoint and halfway fractions, both signs: exercises
 // integer range clipping after rounding, NaNs, infinities and small negatives.
 const unsigned fracbits=TEST_DOUBLE?52:23,maxexp=TEST_DOUBLE?2048:256;
 const uint64_t fracmask=(1ULL<<fracbits)-1;
 for(unsigned e=0;e<maxexp;++e)for(uint64_t f:{0ULL,1ULL,(unsigned long long)(fracmask>>1),(unsigned long long)((fracmask>>1)+1),(unsigned long long)fracmask})
  for(unsigned sign=0;sign<2;++sign)for(unsigned uns=0;uns<2;++uns)for(unsigned rm=0;rm<8;++rm)
   check((uint64_t(sign)<<(TEST_DOUBLE?63:31))|(uint64_t(e)<<fracbits)|f,false,uns,rm);
 for(unsigned bit=0;bit<64;++bit)for(int delta=-2;delta<=2;++delta)for(unsigned neg=0;neg<2;++neg)
  for(unsigned uns=0;uns<2;++uns)for(unsigned rm=0;rm<8;++rm){uint64_t v=(1ULL<<bit)+delta;check(neg?-v:v,true,uns,rm);}
 for(unsigned i=0;i<60000;++i)check(random64(),i&1,(i/2)&1,(i/4)%8);
 for(unsigned dir=0;dir<2;++dir)for(unsigned age=0;age<10;++age){reset();d.req_valid=1;d.to_float=dir;d.unsigned_integer=0;d.operand=0x43dfffffffffffffULL;d.rm=0;tick();d.req_valid=0;for(unsigned j=0;j<age;++j)tick();reset();for(unsigned j=0;j<15;++j){tick();need(!d.rsp_valid,"late result after reset");}}
 std::printf("PASS int_fp Double=%u IntBits=%u cases=%llu reset_boundaries=20 seed=9216d5d98979fb1b\n",TEST_DOUBLE,TEST_INT_BITS,(unsigned long long)count);
}
