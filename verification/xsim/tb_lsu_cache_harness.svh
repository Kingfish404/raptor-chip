  // SQ -> real L1D fixture, shared by visibility, split and AXI-ordering tests.
  // The caller owns LsuTbSqSize/XLEN and any response/backpressure model.
  // No include guard; each bench owns its DUT and consumes its overrides.
  logic clock = 1'b0;
  logic reset = 1'b1;
  logic pmu_sq_full;
  logic [XLEN-1:0] sq_waddr_hi;
  logic [XLEN-1:0] sq_waddr_third;
  logic [2:0][1:0] sq_wpbmt;

  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  lsu_pipe_if exu_lsu ();
  rapt_pkg::completion_t exu_ioq_bcast;
  rou_lsu_if rou_lsu ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  rapt_pkg::mem_context_t test_context;
  assign test_context = '{mmu_en: csr_bcast.dmmu_en,
      eff_priv: (csr_bcast.priv == `RAPT_PRIV_M && csr_bcast.mprv) ? csr_bcast.mpp : csr_bcast.priv,
      sum: csr_bcast.sum, mxr: csr_bcast.mxr, pbmte: csr_bcast.menvcfg_pbmte,
      asid: csr_bcast.satp_asid, version: 8'd0};
  assign exu_lsu.rcontext = test_context;
  assign exu_lsu.rcontext_b = test_context;

  rapt_lsu_sq #(
      .SQ_SIZE(LsuTbSqSize)
  ) dut (
      .clock,
      .cmu_bcast,
      .lsu_l1d,
      .exu_lsu,
      .exu_ioq_bcast,
      .completion_accept(1'b1),
`ifndef TB_LSU_CACHE_NO_HANDOFF
      .sq_forward_pending(1'b0),
      .sq_handoff_alu('0),
`endif
      .sq_waddr_hi,
      .sq_waddr_third,
      .sq_wpbmt,
      .sq_context(test_context),
      .sq_acquire(1'b0),
      .rou_lsu,
      .csr_bcast,
      .pmp_state,
      .pmu_sq_full,
      .reset
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_core_bcast_defaults.svh"
  `include "tb_pmp_state_defaults.svh"

l1d_bus_if l1d_bus ();
  pmp_update_if pmp_update ();
  lsu_l1d_mmu_if exu_l1d ();
  assign exu_l1d.mem_context = test_context;
  rou_cmu_if rou_cmu ();
  rapt_l1d #(
      .LineRefill(0)
  ) cache_dut (
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
      .clock,
      .reset,
      .cmu_bcast,
      .lsu_l1d,
      .l1d_bus,
      .csr_bcast,
      .pmp_update,
      .exu_l1d
  );
  task automatic init_inputs;
    begin
      init_cmu_bcast_defaults();
      init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1'b0);
      init_pmp_state_defaults(1'b0);
      exu_lsu.rvalid = 1'b0;
      exu_lsu.raddr = '0;
      exu_lsu.ralu = `RAPT_ALU_LW__;
      exu_lsu.atomic_lock = 1'b0;
      exu_lsu.atomic_release = 1'b0;
      exu_lsu.ordered = 1;
      exu_lsu.pc = '0;
      exu_lsu.rvalid_b = 1'b0;
      exu_lsu.raddr_b = '0;
      exu_lsu.ralu_b = 0;
      exu_ioq_bcast.pc = '0;
      exu_ioq_bcast.npc = '0;
      exu_ioq_bcast.btaken = 1'b0;
      exu_ioq_bcast.mispredict = 1'b0;
      exu_ioq_bcast.dest = '0;
      exu_ioq_bcast.result = '0;
      exu_ioq_bcast.prd = '0;
      exu_ioq_bcast.rd = '0;
      exu_ioq_bcast.csr_wen = 1'b0;
      exu_ioq_bcast.csr_wdata = '0;
      exu_ioq_bcast.wen = 1'b0;
      exu_ioq_bcast.alu = '0;
      exu_ioq_bcast.sq_waddr = '0;
      exu_ioq_bcast.sq_wdata = '0;
      exu_ioq_bcast.sq_wdata64 = '0;
      exu_ioq_bcast.sq_fp64 = 1'b0;
      exu_ioq_bcast.trap = 1'b0;
      exu_ioq_bcast.tval = '0;
      exu_ioq_bcast.cause = '0;
      exu_ioq_bcast.difftest_skip = 1'b0;
      exu_ioq_bcast.valid = 1'b0;
      rou_lsu.store = 1'b0;
      rou_lsu.dest = '0;
      rou_lsu.sq_vaddr = '0;
      rou_lsu.pc = '0;
      rou_lsu.valid = 1'b0;
      sq_waddr_hi = '0;
      sq_waddr_third = '0;
      sq_wpbmt = '0;


`ifndef TB_LSU_CACHE_EXTERNAL_BUS
      l1d_bus.rdata = '0;
      l1d_bus.rvalid = 1'b0;
      l1d_bus.ptw_rvalid = 1'b0;
      l1d_bus.ptw_rerr = 1'b0;
      l1d_bus.rlast = 1'b1;
      l1d_bus.difftest_skip = 1'b0;
      l1d_bus.rerr = 1'b0;
`ifndef TB_LSU_CACHE_BACKPRESSURE
      l1d_bus.wready = 1'b1;
`endif
      l1d_bus.werr = 1'b0;
`endif

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


      rou_cmu.slot[0].valid = 1'b0;
      rou_cmu.atomic_sc = 1'b0;
      rou_cmu.fence_time = 1'b0;
      rou_cmu.cbo_inval = 0;
      rou_cmu.cbo_block = '0;
      rou_cmu.flush_pipe = 1'b0;
      exu_lsu.fp_rdata64_req = 0;
    end
  endtask
  `undef TB_LSU_CACHE_NO_HANDOFF
  `undef TB_LSU_CACHE_EXTERNAL_BUS
  `undef TB_LSU_CACHE_BACKPRESSURE
