`include "tb_core_bcast_defaults.svh"

// Legacy directed tests drive the architectural CSR model directly. Mirror
// it onto the new request-owned sideband; ownership-specific tests may use a
// dedicated harness that holds this context while changing the CSR source.
assign lsu_l1d.rcontext = '{mmu_en: csr_bcast.dmmu_en,
    eff_priv: (csr_bcast.priv == `RAPT_PRIV_M && csr_bcast.mprv) ? csr_bcast.mpp : csr_bcast.priv,
    sum: csr_bcast.sum, mxr: csr_bcast.mxr, pbmte: csr_bcast.menvcfg_pbmte,
    asid: csr_bcast.satp_asid, version: 8'd0};
assign lsu_l1d.rcontext_b = lsu_l1d.rcontext;
assign exu_l1d.mem_context = lsu_l1d.rcontext;

task automatic init_l1d_inputs;
  begin
    lsu_l1d.raddr = '0;
    lsu_l1d.ralu = '0;
    lsu_l1d.rmisaligned = 0;
    lsu_l1d.rcheck_valid = 0;
    lsu_l1d.rcheck_offset = 0;
    lsu_l1d.rcheck_size_m1 = 0;
    lsu_l1d.rorig_size_m1 = 0;
    lsu_l1d.rvalid = 1'b0;
    lsu_l1d.replay_allowed = 1'b0;
    lsu_l1d.atomic_lock = 1'b0;
    lsu_l1d.ordered = 1'b1;
    lsu_l1d.waddr = '0;
    lsu_l1d.wpbmt = '0;
    lsu_l1d.walu = '0; lsu_l1d.wzero = 0;
    lsu_l1d.wvalid = 1'b0;
    lsu_l1d.wdata = '0;

    l1d_bus.rdata = '0;
    l1d_bus.rvalid = 1'b0;
    l1d_bus.r_mshr = 1'b0;
    l1d_bus.r_mshr_id = '0;
    l1d_bus.ptw_rvalid = 1'b0;
    l1d_bus.ptw_rerr = 1'b0;
    l1d_bus.rlast = 1'b1;
    l1d_bus.difftest_skip = 1'b0;
    l1d_bus.rerr = 1'b0;
    l1d_bus.wready = 1'b1;
    l1d_bus.werr = 1'b0;
    l1d_bus.ptw_wready = 1'b0;
    l1d_bus.ptw_werr = 1'b0;

    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1'b1);
    pmp_update.addr_we = 1'b0;
    pmp_update.addr_idx = '0;
    pmp_update.raw_addr = '0;
    pmp_update.napot_mask = '0;
    pmp_update.cfg_we = '0;
    pmp_update.cfg_r = '0;
    pmp_update.cfg_w = '0;
    pmp_update.cfg_x = '0;
    pmp_update.cfg_l = '0;
    pmp_update.mode_off = '1;
    pmp_update.mode_tor = '0;
    pmp_update.mode_na4 = '0;
    pmp_update.mode_napot = '0;

    exu_l1d.mmu_en = 1'b0;
    exu_l1d.vaddr = '0;
    exu_l1d.walu = '0;
    exu_l1d.misaligned = 0;
    exu_l1d.cmo_mgmt = 1'b0;
    exu_l1d.valid = 1'b0;
    exu_l1d.reservation_clear = 1'b0;

    init_cmu_bcast_defaults();

    rou_cmu.slot[0].valid = 1'b0;
    rou_cmu.atomic_sc = 1'b0;
    rou_cmu.fence_time = 1'b0; rou_cmu.cbo_inval = 0; rou_cmu.cbo_block = '0;
    rou_cmu.flush_pipe = 1'b0;
  end
endtask
