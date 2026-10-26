#include "Vrapt_vpu_fp_reduce.h"
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <initializer_list>
static Vrapt_vpu_fp_reduce d;
static uint64_t cases,random_state=0x34d59127b6e80facULL;
static uint64_t random64(){random_state^=random_state<<13;random_state^=random_state>>7;random_state^=random_state<<17;return random_state;}
static void need(bool b,const char*m){if(!b){std::fprintf(stderr,"FAIL fp_reduce case=%llu %s got=%016llx flags=%u illegal=%u\n",(unsigned long long)cases,m,(unsigned long long)d.result,unsigned(d.flags),unsigned(d.illegal));std::exit(1);}}
static void tick(){d.clock=0;d.eval();d.clock=1;d.eval();d.clock=0;d.eval();}
static void reset(){d.reset=1;d.req_valid=0;d.element_valid=0;d.rsp_ready=0;tick();need(!d.req_ready&&!d.element_ready&&!d.rsp_valid,"reset gating");d.reset=0;tick();need(d.req_ready&&!d.rsp_valid,"reset drain");}
static uint64_t canonical(uint64_t a,bool dbl){uint64_t exp=dbl?0x7ff0000000000000ULL:0x7f800000,frac=dbl?0xfffffffffffffULL:0x7fffff;return (a&exp)==exp&&(a&frac)?(dbl?0x7ff8000000000000ULL:0x7fc00000):a;}
static uint64_t minmax(uint64_t a,uint64_t b,bool dbl,bool maximum){
 const unsigned f=dbl?52:23;const uint64_t sign=1ULL<<(dbl?63:31),exp=dbl?0x7ff0000000000000ULL:0x7f800000,frac=(1ULL<<f)-1;
 if(!dbl){a=uint32_t(a);b=uint32_t(b);}bool an=(a&exp)==exp&&(a&frac),bn=(b&exp)==exp&&(b&frac);
 if((an&&!(a&(1ULL<<(f-1))))||(bn&&!(b&(1ULL<<(f-1)))))softfloat_exceptionFlags|=16;
 if(an&&bn)return dbl?0x7ff8000000000000ULL:0x7fc00000;if(an)return b;if(bn)return a;
 if(!(a&~sign)&&!(b&~sign))return maximum?(a&b):(a|b);
 bool less=dbl?f64_lt_quiet(float64_t{a},float64_t{b}):f32_lt_quiet(float32_t{uint32_t(a)},float32_t{uint32_t(b)});
 return maximum?(less?b:a):(less?a:b);
}
static void check(unsigned op,bool dbl,bool wide,unsigned rm,uint64_t seed,const std::vector<uint64_t>& values,unsigned mask){
 const bool bad=op==3||rm>4||(wide&&(dbl||op!=0))||(TEST_ELEN<64&&(dbl||wide));
 const bool dest_double=dbl||wide;uint64_t expected=bad?0:dest_double?seed:uint32_t(seed);unsigned flags=0;
 softfloat_roundingMode=rm;softfloat_exceptionFlags=0;softfloat_detectTininess=softfloat_tininess_afterRounding;
 if(!bad)for(unsigned i=0;i<values.size();++i)if((mask>>(i%32))&1){
  uint64_t b=values[i];if(wide)b=f32_to_f64(float32_t{uint32_t(b)}).v;
  if(op==0)expected=canonical(dest_double?f64_add(float64_t{expected},float64_t{b}).v:f32_add(float32_t{uint32_t(expected)},float32_t{uint32_t(b)}).v,dest_double);
  else expected=minmax(expected,b,dest_double,op==2);
 }
 flags=bad?0:softfloat_exceptionFlags;
 d.req_valid=1;d.op=op;d.source_double=dbl;d.widen=wide;d.rm=rm;d.count=values.size();d.seed=seed;d.element_valid=0;d.rsp_ready=0;d.eval();need(d.req_ready,"admission");tick();
 d.op=op^3;d.source_double=!dbl;d.widen=!wide;d.rm=rm^7;d.seed=~seed;d.count=values.size()^63;
 if(!bad)for(unsigned i=0;i<values.size();++i){
  for(unsigned gap=0;gap<(i%3);++gap){d.element_valid=0;tick();need(!d.req_ready&&!d.rsp_valid,"stream gap");}
  d.element_valid=1;d.element=values[i];d.element_active=(mask>>(i%32))&1;d.eval();
  unsigned age=0;while(!d.element_ready){need(!d.req_ready&&!d.rsp_valid,"premature completion");tick();need(++age<30,"element backpressure timeout");}
  tick();d.element_valid=0;d.element=~values[i];d.element_active=!d.element_active;
 }
 unsigned age=0;while(!d.rsp_valid){tick();need(!d.req_ready,"second command admitted");need(++age<30,"result timeout");}
 need(d.result==expected&&d.flags==flags&&bool(d.illegal)==bad&&bool(d.write_result)==(!bad&&!values.empty()),"result/flags/write");
 d.element_valid=1;d.element=random64();d.element_active=1;
 for(unsigned stall=0;stall<4;++stall){tick();need(d.rsp_valid&&!d.req_ready&&!d.element_ready&&d.result==expected&&d.flags==flags&&bool(d.illegal)==bad&&bool(d.write_result)==(!bad&&!values.empty()),"response hold");}
 d.req_valid=0;d.element_valid=0;d.rsp_ready=1;tick();d.rsp_ready=0;tick();need(d.req_ready&&!d.rsp_valid&&!d.element_ready,"release");++cases;
}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);reset();
 const uint64_t narrow[]={0,0x80000000,1,0x807fffff,0x00800000,0x3f800000,0xbf800000,0x7f7fffff,0x7f800000,0xff800000,0x7f800001,0x7fc01234};
 const uint64_t full[]={0,0x8000000000000000ULL,1,0x800fffffffffffffULL,0x0010000000000000ULL,0x3ff0000000000000ULL,0xbff0000000000000ULL,0x7fefffffffffffffULL,0x7ff0000000000000ULL,0xfff0000000000000ULL,0x7ff0000000000001ULL,0x7ff8123456789abcULL};
 for(unsigned shape=0;shape<3;++shape)for(unsigned op=0;op<3;++op)for(unsigned rm=0;rm<5;++rm)for(unsigned seed=0;seed<12;++seed)for(unsigned len:{0u,1u,2u,3u,7u,16u})for(unsigned pattern=0;pattern<4;++pattern){
  bool dbl=shape==1,wide=shape==2;std::vector<uint64_t> values;for(unsigned i=0;i<len;++i)values.push_back((dbl?full:narrow)[(i+seed)%12]);
  unsigned mask=pattern==0?0:pattern==1?~0u:pattern==2?0x55555555:len?1u<<(len-1):0;
  check(op,dbl,wide,rm,(dbl||wide?full:narrow)[seed],values,mask);
 }
 for(unsigned i=0;i<20000;++i){unsigned len=random64()%21;std::vector<uint64_t> v;for(unsigned j=0;j<len;++j)v.push_back(random64());uint64_t seed=random64();unsigned mask=random64();check(i%4,(i/4)&1,(i/8)&1,(i/16)%8,seed,v,mask);}
 // Counter high bits and transitions across byte/half-range boundaries.
 for(unsigned shape=0;shape<(TEST_ELEN==64?3u:1u);++shape)for(unsigned len:{255u,256u,511u,512u,1023u})for(unsigned op=0;op<3;++op){
  std::vector<uint64_t> values(len,shape==1?full[5]:narrow[5]);
  check(op,shape==1,shape==2,0,0,values,~0u);
 }
 for(unsigned shape=0;shape<(TEST_ELEN==64?3u:1u);++shape)for(unsigned age=0;age<32;++age){
  reset();d.req_valid=1;d.op=0;d.source_double=shape==1;d.widen=shape==2;d.rm=0;d.seed=0;d.count=4;tick();d.req_valid=0;d.element_valid=1;d.element_active=1;d.element=shape==1?full[5]:narrow[5];
  for(unsigned j=0;j<age;++j)tick();reset();for(unsigned j=0;j<30;++j){tick();need(!d.rsp_valid,"late result after reset");}
 }
 std::printf("PASS fp_reduce ELEN=%d cases=%llu reset_boundaries=%u seed=34d59127b6e80fac\n",TEST_ELEN,(unsigned long long)cases,TEST_ELEN==64?96:32);
}
