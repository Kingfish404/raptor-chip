#pragma once
static void test_vector_prefix(){
    const unsigned rb=TEST_VLEN/8;
    uint64_t cases=0,negative=0;
    auto execute=[&](unsigned op,unsigned vd,unsigned src,bool masked,unsigned vl){
        const auto before=memory;unsigned first=vl;
        for(unsigned i=0;i<vl;++i)if(((before[src*rb+i/8]>>(i%8))&1)&&(!masked||((before[i/8]>>(i%8))&1))){first=i;break;}
        for(unsigned i=0;i<vl;++i){
            if(masked&&!((before[i/8]>>(i%8))&1))continue;
            const bool bit=op==1?i<first:op==2?i==first:i<=first;
            auto& b=memory[vd*rb+i/8];b=(b&~(1u<<(i%8)))|(unsigned(bit)<<(i%8));
        }
        const auto r=command(integer(0x14,2,vd,src,op,!masked));
        require(!r.trap&&!r.rd&&r.dirty,"prefix rejected");
        require(read_csr(0x008)==0&&read_csr(0xc20)==vl,"prefix restart/VL");
        compare_memory("prefix op="+std::to_string(op));++cases;
    };
    for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew)for(int lm=-3;lm<=3;++lm)
    for(unsigned op=1;op<=3;++op)for(unsigned scenario=0;scenario<10;++scenario){
        if(lm<0&&(8u<<sew)>(TEST_ELEN>>-lm))continue;
        initialize();const unsigned vl=configure((sew<<3)|(lm&7)|((scenario%4)<<6),scenario==0?0:scenario==1?1:scenario==2?9:TEST_VLEN);
        const bool masked=scenario>=5;const unsigned src=scenario==7?0:17,vd=scenario==3?0:31;
        for(unsigned b=0;b<rb;++b){
            const uint8_t mask=scenario==5?0:scenario==6?0xff:0x55;
            host(true,b,0,mask);put(b,1,mask);
            const uint8_t value=scenario==4?0:scenario==8?0xff:scenario==9?(b==(vl-1)/8?1u<<((vl-1)%8):0):random64();
            host(true,src*rb+b,0,value);put(src*rb+b,1,value);
        }
        write_csr(0x009,scenario%2);write_csr(0x00a,scenario%4);
        execute(op,vd,src,masked,vl);
        require(read_csr(0x009)==scenario%2&&read_csr(0x00a)==scenario%4,"prefix fixed CSRs");
    }
    // Walk the first set bit across every byte, including no set bit at all.
    initialize();configure(3,TEST_VLEN);
    for(unsigned b=0;b<rb;++b){host(true,17*rb+b,0,0);put(17*rb+b,1,0);}
    for(unsigned i=0;i<=TEST_VLEN;++i){
        if(i){host(true,17*rb+(i-1)/8,0,0);put(17*rb+(i-1)/8,1,0);}
        if(i<TEST_VLEN){host(true,17*rb+i/8,0,1u<<(i%8));put(17*rb+i/8,1,1u<<(i%8));}
        for(unsigned op=1;op<=3;++op)execute(op,31,17,false,TEST_VLEN);
    }
    for(unsigned op=1;op<=3;++op)for(unsigned mode=0;mode<7;++mode){
        initialize();configure(mode==2?0x100:0,mode==0?0:4);write_csr(0x008,mode<2||mode==6?1:0);
        const auto insn=integer(0x14,2,mode==3?17:mode==4?0:31,17,op,mode!=4);
        if(mode==5)dut.vector_enabled=0;
        const auto r=command(insn,0,0,mode==6);
        if(mode!=6)require(r.trap&&r.cause==2&&r.tval==insn&&!r.dirty,"illegal prefix accepted");
        dut.vector_enabled=1;
        require(read_csr(0x008)==(mode<2||mode==6?1u:0u),"negative prefix restart");
        compare_memory("negative prefix");++negative;
    }
    std::printf("PASS vector_prefix cases=%llu negative=%llu\n",(unsigned long long)cases,(unsigned long long)negative);
}
