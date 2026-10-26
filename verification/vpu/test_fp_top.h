#pragma once
static uint64_t fp_bits(int value,unsigned sew){
    uint64_t bits=0;
    if(sew==2){float f=float(value);uint32_t x;std::memcpy(&x,&f,4);bits=x;}
    else {double f=double(value);std::memcpy(&bits,&f,8);}return bits;
}
static void test_vector_fp(){
    uint64_t cases=0,negative=0;const unsigned rb=TEST_VLEN/8;
    const unsigned funcs[]={0,2,0x24,0x27,0x28,0x29,0x2a,0x2b,0x2c,0x2d,0x2e,0x2f};
    for(unsigned sew=2;(8u<<sew)<=TEST_ELEN;++sew)for(int lm=-3;lm<=3;++lm){
      if(lm<0&&(8u<<sew)>(TEST_ELEN>>-lm))continue;
      for(auto fn:funcs)for(unsigned form:{1u,5u})for(unsigned scenario=0;scenario<6;++scenario){
        if(fn==0x27&&form==1)continue;
        initialize();const unsigned vl=configure((sew<<3)|(lm&7)|((scenario%4)<<6),scenario==0?0:scenario==1?1:scenario==2?7:TEST_VLEN);
        const unsigned vd=scenario==3?16:8,src=16,bs=24,start=scenario==4?vl/2:scenario==5?vl:0;
        const bool masked=scenario==4;const unsigned bytes=1u<<sew;
        for(unsigned i=0;i<vl;++i){
          for(unsigned reg:{vd,src,bs}){const int n=int((reg+i)%5)+1;const auto v=fp_bits(n,sew);host(true,reg*rb+i*bytes,sew,v);put(reg*rb+i*bytes,bytes,v);}
        }
        const auto before=memory;
        for(unsigned i=start&(TEST_VLEN-1);i<vl;++i){
          if(masked&&!((before[i/8]>>(i%8))&1))continue;
          const int x=int((src+i)%5)+1,y=form==5?-3:int((bs+i)%5)+1,z=int((vd+i)%5)+1;
          int result=0;
          switch(fn){
            case 0:result=x+y;break;case 2:result=x-y;break;case 0x24:result=x*y;break;case 0x27:result=y-x;break;
            case 0x28:result=y*z+x;break;case 0x29:result=-y*z-x;break;case 0x2a:result=y*z-x;break;case 0x2b:result=-y*z+x;break;
            case 0x2c:result=y*x+z;break;case 0x2d:result=-y*x-z;break;case 0x2e:result=y*x-z;break;case 0x2f:result=-y*x+z;break;
          }
          // Exact cancellation may produce -0 under RDN; use RNE for these
          // integer-valued equations, and test all modes separately below.
          put(vd*rb+i*bytes,bytes,fp_bits(result,sew));
        }
        write_csr(0x008,start);
        const uint64_t scalar=fp_bits(-3,sew)|(sew==2?0xffffffff00000000ULL:0);
        const auto r=command(integer(fn,form,vd,src,bs,!masked),0,0,false,scalar);
        require(!r.trap&&r.dirty&&r.fp_dirty&&!r.fflags&&!r.rd,"FP arithmetic completion");
        require(read_csr(0x008)==0,"FP restart clear");compare_memory("FP arithmetic fn="+std::to_string(fn));++cases;
      }
    }
    for(unsigned sew=2;(8u<<sew)<=TEST_ELEN;++sew)for(unsigned kind=0;kind<5;++kind)for(unsigned rm=0;rm<5;++rm)for(unsigned mode=0;mode<4;++mode){
      initialize();configure(sew<<3,1);const unsigned bytes=1u<<sew;
      const uint64_t one=fp_bits(1,sew),inf=sew==2?0x7f800000ULL:0x7ff0000000000000ULL;
      const uint64_t qnan=sew==2?0x7fc00000ULL:0x7ff8000000000000ULL;
      uint64_t a=one,b=1,out=rm==3?one+1:one;unsigned flags=1,fn=0;
      if(kind==1){a=inf-1;b=fp_bits(2,sew);out=rm==1||rm==2?inf-1:inf;flags=5;fn=0x24;}
      if(kind==2){a=1;b=sew==2?0x3f000000ULL:0x3fe0000000000000ULL;out=rm==3||rm==4?1:0;flags=3;fn=0x24;}
      if(kind==3){a=inf|1;b=one;out=qnan;flags=16;}
      if(kind==4){a=one;b=0;out=qnan;flags=0;}
      host(true,16*rb,sew,a);put(16*rb,bytes,a);host(true,24*rb,sew,b);put(24*rb,bytes,b);
      // Modes suppress the exceptional element through mask, prestart or VL.
      if(mode==1){host(true,0,0,0);put(0,1,0);}if(mode==2)write_csr(0x008,1);if(mode==3)configure(sew<<3,0);
      if(mode==0)put(8*rb,bytes,out);
      // kind 4 exercises invalid FP32 scalar NaN boxing; for FP64 use qNaN.
      const uint64_t scalar=sew==2?uint64_t(0x3f800000):qnan;
      const auto r=command(integer(fn,kind==4?5:1,8,16,24,mode!=1),0,0,false,scalar,rm);
      require(!r.trap&&r.fp_dirty&&r.fflags==(mode==0?flags:0),"FP active flags");compare_memory("FP flags");++cases;
    }
    for(unsigned mode=0;mode<10;++mode){
      initialize();configure(mode==0?0x100:mode==1?0:mode==2?8:mode==3?17:16,4);write_csr(0x008,1);
      const auto insn=integer(0,1,mode==3?9:mode==4?0:8,16,24,mode!=4);
      const auto r=command(insn,0,0,mode==9,0,mode>=5&&mode<=7?mode:0,mode!=8);
      if(mode!=9)require(r.trap&&r.cause==2&&!r.fflags&&!r.fp_dirty&&!r.dirty,"FP illegal completion");
      require(read_csr(0x008)==1,"FP illegal restart");compare_memory("FP illegal");++negative;
    }
    std::printf("PASS vector_fp cases=%llu negative=%llu\n",(unsigned long long)cases,(unsigned long long)negative);
}
