#pragma once
static void test_vector_estimate(){
 const unsigned rb=TEST_VLEN/8;uint64_t cases=0,negative=0;
 for(unsigned sew=2;sew<=(TEST_ELEN==64?3u:2u);++sew)for(unsigned op=0;op<2;++op)
 for(unsigned rm=0;rm<5;++rm)for(unsigned scenario=0;scenario<8;++scenario)for(int lm:{-1,0,2}){
  if(lm<0&&(8u<<sew)>TEST_ELEN/2)continue;
  initialize();const unsigned vl=configure(sew*8|(lm&7)|((scenario%4)<<6),scenario==0?0:scenario==1?1:TEST_VLEN);
  const unsigned f=sew==2?23:52,e=sew==2?8:11,bias=(1u<<(e-1))-1,maxexp=(1u<<e)-1;
  const uint64_t sign=1ULL<<(f+e),inf=uint64_t(maxexp)<<f,nan=inf|(1ULL<<(f-1)),maximum=inf-1;
  const uint64_t a[]={0,sign,inf,sign|inf,nan|1,inf|1,uint64_t(bias)<<f,sign|(uint64_t(bias)<<f),uint64_t(bias+2)<<f,sign|(uint64_t(bias+2)<<f),1,sign|1,maximum,sign|maximum,1ULL<<f,sign|(1ULL<<f)};
  uint64_t out[16];unsigned flags[16];
  for(unsigned k=0;k<16;++k){const bool neg=(a[k]&sign)!=0;flags[k]=0;
   if(k<2){out[k]=a[k]|inf;flags[k]=8;}
   else if(k==4||k==5){out[k]=nan;flags[k]=k==5?16:0;}
   else if(op&&neg){out[k]=nan;flags[k]=16;}
   else if(k==2||k==3)out[k]=a[k]&sign;
   else if((k==10||k==11)&&!op){out[k]=(a[k]&sign)|((rm==1||(rm==2&&!neg)||(rm==3&&neg))?maximum:inf);flags[k]=5;}
   else{
    uint64_t value;
    if(k==6||k==7)value=(uint64_t(bias-1)<<f)|(127ULL<<(f-7));
    else if(k==8||k==9)value=(uint64_t(bias-(op?2:3))<<f)|(127ULL<<(f-7));
    else if(k==10||k==11)value=(uint64_t((3*bias+f-2)/2)<<f)|((f==23?52ULL:127ULL)<<(f-7));
    else if(k==12||k==13)value=op?uint64_t((3*bias-maxexp)/2)<<f:1ULL<<(f-2);
    else value=(uint64_t(op?(3*bias-2)/2:2*bias-2)<<f)|(127ULL<<(f-7));
    out[k]=value|(a[k]&sign);
   }
  }
  const unsigned vd=8,src=scenario==3?vd:16,start=scenario==4?vl/2:scenario==5?vl:0;
  const bool masked=scenario==4||scenario==6;const unsigned rotation=scenario==7?10:0;
  for(unsigned i=0;i<vl;++i){unsigned k=(i+rotation)%16;host(true,src*rb+(i<<sew),sew,a[k]);put(src*rb+(i<<sew),1u<<sew,a[k]);}
  for(unsigned i=0;i<(vl+7)/8;++i){unsigned m=scenario==6?0:0x55;host(true,i,0,m);put(i,1,m);}
  const auto before=memory;unsigned expected=0;write_csr(0x008,start);
  for(unsigned i=start;i<vl;++i){if(masked&&!((before[i/8]>>(i%8))&1))continue;unsigned k=(i+rotation)%16;put(vd*rb+(i<<sew),1u<<sew,out[k]);expected|=flags[k];}
  auto r=command(integer(0x13,1,vd,src,op?4:5,!masked),0,0,false,0x0123456789abcdefULL,rm);
  require(!r.trap&&r.fflags==expected&&r.fp_dirty&&r.dirty,"FP estimate completion");compare_memory("FP estimate");require(read_csr(0x008)==0,"FP estimate restart");++cases;
 }
 for(unsigned op=0;op<2;++op)for(unsigned mode=0;mode<9;++mode){
  initialize();configure(mode==0?8:mode==5?17:16,mode==8?0:1);write_csr(0x008,1);
  auto r=command(integer(0x13,mode==3?5:1,mode==5?9:mode==6?0:8,16,mode==4?6:op?4:5,mode!=6),0,0,mode==7,0,mode==1||mode==8?6:0,mode!=2);
  if(mode!=7)require(r.trap&&r.cause==2&&!r.fflags&&!r.fp_dirty&&!r.dirty,"FP estimate illegal");
  require(read_csr(0x008)==1,"FP estimate illegal restart");compare_memory("FP estimate illegal");++negative;
 }
 std::printf("PASS vector_estimate cases=%llu negative=%llu\n",(unsigned long long)cases,(unsigned long long)negative);
}
