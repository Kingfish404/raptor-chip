#pragma once
static void test_vector_fp_wide(){
 uint64_t cases=0,negative=0;const unsigned rb=TEST_VLEN/8;
 const unsigned funcs[]={0x30,0x32,0x34,0x36,0x38,0x3c,0x3d,0x3e,0x3f};
 if(TEST_ELEN>=64){
  for(int lm=-1;lm<=2;++lm)for(auto fn:funcs)for(unsigned form:{1u,5u})for(unsigned scenario=0;scenario<6;++scenario){
   initialize();const bool wa=fn==0x34||fn==0x36,fused=fn>=0x3c;
   const unsigned vl=configure(16|(lm&7)|((scenario%4)<<6),scenario==0?0:scenario==1?1:scenario==2?7:TEST_VLEN);
   const unsigned vd=8,dg=lm<0?1u:2u<<lm,sg=lm<0?1u:1u<<lm;
   const unsigned src=scenario==3&&!fused&&(wa||lm>=0)?(wa?vd:vd+dg-sg):16;
   const unsigned start=scenario==4?vl/2:scenario==5?vl:0;const bool masked=scenario==4;
   for(unsigned i=0;i<vl;++i){const auto z=fp_bits(2,3);host(true,vd*rb+i*8,3,z);put(vd*rb+i*8,8,z);}
   for(unsigned i=0;i<vl;++i){const auto x=fp_bits(int(i%5)+1,wa?3:2),y=fp_bits(-int(i%3)-1,2);
    host(true,src*rb+i*(wa?8:4),wa?3:2,x);put(src*rb+i*(wa?8:4),wa?8:4,x);
    host(true,24*rb+i*4,2,y);put(24*rb+i*4,4,y);}
   const auto before=memory;
   for(unsigned i=start;i<vl;++i){if(masked&&!((before[i/8]>>(i%8))&1))continue;
    int x=int(i%5)+1,y=form==5?-3:-int(i%3)-1,out=0;
    switch(fn){case 0x30:case 0x34:out=x+y;break;case 0x32:case 0x36:out=x-y;break;
     case 0x38:out=x*y;break;case 0x3c:out=x*y+2;break;case 0x3d:out=-x*y-2;break;case 0x3e:out=x*y-2;break;default:out=-x*y+2;break;}
    put(vd*rb+i*8,8,fp_bits(out,3));}
   write_csr(0x008,start);auto r=command(integer(fn,form,vd,src,24,!masked),0,0,false,0xffffffffc0400000ULL);
   require(!r.trap&&r.fp_dirty&&r.dirty&&!r.fflags,"widening FP completion");compare_memory("FP wide fn="+std::to_string(fn));require(read_csr(0x008)==0,"wide FP restart");++cases;
  }
  // FP64 destination and old addend must survive FP32 source handling. Small
  // FP32 operands combined with an FP64 addend exercise genuine final rounding.
  for(unsigned kind=0;kind<4;++kind)for(unsigned rm=0;rm<5;++rm)for(unsigned scenario=0;scenario<4;++scenario){
   initialize();configure(16,scenario==3?0:1);const uint64_t one=fp_bits(1,3);
   uint32_t a=1,b=0x3f800000;uint64_t old=one,out=rm==3?one+1:one;unsigned flags=1,fn=0x3c;
   if(kind==1){a=0x7f800001;out=0x7ff8000000000000ULL;flags=16;}
   if(kind==2){a=0x7f7fffff;b=0x7f7fffff;fn=0x38;out=0x4fefffffc0000020ULL;flags=0;}
   if(kind==3){a=0x3f800000;b=0;fn=0x30;out=0x7ff8000000000000ULL;flags=0;}
   host(true,16*rb,2,a);put(16*rb,4,a);host(true,24*rb,2,b);put(24*rb,4,b);
   host(true,8*rb,3,old);put(8*rb,8,old);host(true,0,0,scenario==1?0:255);put(0,1,scenario==1?0:255);
   write_csr(0x008,scenario==2?1:0);if(scenario==0)put(8*rb,8,out);
   auto r=command(integer(fn,kind==3?5:1,8,16,24,scenario!=1),0,0,false,0x3f800000,rm);
   require(!r.trap&&r.fflags==(scenario==0?flags:0),"wide FP flags");compare_memory("wide FP flags");++cases;
  }
 }
 // All widening forms remain recognized-but-illegal in ELEN32. In ELEN64,
 // reject unsupported SEW, oversized EMUL, bad alignment and unsafe overlap.
 for(auto fn:funcs)for(unsigned mode=0;mode<9;++mode){
  initialize();configure(mode==0?24:mode==1?8:mode==2?19:17,1);write_csr(0x008,1);
  unsigned vd=mode==3?9:8,src=mode==4?17:mode==5?8:16;
  // For .w forms, identical source/destination EEW allows same-start overlap;
  // use a source group beginning before the destination to force misalignment.
  if(mode==5&&(fn==0x34||fn==0x36))src=6;
  auto r=command(integer(fn,1,vd,src,24,true),0,0,mode==8,0,mode==6?5:0,mode!=7);
  if(mode!=8)require(r.trap&&r.cause==2&&!r.fflags&&!r.fp_dirty&&!r.dirty,"wide FP illegal");
  require(read_csr(0x008)==1,"wide FP illegal restart");compare_memory("wide FP illegal");++negative;
 }
 std::printf("PASS vector_fp_wide cases=%llu negative=%llu\n",(unsigned long long)cases,(unsigned long long)negative);
}
