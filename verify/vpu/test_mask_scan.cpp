#include "Vrapt_vpu_mask_scan.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
static Vrapt_vpu_mask_scan d;
static std::array<uint8_t,32*TEST_VLEN/8> mem;
static uint64_t cycles=0,requests=0,cases=0,rng=0xbe5466cf34e90c6cULL;
static bool pending=false;
static unsigned delay=0;
static uint8_t response=0;
static void check(bool v,const char* s){if(!v)throw std::runtime_error(s);}
static uint64_t random64(){rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;return rng;}
static void tick(){
    d.clock=0;d.vr_ready=!pending&&cycles%5>=2;d.vr_rsp_valid=pending&&!delay;d.vr_rdata=response;d.eval();
    const bool req=d.vr_valid&&d.vr_ready,ack=d.vr_rsp_valid&&d.vr_rsp_ready;
    uint8_t next=0;
    if(req){check(!pending&&d.vr_addr<mem.size(),"bad scan request");next=mem[d.vr_addr];++requests;}
    d.clock=1;d.eval();d.clock=0;d.eval();++cycles;
    if(ack)pending=false;
    if(pending&&delay)--delay;
    if(req){pending=true;response=next;delay=1+cycles%4;}
}
static void run(bool first,bool masked,unsigned src,unsigned vl,unsigned start=0,bool vill=false){
    const uint64_t all=TEST_XLEN==64?UINT64_MAX:UINT32_MAX;
    uint64_t expected=first?all:0;
    unsigned scanned=vl;
    const bool bad=start||vill||vl>TEST_VLEN;
    if(!bad)for(unsigned i=0;i<vl;++i){
        const bool active=((mem[src*(TEST_VLEN/8)+i/8]>>(i%8))&1)&&(!masked||((mem[i/8]>>(i%8))&1));
        if(active){if(first){expected=i;scanned=i+1;break;}++expected;}
    }
    d.cmd_first=first;d.cmd_masked=masked;d.cmd_src=src;d.cmd_vl=vl;d.cmd_vstart=start;d.cmd_vill=vill;
    d.cmd_valid=1;d.done_ready=0;check(d.cmd_ready,"scan not ready");const auto before=requests;tick();d.cmd_valid=0;
    d.cmd_first=!first;d.cmd_masked=!masked;d.cmd_src=0;d.cmd_vl=0;d.cmd_vstart=0;d.cmd_vill=0;
    unsigned timeout=0;
    while(!d.done_valid){tick();check(++timeout<100*TEST_VLEN,"scan timeout");}
    check(bool(d.done_trap)==bad,"scan trap mismatch");
    if(!bad)check(uint64_t(d.done_value)==expected,"scan result mismatch");
    const uint64_t expected_reads=bad?0:((scanned+7)/8)*(masked&&src!=0?2:1);
    check(requests-before==expected_reads,"scan byte-read count/early finish");check(!pending,"scan completion before drain");
    const auto value=d.done_value;
    for(unsigned b=0;b<3;++b){tick();check(d.done_valid&&d.done_value==value&&bool(d.done_trap)==bad,"unstable scan completion");}
    d.done_ready=1;tick();d.done_ready=0;++cases;
}
int main(int argc,char** argv){
    Verilated::commandArgs(argc,argv);
    try{
        d.reset=1;tick();tick();d.reset=0;d.eval();mem.fill(0xff);
        // All source/predicate bytes and all last-byte validity masks.
        for(unsigned source=0;source<256;++source)for(unsigned mask=0;mask<256;++mask){
            mem[0]=mask;mem[17*(TEST_VLEN/8)]=source;
            for(unsigned vl=0;vl<=8;++vl)for(unsigned first=0;first<2;++first)run(first,true,17,vl);
        }
        for(unsigned vl=0;vl<=TEST_VLEN;++vl){
            for(auto& b:mem)b=random64();
            for(unsigned first=0;first<2;++first)for(unsigned masked=0;masked<2;++masked)
                for(unsigned src:{0u,31u})run(first,masked,src,vl);
        }
        for(unsigned first=0;first<2;++first){run(first,false,17,0,1);run(first,true,0,TEST_VLEN,1);run(first,false,31,0,0,true);run(first,false,0,TEST_VLEN+1);}
        std::printf("PASS mask_scan XLEN=%d VLEN=%d cases=%llu reads=%llu cycles=%llu seed=be5466cf34e90c6c\n",TEST_XLEN,TEST_VLEN,(unsigned long long)cases,(unsigned long long)requests,(unsigned long long)cycles);
        d.final();return 0;
    }catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}
}
