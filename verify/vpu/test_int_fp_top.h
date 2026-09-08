#pragma once
// Exact small integer inputs and explicitly rounded half-integers provide a
// portable oracle without relying on the host floating-point rounding mode.
static void test_vector_int_fp(){
 const unsigned rb=TEST_VLEN/8;uint64_t cases=0,negative=0;
 const unsigned selectors[]={0,1,2,3,6,7,8,9,10,11,14,15,16,17,18,19,22,23};
 for(unsigned op:selectors)for(unsigned sew=1;sew<=3;++sew){
  const unsigned low=op%8;const bool tofp=low==2||low==3,uns=!(op&1),wide=op/8==1,narrow=op/8==2;
  const unsigned as=sew+narrow,ds=sew+wide,fs=tofp?ds:as,is=tofp?as:ds;
  const bool legal=fs>=2&&fs<=3&&is>=1&&is<=3&&(8u<<as)<=TEST_ELEN&&(8u<<ds)<=TEST_ELEN;
  if(!legal){initialize();configure(sew*8,1);auto r=command(integer(0x12,1,8,16,op,true));
   require(r.trap&&r.cause==2&&!r.fflags&&!r.fp_dirty,"integer/FP unsupported widths");compare_memory("integer/FP illegal width");++negative;continue;}
  for(unsigned rm=0;rm<5;++rm)for(unsigned scenario=0;scenario<8;++scenario)for(int lm=-1;lm<=1;++lm){
   if((8u<<sew)>(TEST_ELEN>>(-std::min(lm,0))))continue;
   initialize();const unsigned vl=configure(sew*8|(lm&7)|((scenario%4)<<6),scenario==0?0:scenario==1?1:TEST_VLEN);
   const unsigned vd=8,dg=lm<0?1u:(wide?2u:1u)<<lm,sg=lm<0?1u:1u<<lm;
   const unsigned src=scenario==3&&(narrow||(wide&&lm>=0))?(wide?vd+dg-sg:vd):16;
   const unsigned start=scenario==4?vl/2:scenario==5?vl:0;const bool masked=scenario==4||scenario==6;
   uint64_t inputs[8],outputs[8];unsigned flags[8];
   for(unsigned k=0;k<8;++k){
    flags[k]=0;
    if(tofp){int v=uns?int(k*7):int(k*7)-23;inputs[k]=uint64_t(int64_t(v));outputs[k]=fp_bits(v,fs);
     if(k==7&&((fs==2&&is>=2)||(fs==3&&is==3))){
      const uint64_t magnitude=(1ULL<<(fs==2?24:53))+1;
      const bool neg=!uns;inputs[k]=neg?0-magnitude:magnitude;
      const bool up=rm==4||(neg?rm==2:rm==3);
      outputs[k]=(fs==2?0x4b800000ULL:0x4340000000000000ULL)+up;
      if(neg)outputs[k]|=fs==2?0x80000000ULL:0x8000000000000000ULL;
      flags[k]=1;
     }
    }
    else{
     // 2.5, -2.5, exact signed values, +/-infinity and both NaN classes.
     const uint64_t a32[]={0x40200000,0xc0200000,0x40e00000,0xc1000000,0x7f800000,0xff800000,0x7fc00001,0x7f800001};
     const uint64_t a64[]={0x4004000000000000ULL,0xc004000000000000ULL,0x401c000000000000ULL,0xc020000000000000ULL,0x7ff0000000000000ULL,0xfff0000000000000ULL,0x7ff8000000000001ULL,0x7ff0000000000001ULL};
     inputs[k]=fs==3?a64[k]:a32[k];const unsigned effective=low>=6?1:rm,bits=8u<<is;
     const uint64_t max=uns?(bits==64?~0ULL:(1ULL<<bits)-1):(1ULL<<(bits-1))-1;
     const uint64_t min=uns?0:1ULL<<(bits-1);
     if(k>=4){outputs[k]=k==5?min:max;flags[k]=16;}
     else if(uns&&(k==1||k==3)){outputs[k]=0;flags[k]=16;}
     else if(k==0){outputs[k]=effective==3||effective==4?3:2;flags[k]=1;}
     else if(k==1){outputs[k]=uint64_t(int64_t(effective==2||effective==4?-3:-2));flags[k]=1;}
     else outputs[k]=uint64_t(int64_t(k==2?7:-8));
    }
   }
   for(unsigned i=0;i<vl;++i){unsigned k=(i+(scenario==7?4:0))%8;host(true,src*rb+(i<<as),as,inputs[k]);put(src*rb+(i<<as),1u<<as,inputs[k]);}
   for(unsigned i=0;i<(vl+7)/8;++i){unsigned m=scenario==6?0:0x55;host(true,i,0,m);put(i,1,m);}
   const auto before=memory;unsigned expected=0;write_csr(0x008,start);
   for(unsigned i=start;i<vl;++i){if(masked&&!((before[i/8]>>(i%8))&1))continue;unsigned k=(i+(scenario==7?4:0))%8;put(vd*rb+(i<<ds),1u<<ds,outputs[k]);expected|=flags[k];}
   auto r=command(integer(0x12,1,vd,src,op,!masked),0,0,false,0x0123456789abcdefULL,rm);
   require(!r.trap&&r.fp_dirty&&r.dirty&&r.fflags==expected,"integer/FP completion op="+std::to_string(op)+" sew="+std::to_string(sew)+" scenario="+std::to_string(scenario));
   compare_memory("integer/FP conversion");require(read_csr(0x008)==0,"integer/FP restart");++cases;
  }
  for(unsigned mode=0;mode<5;++mode){initialize();configure(sew*8,mode==0?0:1);write_csr(0x008,1);
   auto r=command(integer(0x12,mode==3?5:1,8,16,op,true),0,0,mode==4,0,mode<2?6:0,mode!=2);
   if(mode!=4)require(r.trap&&r.cause==2&&!r.fflags&&!r.fp_dirty&&!r.dirty,"integer/FP illegal control");
   require(read_csr(0x008)==1,"integer/FP illegal restart");compare_memory("integer/FP illegal control");++negative;
  }
 }
 // Finite I16 clipping must replace NX with NV; negative fractions that
 // round to unsigned zero are valid and still inexact.
 for(unsigned op:{16u,17u,22u,23u})for(unsigned rm=0;rm<5;++rm)for(unsigned k=0;k<6;++k){
  initialize();configure(8,1);const bool uns=!(op&1);const unsigned effective=op>=22?1:rm;
  const uint64_t a[]={0x46ffff00,0xc7000080,0x477fff80,0xbf000000,0x47000000,0x47800000};
  // 32767.5, -32768.5, 65535.5, -0.5, 32768, 65536.
  const int64_t lower[]={32767,-32769,65535,-1,32768,65536};
  int64_t value=lower[k];const bool fraction=k<4,neg=k==1||k==3;
  if(fraction){
   if(effective==0)value+=(value&1)!=0;
   else if(effective==1)value+=neg;
   else if(effective==3)value+=1;
   else if(effective==4)value+=!neg;
  }
  unsigned flags=fraction?1:0;const int64_t lo=uns?0:-32768,hi=uns?65535:32767;
  if(value<lo){value=lo;flags=16;}if(value>hi){value=hi;flags=16;}
  host(true,16*rb,2,a[k]);put(16*rb,4,a[k]);put(8*rb,2,uint64_t(value));
  auto r=command(integer(0x12,1,8,16,op,true),0,0,false,0,rm);
  require(!r.trap&&r.fflags==flags,"integer/FP I16 finite boundary");compare_memory("integer/FP I16 finite boundary");++cases;
 }
 std::printf("PASS vector_int_fp cases=%llu negative=%llu\n",(unsigned long long)cases,(unsigned long long)negative);
}
