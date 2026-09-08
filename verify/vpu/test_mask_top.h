#pragma once
static bool compare_reference(unsigned op,unsigned bits,uint64_t a,uint64_t b) {
    const uint64_t mask=UINT64_MAX>>(64-bits);a&=mask;b&=mask;
    const auto sa=signed_element(a,bits),sb=signed_element(b,bits);
    switch(op) {
        case 0:return a==b;case 1:return a!=b;case 2:return a<b;case 3:return sa<sb;
        case 4:return a<=b;case 5:return sa<=sb;case 6:return a>b;case 7:return sa>sb;
    }
    throw std::runtime_error("unknown comparison");
}
static bool logic_reference(unsigned op,bool a,bool b) {
    switch(op) {
        case 0:return a&&!b;case 1:return a&&b;case 2:return a||b;case 3:return a!=b;
        case 4:return a||!b;case 5:return !(a&&b);case 6:return !(a||b);case 7:return a==b;
    }
    throw std::runtime_error("unknown mask logic");
}
static void test_vector_mask() {
    const unsigned rb=TEST_VLEN/8;
    uint64_t cases=0,bits_checked=0;
    for(bool logical:{false,true}) for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew)
    for(int lm=-3;lm<=3;++lm) {
        const unsigned bits=8u<<sew,bytes=1u<<sew;
        if(lm<0 && bits>(TEST_ELEN>>-lm)) continue;
        for(unsigned op=0;op<8;++op) for(unsigned form:{0u,4u,3u}) {
            if(logical && form!=0) continue;
            if(!logical && ((form==0 && op>=6) || (form==3 && (op==2||op==3)))) continue;
            for(unsigned scenario=0;scenario<8;++scenario) {
                initialize();
                const unsigned type=(sew<<3)|(lm&7)|((scenario%4)<<6);
                const unsigned vl=configure(type,scenario==7?0:scenario==6?13:TEST_VLEN);
                const unsigned asked_start=scenario==5?vl+1:scenario==4?vl:scenario==3?3:0;
                write_csr(0x008,asked_start);const unsigned start=asked_start&(TEST_VLEN-1);
                const unsigned a_reg=logical?17:16, b_reg=scenario==2?a_reg:logical?25:24;
                const unsigned vd=scenario==0?0:scenario==1?a_reg:scenario==2?b_reg:scenario==3?(!logical&&lm==3?7:31):9;
                const bool masked=!logical && (scenario%2==0);
                const unsigned src=form==3?(scenario*5)%32:1;
                uint64_t scalar=scenario==0?0:scenario==1?UINT64_MAX:random64();
                if(TEST_XLEN==32) scalar=uint64_t(int64_t(int32_t(scalar)));
                const uint64_t operand=form==3?uint64_t(int64_t(int(src<<27)>>27)):scalar;
                if(!logical) for(unsigned i=0;i<vl;++i) {
                    uint64_t a=i%4==0?0:i%4==1?UINT64_MAX:i%4==2?uint64_t(1)<<(bits-1):random64();
                    const uint64_t b=i%3==0?a:i%3==1?operand:random64();
                    host(true,a_reg*rb+i*bytes,sew,a);put(a_reg*rb+i*bytes,bytes,a);
                    if(form==0){host(true,b_reg*rb+i*bytes,sew,b);put(b_reg*rb+i*bytes,bytes,b);}
                }
                const auto before=memory;
                auto element=[&](unsigned reg,unsigned i) {
                    uint64_t v=0;for(unsigned b=0;b<bytes;++b)v|=uint64_t(before.at(reg*rb+i*bytes+b))<<(8*b);return v;
                };
                auto bit=[&](unsigned reg,unsigned i){return bool((before.at(reg*rb+i/8)>>(i%8))&1);};
                for(unsigned i=start;i<vl;++i) {
                    if(masked&&!bit(0,i))continue;
                    const bool r=logical?logic_reference(op,bit(a_reg,i),bit(b_reg,i))
                        :compare_reference(op,bits,element(a_reg,i),form==0?element(b_reg,i):operand);
                    auto& byte=memory.at(vd*rb+i/8);byte=(byte&~(1u<<(i%8)))|(unsigned(r)<<(i%8));++bits_checked;
                }
                const auto insn=integer(0x18+op,logical?2:form,vd,a_reg,form==0?b_reg:src,!masked);
                auto r=command(insn,scalar);
                require(!r.trap && r.dirty && !r.rd,"mask instruction rejected insn="+std::to_string(insn));
                require(read_csr(0x008)==0,"mask instruction vstart");
                compare_memory("mask logical="+std::to_string(logical)+" op="+std::to_string(op)+" scenario="+std::to_string(scenario));++cases;
            }
        }
    }
    initialize();configure(1,8);write_csr(0x008,2); // e8,m2, vd17 overlaps upper part of vs2
    for(auto insn:{integer(0x18,0,17,16,24,true),integer(0x18,0,25,16,24,true),
                   integer(0x18,0,8,17,24,true),integer(0x18,2,8,16,24,false)}) {
        auto r=command(insn);require(r.trap&&r.cause==2&&!r.dirty,"illegal mask instruction accepted");
        require(read_csr(0x008)==2,"illegal mask reset vstart");compare_memory("illegal mask");
    }
    std::printf("PASS vector_mask cases=%llu active_bits=%llu\n",(unsigned long long)cases,(unsigned long long)bits_checked);
}
