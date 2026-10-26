#pragma once
static void test_vector_gather(){
    const unsigned rb=TEST_VLEN/8;uint64_t cases=0,negative=0;
    for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew)for(int lm=-3;lm<=3;++lm){
      if(lm<0&&(8u<<sew)>(TEST_ELEN>>-lm))continue;
      const unsigned cap=lm>=0?(TEST_VLEN/(8u<<sew))<<lm:(TEST_VLEN/(8u<<sew))>>-lm;
      for(unsigned kind=0;kind<4;++kind){
        const bool vector=kind<2,ei16=kind==1,imm=kind==3;
        const int em=lm+(ei16?1-int(sew):0);
        if(vector&&(em<-3||em>3))continue;
        const unsigned isize=ei16?1:sew;
        for(unsigned scenario=0;scenario<16;++scenario){
          initialize();const unsigned vl=configure((sew<<3)|(lm&7)|((scenario%4)<<6),scenario==0?0:scenario==1?1:scenario==2?cap/2:cap);
          const unsigned start=scenario==3?1:scenario==5?vl:scenario==9?vl/2:0;
          const bool masked=scenario>=6&&scenario<12;
          const unsigned vd=scenario==2?0:8,src=16,idx=scenario==4&&(!ei16||sew==1)?src:scenario==12?0:24;
          const uint64_t xmax=TEST_XLEN==32?UINT32_MAX:UINT64_MAX;
          const uint64_t values[]={0,1,cap-1,cap,1,31,32,255,256,xmax,xmax-1,uint64_t(1)<<(TEST_XLEN-1),0,xmax,cap+1,0};
          const uint64_t scalar=values[scenario];
          if(vector)for(unsigned i=0;i<cap;++i){
            const uint64_t value=scenario==13?random64():scenario==14?cap-1-i:values[(scenario+i)%16];
            host(true,idx*rb+(i<<isize),isize,value);put(idx*rb+(i<<isize),1u<<isize,value);
          }
          // A v0 index operand is tested unmasked; preserve its data there.
          if(idx!=0||!vector)for(unsigned b=0;b<rb;++b){const uint8_t m=scenario==6?0:scenario==7?0xff:0x55;host(true,b,0,m);put(b,1,m);}
          write_csr(0x008,start);write_csr(0x009,scenario%2);write_csr(0x00a,scenario%4);
          const auto before=memory;
          for(unsigned i=start&(TEST_VLEN-1);i<vl;++i){
            if(masked&&!((before[i/8]>>(i%8))&1))continue;
            uint64_t from=imm?scalar&31:scalar;
            if(vector){from=0;for(unsigned b=0;b<(1u<<isize);++b)from|=uint64_t(before[idx*rb+(i<<isize)+b])<<(b*8);}
            for(unsigned b=0;b<(1u<<sew);++b)memory[vd*rb+(i<<sew)+b]=from<cap?before[src*rb+(unsigned(from)<<sew)+b]:0;
          }
          const auto r=command(integer(ei16?0x0e:0x0c,vector?0:imm?3:4,vd,src,vector?idx:imm?scalar&31:3,!masked),scalar);
          require(!r.trap&&!r.rd&&r.dirty,"gather rejected");
          require(read_csr(0x008)==0&&read_csr(0xc20)==vl&&read_csr(0x009)==scenario%2&&read_csr(0x00a)==scenario%4,"gather CSRs");
          compare_memory("gather kind="+std::to_string(kind)+" sew="+std::to_string(sew)+" lm="+std::to_string(lm)+" scenario="+std::to_string(scenario));++cases;
        }
      }
    }
    for(unsigned mode=0;mode<15;++mode){
      initialize();configure(mode==0?0x100:mode==3||mode==4||mode==5?1:mode==6?3:0,mode==2?0:4);write_csr(0x008,1);
      const unsigned vd=mode==1||mode==2?16:mode==3||mode==14?9:mode==8?0:8;
      const unsigned src=mode==4?17:16,idx=mode==5||mode==13?25:mode==7||mode==14?8:24;
      const auto insn=integer(mode==6||mode==7||mode>=13?0x0e:0x0c,mode==9?2:mode==10?6:0,vd,src,idx,mode!=8);
      if(mode==11)dut.vector_enabled=0;
      const auto r=command(insn,0,0,mode==12);
      if(mode!=12)require(r.trap&&r.cause==2&&r.tval==insn&&!r.dirty,"illegal gather accepted");
      dut.vector_enabled=1;require(read_csr(0x008)==1,"negative gather restart");compare_memory("negative gather");++negative;
    }
    std::printf("PASS vector_gather cases=%llu negative=%llu\n",(unsigned long long)cases,(unsigned long long)negative);
}
