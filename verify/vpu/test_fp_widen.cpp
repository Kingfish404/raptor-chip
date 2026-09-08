#include "Vrapt_vpu_fp_widen.h"
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
static Vrapt_vpu_fp_widen d;
static uint64_t count,seed=0xbe5466cf34e90c6cULL;
static uint32_t random32(){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return uint32_t(seed);}
static void check(uint32_t bits){
 float32_t x;x.v=bits;softfloat_exceptionFlags=0;
 const auto converted=f32_to_f64(x);const unsigned cls=f32_classify(x);
 d.value=bits;d.eval();float64_t y;y.v=d.result;
 if(cls&0x300){
  // SoftFloat conversion deliberately quiets NaNs. The operand expander must
  // instead retain signaling status until the final arithmetic operation.
  if(f64_classify(y)!=cls || (d.result>>63)!=(bits>>31)
      || ((d.result&0x000fffffffffffffULL)>>29)!=(bits&0x7fffff)
      || (d.result&0x1fffffffULL)!=0)goto fail;
 }else if(d.result!=converted.v || softfloat_exceptionFlags!=0)goto fail;
 ++count;return;
 fail:std::fprintf(stderr,"FAIL widen input=%08x got=%016llx converted=%016llx class=%x\n",bits,(unsigned long long)d.result,(unsigned long long)converted.v,cls);std::exit(1);
}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 // Every signed subnormal and zero: normalization is the only finite path
 // requiring more than a constant exponent offset and fraction padding.
 for(uint32_t f=0;f<0x800000;++f){check(f);check(f|0x80000000);}
 // Every signed NaN payload and infinity checks preservation, including the
 // signaling/quiet boundary, independently of SoftFloat's conversion policy.
 for(uint32_t f=0;f<0x800000;++f){check(0x7f800000|f);check(0xff800000|f);}
 for(unsigned e=1;e<255;++e)for(unsigned bit=0;bit<23;++bit){
  for(uint32_t f:{uint32_t(1u<<bit),uint32_t((1u<<bit)-1),uint32_t(0x7fffff^(1u<<bit))}){
   check((e<<23)|f);check(0x80000000|(e<<23)|f);
  }
 }
 for(unsigned i=0;i<1000000;++i)check(random32());
 std::printf("PASS fp_widen cases=%llu seed=be5466cf34e90c6c\n",(unsigned long long)count);
}
