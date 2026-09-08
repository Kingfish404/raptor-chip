#pragma once
// Public-interface differential admission and byte effects. The oracle is
// Spike instruction execution, not a second copy of the RTL geometry formula.
static void test_vector_geometry(){
#ifndef VPU_SPIKE
 throw std::runtime_error("geometry audit requires DIFF=1");
#else
 struct Operation { unsigned fn,form; bool unary,compress; };
 const Operation ops[]={{0,0,0,0},{0x18,0,0,0},{0x30,2,0,0},
   {0x34,2,0,0},{0x2c,0,0,0},{0x0e,0,0,0},{0x0e,4,0,0},
   {0x17,2,0,1},{0x12,2,1,0}};
 const unsigned regs[]={0,1,2,3,4,7,8,15,16,23,24,28,30,31};
 uint64_t cases=0,accepted=0,rejected=0;
 for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew)
 for(int lm=-3;lm<=3;++lm){
  if(lm<0&&(8u<<sew)>(TEST_ELEN>>-lm))continue;
  for(const auto& op:ops)for(unsigned axis=0;axis<2;++axis){
   if(axis&&(op.unary||op.form==4))continue;
   for(unsigned vd:regs)for(unsigned src:regs)for(unsigned vm=0;vm<2;++vm){
    initialize();configure((sew<<3)|(lm&7),2);
    // Vary each source against vd independently, including v0 and every
    // relevant power-of-two group edge. Other source remains aligned at v16.
    const unsigned vs2=axis?16:src;
    const unsigned vs1=op.unary?6:op.form==4?3:axis?src:16;
    const unsigned start=op.compress?0:cases%2;
    write_csr(8,start);
    const uint32_t insn=integer(op.fn,op.form,vd,vs2,vs1,vm);
    const auto r=command(insn,1);
    if(r.trap){
     require(r.cause==2&&!r.dirty,"geometry trap cause/side effect");
     require(read_csr(8)==start,"illegal geometry changed vstart");
     compare_memory("illegal geometry changed VRF");
     ++rejected;
    }else ++accepted;
    for(unsigned addr=0;addr<memory.size();addr+=8)
     require(host(false,addr,3,0)==spike->host_read(addr),
       "geometry VRF mismatch insn="+std::to_string(insn)+
       " sew="+std::to_string(sew)+" lm="+std::to_string(lm)+
       " byte="+std::to_string(addr));
    ++cases;
   }
  }
 }
 require(accepted&&rejected,"empty geometry coverage");
 std::printf("PASS vector_geometry cases=%llu accepted=%llu rejected=%llu\n",
   (unsigned long long)cases,(unsigned long long)accepted,(unsigned long long)rejected);
#endif
}
