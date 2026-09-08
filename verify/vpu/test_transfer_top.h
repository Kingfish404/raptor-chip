#pragma once
static void test_vector_transfer(){
 const unsigned rb=TEST_VLEN/8;uint64_t cases=0,negative=0;
 const unsigned funct[]={0x17,0x17,0x10,0x10,0x0e,0x0f};
 for(unsigned op=0;op<6;++op)for(unsigned sew=2;sew<=(TEST_ELEN==64?3u:2u);++sew)
 for(int lm=-1;lm<=3;++lm)for(unsigned scenario=0;scenario<10;++scenario){
  if(lm<0&&(8u<<sew)>TEST_ELEN/2)continue;
  initialize();const bool scalar=op==2||op==3;const unsigned width=1u<<sew;
  const unsigned vl=configure(sew*8|(lm&7)|((scenario%4)<<6),scenario==0?0:scenario==1?1:TEST_VLEN);
  const unsigned start=scenario==2?1:scenario==3?vl:scenario==4?vl+1:0;
  const bool masked=op==0||((op==4||op==5)&&(scenario==5||scenario==6));
  const unsigned vd=op==2?(scenario%2?0:31):scalar?9:8;
  const unsigned src=op==1||op==3?0:scalar?17:scenario==7&&op!=4?8:16;
  const uint64_t values[]={0,0x8000000000000000ULL,0x7ff0000000000001ULL,0xfff8123456789abcULL,0x0123456789abcdefULL,0xfedcba9876543210ULL};
  uint64_t frs1=values[scenario%6];if(sew==2)frs1=(scenario%3?0xffffffff00000000ULL:0x1234567800000000ULL)|uint32_t(frs1^0x7f800001);
  const uint64_t scalar_value=sew==2?((frs1>>32)==UINT32_MAX?uint32_t(frs1):0x7fc00000):frs1;
  for(unsigned i=0;i<(scalar?1:vl);++i){uint64_t v=values[(i+scenario)%6]^uint64_t(i*0x9183);host(true,src*rb+i*width,sew,v);put(src*rb+i*width,width,v);}
  for(unsigned i=0;i<(vl+7)/8;++i){unsigned m=scenario==6?0:0x55;host(true,i,0,m);put(i,1,m);}
  const auto before=memory;auto saved=[&](unsigned addr,unsigned bytes){uint64_t v=0;for(unsigned b=0;b<bytes;++b)v|=uint64_t(before[addr+b])<<(b*8);return v;};write_csr(0x008,start);uint64_t expected_fp=0;
  if(op==2){expected_fp=saved(src*rb,width);if(sew==2)expected_fp|=0xffffffff00000000ULL;}
  else if(op==3){if(start<vl)put(vd*rb,width,scalar_value);}
  else for(unsigned i=start;i<vl;++i){bool bit=(before[i/8]>>(i%8))&1;if(op>=4&&masked&&!bit)continue;
   uint64_t v=scalar_value;
   if(op==0&&!bit)v=saved(src*rb+i*width,width);
   if(op==4&&i>0)v=saved(src*rb+(i-1)*width,width);
   if(op==5&&i+1<vl)v=saved(src*rb+(i+1)*width,width);
   put(vd*rb+i*width,width,v);
  }
  auto r=command(integer(funct[op],op==2?1:5,vd,src,op==2?0:7,!masked),0,0,false,frs1,scenario%5);
  require(!r.trap&&!r.fflags&&r.fp_dirty&&r.dirty,"FP transfer completion op="+std::to_string(op));
  require(r.fp_write==(op==2)&&(!r.fp_write||(r.rd==vd&&r.fp_value==expected_fp&&r.value==0)),"FP transfer scalar destination");
  compare_memory("FP transfer");require(read_csr(0x008)==0,"FP transfer restart");++cases;
 }
 for(unsigned op=0;op<6;++op)for(unsigned mode=0;mode<8;++mode){
  initialize();configure(mode==0?8:16,mode==1?0:1);write_csr(0x008,1);
  bool vm=op!=0;unsigned src=op==1||op==3?0:16,rs=op==2?0:7,form=op==2?1:5;
  if(mode==4){if(op==0)form=1;else if(op==1||op==3)src=1;else if(op==2)rs=1;else form=1;}
  if(mode==5){if(op==2||op==3)vm=false;else form=7;}
  uint32_t insn=integer(funct[op],form,8,src,rs,vm);if(mode==5&&op!=2&&op!=3)insn=(insn&~127u)|0x5b;
  auto r=command(insn,0,0,mode==7,0,mode==1||mode==2?6:0,mode!=3&&mode!=6);
  if(mode!=7)require(r.trap&&r.cause==2&&!r.fflags&&!r.fp_write&&!r.fp_dirty&&!r.dirty,"FP transfer illegal");
  compare_memory("FP transfer illegal");require(read_csr(0x008)==1,"FP transfer illegal restart");++negative;
 }
 // Vector geometry is checked even at zero VL; scalar moves deliberately
 // ignore group alignment and are covered with odd register numbers above.
 for(unsigned op:{0u,1u,4u,5u})for(unsigned empty=0;empty<2;++empty){
  initialize();configure(17,empty?0:1);
  auto r=command(integer(funct[op],5,9,op==1?0:16,7,op!=0),0,0,false,0xffffffff3f800000ULL);
  require(r.trap&&r.cause==2&&!r.fp_write&&!r.fflags,"FP transfer destination geometry");compare_memory("FP transfer geometry");++negative;
 }
 for(unsigned empty=0;empty<2;++empty){initialize();configure(16,empty?0:1);
  auto r=command(integer(0x0e,5,8,8,7,true),0,0,false,0xffffffff3f800000ULL);
  require(r.trap&&r.cause==2&&!r.fp_write&&!r.fflags,"FP slide up overlap");compare_memory("FP slide up overlap");++negative;
 }
 std::printf("PASS vector_transfer cases=%llu negative=%llu\n",(unsigned long long)cases,(unsigned long long)negative);
}
