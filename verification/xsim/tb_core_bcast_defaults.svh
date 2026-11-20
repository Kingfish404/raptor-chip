task automatic init_cmu_bcast_defaults;
  begin
    cmu_bcast.rpc = '0;
    cmu_bcast.cpc = '0;
    cmu_bcast.ben = 1'b0;
    cmu_bcast.jen = 1'b0;
    cmu_bcast.jren = 1'b0;
    cmu_bcast.btaken = 1'b0;
    cmu_bcast.atomic_retired = 1'b0;
    cmu_bcast.call = 1'b0;
    cmu_bcast.ret = 1'b0;
    cmu_bcast.rvc = 1'b0;
    cmu_bcast.fence_time = 1'b0;
    cmu_bcast.sfence_valid = 1'b0;
    cmu_bcast.sfence_vpn = '0;
    cmu_bcast.sfence_asid = '0;
    cmu_bcast.sfence_all_vpn = 1'b1;
    cmu_bcast.sfence_all_asid = 1'b1;
    cmu_bcast.cbo_inval = 1'b0;
    cmu_bcast.cbo_block = '0;
    cmu_bcast.fence_i = 1'b0;
    cmu_bcast.flush_pipe = 1'b0;
    cmu_bcast.flush_redirect = 1'b0;
    cmu_bcast.fetch_context_stable = 1'b0;
    cmu_bcast.redirect_pc = '0;
    cmu_bcast.time_trap = 1'b0;
    cmu_bcast.rob_head = '0;
  end
endtask

task automatic init_csr_bcast_defaults(
    input logic [1:0] priv_value,
    input logic [XLEN-1:0] vector_base,
  input bit unused_pmp_mode_off_value
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
    csr_bcast.bus_error_int = 1'b0;
    csr_bcast.wrs_irq_pending = 1'b0;
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
    csr_bcast.frm = '0;
    csr_bcast.fs = '0;
    csr_bcast.vs = '0;
    csr_bcast.menvcfg_cbie = '0;
    csr_bcast.menvcfg_cbcfe = 1'b0;
    csr_bcast.menvcfg_cbze = 1'b0;
    csr_bcast.menvcfg_stce = 1'b0;
    csr_bcast.menvcfg_pbmte = 1'b0;
    csr_bcast.senvcfg_cbie = '0;
    csr_bcast.senvcfg_cbcfe = 1'b0;
    csr_bcast.senvcfg_cbze = 1'b0;
    csr_bcast.mstateen_se0 = '1;
    csr_bcast.mstateen0_envcfg = 1'b1;
    csr_bcast.data_pmm = '0;
    csr_bcast.data_pmm_sext = 1'b0;
    csr_bcast.virt = 1'b0;
    csr_bcast.mpv = 1'b0;
    csr_bcast.hstatus_vtvm = 1'b0;
    csr_bcast.hstatus_vtw = 1'b0;
    csr_bcast.hstatus_vtsr = 1'b0;
    csr_bcast.hstatus_hu = 1'b0;
    csr_bcast.hstatus_spvp = 1'b0;
    csr_bcast.hstatus_hupmm = '0;
    csr_bcast.vs_sum = 1'b0;
    csr_bcast.vs_mxr = 1'b0;
    csr_bcast.henvcfg_stce = 1'b0;
    csr_bcast.henvcfg_pbmte = 1'b0;
    csr_bcast.henvcfg_cbie = '0;
    csr_bcast.henvcfg_cbcfe = 1'b0;
    csr_bcast.henvcfg_cbze = 1'b0;
    csr_bcast.henvcfg_pmm = '0;
    csr_bcast.hcounteren = '0;
    csr_bcast.hstateen_se0 = '1;
    csr_bcast.hstateen0_envcfg = 1'b1;
    csr_bcast.vsatp_ppn = '0;
    csr_bcast.vsatp_asid = '0;
    csr_bcast.vsatp_en = 1'b0;
    csr_bcast.hgatp_ppn = '0;
    csr_bcast.hgatp_en = 1'b0;
    csr_bcast.senvcfg_pmm = '0;
    csr_bcast.eff_data_guest = 1'b0;
    csr_bcast.hgatp_flush = 1'b0;
  end
endtask

// End shared broadcast defaults.
