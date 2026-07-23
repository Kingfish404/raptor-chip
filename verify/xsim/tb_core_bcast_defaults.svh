task automatic init_cmu_bcast_defaults;
  begin
    cmu_bcast.rpc = '0;
    cmu_bcast.cpc = '0;
    cmu_bcast.ben = 1'b0;
    cmu_bcast.jen = 1'b0;
    cmu_bcast.jren = 1'b0;
    cmu_bcast.btaken = 1'b0;
    cmu_bcast.call = 1'b0;
    cmu_bcast.ret = 1'b0;
    cmu_bcast.rvc = 1'b0;
    cmu_bcast.fence_time = 1'b0;
    cmu_bcast.fence_i = 1'b0;
    cmu_bcast.flush_pipe = 1'b0;
    cmu_bcast.flush_redirect = 1'b0;
    cmu_bcast.redirect_pc = '0;
    cmu_bcast.sys_resume = 1'b0;
    cmu_bcast.time_trap = 1'b0;
    cmu_bcast.rob_head = '0;
    cmu_bcast.rd_a = '0;
    cmu_bcast.rd_b = '0;
    cmu_bcast.valid_b = 1'b0;
  end
endtask

task automatic init_csr_bcast_defaults(
    input logic [1:0] priv_value,
    input logic [XLEN-1:0] vector_base,
    input bit pmp_mode_off_value
);
  begin
    csr_bcast.priv = priv_value;
    csr_bcast.satp_ppn = '0;
    csr_bcast.satp_asid = '0;
    csr_bcast.immu_en = 1'b0;
    csr_bcast.dmmu_en = 1'b0;
    csr_bcast.mtvec = vector_base;
    csr_bcast.tvec = vector_base;
    csr_bcast.timer_int_en = 1'b0;
    csr_bcast.sw_int_en = 1'b0;
    csr_bcast.ext_int_en = 1'b0;
    csr_bcast.mprv = 1'b0;
    csr_bcast.mpp = priv_value;
    csr_bcast.sum = 1'b0;
    csr_bcast.mxr = 1'b0;
    csr_bcast.sbe = 1'b0;
    csr_bcast.tsr = 1'b0;
    csr_bcast.tvm = 1'b0;
    csr_bcast.tw = 1'b0;
    csr_bcast.mcounteren = '0;
    csr_bcast.scounteren = '0;
    csr_bcast.pmp_cfg_r = '0;
    csr_bcast.pmp_cfg_w = '0;
    csr_bcast.pmp_cfg_x = '0;
    csr_bcast.pmp_cfg_l = '0;
    csr_bcast.pmp_mode_off = pmp_mode_off_value ? '1 : '0;
    csr_bcast.pmp_mode_tor = '0;
    csr_bcast.pmp_mode_na4 = '0;
    csr_bcast.pmp_mode_napot = '0;
    for (int i = 0; i < `RAPT_PMP_NUM; i++) begin
      csr_bcast.pmpcfg[i] = '0;
      csr_bcast.pmpaddr[i] = '0;
      csr_bcast.pmp_napot_mask[i] = '0;
      csr_bcast.pmp_napot_base[i] = '0;
      csr_bcast.pmp_tor_lo[i] = '0;
      csr_bcast.pmp_tor_hi[i] = '0;
    end
  end
endtask

// End shared broadcast defaults.