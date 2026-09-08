#pragma once
static void test_vector_scalar_move(){
    const unsigned rb=TEST_VLEN/8;
    uint64_t cases=0,invalids=0;
    for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew)for(int lm=-3;lm<=3;++lm)
    for(unsigned direction=0;direction<2;++direction)for(unsigned scenario=0;scenario<10;++scenario){
        const unsigned bits=8u<<sew;
        if(lm<0&&bits>(TEST_ELEN>>-lm))continue;
        initialize();const auto vl=configure((sew<<3)|(lm&7)|((scenario%4)<<6),scenario%3==0?0:scenario%3==1?1:TEST_VLEN);
        const unsigned requested=scenario<3?0:scenario<6?1:scenario<8?unsigned(vl):TEST_VLEN-1;
        write_csr(0x008,requested);const unsigned start=requested&(TEST_VLEN-1);
        write_csr(0x009,scenario%2);write_csr(0x00a,scenario%4);
        const unsigned reg=scenario==0?0:scenario==1?31:17,rd=scenario%4==0?0:5;
        uint64_t v=scenario%4==0?UINT64_MAX:scenario%4==1?uint64_t(1)<<(bits-1):scenario%4==2?uint64_t(1)<<(TEST_XLEN-1):random64();
        host(true,reg*rb,sew,v);put(reg*rb,1u<<sew,v);
        const auto source=get(reg*rb,1u<<sew);
        uint64_t scalar=scenario==0?0:scenario%2?UINT64_MAX:random64();
        if(TEST_XLEN==32)scalar=uint64_t(int64_t(int32_t(scalar)));
        if(direction&&start<vl)put(reg*rb,1u<<sew,scalar);
        uint64_t expected=source;
        if(bits<64&&(source&(uint64_t(1)<<(bits-1))))expected|=UINT64_MAX<<bits;
        if(TEST_XLEN==32)expected&=UINT32_MAX;
        const auto insn=direction?integer(0x10,6,reg,0,scenario==0?0:1,true):integer(0x10,2,rd,reg,0,true);
        const auto r=command(insn,direction?scalar:0);
        require(!r.trap&&r.dirty,"scalar move rejected");
        require(r.rd==(direction?0:rd),"scalar move result register");
        if(!direction)require(r.value==(rd?expected:0),"scalar move sign/width result");
        require(read_csr(0x008)==0&&read_csr(0xc20)==vl,"scalar move restart/VL");
        require(read_csr(0x009)==scenario%2&&read_csr(0x00a)==scenario%4,"scalar move fixed CSRs");
        compare_memory("scalar move direction="+std::to_string(direction)+" sew="+std::to_string(bits)+" scenario="+std::to_string(scenario));++cases;
    }
    for(unsigned direction=0;direction<2;++direction)for(unsigned mode=0;mode<5;++mode){
        initialize();configure(mode==0?0x100:0,0);write_csr(0x008,2);
        const auto insn=integer(0x10,direction?6:2,8,direction?(mode==2?1:0):17,direction?1:(mode==2?1:0),mode!=1);
        if(mode==3) dut.vector_enabled=0;
        const auto r=command(insn,0,0,mode==4);
        if(mode!=4)require(r.trap&&r.cause==2&&r.tval==insn&&!r.dirty,"illegal scalar move accepted");
        dut.vector_enabled=1;
        require(read_csr(0x008)==2,"illegal/cancelled scalar move restart");
        compare_memory("illegal/cancelled scalar move");++invalids;
    }
    std::printf("PASS vector_scalar_move cases=%llu negative=%llu\n",(unsigned long long)cases,(unsigned long long)invalids);
}
