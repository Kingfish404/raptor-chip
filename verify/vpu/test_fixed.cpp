#include "Vrapt_vpu_fixed.h"
#include "verilated.h"
#include "fixed_reference.h"
#include <array>
#include <cstdio>
#include <stdexcept>
static Vrapt_vpu_fixed dut;
static uint64_t checks,rng=0xa4093822299f31d0ULL;
static uint64_t random64(){rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;return rng;}
static void run(unsigned op,unsigned sew,uint64_t a,uint64_t b,unsigned rm){
    dut.op=op;dut.sew=sew;dut.a=a;dut.b=b;dut.vxrm=rm;
    const unsigned bits=8u<<sew;
    const __uint128_t product=__uint128_t(fixed_signed(a,bits)*fixed_signed(b,bits));
    for(unsigned i=0;i<4;++i)dut.product[i]=uint32_t(product>>(32*i));
    dut.eval();const auto ref=fixed_reference(op,bits,a,b,rm);
    if(uint64_t(dut.result)!=ref.value||bool(dut.saturated)!=ref.saturated){
        std::fprintf(stderr,"FAIL op=%u bits=%u a=%016llx b=%016llx rm=%u got=%016llx/%u expected=%016llx/%u\n",
            op,bits,(unsigned long long)a,(unsigned long long)b,rm,(unsigned long long)dut.result,
            unsigned(dut.saturated),(unsigned long long)ref.value,unsigned(ref.saturated));
        throw std::runtime_error("fixed-point mismatch");
    }
    ++checks;
}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    try{
        for(unsigned op=0;op<13;++op)if(op!=10&&op!=11)
            for(unsigned rm=0;rm<4;++rm)for(unsigned a=0;a<256;++a)for(unsigned b=0;b<256;++b)run(op,0,a,b,rm);
        for(unsigned op:{10u,11u})for(unsigned rm=0;rm<4;++rm)
            for(unsigned a=0;a<65536;++a)for(unsigned shift:{0u,1u,7u,8u,15u})run(op,0,a,shift,rm);
        for(unsigned sew=1;sew<4;++sew)for(unsigned op=0;op<13;++op){
            if((op==10||op==11)&&sew==3)continue;
            const unsigned bits=8u<<sew,abits=(op==10||op==11)?2*bits:bits;
            const uint64_t amask=UINT64_MAX>>(64-abits),mask=UINT64_MAX>>(64-bits);
            const std::array<uint64_t,8> aa={0,1,amask,amask-1,amask>>1,(amask>>1)+1,(amask>>1)+2,3};
            const std::array<uint64_t,8> bb={0,1,mask,mask-1,mask>>1,(mask>>1)+1,(mask>>1)+2,3};
            for(unsigned rm=0;rm<4;++rm){for(auto a:aa)for(auto b:bb)run(op,sew,a,b,rm);
                for(unsigned n=0;n<1000;++n)run(op,sew,random64(),random64(),rm);}
        }
        std::printf("PASS fixed checks=%llu seed=a4093822299f31d0\n",(unsigned long long)checks);dut.final();return 0;
    }catch(const std::exception&e){std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}
}
