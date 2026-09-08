#pragma once
static void test_vector_move() {
    const unsigned rb=TEST_VLEN/8;
    uint64_t cases=0,invalids=0;
    for(unsigned n:{1u,2u,4u,8u})for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew)
    for(int lm=-3;lm<=3;++lm)for(unsigned scenario=0;scenario<8;++scenario) {
        if(lm<0&&(8u<<sew)>(TEST_ELEN>>-lm))continue;
        initialize();
        const auto vl=configure((sew<<3)|(lm&7)|((scenario%4)<<6),scenario%2?3:0);
        const unsigned evl=(n*rb)>>sew;
        const unsigned requested=scenario<2?0:scenario==2?1:scenario==3?evl-1:scenario==4?evl:scenario==5?evl+1:scenario==6?rb/(1u<<sew)+1:TEST_VLEN-1;
        write_csr(0x008,requested);
        const unsigned start=(requested&(TEST_VLEN-1))<<sew;
        write_csr(0x009,scenario%2);write_csr(0x00a,scenario%4);
        const unsigned src=scenario==7?32-n:16,dst=scenario==6?src:scenario==7?0:8;
        const auto before=memory;
        for(unsigned b=start;b<n*rb;++b)memory.at(dst*rb+b)=before.at(src*rb+b);
        const auto r=command(integer(0x27,3,dst,src,n-1,true));
        require(!r.trap&&!r.rd&&r.dirty,"whole move rejected");
        require(read_csr(0x008)==0&&read_csr(0xc20)==vl,"whole move VL/vstart");
        require(read_csr(0x009)==scenario%2&&read_csr(0x00a)==scenario%4,"whole move fixed CSR");
        compare_memory("whole move n="+std::to_string(n)+" sew="+std::to_string(sew)+" scenario="+std::to_string(scenario));++cases;
    }
    // Whole-register moves depend on SEW: corrected RVV text requires VILL=0.
    for(unsigned n:{1u,2u,4u,8u}) {
        initialize();configure(0x100,0);const auto type=read_csr(0xc21);
        require(type==(uint64_t(1)<<(TEST_XLEN-1)),"move test failed to set vill");
        write_csr(0x008,1);
        const auto r=command(integer(0x27,3,8,16,n-1,true));
        require(r.trap&&r.cause==2&&!r.dirty&&read_csr(0xc21)==type&&read_csr(0xc20)==0&&read_csr(0x008)==1,"whole move vill behavior");
        compare_memory("whole move vill");++invalids;
    }
    for(unsigned count=0;count<32;++count)for(unsigned mode=0;mode<4;++mode) {
        const bool valid_count=count==0||count==1||count==3||count==7;
        if(valid_count&&(mode==0||(count==0&&mode>=2)))continue;
        initialize();configure(0,0);write_csr(0x008,3);
        const auto insn=integer(0x27,3,mode==2?9:8,mode==3?17:16,count,mode!=1);
        const auto r=command(insn);
        require(r.trap&&r.cause==2&&r.tval==insn&&!r.dirty,"reserved whole move accepted");
        require(read_csr(0x008)==3,"illegal whole move restart");
        compare_memory("illegal whole move");++invalids;
    }
    initialize();configure(0,0);write_csr(0x008,2);
    command(integer(0x27,3,8,16,7,true),0,0,true);
    require(read_csr(0x008)==2,"cancelled move state");compare_memory("cancelled move");
    std::printf("PASS vector_move cases=%llu illegal=%llu\n",(unsigned long long)cases,(unsigned long long)invalids);
}
