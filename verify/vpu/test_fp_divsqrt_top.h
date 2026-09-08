#pragma once
static void test_vector_fp_divsqrt(){
    uint64_t cases=0,negative=0;const unsigned rb=TEST_VLEN/8;
    for(unsigned sew=2;(8u<<sew)<=TEST_ELEN;++sew)
    for(unsigned op=0;op<4;++op)for(unsigned rm=0;rm<5;++rm)
    for(unsigned rotation=0;rotation<2;++rotation)for(unsigned scenario=0;scenario<8;++scenario){
      initialize();const unsigned bytes=1u<<sew,vd=scenario==7?16:8;
      const unsigned vl=scenario==3?2:scenario==4?0:8,start=scenario==2?6:scenario==5?8:0;
      configure((sew<<3)|2|((scenario%4)<<6),vl);
      const uint64_t inf=sew==2?0x7f800000ULL:0x7ff0000000000000ULL;
      const uint64_t sign=sew==2?0x80000000ULL:0x8000000000000000ULL;
      const uint64_t qnan=sew==2?0x7fc00000ULL:0x7ff8000000000000ULL;
      const uint64_t one=fp_bits(1,sew),two=fp_bits(2,sew),half=sew==2?0x3f000000ULL:0x3fe0000000000000ULL;
      const uint64_t third=sew==2?(rm==1||rm==2?0x3eaaaaaaULL:0x3eaaaaabULL)
          :(rm==3?0x3fd5555555555556ULL:0x3fd5555555555555ULL);
      const uint64_t root_two=sew==2?(rm==3?0x3fb504f4ULL:0x3fb504f3ULL)
          :(rm==1||rm==2?0x3ff6a09e667f3bccULL:0x3ff6a09e667f3bcdULL);
      uint64_t a[]={fp_bits(6,sew),one,0,one,1,inf-1,sign,inf|1};
      uint64_t b[]={two,0,0,fp_bits(3,sew),two,half,two,one};
      uint64_t out[]={fp_bits(3,sew),inf,qnan,third,rm==3||rm==4?1u:0u,rm==1||rm==2?inf-1:inf,sign,qnan};
      unsigned flags[]={0,8,16,1,3,5,0,16};
      if(op==3){
        const uint64_t inputs[]={fp_bits(4,sew),sign|one,two,sign,inf,inf|1,sew==2?0x00800000ULL:0x0010000000000000ULL,qnan};
        const uint64_t outputs[]={two,qnan,root_two,sign,inf,qnan,sew==2?0x20000000ULL:0x2000000000000000ULL,qnan};
        const unsigned exceptions[]={0,16,1,0,0,16,0,0};
        for(unsigned i=0;i<8;++i){a[i]=inputs[i];b[i]=qnan;out[i]=outputs[i];flags[i]=exceptions[i];}
      }
      // Scalar forms use a fixed 2.0 operand: 6/2 or 2/x, including x=0,
      // infinities, NaNs and subnormals. Keep their expected results explicit.
      if(op==1){
        for(unsigned i=0;i<8;++i)b[i]=two;
        out[0]=fp_bits(3,sew);out[1]=half;out[2]=0;out[3]=half;
        out[5]=sew==2?0x7effffffULL:0x7fdfffffffffffffULL;
        flags[1]=flags[2]=flags[3]=flags[5]=0;
      }
      if(op==2){
        const uint64_t inputs[]={one,0,inf,two,sign,sign|one,qnan,inf|1};
        const uint64_t outputs[]={two,inf,0,one,sign|inf,sign|two,qnan,qnan};
        const unsigned exceptions[]={0,8,0,0,8,0,0,16};
        for(unsigned i=0;i<8;++i){a[i]=inputs[i];out[i]=outputs[i];flags[i]=exceptions[i];}
      }
      for(unsigned i=0;i<8;++i){unsigned k=(i+rotation*3)%8;
        host(true,16*rb+i*bytes,sew,a[k]);put(16*rb+i*bytes,bytes,a[k]);
        host(true,24*rb+i*bytes,sew,b[k]);put(24*rb+i*bytes,bytes,b[k]);
      }
      const bool masked=scenario==1||scenario==6;
      const unsigned mask=scenario==1?0x33:scenario==6?0:0xff;
      host(true,0,0,mask);put(0,1,mask);write_csr(0x008,start);
      unsigned expected_flags=0;
      for(unsigned i=start;i<vl;++i){if(masked&&!((mask>>i)&1))continue;
        const unsigned k=(i+rotation*3)%8;put(vd*rb+i*bytes,bytes,out[k]);expected_flags|=flags[k];}
      const unsigned fn=op==3?0x13:op==2?0x21:0x20,form=op==1||op==2?5:1;
      const uint64_t scalar=two|(sew==2?0xffffffff00000000ULL:0);
      auto r=command(integer(fn,form,vd,16,op==3?0:24,!masked),0,0,false,scalar,rm);
      require(!r.trap&&r.fp_dirty&&r.dirty&&r.fflags==expected_flags,"FP divide/sqrt flags");
      compare_memory("FP divide/sqrt op="+std::to_string(op));require(read_csr(0x008)==0,"FP divide/sqrt restart");++cases;
    }
    // Reserved unary selectors/forms, invalid FRM, disabled FS and cancelled
    // ownership must preserve both vector contents and restart state.
    for(unsigned mode=0;mode<8;++mode){
      initialize();configure(16,1);write_csr(0x008,1);
      const unsigned fn=mode==2?0x21:0x13,form=mode==1?5:1,vs1=mode==0?1:0;
      auto r=command(integer(fn,form,8,16,vs1,true),0,0,mode==7,0,mode>=3&&mode<=5?mode+2:0,mode!=6);
      if(mode!=7)require(r.trap&&r.cause==2&&!r.fflags&&!r.fp_dirty&&!r.dirty,"FP divide/sqrt illegal");
      require(read_csr(0x008)==1,"FP divide/sqrt illegal restart");compare_memory("FP divide/sqrt illegal");++negative;
    }
    std::printf("PASS vector_fp_divsqrt cases=%llu negative=%llu\n",(unsigned long long)cases,(unsigned long long)negative);
}
