#pragma once
static void test_vector_index(){
    uint64_t cases=0,wrapped=0;
    for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew)for(int lm=-3;lm<=3;++lm)
    for(unsigned scenario=0;scenario<10;++scenario){
        if(lm<0&&(8u<<sew)>(TEST_ELEN>>-lm))continue;
        initialize();const unsigned vl=configure((sew<<3)|(lm&7)|((scenario%4)<<6),scenario==0?0:scenario==1?1:TEST_VLEN);
        const unsigned start=scenario==3?1:scenario==4?vl:scenario==5?TEST_VLEN-1:0;
        write_csr(0x008,start);write_csr(0x009,scenario%2);write_csr(0x00a,scenario%4);
        const bool masked=scenario>=6;const unsigned vd=scenario==2?0:8;
        for(unsigned b=0;b<TEST_VLEN/8;++b){const unsigned m=scenario==6?0:scenario==7?0xff:0x55;host(true,b,0,m);put(b,1,m);}
        for(unsigned i=start&(TEST_VLEN-1);i<vl;++i){
            if(masked&&!((memory.at(i/8)>>(i%8))&1))continue;
            put(vd*(TEST_VLEN/8)+(i<<sew),1u<<sew,i);
            if(sew==0&&i>255)++wrapped;
        }
        const auto r=command(integer(0x14,2,vd,0,17,!masked));
        require(!r.trap&&!r.rd&&r.dirty,"vid rejected");
        require(read_csr(0x008)==0&&read_csr(0xc20)==vl&&read_csr(0x009)==scenario%2&&read_csr(0x00a)==scenario%4,"vid CSRs");
        compare_memory("vid sew="+std::to_string(sew)+" lm="+std::to_string(lm)+" scenario="+std::to_string(scenario));++cases;
    }
    for(unsigned mode=0;mode<5;++mode){
        initialize();configure(mode==0?0x100:mode==1?1:0,4);write_csr(0x008,2);
        const auto insn=integer(0x14,2,mode==1?9:mode==2?0:8,mode==3?1:0,17,mode!=2);
        const auto r=command(insn,0,0,mode==4);
        if(mode!=4)require(r.trap&&r.cause==2&&r.tval==insn&&!r.dirty,"illegal vid accepted");
        require(read_csr(0x008)==2,"illegal/cancelled vid restart");compare_memory("negative vid");
    }
    if(TEST_VLEN>=512)require(wrapped!=0,"missing e8 index truncation coverage");
    std::printf("PASS vector_index cases=%llu negative=5 wrapped=%llu\n",(unsigned long long)cases,(unsigned long long)wrapped);
}
