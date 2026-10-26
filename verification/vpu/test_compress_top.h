#pragma once
static void test_vector_compress(){
    const unsigned rb=TEST_VLEN/8;uint64_t cases=0,negative=0;
    for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew)for(int lm=-3;lm<=3;++lm)for(unsigned scenario=0;scenario<10;++scenario){
        if(lm<0&&(8u<<sew)>(TEST_ELEN>>-lm))continue;
        initialize();const unsigned vl=configure((sew<<3)|(lm&7)|((scenario%4)<<6),scenario==0?0:scenario==1?1:scenario==2?9:TEST_VLEN);
        const unsigned vd=scenario==3?0:8,src=16,mask=scenario==4?src:scenario==5?0:31;
        for(unsigned b=0;b<rb;++b){const uint8_t m=scenario==6?0:scenario==7?0xff:scenario==8?0x55:random64();host(true,mask*rb+b,0,m);put(mask*rb+b,1,m);}
        const auto before=memory;unsigned target=0;
        for(unsigned i=0;i<vl;++i)if((before[mask*rb+i/8]>>(i%8))&1){
            for(unsigned b=0;b<(1u<<sew);++b)memory[vd*rb+(target<<sew)+b]=before[src*rb+(i<<sew)+b];++target;
        }
        write_csr(0x009,scenario%2);write_csr(0x00a,scenario%4);
        const auto r=command(integer(0x17,2,vd,src,mask,true));
        require(!r.trap&&!r.rd&&r.dirty,"compress rejected");
        require(read_csr(0x008)==0&&read_csr(0xc20)==vl&&read_csr(0x009)==scenario%2&&read_csr(0x00a)==scenario%4,"compress CSRs");
        compare_memory("compress sew="+std::to_string(sew)+" lm="+std::to_string(lm)+" scenario="+std::to_string(scenario));++cases;
    }
    for(unsigned mode=0;mode<10;++mode){
        initialize();configure(mode==2?0x100:mode==4?3:mode==6||mode==7?1:0,mode==0?0:4);
        write_csr(0x008,mode<2||mode==9?1:0);
        const auto insn=integer(0x17,2,mode==3?16:mode==6?9:8,mode==7?17:16,mode==4?11:31,mode!=5);
        if(mode==8)dut.vector_enabled=0;
        const auto r=command(insn,0,0,mode==9);
        if(mode!=9)require(r.trap&&r.cause==2&&r.tval==insn&&!r.dirty,"illegal compress accepted");
        dut.vector_enabled=1;require(read_csr(0x008)==(mode<2||mode==9?1u:0u),"negative compress restart");compare_memory("negative compress");++negative;
    }
    std::printf("PASS vector_compress cases=%llu negative=%llu\n",(unsigned long long)cases,(unsigned long long)negative);
}
