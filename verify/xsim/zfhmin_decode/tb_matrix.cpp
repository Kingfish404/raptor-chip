#include <cstdint>
#include <cstdio>
#include "Vrapt_idu_decoder.h"
#include "verilated.h"
static Vrapt_idu_decoder dut;
static unsigned total=0,failures=0,half_cases=0;
static bool half(uint32_t i){
 const unsigned op=i&127,rm=(i>>12)&7,f7=i>>25,rs2=(i>>20)&31;
 if(op==7 || op==39)return rm==1;
 if(op!=83)return false;
 return ((f7==0x72 || f7==0x7a)&&rs2==0&&rm==0)
     || ((f7==0x20 || f7==0x21)&&rs2==2)
     || (f7==0x22 && rs2<=1);
}
static void check(uint32_t i){
 dut.in_inst=i;dut.in_pc=0x80000000;dut.eval();++total;
 const unsigned op=i&127,rm=(i>>12)&7,f7=i>>25,rs1=(i>>15)&31,rs2=(i>>20)&31,rd=(i>>7)&31;
 const bool expected=half(i),got=dut.out_fp_valid && dut.out_fp_op==63;
 bool ok=expected==got;
 if(expected){
  ++half_cases;const bool load=op==7,store=op==39,toint=op==83&&f7==0x72;
  ok &= dut.out_fp_load==load && dut.out_fp_store==store && dut.out_fp_to_int==toint && dut.out_fp_writes_fpr==(!store&&!toint);
  ok &= dut.out_fp_rd==rd && dut.out_fp_rs1==rs1 && dut.out_fp_rs2==rs2 && dut.out_fp_rm==rm;
  if(load||store){
   const unsigned raw=load?(i>>20):(((i>>25)<<5)|rd);
   const int64_t imm=(raw&2048)?int64_t(raw)-4096:raw;
   ok &= dut.out_imm==uint64_t(imm) && dut.out_rs1==rs1;
   if(store)ok &= dut.out_rs2==rs2;
  }
 }
 // Half arithmetic, classify, integer conversions, sign injection are not
 // implemented by this Zfhmin-only core. Other F/D encodings are unconstrained.
 if(op==83 && (f7&3)==2 && !expected)ok &= !dut.out_fp_valid;
 if(!ok){++failures;std::printf("FAIL inst=%08x expected_half=%d fp_valid=%d fp_op=%u\n",i,expected,int(dut.out_fp_valid),unsigned(dut.out_fp_op));}
}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 const unsigned regs[4][2]={{0,0},{31,31},{1,30},{30,1}};
 for(unsigned f7=0;f7<128;f7++)for(unsigned s2=0;s2<32;s2++)for(unsigned rm=0;rm<8;rm++)for(auto &r:regs)
  check((f7<<25)|(s2<<20)|(r[0]<<15)|(rm<<12)|(r[1]<<7)|83);
 const uint32_t bases[]={0xe4000053,0xf4000053,0x40200053,0x42200053,0x44000053,0x44100053};
 for(auto base:bases)for(unsigned s1=0;s1<32;s1++)for(unsigned rd=0;rd<32;rd++)for(unsigned rm=0;rm<8;rm++)check(base|(s1<<15)|(rd<<7)|(rm<<12));
 for(unsigned imm=0;imm<4096;imm++)for(unsigned width=0;width<8;width++)for(auto &r:regs){
  check((imm<<20)|(r[0]<<15)|(width<<12)|(r[1]<<7)|7);
  check(((imm>>5)<<25)|(r[1]<<20)|(r[0]<<15)|(width<<12)|((imm&31)<<7)|39);
 }
 // Every opcode for each required computational encoding (including low bits).
 for(auto base:bases)for(unsigned op=0;op<128;op++)check((base&~127U)|op);
 std::printf("Zfhmin generated decoder TOTAL=%u HALF=%u FAILS=%u\n",total,half_cases,failures);
 dut.final();return failures?1:0;
}
