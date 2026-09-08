#pragma once
static void test_vector_fp_misc(){
 const unsigned rb=TEST_VLEN/8;uint64_t cases=0,negative=0;
 const unsigned functs[]={4,6,8,9,10,0x13,0x18,0x1c,0x1b,0x19,0x1d,0x1f};
 // Ten categorical operands make an oracle independent of RTL comparisons:
 // -inf,-2,-subnormal,-0,+0,+subnormal,+2,+inf,sNaN,qNaN.
 const int rank[]={-4,-2,-1,0,0,1,2,4,0,0};
 for(unsigned sew=2;(8u<<sew)<=TEST_ELEN;++sew)for(unsigned op=0;op<12;++op)
 for(unsigned form:{1u,5u})for(unsigned lm:{0u,2u})for(unsigned scenario=0;scenario<9;++scenario)
 for(unsigned rotation=0;rotation<3;++rotation){
  if((op==5&&form!=1)||(op>=10&&form!=5))continue;
  initialize();const unsigned bytes=1u<<sew;
  const unsigned vl=configure((sew<<3)|lm|((scenario%4)<<6),scenario==4?0:TEST_VLEN);
  const bool pred=op>=6,masked=scenario==1||scenario==6||scenario==8;
  const unsigned vd=scenario==7?16:scenario==8&&pred?0:8,start=scenario==2?vl/2:scenario==5?vl:0;
  const uint64_t sign=sew==2?0x80000000ULL:0x8000000000000000ULL;
  const uint64_t inf=sew==2?0x7f800000ULL:0x7ff0000000000000ULL;
  const uint64_t qnan=sew==2?0x7fc00000ULL:0x7ff8000000000000ULL;
  const uint64_t two=fp_bits(2,sew);
  const uint64_t values[]={sign|inf,sign|two,sign|1,sign,0,1,two,inf,inf|1,qnan};
  const unsigned classes[]={1,2,4,8,16,32,64,128,256,512};
  for(unsigned i=0;i<vl;++i){unsigned a=(i+rotation*3)%10,b=(i*3+rotation+1)%10;
   host(true,16*rb+i*bytes,sew,values[a]);put(16*rb+i*bytes,bytes,values[a]);
   host(true,24*rb+i*bytes,sew,values[b]);put(24*rb+i*bytes,bytes,values[b]);}
  for(unsigned i=0;i<(vl+7)/8;++i){unsigned m=scenario==6?0:0xa5;host(true,i,0,m);put(i,1,m);}
  write_csr(0x008,start);const auto before=memory;unsigned expected_flags=0;
  const unsigned scalar_kind=scenario==3?9:(scenario+rotation*3)%10;
  const uint64_t scalar=scenario==3&&sew==2?uint64_t(0x40000000):values[scalar_kind]|(sew==2?0xffffffff00000000ULL:0);
  for(unsigned i=start;i<vl;++i){
   if(masked&&!((before[i/8]>>(i%8))&1))continue;
   const unsigned a=(i+rotation*3)%10,b=form==5?scalar_kind:(i*3+rotation+1)%10;
   const bool na=a>=8,nb=b>=8;uint64_t out=0;
   if(op<=1){
    if(a==8||b==8)expected_flags|=16;
    if(na&&nb)out=qnan;else if(na)out=values[b];else if(nb)out=values[a];
    else if((a==3||a==4)&&(b==3||b==4))out=op==0?(a==3||b==3?sign:0):(a==3&&b==3?sign:0);
    else out=values[op==0?(rank[a]<rank[b]?a:b):(rank[a]>rank[b]?a:b)];
   }else if(op<=4){
    const bool sa=a<=3,sb=b<=3;
    out=(values[a]&~sign)|((op==2?sb:op==3?!sb:sa!=sb)?sign:0);
   }else if(op==5)out=classes[a];
   else {
    if((op<=7?(a==8||b==8):(na||nb)))expected_flags|=16;
    if(na||nb)out=op==7;
    else switch(op){case 6:out=rank[a]==rank[b];break;case 7:out=rank[a]!=rank[b];break;
     case 8:out=rank[a]<rank[b];break;case 9:out=rank[a]<=rank[b];break;
     case 10:out=rank[a]>rank[b];break;default:out=rank[a]>=rank[b];break;}
   }
   if(pred){const unsigned addr=vd*rb+i/8;memory[addr]=(memory[addr]&~(1u<<(i%8)))|(out<<(i%8));}
   else put(vd*rb+i*bytes,bytes,out);
  }
  auto r=command(integer(functs[op],form,vd,16,op==5?16:24,!masked),0,0,false,scalar,scenario%5);
  require(!r.trap&&r.fp_dirty&&r.dirty&&r.fflags==expected_flags,"FP misc completion");
  compare_memory("FP misc op="+std::to_string(op));require(read_csr(0x008)==0,"FP misc restart");++cases;
 }
 for(unsigned mode=0;mode<10;++mode){
  initialize();configure(18,4);write_csr(0x008,1);
  unsigned fn=mode==0?0x13:mode==1?0x1d:mode==2?0x1f:0x18,form=1,vd=8,vs2=16,vs1=24;
  if(mode==0)vs1=17;if(mode==3)vs2=17;if(mode==4)vd=17;
  auto r=command(integer(fn,form,vd,vs2,vs1,true),0,0,mode==9,0,mode>=5&&mode<=7?mode:0,mode!=8);
  if(mode!=9)require(r.trap&&r.cause==2&&!r.fflags&&!r.fp_dirty&&!r.dirty,"FP misc illegal");
  require(read_csr(0x008)==1,"FP misc illegal restart");compare_memory("FP misc illegal");++negative;
 }
 std::printf("PASS vector_fp_misc cases=%llu negative=%llu\n",(unsigned long long)cases,(unsigned long long)negative);
}
