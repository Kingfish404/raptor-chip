#pragma once
// Supervisor-style save/restore using only encoded vector/CSR instructions.
// Host writes below emulate another context modifying VRF while this one is
// descheduled; the restore itself may not use the host port.
static void test_vector_context(){
 unsigned cases=0;
 for(unsigned type:{0u,1u,0xc0u,0x10u,0x18u,0xd7u,0x100u,0x200u})
 for(unsigned avl:{0u,1u,3u,31u}){
  memory_fixture();configure(type,avl);
  write_csr(15,cases&7);write_csr(8,cases%(TEST_VLEN/8));
  if(type==0x200){
   configure(0,4);write_csr(8,0);
   set_memory_fault(data_base+2,false,false,bool(avl&1));
   transfer_expected(false,8*(TEST_VLEN/8),data_base,1);
   transfer_expected(false,8*(TEST_VLEN/8)+1,data_base+1,1);
   auto fault=command(mem_insn(false,0),data_base);
   require(fault.trap&&fault.cause==((avl&1)?13u:5u)
       &&read_csr(8)==2,"context fault prefix");
   compare_data("context before save fault prefix");
   set_memory_fault(UINT64_MAX);
  }
  const uint64_t saved_type=read_csr(0xc21),saved_vl=read_csr(0xc20);
  const uint64_t saved_start=read_csr(8),saved_control=read_csr(15);
  const auto saved_vrf=memory;
  // vstart must be saved and cleared before whole-register transfers, which
  // honor restart state even when the current VTYPE is vill or VL is zero.
  write_csr(8,0);
  for(unsigned reg=0;reg<32;reg+=8){
   const uint64_t address=data_base+4096+reg*(TEST_VLEN/8);
   for(unsigned byte=0;byte<8*(TEST_VLEN/8);++byte)
    transfer_expected(true,reg*(TEST_VLEN/8)+byte,address+byte,1);
   check_success(mem_insn(true,0,8,0,8,true,reg),address);
  }
  initialize();configure(0,7);write_csr(15,(cases+3)&7);write_csr(8,0);
  for(unsigned reg=0;reg<32;reg+=8){
   const uint64_t address=data_base+4096+reg*(TEST_VLEN/8);
   for(unsigned byte=0;byte<8*(TEST_VLEN/8);++byte)
    transfer_expected(false,reg*(TEST_VLEN/8)+byte,address+byte,1);
   check_success(mem_insn(false,0,8,0,8,true,reg),address);
  }
  // Register form preserves unsupported/vill configurations too. Restore
  // VSTART last because successful configuration clears it.
  command(0x803170d7,saved_vl,saved_type);
  write_csr(15,saved_control);write_csr(8,saved_start);
  require(read_csr(0xc21)==saved_type&&read_csr(0xc20)==saved_vl
      &&read_csr(8)==saved_start&&read_csr(15)==saved_control,
      "vector context CSR roundtrip");
  require(memory==saved_vrf,"vector context saved byte image");
  compare_data("vector context restored state");
  if(type==0x200){
   // Continue the faulting instruction after restoring its partial state.
   for(unsigned i=2;i<4;++i)
    transfer_expected(false,8*(TEST_VLEN/8)+i,data_base+i,1);
   auto resumed=command(mem_insn(false,0),data_base);
   require(!resumed.trap&&resumed.dirty,"context resumed load");
   require(bus_log.size()==2,"context resume repeated completed elements");
   for(unsigned i=0;i<2;++i)
    require(bus_log[i].addr==data_base+2+i&&!bus_log[i].write&&!bus_log[i].probe,
        "context resume prefix request");
   require(read_csr(8)==0,"context resume clears vstart");
   compare_data("context resumed state");
  }
  ++cases;
 }
 std::printf("PASS vector_context cases=%u\n",cases);
}
