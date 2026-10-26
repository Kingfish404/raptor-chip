#pragma once
static void test_vector_slide(){
    const unsigned rb=TEST_VLEN/8;uint64_t cases=0,negative=0;
    for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew)for(int lm=-3;lm<=3;++lm){
      if(lm<0&&(8u<<sew)>(TEST_ELEN>>-lm))continue;
      const unsigned cap=lm>=0?(TEST_VLEN/(8u<<sew))<<lm:(TEST_VLEN/(8u<<sew))>>-lm;
      for(unsigned kind=0;kind<6;++kind)for(unsigned scenario=0;scenario<16;++scenario){
        const bool up=!(kind&1),single=kind>=4,imm=kind<2,masked=scenario>=6&&scenario<12;
        initialize();const unsigned vl=configure((sew<<3)|(lm&7)|((scenario%4)<<6),scenario==0?0:scenario==1?1:scenario==2?cap/2:cap);
        const unsigned start=scenario==3?1:scenario==5?vl:scenario==9?vl/2:0;
        write_csr(0x008,start);write_csr(0x009,scenario%2);write_csr(0x00a,scenario%4);
        const unsigned src=16,vd=(scenario==4||scenario==15)&&!up?src:scenario==2?0:8;
        for(unsigned b=0;b<rb;++b){const uint8_t m=scenario==6?0:scenario==7?0xff:0x55;host(true,b,0,m);put(b,1,m);}
        const uint64_t xmax=TEST_XLEN==32?UINT32_MAX:UINT64_MAX;
        const uint64_t values[]={0,1,cap-1,cap,1,31,32,255,256,xmax,xmax-1,uint64_t(1)<<(TEST_XLEN-1),uint64_t(1)<<(TEST_XLEN-1),xmax,cap+1,0};
        const uint64_t scalar=values[scenario],offset=single?1:imm?scalar&31:scalar;
        const auto before=memory;
        for(unsigned i=start&(TEST_VLEN-1);i<vl;++i){
          if(masked&&!((before[i/8]>>(i%8))&1))continue;
          const bool insert=single&&(up?i==0:i+1==vl);
          const __int128 from=__int128(i)+(up?-1:1)*__int128(offset);
          if(!insert&&from<0)continue;
          const uint64_t inserted=TEST_XLEN==32?uint64_t(int64_t(int32_t(scalar))):scalar;
          for(unsigned b=0;b<(1u<<sew);++b)
            memory[vd*rb+(i<<sew)+b]=insert?uint8_t(inserted>>(b*8)):from<cap?before[src*rb+(unsigned(from)<<sew)+b]:0;
        }
        const auto r=command(integer(up?0x0e:0x0f,imm?3:single?6:4,vd,src,imm?scalar&31:3,!masked),scalar);
        require(!r.trap&&!r.rd&&r.dirty,"slide rejected");
        require(read_csr(0x008)==0&&read_csr(0xc20)==vl&&read_csr(0x009)==scenario%2&&read_csr(0x00a)==scenario%4,"slide CSRs");
        compare_memory("slide kind="+std::to_string(kind)+" sew="+std::to_string(sew)+" lm="+std::to_string(lm)+" scenario="+std::to_string(scenario));++cases;
      }
    }
    for(unsigned mode=0;mode<10;++mode){
      initialize();configure(mode==4?0x100:mode==2||mode==3?1:0,mode==1?0:4);write_csr(0x008,1);
      const unsigned vd=mode<2?16:mode==2?9:mode==5?0:8;
      const auto insn=integer(mode==7?0x0f:0x0e,mode==6?0:mode==7?2:mode==1?6:4,vd,mode==3?17:16,3,mode!=5);
      if(mode==8)dut.vector_enabled=0;
      const auto r=command(insn,1,0,mode==9);
      if(mode!=9)require(r.trap&&r.cause==2&&r.tval==insn&&!r.dirty,"illegal slide accepted");
      dut.vector_enabled=1;require(read_csr(0x008)==1,"negative slide restart");compare_memory("negative slide");++negative;
    }
    std::printf("PASS vector_slide cases=%llu negative=%llu\n",(unsigned long long)cases,(unsigned long long)negative);
}
