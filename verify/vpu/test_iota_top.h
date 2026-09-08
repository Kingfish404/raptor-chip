#pragma once
static void test_vector_iota(){
    const unsigned rb=TEST_VLEN/8;
    uint64_t cases=0,negative=0,wrapped=0;
    for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew)for(int lm=-3;lm<=3;++lm)
    for(unsigned scenario=0;scenario<12;++scenario){
        if(lm<0&&(8u<<sew)>(TEST_ELEN>>-lm))continue;
        initialize();const unsigned vl=configure((sew<<3)|(lm&7)|((scenario%4)<<6),scenario==0?0:scenario==1?1:scenario==2?9:TEST_VLEN);
        const bool masked=scenario>=6;const unsigned src=scenario==7?0:scenario==8?31:17,vd=scenario==3?0:8;
        for(unsigned b=0;b<rb;++b){
            const uint8_t mask=scenario==6?0:scenario==9?0xff:0x55;
            host(true,b,0,mask);put(b,1,mask);
            const uint8_t value=scenario==4?0:scenario==5||scenario==9?0xff:random64();
            host(true,src*rb+b,0,value);put(src*rb+b,1,value);
        }
        write_csr(0x009,scenario%2);write_csr(0x00a,scenario%4);
        const auto before=memory;
        // Each expected output independently counts the enabled earlier bits.
        for(unsigned i=0;i<vl;++i){
            if(masked&&!((before[i/8]>>(i%8))&1))continue;
            unsigned count=0;
            for(unsigned j=0;j<i;++j)count+=((before[src*rb+j/8]>>(j%8))&1)&&(!masked||((before[j/8]>>(j%8))&1));
            put(vd*rb+(i<<sew),1u<<sew,count);if(sew==0&&count>255)++wrapped;
        }
        const auto r=command(integer(0x14,2,vd,src,16,!masked));
        require(!r.trap&&!r.rd&&r.dirty,"iota rejected");
        require(read_csr(0x008)==0&&read_csr(0xc20)==vl&&read_csr(0x009)==scenario%2&&read_csr(0x00a)==scenario%4,"iota CSRs");
        compare_memory("iota sew="+std::to_string(sew)+" lm="+std::to_string(lm)+" scenario="+std::to_string(scenario));++cases;
    }
    for(unsigned mode=0;mode<9;++mode){
        initialize();configure(mode==2?0x100:mode==4?3:mode==6?1:0,mode==0?0:4);
        write_csr(0x008,mode<2||mode==8?1:0);
        const unsigned vd=mode==3?17:mode==5?0:mode==6?9:8,src=mode==4?11:17;
        const auto insn=integer(0x14,2,vd,src,16,mode!=5);
        if(mode==7)dut.vector_enabled=0;
        const auto r=command(insn,0,0,mode==8);
        if(mode!=8)require(r.trap&&r.cause==2&&r.tval==insn&&!r.dirty,"illegal iota accepted");
        dut.vector_enabled=1;
        require(read_csr(0x008)==(mode<2||mode==8?1u:0u),"negative iota restart");compare_memory("negative iota");++negative;
    }
    if(TEST_VLEN>=512)require(wrapped!=0,"missing iota e8 wrap coverage");
    std::printf("PASS vector_iota cases=%llu negative=%llu wrapped=%llu\n",(unsigned long long)cases,(unsigned long long)negative,(unsigned long long)wrapped);
}
