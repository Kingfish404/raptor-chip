#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <vector>
#include "Vtb.h"
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
static Vtb dut;
static unsigned comparisons=0,signs=0,classes=0,failures=0;
static uint64_t canon(bool d){return d?0x7ff8000000000000ULL:0xffffffff7fc00000ULL;}
static uint64_t box(uint64_t x,bool d){return d?x:(0xffffffff00000000ULL|uint32_t(x));}
static uint64_t value(uint64_t x,bool d){return !d&&(x>>32)!=0xffffffffULL?canon(false):x;}
static bool nan(uint64_t x,bool d){return d?(x&0x7fffffffffffffffULL)>0x7ff0000000000000ULL:(x&0x7fffffff)>0x7f800000;}
static bool snan(uint64_t x,bool d){return nan(x,d)&&!(x&(uint64_t(1)<<(d?51:22)));}
static void fail(const char* kind,uint64_t a,uint64_t b,unsigned op){if(++failures<=20)std::printf("FAIL %s d=%u op=%u a=%016llx b=%016llx\n",kind,dut.is_double,op,(unsigned long long)a,(unsigned long long)b);}
static void classify(uint64_t raw,bool d){
 uint64_t a=value(raw,d);int cl;bool neg;
 if(d){double v;std::memcpy(&v,&a,8);cl=std::fpclassify(v);neg=std::signbit(v);}
 else{uint32_t bits=a;float v;std::memcpy(&v,&bits,4);cl=std::fpclassify(v);neg=std::signbit(v);}
 unsigned index=cl==FP_NAN?(snan(a,d)?8:9):cl==FP_INFINITE?(neg?0:7):cl==FP_ZERO?(neg?3:4):cl==FP_SUBNORMAL?(neg?2:5):(neg?1:6);
 dut.is_double=d;dut.a=raw;dut.eval();++classes;
 if(dut.classification!=(1u<<index))fail("classify",raw,0,0);
}
static void pair(uint64_t raw_a,uint64_t raw_b,bool d){
 uint64_t a=value(raw_a,d),b=value(raw_b,d),sm=uint64_t(1)<<(d?63:31);
 dut.is_double=d;dut.a=raw_a;dut.b=raw_b;
 for(unsigned op=0;op<5;op++){
  softfloat_exceptionFlags=0;uint64_t expected;
  if(op<3){
   if(d){float64_t x{a},y{b};expected=op==0?f64_eq(x,y):op==1?f64_lt(x,y):f64_le(x,y);}
   else{float32_t x{uint32_t(a)},y{uint32_t(b)};expected=op==0?f32_eq(x,y):op==1?f32_lt(x,y):f32_le(x,y);}
  }else{
   bool less=d?f64_lt_quiet(float64_t{a},float64_t{b}):f32_lt_quiet(float32_t{uint32_t(a)},float32_t{uint32_t(b)});
   bool az=d?(a&~sm)==0:uint32_t(a&~sm)==0,bz=d?(b&~sm)==0:uint32_t(b&~sm)==0;
   if(nan(a,d)&&nan(b,d))expected=canon(d);
   else if(nan(a,d))expected=b;
   else if(nan(b,d))expected=a;
   else if(az&&bz)expected=box(op==3?((a|b)&sm):((a&b)&sm),d);
   else expected=op==3?(less?a:b):(less?b:a);
   // RISC-V min/max quiet-NaN behavior differs from ordinary comparisons.
   softfloat_exceptionFlags=(snan(a,d)||snan(b,d))?softfloat_flag_invalid:0;
  }
  unsigned flags=softfloat_exceptionFlags;dut.choice=op;dut.eval();++comparisons;
  if(dut.cmp!=expected||dut.flags!=flags)fail("compare",raw_a,raw_b,op);
  if(op<3){uint64_t sign=op==0?(b&sm):op==1?((~b)&sm):((a^b)&sm);uint64_t e=(a&~sm)|sign;++signs;if(dut.sgnj!=e)fail("sgnj",raw_a,raw_b,op);}
 }
}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 uint64_t rng=0x9e3779b97f4a7c15ULL;
 for(unsigned d=0;d<2;d++){
  unsigned f=d?52:23,exps=d?2048:256;uint64_t sm=uint64_t(1)<<(d?63:31),max=(uint64_t(exps-1)<<f),half=uint64_t(1)<<(f-1);
  std::vector<uint64_t> corners;
  for(uint64_t v:{uint64_t(0),uint64_t(1),(uint64_t(1)<<f)-1,uint64_t(1)<<f,max-1,max,max|1,max|half})for(uint64_t sign:{uint64_t(0),sm})corners.push_back(box(v|sign,d));
  if(!d)for(unsigned bit=32;bit<64;bit++)corners.push_back(canon(false)&~(uint64_t(1)<<bit));
  for(auto a:corners){classify(a,d);for(auto b:corners)pair(a,b,d);}
  for(unsigned e=0;e<exps;e++)for(uint64_t frac:{uint64_t(0),uint64_t(1),half-1,half,(uint64_t(1)<<f)-1})for(uint64_t sign:{uint64_t(0),sm})classify(box((uint64_t(e)<<f)|frac|sign,d),d);
  for(unsigned i=0;i<8192;i++){rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;uint64_t a=box(rng,d);rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;uint64_t b=box(rng,d);pair(a,b,d);classify(a,d);}
 }
 std::printf("%s nonarith compare=%u sgnj=%u classify=%u failures=%u\n",failures?"FAIL":"PASS",comparisons,signs,classes,failures);dut.final();return failures?1:0;
}
