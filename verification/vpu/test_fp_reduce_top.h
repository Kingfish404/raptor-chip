#pragma once
static void test_vector_fp_reduce(){
 const unsigned rb=TEST_VLEN/8,fn[]={1,3,5,7,0x31,0x33};
 uint64_t cases=0,negative=0;
 for(unsigned kind=0;kind<6;++kind)for(unsigned sew=2;sew<=(TEST_ELEN==64?3u:2u);++sew)
 for(int lm=-1;lm<=3;++lm)for(unsigned scenario=0;scenario<10;++scenario){
  bool wide=kind>=4;if(wide&&(sew!=2||TEST_ELEN<64))continue;
  if(lm<0&&(8u<<sew)>TEST_ELEN/2)continue;
  initialize();unsigned outsew=sew+unsigned(wide),bytes=1u<<sew;
  unsigned vl=configure((sew<<3)|(lm&7)|((scenario%4)<<6),scenario==0?0:scenario==1?1:TEST_VLEN);
  unsigned dest=scenario==5?16:scenario==6?3:scenario==7?0:9;
  bool masked=scenario==3||scenario==4||scenario==7;
  for(unsigned i=0;i<vl;++i){auto v=fp_bits(1+i%3,sew);host(true,16*rb+i*bytes,sew,v);put(16*rb+i*bytes,bytes,v);}
  for(unsigned i=0;i<(vl+7)/8;++i){unsigned m=scenario==4?0:0x55;host(true,i,0,m);put(i,1,m);}
  const uint64_t snan=outsew==2?0x7f800001ULL:0x7ff0000000000001ULL;
  bool nanseed=scenario==4||scenario==9;uint64_t seed=nanseed?snan:fp_bits(7,outsew);
  host(true,3*rb,outsew,seed);put(3*rb,1u<<outsew,seed);
  int accumulator=7;unsigned active=0;
  for(unsigned i=0;i<vl;++i)if(!masked||((memory[i/8]>>(i%8))&1)){
   int value=1+i%3;
   if(kind==2)accumulator=nanseed&&active==0?value:std::min(accumulator,value);
   else if(kind==3)accumulator=nanseed&&active==0?value:std::max(accumulator,value);
   else accumulator+=value;
   ++active;
  }
  uint64_t expected=seed;
  if(active)expected=nanseed&&kind!=2&&kind!=3?(outsew==2?0x7fc00000ULL:0x7ff8000000000000ULL):fp_bits(accumulator,outsew);
  if(vl)put(dest*rb,1u<<outsew,expected);
  auto r=command(integer(fn[kind],1,dest,16,3,!masked),0,0,false,0,scenario%5);
  require(!r.trap&&r.fp_dirty&&r.dirty&&!r.fp_write&&!r.rd&&r.fflags==(nanseed&&active?16u:0u),"FP reduction completion");
  compare_memory("FP reduction");require(read_csr(0x008)==0,"FP reduction restart");++cases;
 }
 for(unsigned kind=0;kind<6;++kind)for(unsigned mode=0;mode<10;++mode){
  initialize();configure(mode==0?8:mode==1?17:16,mode==2?0:2);
  unsigned src=mode==1?17:16,start=mode==3?1:0;write_csr(0x008,start);
  unsigned rm=mode==2?5:mode==4?6:mode==5?7:0;
  bool enabled=mode!=6;unsigned form=mode==7?5:1;
  if(mode==8)configure(1u<<8,2);
  uint32_t insn=integer(fn[kind],form,9,src,3,true);
  if(mode==9)insn=(insn&~127u)|0x5b;
  auto r=command(insn,0,0,false,0,rm,enabled);
  require(r.trap&&r.cause==2&&!r.fflags&&!r.fp_dirty&&!r.dirty,"FP reduction illegal");
  compare_memory("FP reduction illegal");require(read_csr(0x008)==start,"FP reduction illegal restart");++negative;
 }
 for(unsigned k=0;k<6;++k){initialize();configure(16,2);command(integer(fn[k],1,0,16,3,false),0,0,true);compare_memory("FP reduction cancelled");}
 std::printf("PASS vector_fp_reduce cases=%llu negative=%llu cancelled=6\n",(unsigned long long)cases,(unsigned long long)negative);
}
