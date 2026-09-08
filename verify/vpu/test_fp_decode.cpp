#include "Vrapt_vpu_fp_decode.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
static Vrapt_vpu_fp_decode d;
struct Entry {unsigned funct,op,ai,bi,ci,signs;bool scalar_only,old; bool divsqrt=false,sqrt=false; int misc=-1; bool widen=false,wide_a=false; int convert=-1;};
// Operand slots: 0=vs2, 1=vs1/FPR, 2=old vd, 3=zero. This table follows
// architectural equations, not the RTL's encoding-bit equations.
static const Entry table[]={
 {0x13,0,0,3,3,0,false,false,false,false,12},
 {0x13,0,0,3,3,0,false,false,false,false,13},
 {0x12,0,0,3,3,0,false,false,false,false,-1,true,false,0},
 {0x12,0,0,3,3,0,false,false,false,false,-1,false,false,1},
 {0x12,0,0,3,3,0,false,false,false,false,-1,false,false,2},
 {0x30,1,0,1,3,0,false,false,false,false,-1,true,false},
 {0x32,2,0,1,3,0,false,false,false,false,-1,true,false},
 {0x34,1,0,1,3,0,false,false,false,false,-1,true,true},
 {0x36,2,0,1,3,0,false,false,false,false,-1,true,true},
 {0x38,3,0,1,3,0,false,false,false,false,-1,true,false},
 {0x3c,0,1,0,2,0,false,true,false,false,-1,true,false},
 {0x3d,0,1,0,2,3,false,true,false,false,-1,true,false},
 {0x3e,0,1,0,2,1,false,true,false,false,-1,true,false},
 {0x3f,0,1,0,2,2,false,true,false,false,-1,true,false},
 {0x04,0,0,1,3,0,false,false,false,false,0},
 {0x06,0,0,1,3,0,false,false,false,false,1},
 {0x08,0,0,1,3,0,false,false,false,false,2},
 {0x09,0,0,1,3,0,false,false,false,false,3},
 {0x0a,0,0,1,3,0,false,false,false,false,4},
 {0x13,0,0,3,3,0,false,false,false,false,5},
 {0x18,0,0,1,3,0,false,false,false,false,6},
 {0x1c,0,0,1,3,0,false,false,false,false,7},
 {0x1b,0,0,1,3,0,false,false,false,false,8},
 {0x19,0,0,1,3,0,false,false,false,false,9},
 {0x1d,0,0,1,3,0,true,false,false,false,10},
 {0x1f,0,0,1,3,0,true,false,false,false,11},
 {0x20,0,0,1,3,0,false,false,true,false},{0x21,0,1,0,3,0,true,false,true,false},
 {0x13,0,0,3,3,0,false,false,true,true},
 {0x00,1,0,1,3,0,false,false},{0x02,2,0,1,3,0,false,false},
 {0x24,3,0,1,3,0,false,false},{0x27,2,1,0,3,0,true,false},
 {0x28,0,1,2,0,0,false,true},{0x29,0,1,2,0,3,false,true},
 {0x2a,0,1,2,0,1,false,true},{0x2b,0,1,2,0,2,false,true},
 {0x2c,0,1,0,2,0,false,true},{0x2d,0,1,0,2,3,false,true},
 {0x2e,0,1,0,2,1,false,true},{0x2f,0,1,0,2,2,false,true}};
static uint64_t count;
static void check(uint32_t insn,unsigned sew,unsigned rm,bool enabled,bool vill){
 d.insn=insn;d.sew=sew;d.frm=rm;d.enabled=enabled;d.vill=vill;d.eval();
 const unsigned form=(insn>>12)&7;
 const Entry* entry=nullptr;
 for(const auto&e:table)if((insn&127)==0x57&&(form==1||form==5)&&(insn>>26)==e.funct&&(!e.scalar_only||form==5)&&(!e.sqrt||(form==1&&((insn>>15)&31)==0))&&(e.misc!=5||(form==1&&((insn>>15)&31)==16))&&(e.misc<12||(form==1&&((insn>>15)&31)==(e.misc==12?5u:4u)))&&(e.convert<0||(form==1&&((insn>>15)&31)==(e.convert==0?12u:e.convert==1?20u:21u))))entry=&e;
 const bool legal=entry&&enabled&&!vill&&rm<5&&(sew==2||(sew==3&&TEST_ELEN==64))&&(!(entry->widen||entry->convert>=0)||(sew==2&&TEST_ELEN==64));
 uint64_t scalar=d.scalar;
 if(sew==2&&(scalar>>32)!=UINT32_MAX)scalar=0x7fc00000;
 const uint64_t data[]={d.vs2,form==5?scalar:uint64_t(d.vs1),d.old_destination,0};
 const uint64_t mask=sew==2?UINT32_MAX:UINT64_MAX;
 if(d.recognized!=bool(entry)||d.legal!=legal||d.source_scalar!=(legal&&form==5)
    ||d.format_convert!=(legal&&entry->convert>=0)||d.narrow!=(legal&&entry->convert>0)||d.round_odd!=(legal&&entry->convert==2)
    ||d.widen!=(legal&&entry->widen)||d.wide_source_a!=(legal&&entry->wide_a)
    ||d.divide_sqrt!=(legal&&entry->divsqrt)||d.sqrt_operation!=(legal&&entry->sqrt)
    ||d.uses_vs1!=(legal&&!entry->sqrt&&entry->misc!=5&&entry->misc<12&&entry->convert<0)
    ||d.miscellaneous!=(legal&&entry->misc>=0)||d.mask_result!=(legal&&entry->misc>=6&&entry->misc<=11)
    ||d.misc_operation!=(legal&&entry->misc>=0?entry->misc:0)
    ||d.uses_old_destination!=(legal&&entry->old)||d.operation!=(legal?entry->op:0)
    ||d.negate_product!=(legal?entry->signs>>1:0)||d.negate_addend!=(legal?entry->signs&1:0)
    ||d.a!=(legal?data[entry->ai]&((entry->wide_a||entry->convert>0)?UINT64_MAX:mask):0)||d.b!=(legal?data[entry->bi]&mask:0)||d.c!=(legal?data[entry->ci]&(entry->widen?UINT64_MAX:mask):0)){
   std::fprintf(stderr,"FAIL fp decode insn=%08x sew=%u frm=%u enabled=%d vill=%d\n",insn,sew,rm,enabled,vill);std::exit(1);
 }
 ++count;
}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 d.vs2=0x123456783f800000ULL;d.vs1=0x8765432140000000ULL;d.old_destination=0xabcdabcd40400000ULL;d.scalar=0xffffffff40800000ULL;
 for(unsigned opcode=0;opcode<128;++opcode)for(unsigned funct=0;funct<64;++funct)
  for(unsigned form=0;form<8;++form)for(unsigned vm=0;vm<2;++vm)
   check((funct<<26)|(vm<<25)|(16<<20)|(24<<15)|(form<<12)|(8<<7)|opcode,2,0,true,false);
 for(unsigned funct=0;funct<64;++funct)for(unsigned form=0;form<8;++form)
  for(unsigned sew=0;sew<8;++sew)for(unsigned rm=0;rm<8;++rm)for(unsigned state=0;state<4;++state)
   check((funct<<26)|(form<<12)|0x57,sew,rm,state&1,state&2);
 // Unary selectors must each see the full type/rounding/enable matrix;
 // selector zero alone only exercises square root admission.
 for(unsigned selector=0;selector<32;++selector)for(unsigned form=0;form<8;++form)
  for(unsigned sew=0;sew<8;++sew)for(unsigned rm=0;rm<8;++rm)for(unsigned state=0;state<4;++state)
   check((0x13u<<26)|(selector<<15)|(form<<12)|0x57,sew,rm,state&1,state&2);
 // Every bit of scalar/vector inputs, valid and invalid scalar NaN boxes,
 // and changing register identities must retain operand provenance.
 for(unsigned bit=0;bit<64;++bit)for(unsigned box=0;box<3;++box){
  d.vs2=uint64_t(1)<<bit;d.vs1=~uint64_t(d.vs2);d.old_destination=0x0123456789abcdefULL^d.vs2;
  d.scalar=box==0?d.vs2:box==1?0xffffffff00000000ULL|uint32_t(d.vs2):0xfffffff000000000ULL|uint32_t(d.vs2);
  for(const auto&e:table)for(unsigned form:{1u,5u})for(unsigned sew:{2u,3u})for(unsigned reg=0;reg<32;++reg)
   check((e.funct<<26)|((reg&1)<<25)|(reg<<20)|(reg<<15)|(form<<12)|(reg<<7)|0x57,sew,4,true,false);
 }
 std::printf("PASS fp_decode ELEN=%u cases=%llu\n",TEST_ELEN,(unsigned long long)count);
}
