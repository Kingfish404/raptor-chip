#include "Vrapt_vpu_muldiv.h"
#include "verilated.h"
#include "muldiv_reference.h"
#include <array>
#include <cstdio>
#include <stdexcept>
static Vrapt_vpu_muldiv dut;
static uint64_t workload_hash=14695981039346656037ULL;
static void hash_word(uint64_t v) { for(unsigned b=0;b<8;++b) workload_hash=(workload_hash ^ uint8_t(v>>(8*b)))*1099511628211ULL; }
static uint64_t cycles, checks, rng=0x13198a2e03707344ULL;
static uint64_t random64() { rng^=rng<<13; rng^=rng>>7; rng^=rng<<17; return rng; }
static void require(bool ok,const char* what) { if (!ok) throw std::runtime_error(what); }
static void tick() { dut.clock=0;dut.eval();dut.clock=1;dut.eval();dut.clock=0;dut.eval();++cycles; }
static void run(unsigned op,unsigned sew,uint64_t a,uint64_t b) {
    hash_word(op);hash_word(sew);hash_word(a);hash_word(b);
    const unsigned bits=8u<<sew;
    const auto expected=muldiv_reference(op,bits,a,b);
    require(dut.req_ready && !dut.rsp_valid,"not idle");
    dut.req_valid=1;dut.op=op;dut.sew=sew;dut.a=a;dut.b=b;dut.rsp_ready=0;tick();
    dut.req_valid=0;dut.op=~op;dut.a=~a;dut.b=~b;dut.sew=~sew;
    const auto begin=cycles;
    while (!dut.rsp_valid) { require(!dut.req_ready,"accepted during execution");tick();require(cycles-begin<=65,"execution timeout"); }
    if (uint64_t(dut.result)!=expected) {
        std::fprintf(stderr,"op=%u bits=%u a=%016llx b=%016llx got=%016llx expected=%016llx\n",
            op,bits,(unsigned long long)a,(unsigned long long)b,(unsigned long long)dut.result,(unsigned long long)expected);
        require(false,"result mismatch");
    }
    if(op>=4) {
        const uint64_t mask=UINT64_MAX>>(64-bits),au=a&mask,bu=b&mask;
        const __int128 sa=au&(uint64_t(1)<<(bits-1))?__int128(au)-(__int128(1)<<bits):__int128(au);
        const __int128 sb=bu&(uint64_t(1)<<(bits-1))?__int128(bu)-(__int128(1)<<bits):__int128(bu);
        const __uint128_t expected_product=op>=6?__uint128_t(sa*(op==7?sb:__int128(bu))):__uint128_t(au)*bu;
        for(unsigned i=0;i<4;++i)require(dut.full_product[i]==uint32_t(expected_product>>(32*i)),"full product mismatch");
    }
    // Hold a distinct new request while the old result is backpressured.
    dut.req_valid=1;
    for (unsigned i=0;i<(checks%4);++i) { tick();require(dut.rsp_valid && !dut.req_ready && uint64_t(dut.result)==expected,"stalled result changed"); }
    dut.rsp_ready=1;tick();dut.rsp_ready=0;dut.req_valid=0;dut.eval();++checks;
}
int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    try {
        dut.reset=1;tick();dut.reset=0;tick();
        for (unsigned op=0;op<8;++op) for (unsigned a=0;a<256;++a) for(unsigned b=0;b<256;++b) run(op,0,a,b);
        for (unsigned sew=1;sew<4;++sew) {
            const unsigned bits=8u<<sew;
            const uint64_t mask=UINT64_MAX>>(64-bits), sign=uint64_t(1)<<(bits-1);
            const std::array<uint64_t,8> values={0,1,2,mask,sign,sign-1,sign+1,mask-1};
            for(unsigned op=0;op<8;++op) {
                for(auto a:values) for(auto b:values) run(op,sew,a,b);
                for(unsigned i=0;i<1000;++i) run(op,sew,random64(),random64());
            }
        }
        // Reset is a hardware reset, and must discard both busy and held-result state.
        for(unsigned op:{0u,5u}) for(unsigned delay:{0u,1u,32u,65u}) {
            dut.req_valid=1;dut.op=op;dut.sew=3;dut.a=UINT64_MAX;dut.b=17;tick();dut.req_valid=0;
            for(unsigned i=0;i<delay;++i) tick();
            dut.reset=1;tick();dut.reset=0;tick();require(dut.req_ready && !dut.rsp_valid,"reset retained response");
            run(7,3,UINT64_MAX,2);
        }
        std::printf("PASS muldiv checks=%llu cycles=%llu seed=13198a2e03707344 exhaustive_e8=524288 workload_hash=%016llx\n",
            (unsigned long long)checks,(unsigned long long)cycles,(unsigned long long)workload_hash);
        dut.final();return 0;
    } catch(const std::exception& e) { std::fprintf(stderr,"FAIL %s cycle=%llu\n",e.what(),(unsigned long long)cycles);return 1; }
}
