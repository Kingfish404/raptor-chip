#pragma once
static void test_vector_memory_encoding(){
#ifndef VPU_SPIKE
 throw std::runtime_error("memory encoding audit requires DIFF=1");
#else
 uint64_t cases=0,accepted=0,illegal=0,faults=0;
 // Only vector memory width encodings: the other widths overlap scalar FP
 // memory instructions, which are outside the standalone VPU interface.
 for(bool store:{false,true})for(unsigned width:{0u,5u,6u,7u})
 for(unsigned mew=0;mew<2;++mew)for(unsigned nf=0;nf<8;++nf)
 for(unsigned mop=0;mop<4;++mop)for(unsigned aux=0;aux<32;++aux)
 for(unsigned vm=0;vm<2;++vm){
  memory_fixture();configure(0,2);
  if(mop&1){
   unsigned bytes=width==0?1:1u<<(width-4);
   // Deterministic in-range index values, including overlapping index/data
   // register groups. Snapshot all operands before executing the instruction.
   for(unsigned i=0;i<2;++i)put(aux*(TEST_VLEN/8)+i*bytes,bytes,16*i);
   for(unsigned addr=0;addr<memory.size();addr+=8)host(true,addr,3,get(addr,8));
  }
  uint32_t insn=(nf<<29)|(mew<<28)|(mop<<26)|(vm<<25)|(aux<<20)
      |(2<<15)|(width<<12)|(8<<7)|(store?0x27:7);
  // A strided instruction naming x2 for both inputs must receive equal
  // scalar values. This deliberately also exercises a later-element fault.
  auto r=command(insn,data_base,aux==0?0:aux==2?data_base:16);
  if(r.trap&&r.cause==2){
   require(bus_log.empty(),"illegal memory encoding issued a request");
   require(!r.dirty,"illegal memory encoding changed vector state");
   require(data_ram==data_expected,"illegal memory encoding changed RAM");
   compare_memory("illegal memory encoding changed VRF");
   ++illegal;
  }else if(r.trap)++faults;else ++accepted;
  require(data_ram==spike->data_memory,"memory encoding RAM mismatch insn="+std::to_string(insn));
  for(unsigned addr=0;addr<memory.size();addr+=8)
   require(host(false,addr,3,0)==spike->host_read(addr),
       "memory encoding VRF mismatch insn="+std::to_string(insn)+" byte="+std::to_string(addr));
  for(unsigned addr:{8u,0xc20u,0xc21u})read_csr(addr);
  ++cases;
 }
 std::printf("PASS vector_memory_encoding cases=%llu accepted=%llu illegal=%llu faults=%llu\n",
  (unsigned long long)cases,(unsigned long long)accepted,(unsigned long long)illegal,(unsigned long long)faults);
#endif
}

// Configuration encodings have a separate bounded sweep so the arithmetic
// encoding audit need not be rerun to inspect configuration state transitions.
static void test_vector_config_encoding(){
#ifndef VPU_SPIKE
 throw std::runtime_error("configuration audit requires DIFF=1");
#else
 uint64_t cases=0,accepted=0,rejected=0;
 initialize();
 auto check=[&](uint32_t insn,uint64_t a,uint64_t b,bool enabled){
  configure(0,3);write_csr(8,7);write_csr(9,1);write_csr(10,2);
  dut.vector_enabled=enabled;
  auto r=command(insn,a,b);
  dut.vector_enabled=1;
  require(r.trap||r.rd==((insn>>7)&31),"configuration destination identity");
  require(r.dirty==!r.trap,"configuration dirty event");
  // Every read is independently compared with Spike by command().
  for(unsigned addr:{8u,9u,10u,15u,0xc20u,0xc21u,0xc22u})read_csr(addr);
  compare_memory("configuration must preserve VRF");
  if(r.trap)++rejected;else ++accepted;
  ++cases;
 };
 // All upper 12-bit encodings: immediate forms, register selectors and
 // reserved funct7 values. Equal register identities get equal values;
 // x0 always supplies zero, respecting the scalar adapter contract.
 for(unsigned upper=0;upper<4096;++upper)
 for(unsigned src:{0u,2u,31u}){
  unsigned rs2=upper&31;
  uint64_t b=rs2?0x18:0,a=src?(src==rs2?b:5):0;
  check((upper<<20)|(src<<15)|0x70d7,a,b,true);
 }
 // Register VTYPE tests exercise every low-byte combination, unsupported
 // upper bits, AVL boundaries and rd=x0 without reserved keep-VL changes.
 for(unsigned type=0;type<256;++type)
 for(uint64_t avl:{uint64_t(0),uint64_t(1),uint64_t(17),xmask()})
 for(unsigned rd:{0u,1u})
  check(0x80317057|(rd<<7),avl,type,true);
 for(unsigned bit=8;bit<TEST_XLEN;++bit)
  check(0x803170d7,5,uint64_t(1)<<bit,true);
 // Legal keep-VL (same VLMAX), maximum AVL and VS-off gating.
 for(unsigned policy=0;policy<4;++policy){
  check(0x80307057,0,policy<<6,true);
  check(0x803070d7,0,policy<<6,true);
 }
 for(uint32_t insn:{0x000170d7u,0xc00170d7u,0x803170d7u,0x900170d7u})
  check(insn,5,0,false);
 std::printf("PASS vector_config_encoding cases=%llu accepted=%llu rejected=%llu\n",
  (unsigned long long)cases,(unsigned long long)accepted,(unsigned long long)rejected);
#endif
}

// Admission audit through the real instruction top and independent ISA model.
// command() compares trap/cause/tval, scalar destinations and FP flags;
// this sweep additionally compares the entire VRF with Spike after execution.
// VTYPE requests undisturbed tail/mask policies. The focused instruction
// suites retain their independent explicit numerical and byte-array oracles.
static void test_vector_encoding(){
#ifndef VPU_SPIKE
 throw std::runtime_error("encoding audit requires DIFF=1");
#else
 uint64_t cases=0,accepted=0,rejected=0;
 for(unsigned sew=0;sew<=(TEST_ELEN==64?3u:2u);++sew)
 for(unsigned source:{0u,16u})
 for(unsigned fn=0;fn<64;++fn)for(unsigned form=0;form<7;++form)
 for(unsigned vm=0;vm<2;++vm)for(unsigned selector=0;selector<32;++selector){
  initialize();configure(sew<<3,2);
  // Naturally aligned groups and a distinct destination isolate encoding
  // legality; selector doubles as vector source, scalar source or subopcode.
  uint32_t insn=integer(fn,form,8,source,selector,vm);
  auto r=command(insn,0,0,false,0xffffffff3f800000ULL,0);
  for(unsigned addr=0;addr<memory.size();addr+=8){
   uint64_t actual=host(false,addr,3,0),expected=spike->host_read(addr);
   require(actual==expected,"encoding VRF mismatch insn="+std::to_string(insn)+
       " sew="+std::to_string(8u<<sew)+" byte="+std::to_string(addr)+
       " dut="+std::to_string(actual)+" reference="+std::to_string(expected));
  }
  if(r.trap)++rejected;else ++accepted;
  ++cases;
 }
 std::printf("PASS vector_encoding cases=%llu accepted=%llu rejected=%llu\n",
  (unsigned long long)cases,(unsigned long long)accepted,(unsigned long long)rejected);
#endif
}
