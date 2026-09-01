`include "rapt.svh"
`include "rapt_if.svh"

module rapt_lsu_syn_top #(
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    parameter unsigned XLEN = `RAPT_XLEN
) (
    input  logic          clock,
    input  logic          reset,
    input  logic [2047:0] stimulus,
    output logic          response
);
  cmu_bcast_if cmu_bcast ();
  lsu_l1d_if lsu_l1d ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_exu_if rou_exu ();
  dpu_ioq_if disp_ioq ();
  cdb_if wb_alu_csr ();
  cdb_if wb_alu ();
  cdb_if exu_wb_mul ();
  cdb_if exu_ioq_bcast ();
  rou_lsu_if rou_lsu ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  fpr_if fpr ();
  load_fast_if load_fast ();
  logic pmu_sq_full;

  assign rou_exu.uop           = rapt_pkg::uop_t'(stimulus);
  assign rou_exu.op1           = stimulus;
  assign rou_exu.op2           = stimulus >> XLEN;
  assign rou_exu.pr1           = stimulus >> 128;
  assign rou_exu.pr2           = stimulus >> 136;
  assign rou_exu.prd           = stimulus >> 144;
  assign rou_exu.prs           = stimulus >> 152;
  assign rou_exu.fp_dep1_valid = stimulus[160];
  assign rou_exu.fp_dep2_valid = stimulus[161];
  assign rou_exu.fp_dep3_valid = stimulus[162];
  assign rou_exu.fp_dep1       = stimulus >> 163;
  assign rou_exu.fp_dep2       = stimulus >> 171;
  assign rou_exu.fp_dep3       = stimulus >> 179;
  assign rou_exu.dest          = stimulus >> 187;
  assign rou_exu.valid         = stimulus[195];
`ifdef RAPT_DUAL_ISSUE
  assign rou_exu.uop_b           = rapt_pkg::uop_t'(stimulus >> 256);
  assign rou_exu.op1_b           = stimulus >> 512;
  assign rou_exu.op2_b           = stimulus >> (512 + XLEN);
  assign rou_exu.pr1_b           = stimulus >> 640;
  assign rou_exu.pr2_b           = stimulus >> 648;
  assign rou_exu.prd_b           = stimulus >> 656;
  assign rou_exu.prs_b           = stimulus >> 664;
  assign rou_exu.fp_dep1_valid_b = stimulus[672];
  assign rou_exu.fp_dep2_valid_b = stimulus[673];
  assign rou_exu.fp_dep3_valid_b = stimulus[674];
  assign rou_exu.fp_dep1_b       = stimulus >> 675;
  assign rou_exu.fp_dep2_b       = stimulus >> 683;
  assign rou_exu.fp_dep3_b       = stimulus >> 691;
  assign rou_exu.dest_b          = stimulus >> 699;
  assign rou_exu.valid_b         = stimulus[707];
`endif

  assign cmu_bcast.rpc             = stimulus;
  assign cmu_bcast.cpc             = stimulus >> XLEN;
  assign cmu_bcast.ben             = stimulus[128];
  assign cmu_bcast.jen             = stimulus[129];
  assign cmu_bcast.jren            = stimulus[130];
  assign cmu_bcast.btaken          = stimulus[131];
  assign cmu_bcast.call            = stimulus[132];
  assign cmu_bcast.ret             = stimulus[133];
  assign cmu_bcast.rvc             = stimulus[134];
  assign cmu_bcast.fence_time      = stimulus[135];
  assign cmu_bcast.fence_i         = stimulus[136];
  assign cmu_bcast.flush_pipe      = stimulus[137];
  assign cmu_bcast.flush_redirect  = stimulus[138];
  assign cmu_bcast.sys_resume      = stimulus[139];
  assign cmu_bcast.time_trap       = stimulus[140];
  assign cmu_bcast.redirect_pc     = stimulus >> 141;
  assign cmu_bcast.rob_head        = stimulus >> 205;
  assign cmu_bcast.rd_a            = stimulus >> 213;
  assign cmu_bcast.rd_b            = stimulus >> 221;
  assign cmu_bcast.valid_b         = stimulus[229];

  assign lsu_l1d.rdata             = stimulus >> 768;
  assign lsu_l1d.trap              = stimulus[832];
  assign lsu_l1d.cause             = stimulus >> 833;
  assign lsu_l1d.difftest_skip     = stimulus[897];
  assign lsu_l1d.rready            = stimulus[898];
  assign lsu_l1d.rdata_b           = stimulus >> 899;
  assign lsu_l1d.rready_b          = stimulus[963];
  assign lsu_l1d.wready            = stimulus[964];

  assign exu_l1d.paddr             = stimulus >> 1024;
  assign exu_l1d.trap              = stimulus[1088];
  assign exu_l1d.cause             = stimulus >> 1089;
  assign exu_l1d.reservation       = stimulus >> 1153;
  assign exu_l1d.reservation_valid = stimulus[1217];
  assign exu_l1d.ready             = stimulus[1218];

  assign disp_ioq.accept_a         = stimulus[1220];
  assign disp_ioq.accept_b_paired  = stimulus[1221];
  assign disp_ioq.accept_b_alone   = stimulus[1222];

  `define DRIVE_CDB(IFACE, BASE) \
  assign {IFACE.pc, IFACE.npc, IFACE.btaken, IFACE.mispredict, IFACE.dest, \
          IFACE.result, IFACE.prd, IFACE.rd, IFACE.csr_wen, IFACE.csr_wdata, \
          IFACE.fp_flags_valid, IFACE.fp_flags, IFACE.wen, IFACE.alu, \
          IFACE.sq_waddr, IFACE.sq_wdata, IFACE.sq_wdata64, IFACE.sq_fp64, \
          IFACE.trap, IFACE.tval, IFACE.cause, IFACE.difftest_skip, IFACE.valid} = \
      stimulus >> BASE

  `DRIVE_CDB(wb_alu_csr, 1232);
  `DRIVE_CDB(wb_alu, 1488);
  `DRIVE_CDB(exu_wb_mul, 1744);
  `undef DRIVE_CDB

  assign rou_lsu.store = stimulus[0];
  assign rou_lsu.alu = stimulus >> 1;
  assign rou_lsu.dest = stimulus >> 7;
  assign rou_lsu.sq_waddr = stimulus >> 15;
  assign rou_lsu.sq_vaddr = stimulus >> 79;
  assign rou_lsu.sq_wdata = stimulus >> 143;
  assign rou_lsu.sq_wdata64 = stimulus >> 207;
  assign rou_lsu.sq_fp64 = stimulus[271];
  assign rou_lsu.pc = stimulus >> 272;
  assign rou_lsu.valid = stimulus[336];

  assign csr_bcast.priv = stimulus;
  assign csr_bcast.satp_ppn = stimulus >> 2;
  assign csr_bcast.satp_asid = stimulus >> 46;
  assign csr_bcast.immu_en = stimulus[55];
  assign csr_bcast.dmmu_en = stimulus[56];
  assign csr_bcast.mtvec = stimulus >> 57;
  assign csr_bcast.tvec = stimulus >> 121;
  assign csr_bcast.timer_int_en = stimulus[185];
  assign csr_bcast.sw_int_en = stimulus[186];
  assign csr_bcast.ext_int_en = stimulus[187];
  assign csr_bcast.mprv = stimulus[188];
  assign csr_bcast.mpp = stimulus >> 189;
  assign csr_bcast.sum = stimulus[191];
  assign csr_bcast.mxr = stimulus[192];
  assign csr_bcast.sbe = stimulus[193];
  assign csr_bcast.tsr = stimulus[194];
  assign csr_bcast.tvm = stimulus[195];
  assign csr_bcast.tw = stimulus[196];
  assign csr_bcast.mcounteren = stimulus >> 197;
  assign csr_bcast.scounteren = stimulus >> 200;
  assign csr_bcast.frm = stimulus >> 203;
  assign csr_bcast.fs = stimulus >> 206;

  assign pmp_update.addr_we = stimulus[384];
  assign pmp_update.addr_idx = stimulus >> 385;
  assign pmp_update.raw_addr = stimulus >> 400;
  assign pmp_update.napot_mask = stimulus >> 464;
  assign pmp_update.cfg_we = stimulus >> 528;
  assign pmp_update.cfg_r = stimulus >> 544;
  assign pmp_update.cfg_w = stimulus >> 560;
  assign pmp_update.cfg_x = stimulus >> 576;
  assign pmp_update.cfg_l = stimulus >> 592;
  assign pmp_update.mode_off = stimulus >> 608;
  assign pmp_update.mode_tor = stimulus >> 624;
  assign pmp_update.mode_na4 = stimulus >> 640;
  assign pmp_update.mode_napot = stimulus >> 656;

  assign fpr.ioq_rdata = stimulus >> 704;

  assign response = ^{
    lsu_l1d.raddr, lsu_l1d.ralu, lsu_l1d.rvalid, lsu_l1d.atomic_lock,
    lsu_l1d.ordered, lsu_l1d.raddr_b, lsu_l1d.ralu_b, lsu_l1d.rvalid_b,
    lsu_l1d.waddr, lsu_l1d.walu, lsu_l1d.wvalid, lsu_l1d.wdata,
    exu_l1d.mmu_en, exu_l1d.vaddr, exu_l1d.walu, exu_l1d.valid,
    exu_l1d.reservation_clear, disp_ioq.ready, disp_ioq.ready_b,
    exu_ioq_bcast.pc, exu_ioq_bcast.npc, exu_ioq_bcast.btaken,
    exu_ioq_bcast.mispredict, exu_ioq_bcast.dest, exu_ioq_bcast.result,
    exu_ioq_bcast.prd, exu_ioq_bcast.rd, exu_ioq_bcast.csr_wen,
    exu_ioq_bcast.csr_wdata, exu_ioq_bcast.fp_flags_valid,
    exu_ioq_bcast.fp_flags, exu_ioq_bcast.wen, exu_ioq_bcast.alu,
    exu_ioq_bcast.sq_waddr, exu_ioq_bcast.sq_wdata,
    exu_ioq_bcast.sq_wdata64, exu_ioq_bcast.sq_fp64,
    exu_ioq_bcast.trap, exu_ioq_bcast.tval, exu_ioq_bcast.cause,
    exu_ioq_bcast.difftest_skip, exu_ioq_bcast.valid,
    rou_lsu.sq_ready, rou_lsu.sq_empty,
    fpr.ioq_raddr, fpr.ioq_wvalid, fpr.ioq_waddr, fpr.ioq_wdata,
    load_fast.valid, load_fast.rebusy, load_fast.prd, pmu_sq_full
  };

  rapt_lsu #(
      .ROB_SIZE(ROB_SIZE),
      .XLEN    (XLEN)
  ) dut (
      .clock,
      .reset,
      .cmu_bcast,
      .lsu_l1d,
      .exu_l1d,
      .rou_exu,
      .disp_ioq,
      .wb_alu_csr,
      .wb_alu,
      .exu_wb_mul,
      .exu_ioq_bcast,
      .rou_lsu,
      .csr_bcast,
      .pmp_update,
      .fpr,
      .load_fast,
      .pmu_sq_full
  );
endmodule
