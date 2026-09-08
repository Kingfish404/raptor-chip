#include "Vrapt_vpu_fp_reduce_decode.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
// RVV encoding constants, independently matched with the opcode mask.
static const uint32_t enc[]={0x04001057,0x0c001057,0x14001057,0x1c001057,0xc4001057,0xcc001057};
static Vrapt_vpu_fp_reduce_decode d;
static uint64_t cases=0;
static void check(uint32_t insn,unsigned sew,unsigned frm,bool enabled,bool vill){
 int kind=-1;for(unsigned i=0;i<6;++i)if((insn&0xfc00707f)==enc[i])kind=i;
 bool legal=kind>=0&&enabled&&!vill&&frm<5&&(sew==2||(sew==3&&TEST_ELEN>=64))&&(kind<4||(sew==2&&TEST_ELEN>=64));
 d.insn=insn;d.sew=sew;d.frm=frm;d.enabled=enabled;d.vill=vill;d.eval();
 unsigned op=legal?(kind==2?1:kind==3?2:0):0;
 if(bool(d.recognized)!=(kind>=0)||bool(d.legal)!=legal||d.operation!=op||
    bool(d.source_double)!=(legal&&sew==3)||bool(d.widen)!=(legal&&kind>=4)||
    bool(d.ordered_sum)!=(legal&&(kind==1||kind==5))){
  std::fprintf(stderr,"FAIL insn=%08x sew=%u frm=%u enabled=%u vill=%u\n",insn,sew,frm,enabled,vill);std::exit(1);
 }
 ++cases;
}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 for(unsigned f=0;f<64;++f)for(unsigned form=0;form<8;++form)
 for(unsigned sew=0;sew<8;++sew)for(unsigned rm=0;rm<8;++rm)
 for(unsigned gate=0;gate<4;++gate)for(unsigned vm=0;vm<2;++vm)
 check((f<<26)|(vm<<25)|(form<<12)|0x57,sew,rm,gate&1,gate&2);
 // All opcode values; arbitrary register fields (including v0/odd registers)
 // and masking must not impose group geometry on scalar seed/destination.
 for(auto instruction:enc)for(unsigned opcode=0;opcode<128;++opcode)
 for(unsigned reg=0;reg<32;++reg)for(unsigned vm=0;vm<2;++vm)
 check((instruction&~0x7fu)|opcode|(reg<<7)|(((reg+7)%32)<<15)|(((reg+13)%32)<<20)|(vm<<25),2,0,true,false);
 std::printf("PASS fp_reduce_decode ELEN=%d cases=%llu\n",TEST_ELEN,(unsigned long long)cases);
}
