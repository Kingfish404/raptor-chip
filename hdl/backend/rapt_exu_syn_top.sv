`include "rapt.svh"
`include "rapt_if.svh"

module rapt_exu_syn_top #(
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    parameter unsigned XLEN = `RAPT_XLEN
) (
    input  logic clock,
    input  logic reset,
  input  logic [2047:0] stimulus,
  output logic response
);
  cmu_bcast_if cmu_bcast ();
  rou_exu_if rou_exu ();
  exu_wb_if wb_alu_csr ();
  exu_wb_if wb_alu ();
  exu_wb_if wb_branch ();
  exu_wb_if exu_ioq_bcast ();
  exu_wb_if exu_wb_mul ();
  exu_lsu_if exu_lsu ();
  exu_csr_if exu_csr ();
  fpr_if fpr ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  exu_l1d_if exu_l1d ();
  rapt_pkg::uop_payload_t uop_pl[ROB_SIZE];

  assign rou_exu.uop = rapt_pkg::uop_t'(stimulus);
  assign rou_exu.op1 = stimulus;
  assign rou_exu.op2 = stimulus >> XLEN;
  assign rou_exu.pr1 = stimulus;
  assign rou_exu.pr2 = stimulus >> 8;
  assign rou_exu.prd = stimulus >> 16;
  assign rou_exu.prs = stimulus >> 24;
  assign rou_exu.fp_dep1_valid = stimulus[32];
  assign rou_exu.fp_dep2_valid = stimulus[33];
  assign rou_exu.fp_dep3_valid = stimulus[34];
  assign rou_exu.fp_dep1 = stimulus >> 35;
  assign rou_exu.fp_dep2 = stimulus >> 43;
  assign rou_exu.fp_dep3 = stimulus >> 51;
  assign rou_exu.dest = stimulus >> 59;
  assign rou_exu.valid = stimulus[67];
`ifdef RAPT_DUAL_ISSUE
  assign rou_exu.uop_b = rapt_pkg::uop_t'(stimulus >> 256);
  assign rou_exu.op1_b = stimulus >> 512;
  assign rou_exu.op2_b = stimulus >> (512 + XLEN);
  assign rou_exu.pr1_b = stimulus >> 640;
  assign rou_exu.pr2_b = stimulus >> 648;
  assign rou_exu.prd_b = stimulus >> 656;
  assign rou_exu.prs_b = stimulus >> 664;
  assign rou_exu.fp_dep1_valid_b = stimulus[672];
  assign rou_exu.fp_dep2_valid_b = stimulus[673];
  assign rou_exu.fp_dep3_valid_b = stimulus[674];
  assign rou_exu.fp_dep1_b = stimulus >> 675;
  assign rou_exu.fp_dep2_b = stimulus >> 683;
  assign rou_exu.fp_dep3_b = stimulus >> 691;
  assign rou_exu.dest_b = stimulus >> 699;
  assign rou_exu.valid_b = stimulus[707];
`endif

  assign cmu_bcast.rpc = stimulus;
  assign cmu_bcast.cpc = stimulus >> XLEN;
  assign cmu_bcast.ben = stimulus[128];
  assign cmu_bcast.jen = stimulus[129];
  assign cmu_bcast.jren = stimulus[130];
  assign cmu_bcast.btaken = stimulus[131];
  assign cmu_bcast.call = stimulus[132];
  assign cmu_bcast.ret = stimulus[133];
  assign cmu_bcast.rvc = stimulus[134];
  assign cmu_bcast.fence_time = stimulus[135];
  assign cmu_bcast.fence_i = stimulus[136];
  assign cmu_bcast.flush_pipe = stimulus[137];
  assign cmu_bcast.flush_redirect = stimulus[138];
  assign cmu_bcast.sys_resume = stimulus[139];
  assign cmu_bcast.time_trap = stimulus[140];
  assign cmu_bcast.redirect_pc = stimulus >> 141;
  assign cmu_bcast.rob_head = stimulus >> 205;
  assign cmu_bcast.rd_a = stimulus >> 213;
  assign cmu_bcast.rd_b = stimulus >> 221;
  assign cmu_bcast.valid_b = stimulus[229];

  assign exu_lsu.rdata = stimulus;
  assign exu_lsu.fp_rdata64 = stimulus >> 64;
  assign exu_lsu.fp_rdata64_valid = stimulus[128];
  assign exu_lsu.trap = stimulus[129];
  assign exu_lsu.cause = stimulus >> 130;
  assign exu_lsu.difftest_skip = stimulus[194];
  assign exu_lsu.rready = stimulus[195];
  assign exu_lsu.stq_ready = stimulus[196];
  assign exu_lsu.rdata_b = stimulus >> 197;
  assign exu_lsu.rready_b = stimulus[261];

  assign exu_csr.rdata = stimulus;
  assign exu_csr.mtvec = stimulus >> 64;
  assign exu_csr.mepc = stimulus >> 128;
  assign exu_csr.sepc = stimulus >> 192;

  assign fpr.alu_rdata_a = stimulus;
  assign fpr.alu_rdata_b = stimulus >> 64;
  assign fpr.alu_rdata_c = stimulus >> 128;
  assign fpr.ioq_rdata = stimulus >> 192;

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

  for (genvar index = 0; index < `RAPT_PMP_NUM; index++) begin : gen_pmp_stimulus
    assign pmp_state.pmp_raw_addr[index] = stimulus >> (index * 8);
    assign pmp_state.pmp_napot_mask[index] = stimulus >> (index * 8 + 4);
  end
  assign pmp_state.pmp_cfg_r = stimulus;
  assign pmp_state.pmp_cfg_w = stimulus >> 16;
  assign pmp_state.pmp_cfg_x = stimulus >> 32;
  assign pmp_state.pmp_cfg_l = stimulus >> 48;
  assign pmp_state.pmp_mode_off = stimulus >> 64;
  assign pmp_state.pmp_mode_tor = stimulus >> 80;
  assign pmp_state.pmp_mode_na4 = stimulus >> 96;
  assign pmp_state.pmp_mode_napot = stimulus >> 112;

  assign exu_l1d.paddr = stimulus;
  assign exu_l1d.trap = stimulus[64];
  assign exu_l1d.cause = stimulus >> 65;
  assign exu_l1d.reservation = stimulus >> 129;
  assign exu_l1d.reservation_valid = stimulus[193];
  assign exu_l1d.ready = stimulus[194];

  for (genvar index = 0; index < ROB_SIZE; index++) begin : gen_uop_payload
    assign uop_pl[index] = rapt_pkg::uop_payload_t'(stimulus >> (index % 16));
  end

  assign response = ^{
      rou_exu.ready,
`ifdef RAPT_DUAL_ISSUE
      rou_exu.ready_b,
`endif
      wb_alu_csr.pc, wb_alu_csr.npc, wb_alu_csr.result, wb_alu_csr.valid,
      wb_alu.pc, wb_alu.npc, wb_alu.result, wb_alu.valid,
      wb_branch.pc, wb_branch.npc, wb_branch.btaken, wb_branch.valid,
      exu_ioq_bcast.pc, exu_ioq_bcast.result, exu_ioq_bcast.valid,
      exu_wb_mul.pc, exu_wb_mul.result, exu_wb_mul.valid,
      exu_lsu.rvalid, exu_lsu.raddr, exu_lsu.ralu, exu_lsu.atomic_lock,
      exu_lsu.ordered, exu_lsu.pc, exu_lsu.fp_rdata64_req,
      exu_lsu.rvalid_b, exu_lsu.raddr_b, exu_lsu.ralu_b,
      exu_csr.raddr,
      fpr.alu_raddr_a, fpr.alu_raddr_b, fpr.alu_raddr_c,
      fpr.alu_wvalid, fpr.alu_waddr, fpr.alu_wdata,
      fpr.ioq_raddr, fpr.ioq_wvalid, fpr.ioq_waddr, fpr.ioq_wdata,
      exu_l1d.mmu_en, exu_l1d.vaddr, exu_l1d.walu, exu_l1d.valid,
      exu_l1d.reservation_clear
  };

  rapt_exu u_exu (
      .clock,
      .reset,
      .cmu_bcast,
      .rou_exu,
      .wb_alu_csr,
      .wb_alu,
      .wb_branch,
      .exu_ioq_bcast,
      .exu_wb_mul,
      .exu_lsu,
      .exu_csr,
      .fpr,
      .csr_bcast,
      .pmp_state,
      .exu_l1d,
      .uop_pl
  );
endmodule
