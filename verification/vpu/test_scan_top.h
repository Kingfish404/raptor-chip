#pragma once
static void test_vector_scan(){
    const unsigned rb=TEST_VLEN/8;
    uint64_t cases=0,negative=0;
    for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew)for(int lm=-3;lm<=3;++lm)
    for(unsigned first=0;first<2;++first)for(unsigned scenario=0;scenario<12;++scenario){
        if(lm<0&&(8u<<sew)>(TEST_ELEN>>-lm))continue;
        initialize();const unsigned vl=configure((sew<<3)|(lm&7)|((scenario%4)<<6),scenario<2?0:scenario==2?1:scenario==3?7:scenario==4?9:TEST_VLEN);
        const bool masked=scenario>=6;const unsigned src=scenario==7?0:scenario==8?31:17,rd=scenario==0?0:5;
        for(unsigned b=0;b<rb;++b){
            const uint8_t m=scenario==6?0:scenario==9?0xff:0x55;
            host(true,b,0,m);put(b,1,m);
            const uint8_t v=scenario==5||scenario==6?0xff:scenario==8?0:scenario==9?(b==(vl-1)/8?1u<<((vl-1)%8):0):random64();
            host(true,src*rb+b,0,v);put(src*rb+b,1,v);
        }
        write_csr(0x009,scenario%2);write_csr(0x00a,scenario%4);
        uint64_t value=first?(TEST_XLEN==64?UINT64_MAX:UINT32_MAX):0;
        for(unsigned i=0;i<vl;++i)if(((memory[src*rb+i/8]>>(i%8))&1)&&(!masked||((memory[i/8]>>(i%8))&1))){
            if(first){value=i;break;}++value;
        }
        const auto r=command(integer(0x10,2,rd,src,16+first,!masked));
        require(!r.trap&&r.dirty&&r.rd==rd&&r.value==(rd?value:0),"mask scalar scan result");
        require(read_csr(0x008)==0&&read_csr(0xc20)==vl&&read_csr(0x009)==scenario%2&&read_csr(0x00a)==scenario%4,"scan CSR state");
        compare_memory("scan first="+std::to_string(first)+" sew="+std::to_string(sew)+" lm="+std::to_string(lm)+" scenario="+std::to_string(scenario));++cases;
    }
    // Every possible first bit, including byte boundaries and the final VL bit.
    initialize();configure(3,TEST_VLEN);
    for(unsigned b=0;b<rb;++b){host(true,17*rb+b,0,0);put(17*rb+b,1,0);}
    for(unsigned i=0;i<TEST_VLEN;++i){
        if(i){host(true,17*rb+(i-1)/8,0,0);put(17*rb+(i-1)/8,1,0);}
        host(true,17*rb+i/8,0,1u<<(i%8));put(17*rb+i/8,1,1u<<(i%8));
        auto r=command(integer(0x10,2,5,17,17,true));require(!r.trap&&r.value==i,"first bit location");
        r=command(integer(0x10,2,5,17,16,true));require(!r.trap&&r.value==1,"one-hot popcount");
        compare_memory("scan one-hot");cases+=2;
    }
    for(unsigned first=0;first<2;++first)for(unsigned mode=0;mode<6;++mode){
        initialize();configure(mode==2?0x100:0,mode==0?0:4);
        write_csr(0x008,mode<2||mode==5?1:0);
        const auto insn=integer(0x10,2,5,17,mode==3?18:16+first,true);
        if(mode==4)dut.vector_enabled=0;
        const auto r=command(insn,0,0,mode==5);
        if(mode!=5)require(r.trap&&r.cause==2&&r.tval==insn&&!r.dirty&&!r.rd,"illegal scan accepted");
        dut.vector_enabled=1;
        require(read_csr(0x008)==(mode<2||mode==5?1u:0u),"negative scan restart");
        compare_memory("negative scan");++negative;
    }
    std::printf("PASS vector_scan cases=%llu negative=%llu\n",(unsigned long long)cases,(unsigned long long)negative);
}
