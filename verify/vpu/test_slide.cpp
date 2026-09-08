#include "Vrapt_vpu_slide.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static Vrapt_vpu_slide dut;
static uint64_t cases;
static void check(unsigned cap,unsigned vl,unsigned start,unsigned index,
                  uint64_t offset,bool up,bool single,bool enabled){
    dut.vlmax=cap;dut.vl=vl;dut.vstart=start;dut.index=index;
    dut.offset=offset;dut.up=up;dut.single=single;dut.mask_active=enabled;dut.eval();
    // Signed 128-bit reference coordinates avoid hardware-width wraparound.
    const __int128 source=__int128(index)+(up?-1:1)*__int128(single?1:offset);
    bool write=enabled&&index>=start&&index<vl;
    const bool scalar=write&&single&&(up?index==0:index+1==vl);
    if(write&&!scalar&&source<0)write=false;
    const bool read=write&&!scalar&&source>=0&&source<cap;
    if(dut.write_element!=write||dut.scalar_select!=scalar||dut.read_source!=read
       ||dut.source_index!=(read?unsigned(source):0)){
        std::fprintf(stderr,"slide mismatch cap=%u vl=%u start=%u i=%u off=%llu up=%d single=%d enabled=%d\n",
                     cap,vl,start,index,(unsigned long long)offset,up,single,enabled);
        std::exit(1);
    }
    ++cases;
}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    const uint64_t max=TEST_XLEN==32?UINT32_MAX:UINT64_MAX;
    for(unsigned cap=1;cap<=16;cap*=2)
      for(unsigned vl=0;vl<=cap;++vl)for(unsigned start=0;start<=cap;++start)
       for(unsigned i=0;i<=cap;++i)for(unsigned off=0;off<=cap+1;++off)
        for(unsigned mode=0;mode<8;++mode)check(cap,vl,start,i,off,mode&1,mode&2,mode&4);
    // Every destination at large capacity; source may legally lie beyond VL.
    for(unsigned cap=32;cap<=TEST_VLEN;cap*=2){
      const std::vector<uint64_t> offsets={0,1,31,32,63,64,255,256,cap-1,cap,cap+1,
                                        max,max-1,uint64_t(1)<<(TEST_XLEN-1)};
      for(unsigned vl:{0u,1u,cap/2,cap})for(unsigned start:{0u,1u,cap/2,cap})
       for(unsigned i=0;i<=cap;++i)for(auto off:offsets)
        for(unsigned mode=0;mode<8;++mode)check(cap,vl,start,i,off,mode&1,mode&2,mode&4);
    }
    std::printf("PASS slide XLEN=%u VLEN=%u cases=%llu\n",TEST_XLEN,TEST_VLEN,(unsigned long long)cases);
}
