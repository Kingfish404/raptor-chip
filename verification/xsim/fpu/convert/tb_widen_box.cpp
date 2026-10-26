#include <cstdint>
#include <cstdio>
#include "Vrapt_fpu_convert_widen.h"
#include "verilated.h"
static Vrapt_fpu_convert_widen dut;
static void tick(){dut.clock=0;dut.eval();dut.clock=1;dut.eval();}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);dut.reset=1;dut.flush=0;dut.valid=0;
 for(int i=0;i<4;i++)tick();dut.reset=0;tick();unsigned total=0,failures=0;
 const uint32_t values[]={0,1,0x80000000,0x80000001,0x007fffff,0x00800000,0x3f800000,0xbf800000,0x7f7fffff,0xff7fffff,0x7f800000,0xff800000,0x7f800001,0xff800001,0x7fc12345,0xffc12345};
 for(uint32_t v:values)for(unsigned bit=32;bit<=64;bit++){
  // One missing high bit, plus all high bits clear; every case must be qNaN.
  uint64_t raw=bit==64?v:((0xffffffff00000000ULL|v)&~(uint64_t(1)<<bit));
  ++total;if(!dut.ready){++failures;continue;}
  dut.operand=raw;dut.valid=1;tick();dut.valid=0;unsigned cycles=0;
  while(!dut.result_valid&&cycles++<12)tick();
  if(!dut.result_valid||dut.result!=0x7ff8000000000000ULL||dut.flags){++failures;std::printf("FAIL input=%016llx result=%016llx flags=%x\n",(unsigned long long)raw,(unsigned long long)dut.result,dut.flags);}
  tick();if(dut.result_valid)++failures;
 }
 std::printf("%s widen invalid-box checks=%u failures=%u\n",failures?"FAIL":"PASS",total,failures);dut.final();return failures?1:0;
}
