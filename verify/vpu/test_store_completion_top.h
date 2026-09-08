#pragma once
static void test_vector_store_completion(){
 unsigned cases=0;
 const uint64_t wait_begin=store_wait_cycles;
 for(unsigned delay:{0u,1u,7u,31u,127u})
 for(unsigned fields:{1u,2u,8u})
 for(unsigned fault_index=0;fault_index<4;++fault_index)
 for(unsigned fault_field=0;fault_field<fields;++fault_field){
  memory_fixture();configure(0,4);
  store_response_delay=int(delay);
  const uint64_t fault_addr=data_base+fault_index*fields+fault_field;
  // Every segment probe succeeds. The later actual access fails without an
  // effect; preceding idempotent fields/elements may already be visible.
  set_memory_fault(fault_addr,true,fields==1,false);
  for(unsigned i=0;i<=fault_index;++i)
   for(unsigned f=0;f<fields;++f){
    if(i==fault_index&&f>=fault_field)break;
    transfer_expected(true,(8+f)*(TEST_VLEN/8)+i,data_base+i*fields+f,1);
   }
  auto r=command(mem_insn(true,0,fields),data_base);
  require(r.trap&&r.cause==7&&r.tval==fault_addr,"late store fault metadata");
  unsigned writes=0;
  for(const auto& req:bus_log)if(!req.probe){
   require(req.write&&req.addr==data_base+writes,"store ordered prefix");++writes;
  }
  require(writes==fault_index*fields+fault_field+1,"store stopped at failing access");
  require(read_csr(8)==fault_index&&read_csr(0xc20)==4,"store restart position");
  compare_data("late store fault prefix");
  set_memory_fault(UINT64_MAX);
  for(unsigned i=fault_index;i<4;++i)
   for(unsigned f=0;f<fields;++f)
    transfer_expected(true,(8+f)*(TEST_VLEN/8)+i,data_base+i*fields+f,1);
  auto resumed=command(mem_insn(true,0,fields),data_base);
  require(!resumed.trap,"store restart completion");
  for(const auto& req:bus_log)
   require(req.index>=fault_index,"store replayed completed element");
  require(read_csr(8)==0,"store restart clears vstart");
  compare_data("late store restart");
  ++cases;
 }
 // A single instruction has more elements than the current default SQ's
 // capacity. The service returns final acknowledgements as it progresses;
 // this validates the VPU side, not the real SQ's allocation/drain policy.
 for(unsigned delay:{0u,127u}){
  memory_fixture();const unsigned count=unsigned(configure(3,TEST_VLEN));
  require(count>16,"long store did not exceed default SQ capacity");
  store_response_delay=int(delay);
  set_memory_fault(data_base+count-1,true,true,false);
  for(unsigned i=0;i<count-1;++i)
   transfer_expected(true,8*(TEST_VLEN/8)+i,data_base+i,1);
  auto failed=command(mem_insn(true,0),data_base);
  require(failed.trap&&failed.cause==7&&failed.tval==data_base+count-1,
      "long store final error");
  require(bus_log.size()==count,"long store request count");
  require(read_csr(8)==count-1,"long store restart index");
  compare_data("long store prefix");
  set_memory_fault(UINT64_MAX,false,true,false);
  transfer_expected(true,8*(TEST_VLEN/8)+count-1,data_base+count-1,1);
  auto resumed=command(mem_insn(true,0),data_base);
  require(!resumed.trap&&bus_log.size()==1&&bus_log[0].addr==data_base+count-1,
      "long non-idempotent store repeated its prefix");
  require(read_csr(8)==0,"long store clears vstart");
  compare_data("long store resumed");
  ++cases;
 }
 store_response_delay=-1;
 require(store_wait_cycles>wait_begin,"store final-response waiting not exercised");
 std::printf("PASS vector_store_completion cases=%u wait_cycles=%llu\n",cases,
     (unsigned long long)(store_wait_cycles-wait_begin));
}
