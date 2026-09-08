#pragma once
static void test_vector_carry() {
    const unsigned rb=TEST_VLEN/8;
    uint64_t cases=0,elements=0;
    for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew)for(int lm=-3;lm<=3;++lm){
        const unsigned bits=8u<<sew,bytes=1u<<sew;
        if(lm<0&&bits>(TEST_ELEN>>-lm))continue;
        const uint64_t mask=UINT64_MAX>>(64-bits);
        for(unsigned op=0;op<4;++op)for(unsigned form:{0u,4u,3u})for(unsigned scenario=0;scenario<8;++scenario){
            if((op&2)&&form==3)continue;
            initialize();const unsigned vl=configure((sew<<3)|(lm&7),scenario==7?0:TEST_VLEN);
            const unsigned requested=scenario==5?vl:scenario==6?vl+1:scenario==4?3:0;
            write_csr(0x008,requested);const unsigned start=requested&(TEST_VLEN-1);
            const unsigned vd=(op&1)&&scenario==0?0:scenario%3==0?8:scenario%3==1?16:24;
            const unsigned src_reg=scenario==3?16:24;
            const bool vm=(op&1)&&(scenario%2);
            const unsigned imm=(scenario*5)%32;
            uint64_t scalar=scenario==0?0:scenario==1?UINT64_MAX:random64();
            if(TEST_XLEN==32)scalar=uint64_t(int64_t(int32_t(scalar)));
            const uint64_t operand=form==3?uint64_t(int64_t(int(imm<<27)>>27)):scalar;
            // Include all-zero/all-one and alternating carry masks; a zero
            // carry bit still executes and writes the element.
            for(unsigned o=0;o<rb;++o){const uint8_t v=scenario%3==0?0:scenario%3==1?255:0x55;
                host(true,o,0,v);put(o,1,v);}
            for(unsigned i=0;i<vl;++i){
                const uint64_t a=i%3==0?mask:i%3==1?0:random64();
                const uint64_t b=i%3==0?1:i%3==1?mask:random64();
                host(true,16*rb+i*bytes,sew,a);put(16*rb+i*bytes,bytes,a);
                if(form==0){host(true,src_reg*rb+i*bytes,sew,b);put(src_reg*rb+i*bytes,bytes,b);}
            }
            const auto before=memory;
            auto read=[&](unsigned reg,unsigned i){uint64_t v=0;for(unsigned b=0;b<bytes;++b)
                v|=uint64_t(before.at(reg*rb+i*bytes+b))<<(8*b);return v;};
            for(unsigned i=start;i<vl;++i){
                const __uint128_t a=read(16,i)&mask,b=(form==0?read(src_reg,i):operand)&mask;
                const unsigned c=vm?0:(before.at(i/8)>>(i%8))&1;
                const __uint128_t value=op&2?a-b-c:a+b+c;
                if(op&1){const bool bit=op&2?a<b+c:(value>>bits)&1;
                    auto& byte=memory.at(vd*rb+i/8);byte=(byte&~(1u<<(i%8)))|(unsigned(bit)<<(i%8));}
                else put(vd*rb+i*bytes,bytes,uint64_t(value));
                ++elements;
            }
            const auto r=command(integer(0x10+op,form,vd,16,form==0?src_reg:form==3?imm:1,vm),scalar);
            require(!r.trap&&r.dirty&&!r.rd,"carry instruction rejected");
            require(read_csr(0x008)==0,"carry restart state");compare_memory("carry op="+std::to_string(op)+" scenario="+std::to_string(scenario));++cases;
        }
    }
    initialize();configure(0,4);write_csr(0x008,2);
    for(auto insn:{integer(0x10,0,8,16,24,true),integer(0x12,0,8,16,24,true),
                   integer(0x10,0,0,16,24,false),integer(0x12,3,8,16,1,false)}){
        auto r=command(insn);require(r.trap&&r.cause==2&&!r.dirty,"reserved carry accepted");
        require(read_csr(0x008)==2,"reserved carry changed restart");compare_memory("reserved carry");
    }
    std::printf("PASS vector_carry cases=%llu elements=%llu\n",(unsigned long long)cases,(unsigned long long)elements);
}
