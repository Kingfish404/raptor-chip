#include "Vrapt_vpu_move.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
static Vrapt_vpu_move d;
static std::array<uint8_t,32*TEST_VLEN/8> mem;
static uint64_t cycle=0,requests=0,rng=0x452821e638d01377ULL;
static bool pending=false;
static unsigned delay=0;
static uint64_t response=0;
static void check(bool b,const char* msg){if(!b)throw std::runtime_error(msg);}
static uint64_t random64(){rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;return rng;}
static void tick(){
    d.clock=0;d.vr_ready=!pending&&(cycle%7>=3);
    d.vr_rsp_valid=pending&&delay==0;d.vr_rdata=response;d.eval();
    const bool req=d.vr_valid&&d.vr_ready,ack=d.vr_rsp_valid&&d.vr_rsp_ready;
    uint64_t next=0;
    if(req){
        const unsigned size=1u<<d.vr_size,addr=d.vr_addr;
        check(!pending,"overlapping transactions");check(addr+size<=mem.size()&&addr%size==0,"bad move address");
        for(unsigned b=0;b<size;++b){if(d.vr_write)mem[addr+b]=d.vr_wdata>>(8*b);else next|=uint64_t(mem[addr+b])<<(8*b);}
        ++requests;
    }
    d.clock=1;d.eval();d.clock=0;d.eval();++cycle;
    if(ack)pending=false;
    if(pending&&delay)--delay;
    if(req){pending=true;response=next;delay=1+random64()%6;}
}
int main(int argc,char** argv){
    Verilated::commandArgs(argc,argv);
    try{
        d.reset=1;tick();tick();d.reset=0;d.eval();
        uint64_t cases=0;
        for(unsigned n:{1u,2u,4u,8u})for(unsigned sew=0;sew<4;++sew)
        for(unsigned scenario=0;scenario<8;++scenario)for(unsigned invalid=0;invalid<4;++invalid){
            for(auto& b:mem)b=random64();auto expected=mem;
            const unsigned rb=TEST_VLEN/8,evl=n*rb/(1u<<sew);
            const unsigned start=(scenario==0?0:scenario==1?1:scenario==2?evl-1:scenario==3?evl:scenario==4?evl+1:scenario==5?rb/(1u<<sew)+1:TEST_VLEN-1)&(TEST_VLEN-1);
            const unsigned src=16,dst=scenario==7?16:8;
            if(!invalid)for(unsigned b=start<<sew;b<n*rb;++b)expected[dst*rb+b]=mem[src*rb+b];
            const uint32_t insn=(0x27u<<26)|((invalid==1?0u:1u)<<25)|(src<<20)|((invalid==2?2u:n-1)<<15)|(3u<<12)|(dst<<7)|0x57;
            d.cmd_insn=insn;d.cmd_vill=invalid==3;d.cmd_sew=sew;d.cmd_vstart=start;d.cmd_valid=1;d.done_ready=0;
            check(d.cmd_ready,"not ready for move");tick();d.cmd_valid=0;
            // Accepted command must not follow changing external payloads.
            d.cmd_insn=0;d.cmd_vill=0;d.cmd_sew=0;d.cmd_vstart=0;
            unsigned timeout=0;const auto before=requests;
            while(!d.done_valid){tick();check(++timeout<200*TEST_VLEN,"move timeout");}
            check(bool(d.done_trap)==bool(invalid),"move trap mismatch");
            check(mem==expected,"move bytes mismatch");check(!pending,"completion before drain");
            if(invalid||src==dst||(start<<sew)>=n*rb)check(requests==before,"no-op/illegal VRF access");
            for(unsigned b=0;b<9;++b){tick();check(d.done_valid&&bool(d.done_trap)==bool(invalid),"unstable completion");}
            d.done_ready=1;tick();d.done_ready=0;++cases;
        }
        std::printf("PASS move VLEN=%d cases=%llu requests=%llu cycles=%llu seed=452821e638d01377\n",TEST_VLEN,(unsigned long long)cases,(unsigned long long)requests,(unsigned long long)cycle);
        d.final();return 0;
    }catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}
}
