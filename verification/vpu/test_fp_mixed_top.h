#pragma once
static void test_vector_fp_mixed(){
    uint64_t cases=0;unsigned unions_seen=0;
    const unsigned rb=TEST_VLEN/8;
    for(unsigned sew=2;(8u<<sew)<=TEST_ELEN;++sew)
    for(unsigned rm=0;rm<5;++rm)for(unsigned rotation=0;rotation<4;++rotation)
    for(unsigned scenario=0;scenario<8;++scenario){
      initialize();const unsigned bytes=1u<<sew,vd=scenario==7?16:8;
      const unsigned vl=scenario==3?2:scenario==4?0:8,start=scenario==2?6:scenario==5?8:0;
      configure((sew<<3)|2|((scenario%4)<<6),vl); // LMUL=4 accommodates eight e64 elements at VLEN=128.
      const uint64_t inf=sew==2?0x7f800000ULL:0x7ff0000000000000ULL;
      const uint64_t qnan=sew==2?0x7fc00000ULL:0x7ff8000000000000ULL;
      const uint64_t half=sew==2?0x3f000000ULL:0x3fe0000000000000ULL;
      const uint64_t lhs[]={1,inf-1,inf|1,fp_bits(2,sew)};
      const uint64_t rhs[]={half,fp_bits(2,sew),fp_bits(1,sew),fp_bits(3,sew)};
      const uint64_t expected[]={rm==3||rm==4?1u:0u,rm==1||rm==2?inf-1:inf,qnan,fp_bits(6,sew)};
      const unsigned exceptions[]={3,5,16,0};
      for(unsigned i=0;i<8;++i){unsigned kind=(i+rotation)%4;
        host(true,16*rb+i*bytes,sew,lhs[kind]);put(16*rb+i*bytes,bytes,lhs[kind]);
        host(true,24*rb+i*bytes,sew,rhs[kind]);put(24*rb+i*bytes,bytes,rhs[kind]);
      }
      const bool masked=scenario==1||scenario==6;
      // Select two exception classes in mode 1; none in mode 6.
      const unsigned mask=scenario==1?0x33:scenario==6?0:0xff;
      host(true,0,0,mask);put(0,1,mask);write_csr(0x008,start);
      unsigned expected_flags=0;
      for(unsigned i=start;i<vl;++i){
        if(masked&&!((mask>>i)&1))continue;
        unsigned kind=(i+rotation)%4;expected_flags|=exceptions[kind];
        put(vd*rb+i*bytes,bytes,expected[kind]);
      }
      auto r=command(integer(0x24,1,vd,16,24,!masked),0,0,false,0,rm);
      require(!r.trap&&r.fp_dirty&&r.dirty&&r.fflags==expected_flags,"mixed FP flags union");
      if(expected_flags==23)++unions_seen;
      compare_memory("mixed FP flags");require(read_csr(0x008)==0,"mixed FP restart");
      // An exact FP command immediately after every mixture must return a new
      // zero delta, even if the preceding owner accumulated NV|OF|UF|NX.
      configure(sew<<3,1);
      const uint64_t two=fp_bits(2,sew),three=fp_bits(3,sew),six=fp_bits(6,sew);
      host(true,16*rb,sew,two);put(16*rb,bytes,two);host(true,24*rb,sew,three);put(24*rb,bytes,three);
      put(8*rb,bytes,six);r=command(integer(0x24,1,8,16,24,true),0,0,false,0,rm);
      require(!r.trap&&r.fp_dirty&&!r.fflags,"FP flags leaked across owners");compare_memory("FP delta reset");
      cases+=2;
    }
    require(unions_seen!=0,"mixed exception union coverage missing");
    std::printf("PASS vector_fp_mixed cases=%llu full_unions=%u\n",(unsigned long long)cases,unions_seen);
}
