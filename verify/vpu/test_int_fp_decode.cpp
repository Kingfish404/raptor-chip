#include "Vrapt_vpu_int_fp_decode.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
static Vrapt_vpu_int_fp_decode d;
struct Entry{unsigned selector;bool tofp,uns,rtz;int source_delta,dest_delta;};
static const Entry table[]={
 {0,0,1,0,0,0},{1,0,0,0,0,0},{2,1,1,0,0,0},{3,1,0,0,0,0},{6,0,1,1,0,0},{7,0,0,1,0,0},
 {8,0,1,0,0,1},{9,0,0,0,0,1},{10,1,1,0,0,1},{11,1,0,0,0,1},{14,0,1,1,0,1},{15,0,0,1,0,1},
 {16,0,1,0,1,0},{17,0,0,0,1,0},{18,1,1,0,1,0},{19,1,0,0,1,0},{22,0,1,1,1,0},{23,0,0,1,1,0}};
static uint64_t count;
static void check(uint32_t insn,unsigned sew,unsigned frm,bool enable,bool vill){
 const Entry* e=nullptr;
 for(const auto& t:table)if((insn&127)==0x57&&(insn>>26)==0x12&&((insn>>12)&7)==1&&((insn>>15)&31)==t.selector)e=&t;
 unsigned is=0,fs=0;
 if(e){unsigned src=sew+e->source_delta,dst=sew+e->dest_delta;is=e->tofp?src:dst;fs=e->tofp?dst:src;}
 const bool legal=e&&enable&&!vill&&frm<5&&(fs==2||fs==3)&&is>=1&&is<=3&&(8u<<fs)<=TEST_ELEN&&(8u<<is)<=TEST_ELEN;
 d.insn=insn;d.sew=sew;d.frm=frm;d.enabled=enable;d.vill=vill;d.eval();
 if(d.recognized!=bool(e)||d.legal!=legal||d.to_float!=(legal&&e->tofp)||d.unsigned_integer!=(legal&&e->uns)
   ||d.widen!=(legal&&e->dest_delta)||d.narrow!=(legal&&e->source_delta)||d.float_double!=(legal&&fs==3)
   ||d.integer_size!=(legal?is:0)||d.rounding_mode!=(legal?(e->rtz?1:frm):0)){
  std::fprintf(stderr,"FAIL int_fp_decode insn=%08x sew=%u frm=%u enabled=%u vill=%u\n",insn,sew,frm,enable,vill);std::exit(1);}
 ++count;
}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 for(unsigned opcode=0;opcode<128;++opcode)for(unsigned fn=0;fn<64;++fn)for(unsigned form=0;form<8;++form)
  for(unsigned sel=0;sel<32;++sel)check((fn<<26)|(1u<<25)|(16u<<20)|(sel<<15)|(form<<12)|(8u<<7)|opcode,2,0,true,false);
 for(unsigned sel=0;sel<32;++sel)for(unsigned sew=0;sew<8;++sew)for(unsigned rm=0;rm<8;++rm)
  for(unsigned state=0;state<4;++state)for(unsigned reg=0;reg<32;++reg)
   check((0x12u<<26)|((reg&1)<<25)|(reg<<20)|(sel<<15)|(1u<<12)|(reg<<7)|0x57,sew,rm,state&1,state&2);
 std::printf("PASS int_fp_decode ELEN=%u cases=%llu\n",TEST_ELEN,(unsigned long long)count);
}
