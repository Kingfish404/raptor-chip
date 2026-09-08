#include "Vrapt_vpu_fp_transfer.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#ifndef TEST_ELEN
#define TEST_ELEN 64
#define TEST_VLEN 128
#endif
static Vrapt_vpu_fp_transfer d;
struct Encoding{uint32_t match,mask;};
static const Encoding enc[]={{0x5c005057,0xfe00707f},{0x5e005057,0xfff0707f},{0x42001057,0xfe0ff07f},{0x42005057,0xfff0707f},{0x38005057,0xfc00707f},{0x3c005057,0xfc00707f}};
static uint64_t cases,seed=0x416c9fa3d72805beULL;
static uint64_t random64(){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return seed;}
static void check(){
 d.eval();int op=-1;for(unsigned i=0;i<6;++i)if((d.insn&enc[i].mask)==enc[i].match)op=i;
 bool legal=op>=0&&d.enabled&&!d.vill&&d.frm<5&&(d.sew==2||(d.sew==3&&TEST_ELEN==64));
 bool wv=false,wf=false,read=false;unsigned si=0,di=0;uint64_t value=0;
 uint64_t scalar=d.sew==2?((d.scalar>>32)==UINT32_MAX?uint32_t(d.scalar):0x7fc00000):d.scalar;
 uint64_t vector=d.sew==2?uint32_t(d.vector_element):d.vector_element;
 if(legal){
  if(op==2){wf=read=true;value=d.sew==2?(0xffffffff00000000ULL|uint32_t(d.vector_element)):d.vector_element;}
  else if(op==3){wv=d.vstart<d.vl;if(wv)value=scalar;}
  else if(d.index>=d.vstart&&d.index<d.vl){
   if(op<2){wv=true;read=op==0&&!d.mask_bit;di=d.index;si=read?d.index:0;value=read?vector:scalar;}
   else if((d.insn&(1u<<25))||d.mask_bit){
    wv=true;di=d.index;
    if((op==4&&d.index==0)||(op==5&&d.index+1==d.vl))value=scalar;
    else {int64_t position=int64_t(d.index)+(op==4?-1:1);if(position>=0&&uint64_t(position)<d.vlmax){read=true;si=position;value=vector;}}
   }
  }
 }
 if(d.recognized!=(op>=0)||d.legal!=legal||d.operation!=(legal?op:0)||d.write_vector!=wv||d.write_scalar!=wf||d.read_source!=read||d.source_index!=si||d.destination_index!=di||d.result!=value){
  std::fprintf(stderr,"FAIL transfer insn=%08x sew=%u frm=%u index=%u vl=%u start=%u mask=%u op=%d result=%016llx/%016llx\n",d.insn,unsigned(d.sew),unsigned(d.frm),unsigned(d.index),unsigned(d.vl),unsigned(d.vstart),unsigned(d.mask_bit),op,(unsigned long long)d.result,(unsigned long long)value);throw std::runtime_error("transfer mismatch");}
 ++cases;
}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{
 d.enabled=1;d.vill=0;d.frm=0;d.sew=2;d.vl=7;d.vlmax=16;d.vstart=0;d.index=2;d.mask_bit=0;
 d.scalar=0xffffffff7f800001ULL;d.vector_element=0xabcdabcd7f800123ULL;
 for(unsigned opcode=0;opcode<128;++opcode)for(unsigned funct=0;funct<64;++funct)for(unsigned form=0;form<8;++form)for(unsigned vm=0;vm<2;++vm)for(unsigned reg=0;reg<32;++reg){
  d.insn=(funct<<26)|(vm<<25)|(reg<<20)|(reg<<15)|(form<<12)|(reg<<7)|opcode;check();}
 for(const auto&e:enc)for(unsigned vs1=0;vs1<32;++vs1)for(unsigned vs2=0;vs2<32;++vs2)for(unsigned vm=0;vm<2;++vm){
  d.insn=(e.match&~0x03ff8000u)|(vm<<25)|(vs2<<20)|(vs1<<15)|((vs1^vs2)<<7);check();}
 for(const auto&e:enc)for(unsigned sew=0;sew<8;++sew)for(unsigned rm=0;rm<8;++rm)for(unsigned state=0;state<4;++state){
  d.insn=e.match;d.sew=sew;d.frm=rm;d.enabled=state&1;d.vill=bool(state&2);check();}
 d.enabled=1;d.vill=0;d.frm=0;
 const unsigned bounds[]={0,1,2,3,TEST_VLEN/64,TEST_VLEN/32,TEST_VLEN-1,TEST_VLEN};
 for(const auto&e:enc)for(unsigned sew:{2u,3u})for(unsigned vl:bounds)for(unsigned start:bounds)for(unsigned index:bounds)for(unsigned vm=0;vm<2;++vm)for(unsigned mask=0;mask<2;++mask){
  d.insn=(e.match&~(1u<<25))|(vm<<25);d.sew=sew;d.vl=vl;d.vstart=start;d.index=index;d.vlmax=TEST_VLEN;d.mask_bit=mask;check();}
 // Random operand provenance and malformed scalar boxing, including sNaNs;
 // legal raw copies preserve bits, without floating-point arithmetic.
 for(unsigned i=0;i<200000;++i){unsigned op=i%6;d.insn=enc[op].match|(uint32_t(random64())&~enc[op].mask);d.sew=((i/6)&1)?2:3;d.frm=(i>>1)%8;
  d.scalar=random64();if(i&4)d.scalar|=0xffffffff00000000ULL;d.vector_element=random64();
  d.vl=random64()%(TEST_VLEN+1);d.vstart=random64()%(TEST_VLEN+1);d.index=random64()%(TEST_VLEN+1);d.vlmax=TEST_VLEN;d.mask_bit=(i>>3)&1;check();}
 d.final();std::printf("PASS fp_transfer ELEN=%d VLEN=%d cases=%llu seed=416c9fa3d72805be\n",TEST_ELEN,TEST_VLEN,(unsigned long long)cases);return 0;
 }catch(const std::exception&e){std::fprintf(stderr,"%s\n",e.what());return 1;}}
