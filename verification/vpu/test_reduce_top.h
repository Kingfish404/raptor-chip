#pragma once
// Numeric reduction model snapshots all operands before changing element zero.
// Seed/destination are scalar registers even when the source uses LMUL > 1.
static void test_vector_reduce() {
    const unsigned rb=TEST_VLEN/8;
    uint64_t cases=0, invalids=0;
    for(unsigned op=0;op<10;++op)for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew)
    for(int lm=-3;lm<=3;++lm) {
        const unsigned bits=8u<<sew;
        const bool wide=op>=8;
        if((lm<0&&bits>(TEST_ELEN>>-lm))||(wide&&2*bits>TEST_ELEN))continue;
        const unsigned outbits=bits*(wide?2:1),outbytes=outbits/8;
        const uint64_t omask=outbits==64?UINT64_MAX:(uint64_t(1)<<outbits)-1;
        for(unsigned scenario=0;scenario<10;++scenario) {
            initialize();
            const unsigned vl=configure((sew<<3)|(lm&7)|((scenario%4)<<6),
                scenario==0?0:scenario==1?1:scenario==2?3:TEST_VLEN);
            const bool masked=scenario>=4;
            const unsigned vd=scenario==5?0:scenario==6?17:scenario==7?16:scenario==8?31:8;
            const unsigned seed=scenario==6?18:scenario==7?16:scenario==8?31:scenario==9?vd:24;
            for(unsigned b=0;b<rb;++b) {
                const uint8_t mask=scenario==4?0:scenario==5?0xff:0x55;
                host(true,b,0,mask);put(b,1,mask);
            }
            for(unsigned i=0;i<vl;++i) {
                const uint64_t v=i%4==0?UINT64_MAX:i%4==1?uint64_t(1)<<(bits-1):i%4==2?1:random64();
                host(true,16*rb+(i<<sew),sew,v);put(16*rb+(i<<sew),1u<<sew,v);
            }
            write_csr(0x009,scenario%2);write_csr(0x00a,scenario%4);
            uint64_t acc=get(seed*rb,outbytes)&omask;
            auto signed_value=[](uint64_t v,unsigned width)->__int128 {
                const __int128 n=v;
                return (v&(uint64_t(1)<<(width-1)))?n-(__int128(1)<<width):n;
            };
            for(unsigned i=0;i<vl;++i) {
                if(masked&&!((memory.at(i/8)>>(i%8))&1))continue;
                uint64_t v=get(16*rb+(i<<sew),1u<<sew);
                if(op==9)v=uint64_t(signed_value(v,bits));
                switch(op) {
                    case 0:case 8:case 9:acc+=v;break;
                    case 1:acc&=v;break;
                    case 2:acc|=v;break;
                    case 3:acc^=v;break;
                    case 4:acc=std::min(acc,v);break;
                    case 5:if(signed_value(v,bits)<signed_value(acc,bits))acc=v;break;
                    case 6:acc=std::max(acc,v);break;
                    case 7:if(signed_value(v,bits)>signed_value(acc,bits))acc=v;break;
                }
                acc&=omask;
            }
            if(vl)put(vd*rb,outbytes,acc);
            const auto r=command(integer(wide?0x30+op-8:op,wide?0:2,vd,16,seed,!masked));
            require(!r.trap&&!r.rd&&r.dirty,"reduction rejected op="+std::to_string(op));
            require(read_csr(0x008)==0&&read_csr(0x009)==scenario%2&&read_csr(0x00a)==scenario%4,"reduction CSR state");
            compare_memory("reduce op="+std::to_string(op)+" sew="+std::to_string(bits)+" lm="+std::to_string(lm)+" scenario="+std::to_string(scenario));
            ++cases;
        }
    }
    for(unsigned op=0;op<10;++op)for(unsigned avl:{0u,4u}) {
        initialize();configure(0,avl);write_csr(0x008,1);
        const auto insn=integer(op>=8?0x30+op-8:op,op>=8?0:2,8,16,24,true);
        const auto r=command(insn);
        require(r.trap&&r.cause==2&&r.tval==insn&&!r.dirty,"nonzero reduction vstart accepted");
        require(read_csr(0x008)==1,"illegal reduction changed vstart");
        compare_memory("illegal reduction start");++invalids;
    }
    for(unsigned mode=0;mode<2;++mode) {
        initialize();configure(mode?1:(TEST_ELEN==64?24:16),4);
        const auto insn=integer(mode?0:0x30,mode?2:0,8,mode?17:16,24,true);
        const auto r=command(insn);
        require(r.trap&&r.cause==2&&!r.dirty,"illegal reduction geometry accepted");
        compare_memory("illegal reduction geometry");++invalids;
    }
    std::printf("PASS vector_reduce cases=%llu illegal=%llu\n",(unsigned long long)cases,(unsigned long long)invalids);
}
