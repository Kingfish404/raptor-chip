#include <cstdio>
#include <cstdint>
extern "C" {
#include "softfloat.h"
}
void row(uint64_t operand,bool d){
 uint16_t h=(operand>>16)==0xffffffffffffULL?uint16_t(operand):0x7e00;
 softfloat_exceptionFlags=0;uint64_t v;
 if(d){v=f16_to_f64(float16_t{h}).v;if((v&0x7ff0000000000000ULL)==0x7ff0000000000000ULL&&(v&0xfffffffffffffULL))v=0x7ff8000000000000ULL;}
 else{uint32_t u=f16_to_f32(float16_t{h}).v;if((u&0x7f800000)==0x7f800000&&(u&0x7fffff))u=0x7fc00000;v=0xffffffff00000000ULL|u;}
 printf(".quad 0x%016llx, 0x%016llx\n.word %u, 0\n",(unsigned long long)operand,(unsigned long long)v,unsigned(softfloat_exceptionFlags));
}
int main(){
 const uint16_t edges[]={0,0x8000,1,0x8001,0x3ff,0x400,0x3c00,0xbc00,0x4000,0x3bff,0x7bff,0xfbff,0x7c00,0xfc00,0x7c01,0x7e00};
 for(int d=0;d<2;d++){
  printf("#if CASE_KIND == %d\n",d);
  for(auto h:edges){row(0xffffffffffff0000ULL|h,d);row(h,d);for(int bit=16;bit<64;bit++)row((0xffffffffffff0000ULL|h)&~(1ULL<<bit),d);}
  puts("#endif");
 }
}
