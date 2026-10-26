#pragma once
static void test_vector_fp_convert(){
 const unsigned rb=TEST_VLEN/8;uint64_t cases=0,negative=0;
 if(TEST_ELEN>=64)for(unsigned op=0;op<3;++op)for(int lm=-1;lm<=2;++lm)
 for(unsigned rm=0;rm<5;++rm)for(unsigned scenario=0;scenario<8;++scenario){
  initialize();const bool widen=op==0,odd=op==2;
  const unsigned as=widen?2:3,ds=widen?3:2,ab=1u<<as,db=1u<<ds;
  const unsigned vl=configure(16|(lm&7)|((scenario%4)<<6),scenario==0?0:scenario==1?1:TEST_VLEN);
  const unsigned vd=8,dg=lm<0?1u:2u<<lm,sg=lm<0?1u:1u<<lm;
  const unsigned src=scenario==3&&(!widen||lm>=0)?(widen?vd+dg-sg:vd):16;
  const unsigned start=scenario==4?vl/2:scenario==5?vl:0;const bool masked=scenario==4||scenario==6;
  uint64_t a[8],out[8];unsigned flags[8];
  if(widen){
   const uint64_t inputs[]={1,0x7f7fffff,0x7f800001,0xffc00000,0x80000000,0x40000000,0x7f800000,0x00800000};
   const uint64_t outputs[]={0x36a0000000000000ULL,0x47efffffe0000000ULL,0x7ff8000000000000ULL,0x7ff8000000000000ULL,0x8000000000000000ULL,0x4000000000000000ULL,0x7ff0000000000000ULL,0x3810000000000000ULL};
   for(unsigned i=0;i<8;++i){a[i]=inputs[i];out[i]=outputs[i];flags[i]=i==2?16:0;}
  }else{
   const uint64_t inputs[]={0x3ff0000010000000ULL,0x3ff0000030000000ULL,1,0x7fefffffffffffffULL,0x7ff0000000000001ULL,0x8000000000000000ULL,0x4000000000000000ULL,0x7ff0000000000000ULL};
   const uint64_t outputs[]={odd||rm==3||rm==4?0x3f800001u:0x3f800000u,odd||rm==1||rm==2?0x3f800001u:0x3f800002u,odd||rm==3?1u:0u,odd||rm==1||rm==2?0x7f7fffffu:0x7f800000u,0x7fc00000,0x80000000,0x40000000,0x7f800000};
   const unsigned exceptions[]={1,1,3,5,16,0,0,0};
   for(unsigned i=0;i<8;++i){a[i]=inputs[i];out[i]=outputs[i];flags[i]=exceptions[i];}
  }
  const unsigned rotation=scenario==7?5:0;
  for(unsigned i=0;i<vl;++i){unsigned k=(i+rotation)%8;host(true,src*rb+i*ab,as,a[k]);put(src*rb+i*ab,ab,a[k]);}
  for(unsigned i=0;i<(vl+7)/8;++i){unsigned m=scenario==6?0:0x55;host(true,i,0,m);put(i,1,m);}
  const auto before=memory;unsigned expected_flags=0;write_csr(0x008,start);
  for(unsigned i=start;i<vl;++i){if(masked&&!((before[i/8]>>(i%8))&1))continue;
   unsigned k=(i+rotation)%8;put(vd*rb+i*db,db,out[k]);expected_flags|=flags[k];}
  auto r=command(integer(0x12,1,vd,src,widen?12:odd?21:20,!masked),0,0,false,0x123456789abcdef0ULL,rm);
  require(!r.trap&&r.fp_dirty&&r.dirty&&r.fflags==expected_flags,"FP format conversion completion");
  compare_memory("FP format conversion op="+std::to_string(op));require(read_csr(0x008)==0,"FP conversion restart");++cases;
 }
 for(unsigned op=0;op<3;++op)for(unsigned mode=0;mode<11;++mode){
  initialize();configure(mode==0?24:mode==1?8:mode==2?19:17,mode==10?0:1);write_csr(0x008,1);
  unsigned vd=mode==3?9:8,src=mode==4?17:mode==5?(op==0?8:4):16;
  // Narrow destination LMUL2 requires two-register alignment, and overlap
  // must begin at the low part of the four-register source group.
  if(mode==5&&op!=0){src=8;vd=10;}
  auto r=command(integer(0x12,mode==6?5:1,vd,src,op==0?12:op==1?20:21,true),0,0,mode==9,0,mode==7||mode==10?6:0,mode!=8);
  if(mode!=9)require(r.trap&&r.cause==2&&!r.fflags&&!r.fp_dirty&&!r.dirty,"FP conversion illegal");
  require(read_csr(0x008)==1,"FP conversion illegal restart");compare_memory("FP conversion illegal");++negative;
 }
 std::printf("PASS vector_fp_convert cases=%llu negative=%llu\n",(unsigned long long)cases,(unsigned long long)negative);
}
