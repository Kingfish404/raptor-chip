#pragma once
#include "fixed_reference.h"
static void test_vector_fixed(){
    const unsigned rb=TEST_VLEN/8;
    const unsigned funct[]={0x20,0x21,0x22,0x23,0x08,0x09,0x0a,0x0b,0x2a,0x2b,0x2e,0x2f,0x27};
    uint64_t cases=0,active=0,saturations=0;
    for(unsigned op=0;op<13;++op)for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew)for(int lm=-3;lm<=3;++lm){
        const unsigned bits=8u<<sew;
        if(lm<0&&bits>(TEST_ELEN>>-lm))continue;
        const bool clip=op==10||op==11,average=op>=4&&op<=7;
        if(clip&&(2*bits>TEST_ELEN||lm==3))continue;
        const unsigned asize=sew+clip,abits=8u<<asize;
        for(unsigned f=0;f<3;++f){
            if(f==2&&(op==2||op==3||average||op==12))continue;
            const unsigned form=average?(f==0?2:6):(f==0?0:f==1?4:3);
            for(unsigned rm=0;rm<4;++rm)for(unsigned scenario=0;scenario<6;++scenario){
                initialize();const unsigned vl=configure((sew<<3)|(lm&7)|((scenario%4)<<6),scenario==5?0:scenario>=3?5:TEST_VLEN);
                const unsigned requested=scenario==3?1:scenario==4?vl:0;
                write_csr(0x008,requested);const unsigned start=requested&(TEST_VLEN-1);
                write_csr(0x00a,rm);bool expected_sat=(scenario+rm)%2;write_csr(0x009,expected_sat);
                const bool masked=scenario==1||scenario==2;
                const unsigned vd=scenario==1?16:scenario==2?24:8,src=scenario==3?16:24;
                const unsigned imm=(scenario*7+rm)%32;
                uint64_t scalar=scenario==0?UINT64_MAX:scenario==1?uint64_t(1)<<(bits-1):random64();
                if(TEST_XLEN==32)scalar=uint64_t(int64_t(int32_t(scalar)));
                const uint64_t operand=f!=2?scalar:op<2?uint64_t(int64_t(int(imm<<27)>>27)):imm;
                for(unsigned o=0;o<rb;++o){const uint8_t mask=scenario==2?0:0x55;host(true,o,0,mask);put(o,1,mask);}
                for(unsigned i=0;i<vl;++i){
                    const uint64_t a=i%4==0?UINT64_MAX:i%4==1?uint64_t(1)<<(abits-1):i%4==2?3:random64();
                    const uint64_t b=i%4==0?1:i%4==1?uint64_t(1)<<(bits-1):i%4==2?1:random64();
                    host(true,16*rb+(i<<asize),asize,a);put(16*rb+(i<<asize),1u<<asize,a);
                    if(f==0){host(true,src*rb+(i<<sew),sew,b);put(src*rb+(i<<sew),1u<<sew,b);}
                }
                const auto before=memory;
                auto read=[&](unsigned reg,unsigned i,unsigned size){uint64_t v=0;for(unsigned b=0;b<(1u<<size);++b)
                    v|=uint64_t(before.at(reg*rb+(i<<size)+b))<<(8*b);return v;};
                for(unsigned i=start;i<vl;++i){
                    if(masked&&!((before.at(i/8)>>(i%8))&1))continue;
                    const auto r=fixed_reference(op,bits,read(16,i,asize),f==0?read(src,i,sew):operand,rm);
                    put(vd*rb+(i<<sew),1u<<sew,r.value);expected_sat|=r.saturated;++active;saturations+=r.saturated;
                }
                const auto insn=integer(funct[op],form,vd,16,f==0?src:f==2?imm:1,!masked);
                const auto r=command(insn,scalar);
                require(!r.trap&&r.dirty&&!r.rd,"fixed instruction rejected op="+std::to_string(op));
                require(read_csr(0x009)==expected_sat,"fixed sticky saturation op="+std::to_string(op));
                require(read_csr(0x00a)==rm&&read_csr(0x00f)==((rm<<1)|expected_sat),"fixed rounding/alias state");
                require(read_csr(0x008)==0,"fixed completion restart");
                compare_memory("fixed op="+std::to_string(op)+" sew="+std::to_string(bits)+" rm="+std::to_string(rm)+" scenario="+std::to_string(scenario));++cases;
            }
        }
    }
    // Saturation must survive configuration and non-saturating operations;
    // illegal or cancelled instructions must preserve all architectural state.
    initialize();configure(0,4);write_csr(0x009,1);write_csr(0x00a,3);write_csr(0x008,2);
    const auto cancelled=command(integer(0x20,0,8,16,24,true),0,0,true);(void)cancelled;
    require(read_csr(0x009)==1&&read_csr(0x008)==2,"cancelled fixed state");
    // OPIV funct6=0x27 with vi form also encodes whole-register moves;
    // use reserved count=3 here, not the legal vmv2r.v alias.
    for(auto insn:{integer(0x22,3,8,16,1,true),integer(0x27,3,8,16,2,true),integer(0x20,0,0,16,24,false)}){
        auto r=command(insn);require(r.trap&&r.cause==2&&!r.dirty,"reserved fixed accepted");
        require(read_csr(0x009)==1&&read_csr(0x008)==2&&read_csr(0x00a)==3,"illegal fixed state");compare_memory("illegal fixed");
    }
    configure(TEST_ELEN==64?24:16,1);write_csr(0x008,1);
    auto invalid=command(integer(0x2e,0,8,16,24,true));
    require(invalid.trap&&invalid.cause==2&&!invalid.dirty,"clip above ELEN accepted");
    require(read_csr(0x009)==1&&read_csr(0x008)==1,"invalid clip state");compare_memory("invalid clip");
    std::printf("PASS vector_fixed cases=%llu active=%llu saturated_elements=%llu\n",(unsigned long long)cases,
        (unsigned long long)active,(unsigned long long)saturations);
}
