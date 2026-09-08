#include "Vrapt_vpu_fp_misc.h"
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>
static Vrapt_vpu_fp_misc d;
static uint64_t seed=0x452821e638d01377ULL,count;
static uint64_t random64(){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return seed;}
#if TEST_DOUBLE
using FP=float64_t;
#define CLASS f64_classify
#define EQ f64_eq
#define LT f64_lt
#define LE f64_le
#define QUIET_LT f64_lt_quiet
static constexpr uint64_t mask=UINT64_MAX,sign=1ULL<<63,inf=0x7ff0000000000000ULL,qn=0x7ff8000000000000ULL,one=0x3ff0000000000000ULL;
#else
using FP=float32_t;
#define CLASS f32_classify
#define EQ f32_eq
#define LT f32_lt
#define LE f32_le
#define QUIET_LT f32_lt_quiet
static constexpr uint64_t mask=UINT32_MAX,sign=1ULL<<31,inf=0x7f800000ULL,qn=0x7fc00000ULL,one=0x3f800000ULL;
#endif
static void check(uint64_t raw_a,uint64_t raw_b,unsigned op){
 uint64_t a=raw_a&mask,b=raw_b&mask,out=0;
 FP x,y;x.v=a;y.v=b;
 const unsigned ca=CLASS(x),cb=CLASS(y);
 const bool na=ca&0x300,nb=cb&0x300;
 softfloat_exceptionFlags=0;
 switch(op){
  case 0:case 1:{
   // SoftFloat's quiet comparator supplies numeric ordering; CLASS supplies
   // the RISC-V NaN and signed-zero policies independently of DUT bit fields.
   const bool less=QUIET_LT(x,y);
   if(na&&nb)out=qn;
   else if(na)out=b;
   else if(nb)out=a;
   else if((ca&0x18)&&(cb&0x18))out=op?((ca&8)&&(cb&8)?sign:0):((ca&8)||(cb&8)?sign:0);
   else out=op?(less?b:a):(less?a:b);
   break;}
  case 2:out=(a&~sign)|(b&sign);break;
  case 3:out=(a&~sign)|((b^sign)&sign);break;
  case 4:out=a^(b&sign);break;
  case 5:out=ca;break;
  case 6:out=EQ(x,y);break;
  case 7:out=!EQ(x,y);break;
  case 8:out=LT(x,y);break;
  case 9:out=LE(x,y);break;
  case 10:out=LT(y,x);break;
  case 11:out=LE(y,x);break;
 }
 d.a=raw_a;d.b=raw_b;d.operation=op;d.eval();
 if(d.result!=out||d.flags!=softfloat_exceptionFlags||d.illegal!=(op>=12)){
  std::fprintf(stderr,"FAIL misc double=%u op=%u a=%016llx b=%016llx got=%016llx/%u/%u expected=%016llx/%u/%u\n",TEST_DOUBLE,op,(unsigned long long)a,(unsigned long long)b,(unsigned long long)d.result,d.flags,d.illegal,(unsigned long long)out,unsigned(softfloat_exceptionFlags),op>=12);std::exit(1);
 }
 ++count;
}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 const uint64_t quiet_bit=qn^inf,minnormal=TEST_DOUBLE?0x0010000000000000ULL:0x00800000ULL;
 std::vector<uint64_t> values;
 for(uint64_t x:{0ULL,1ULL,2ULL,(unsigned long long)(minnormal-1),(unsigned long long)minnormal,(unsigned long long)(minnormal+1),(unsigned long long)(one-1),(unsigned long long)one,(unsigned long long)(one+1),(unsigned long long)(inf-1),(unsigned long long)inf,(unsigned long long)(inf|1),(unsigned long long)(inf|(quiet_bit-1)),(unsigned long long)qn,(unsigned long long)(qn|1),(unsigned long long)(inf|(minnormal-1))}){
  values.push_back(x);values.push_back(x|sign);
 }
 for(auto a:values)for(auto b:values)for(unsigned op=0;op<16;++op)check(a,b,op);
 // Payload-bit sweeps and the other operand's complete class set.
 for(unsigned bit=0;bit<(TEST_DOUBLE?52u:23u);++bit)for(auto b:values)
  for(unsigned op=0;op<16;++op){check(inf|(1ULL<<bit),b,op);check(b,inf|sign|(1ULL<<bit),op);}
 for(unsigned i=0;i<100000;++i){uint64_t a=random64(),b=random64();
  if(i%4==0)b=a;else if(i%4==1)b=a^sign;
  for(unsigned op=0;op<16;++op)check(a,b,op);
 }
 std::printf("PASS fp_misc Double=%u cases=%llu seed=452821e638d01377\n",TEST_DOUBLE,(unsigned long long)count);
}
