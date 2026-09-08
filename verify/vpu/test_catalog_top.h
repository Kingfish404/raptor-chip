#pragma once
#include "catalog_entries.h"
static void test_vector_catalog(){
#ifndef VPU_SPIKE
 throw std::runtime_error("instruction catalog requires DIFF=1");
#else
 uint64_t cases=0,accepted=0,rejected=0,variants=0,missing=0;
 for(const auto& entry:vector_catalog){
  for(unsigned nf=0;nf<(entry.segment?8u:1u);++nf){
   unsigned positive=0,negative=0;
   for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew)
   for(unsigned mask=0;mask<(entry.mask?2u:1u);++mask){
    memory_fixture();configure(sew<<3,2);
    uint32_t insn=entry.insn|(nf<<29);
    if(mask)insn&=~(1u<<25);
    const bool mem=(insn&0x7f)==7||(insn&0x7f)==0x27;
    if(mem&&((insn>>26)&1)){
     // Zero indices keep all valid index widths and segment fields in RAM.
     // The catalog fixes vs2=v16; initialize enough space for EMUL=8.
     for(unsigned addr=16*(TEST_VLEN/8);addr<24*(TEST_VLEN/8);addr+=8){
      host(true,addr,3,0);put(addr,8,0);
     }
    }
    const auto r=command(insn,mem?data_base:2,mem?16:0,false,
                         sew==3?0x3ff0000000000000ULL:0xffffffff3f800000ULL,0);
    if(r.trap){
     require(r.cause==2&&!r.dirty,"catalog unexpected trap/dirty: "+std::string(entry.name));
     compare_memory("catalog illegal VRF: "+std::string(entry.name));
     ++negative;++rejected;
    }else{++positive;++accepted;}
    require(data_ram==spike->data_memory,"catalog RAM: "+std::string(entry.name));
    for(unsigned addr=0;addr<memory.size();addr+=8)
     require(host(false,addr,3,0)==spike->host_read(addr),
       "catalog VRF: "+std::string(entry.name)+" nf="+std::to_string(nf)+
       " sew="+std::to_string(sew)+" byte="+std::to_string(addr));
    for(unsigned csr:{8u,15u,0xc20u,0xc21u})read_csr(csr);
    ++cases;
   }
   std::printf("CATALOG name=%s nf=%u accepted=%u illegal=%u\n",entry.name,nf,positive,negative);
   ++variants;if(!positive)++missing;
  }
 }
 // The RV64/ELEN64 baseline must execute every catalog variant somewhere
 // in the supported SEW sweep. Narrower configurations report projections.
 require(TEST_XLEN!=64||TEST_ELEN!=64||missing==0,"baseline catalog has unexecuted variants");
 std::printf("PASS vector_catalog entries=375 variants=%llu cases=%llu accepted=%llu illegal=%llu unexecuted=%llu\n",
  (unsigned long long)variants,(unsigned long long)cases,(unsigned long long)accepted,
  (unsigned long long)rejected,(unsigned long long)missing);
#endif
}
