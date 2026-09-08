#include "Vrapt_vpu_fp_estimate.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <stdexcept>
extern "C" {
#include "softfloat.h"
}
#ifndef TEST_DOUBLE
#define TEST_DOUBLE 1
#endif
static Vrapt_vpu_fp_estimate dut;
static uint64_t cases,seed=0x7e915cd21647ab39ULL;
static uint64_t random64(){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return seed;}
static void check(uint64_t value,unsigned op,unsigned rm){
 dut.operand=value;dut.reciprocal_sqrt=op;dut.rm=rm;dut.eval();
 uint64_t expected=0;unsigned flags=0;
 if(rm<=4){softfloat_exceptionFlags=0;softfloat_roundingMode=rm;
  if(TEST_DOUBLE){float64_t a{value};expected=op?f64_rsqrte7(a).v:f64_recip7(a).v;}
  else{float32_t a{uint32_t(value)};expected=op?f32_rsqrte7(a).v:f32_recip7(a).v;}
  flags=softfloat_exceptionFlags;
 }
 if(dut.result!=expected||dut.flags!=flags||bool(dut.illegal)!=(rm>4)){
  std::fprintf(stderr,"FAIL estimate double=%d a=%016llx sqrt=%u rm=%u got=%016llx/%u/%u want=%016llx/%u/%u\n",TEST_DOUBLE,(unsigned long long)value,op,rm,(unsigned long long)dut.result,unsigned(dut.flags),unsigned(dut.illegal),(unsigned long long)expected,flags,rm>4);throw std::runtime_error("estimate mismatch");
 }
 ++cases;
}
static void all(uint64_t value){for(unsigned op=0;op<2;++op)for(unsigned rm=0;rm<8;++rm)check(value,op,rm);}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{
 constexpr unsigned f=TEST_DOUBLE?52:23,e=TEST_DOUBLE?11:8;const uint64_t sign=1ULL<<(f+e),mask=(1ULL<<f)-1;
 // Every exponent, table interval and interval endpoint in both signs. This
 // includes zeros, infinities, quiet/signaling NaNs and output subnormals.
 for(unsigned exp=0;exp<(1u<<e);++exp)for(unsigned bucket=0;bucket<128;++bucket)
 for(unsigned end=0;end<2;++end){uint64_t a=(uint64_t(exp)<<f)|(uint64_t(bucket)<<(f-7))|(end?((1ULL<<(f-7))-1):0);all(a);all(a|sign);}
 // Every possible subnormal leading bit, with the following lookup bits and
 // both interval endpoints, stresses normalization across the full exponent range.
 for(unsigned leading=0;leading<f;++leading)for(unsigned bucket=0;bucket<128;++bucket)for(unsigned end=0;end<2;++end){
  uint64_t a=(1ULL<<leading)|((uint64_t(bucket)<<(f-7))>>(f-leading));
  if(end&&leading>7)a|=(1ULL<<(leading-7))-1;
  all(a);all(a|sign);
 }
 for(unsigned i=0;i<200000;++i){uint64_t a=random64();check(a,i&1,(i>>1)%8);}
 // These four examples are explicit values in the vector specification.
 if(!TEST_DOUBLE){
  const uint64_t inputs[]={0x00718abc,0x7f765432,0x00718abc,0x7f765432};
  const uint64_t outputs[]={0x7e900000,0x00214000,0x5f080000,0x1f820000};
  for(unsigned i=0;i<4;++i){check(inputs[i],i/2,0);if(dut.result!=outputs[i]||dut.flags)throw std::runtime_error("normative example mismatch");}
 }
 // Upper raw FP32 bits are ignored, including malformed scalar NaN boxes.
 if(!TEST_DOUBLE)for(unsigned i=0;i<10000;++i)all((random64()&~mask)|uint32_t(random64()));
 dut.final();std::printf("PASS fp_estimate Double=%d cases=%llu seed=7e915cd21647ab39\n",TEST_DOUBLE,(unsigned long long)cases);return 0;
 }catch(const std::exception& e){std::fprintf(stderr,"%s\n",e.what());return 1;}}
