#include "Vformal_npc_read_stability.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>

// Real watchdog duration; no hierarchical forcing or reduced timeout.
int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vformal_npc_read_stability d;
  d.clock=0; d.reset=1; d.arvalid=0; d.awvalid=0; d.wvalid=0;
  d.rready=0; d.bready=0; d.araddr=0x80000000; d.arsize=2;
  d.arlen=0; d.arburst=1; d.arid=9; d.awaddr=0x80000008;
  d.awsize=2; d.awlen=0; d.awburst=1; d.awid=3;
  d.wdata=0x12345678; d.wstrb=15; d.wlast=1;
  d.memory_word=0x00260513; d.delay_word=0;
  auto tick=[&](){ d.clock=0; d.eval(); d.clock=1; d.eval(); };
  auto fail=[&](const char* why, unsigned cycle=0){
    std::printf("FAIL %s cycle=%u\n",why,cycle); return 1;
  };
  tick(); tick(); d.reset=0; d.eval();
  bool read=argc>1 && std::strcmp(argv[1],"r")==0;
  bool wait_w=argc>1 && std::strcmp(argv[1],"aw")==0;
  if(read) {
    if(!d.observed_arready) return fail("AR admission");
    d.arvalid=1; tick(); d.arvalid=0;
    for(unsigned i=0;i<1100000;i++) {
      d.memory_word ^= 0xffffffffU; tick();
      if(d.mismatch || !d.observed_rvalid || d.observed_rdata!=0x00260513)
        return fail("R hold",i);
    }
    d.rready=1; tick(); tick();
    if(d.observed_rvalid || !d.observed_arready) return fail("R drain");
  } else {
    if(!d.observed_awready) return fail("AW admission");
    d.awvalid=1; tick(); d.awvalid=0;
    if(wait_w) {
      for(unsigned i=0;i<1100000;i++) {
        tick();
        if(d.observed_bvalid || d.observed_awready || !d.observed_wready)
          return fail("AW ownership before W",i);
      }
    }
    if(!d.observed_wready) return fail("W admission");
    d.wvalid=1; tick(); d.wvalid=0;
    for(unsigned i=0;i<1100000;i++) {
      tick();
      if(d.mismatch || !d.observed_bvalid || d.observed_bresp!=0)
        return fail("B hold",i);
    }
    d.bready=1; tick(); tick();
    if(d.observed_bvalid || !d.observed_awready) return fail("B drain");
  }
  std::printf("PASS %s hold and drain beyond watchdog\n",read?"R":wait_w?"AW/W/B":"B");
  return 0;
}
