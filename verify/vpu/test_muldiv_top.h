#pragma once
#include "muldiv_reference.h"
static void test_vector_muldiv() {
    const unsigned rb=TEST_VLEN/8;
    uint64_t cases=0,elements=0,latency=0;
    for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew) for(int lm=-3;lm<=3;++lm) {
        const unsigned bits=8u<<sew,bytes=1u<<sew;
        if(lm<0 && bits>(TEST_ELEN>>-lm)) continue;
        const uint64_t mask=UINT64_MAX>>(64-bits),sign=uint64_t(1)<<(bits-1);
        const std::array<uint64_t,8> edge={0,1,mask,sign,sign-1,sign+1,2,mask-1};
        for(unsigned op : {0u,1u,2u,3u,4u,5u,6u,7u,9u,11u,13u,15u}) for(unsigned form:{2u,6u}) for(unsigned scenario=0;scenario<8;++scenario) {
            initialize();
            const unsigned vl=configure((sew<<3)|(lm&7),scenario==7?0:TEST_VLEN);
            const unsigned src=scenario==6?16:24,vd=scenario%3==0?16:scenario%3==1?24:8;
            const bool masked=scenario%2;
            const unsigned requested_start=scenario==5?vl+1:scenario==4?vl:scenario==3&&vl>1?1:0;
            write_csr(0x008,requested_start);
            const unsigned start=requested_start & (TEST_VLEN-1);
            require(read_csr(0x008)==start,"muldiv test vstart WARL");
            uint64_t scalar=edge[scenario];
            if(TEST_XLEN==32) scalar=uint64_t(int64_t(int32_t(scalar)));
            for(unsigned i=0;i<vl;++i) {
                const uint64_t a=i<8?edge[(i+scenario)%8]:random64();
                const uint64_t b=i<8?edge[(i*3+scenario)%8]:random64();
                host(true,16*rb+i*bytes,sew,a);put(16*rb+i*bytes,bytes,a);
                if(form==2) { host(true,src*rb+i*bytes,sew,b);put(src*rb+i*bytes,bytes,b); }
            }
            const auto before=memory;
            auto read=[&](unsigned base,unsigned i) {
                uint64_t v=0;for(unsigned b=0;b<bytes;++b)v|=uint64_t(before.at(base*rb+i*bytes+b))<<(8*b);return v;
            };
            for(unsigned i=start;i<vl;++i) {
                if(masked && !((before.at(i/8)>>(i%8))&1)) continue;
                const uint64_t a=read(16,i),b=form==2?read(src,i):scalar,c=read(vd,i);
                uint64_t expected;
                if(op<8) expected=muldiv_reference(op,bits,a,b);
                else {
                    const auto product=__uint128_t(b)*(op&4 ? a : c);
                    const auto addend=op&4 ? c : a;
                    expected=uint64_t(op&2 ? __uint128_t(addend)-product : __uint128_t(addend)+product);
                }
                put(vd*rb+i*bytes,bytes,expected);++elements;
            }
            const auto r=command(integer(0x20+op,form,vd,16,form==2?src:1,!masked),scalar);
            require(!r.trap && r.dirty && r.rd==0,"vector muldiv execution trap");latency+=r.latency;
            require(read_csr(0x008)==0,"muldiv vstart not cleared");
            compare_memory("muldiv op="+std::to_string(op)+" sew="+std::to_string(bits)+" scenario="+std::to_string(scenario));++cases;
        }
    }
    std::printf("PASS vector_muldiv cases=%llu elements=%llu latency=%llu\n",(unsigned long long)cases,
        (unsigned long long)elements,(unsigned long long)latency);
}
