// Shared module-local tasks. Intentionally no include guard.
task automatic clear_commit;
  rou_csr.valid = 0;
  rou_csr.retire_count = 0;
  rou_csr.csr_wen = 0;
  rou_csr.csr_wdata = 0;
  rou_csr.csr_addr = 0;
  rou_csr.pc = 0;
  rou_csr.ecall = 0;
  rou_csr.ebreak = 0;
  rou_csr.mret = 0;
  rou_csr.sret = 0;
  rou_csr.trap = 0;
  rou_csr.tval = 0;
  rou_csr.cause = 0;
  rou_csr.fp_flags_valid = 0;
  rou_csr.fp_flags = 0;
  rou_csr.fp_dirty = 0;
endtask
