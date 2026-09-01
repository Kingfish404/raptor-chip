`include "rapt.svh"
`include "rapt_if.svh"

module rapt_ieu_syn_top #(
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    parameter unsigned XLEN = `RAPT_XLEN
) (
    input  logic          clock,
    input  logic          reset,
    input  logic [2047:0] stimulus,
    output logic          response
);
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  rou_exu_if rou_exu ();
  dpu_iq_if disp_alq ();
  dpu_iq_if #(.RS_SIZE(4)) disp_brq ();
  dpu_iq_if #(.RS_SIZE(4)) disp_mdq ();
  cdb_if exu_ioq_bcast ();
  load_fast_if load_fast ();
  exu_csr_if exu_csr ();
  cdb_if wb_alu_csr_raw ();
  cdb_if wb_alu_csr ();
  cdb_if wb_alu ();
  cdb_if wb_branch ();
  cdb_if exu_wb_mul ();
  rapt_pkg::uop_payload_t uop_pl[ROB_SIZE];
  logic pmu_ooo_valid, pmu_ooo_valid_found, pmu_ooo_full;

  assign rou_exu.uop   = rapt_pkg::uop_t'(stimulus);
  assign rou_exu.op1   = stimulus;
  assign rou_exu.op2   = stimulus >> XLEN;
  assign rou_exu.pr1   = stimulus;
  assign rou_exu.pr2   = stimulus >> 8;
  assign rou_exu.prd   = stimulus >> 16;
  assign rou_exu.dest  = stimulus >> 24;
  assign rou_exu.valid = stimulus[32];
`ifdef RAPT_DUAL_ISSUE
  assign rou_exu.uop_b   = rapt_pkg::uop_t'(stimulus >> 256);
  assign rou_exu.op1_b   = stimulus >> 512;
  assign rou_exu.op2_b   = stimulus >> (512 + XLEN);
  assign rou_exu.pr1_b   = stimulus >> 640;
  assign rou_exu.pr2_b   = stimulus >> 648;
  assign rou_exu.prd_b   = stimulus >> 656;
  assign rou_exu.dest_b  = stimulus >> 664;
  assign rou_exu.valid_b = stimulus[672];
`endif
  assign cmu_bcast.flush_pipe = stimulus[700];
  assign exu_csr.rdata = stimulus;
  assign exu_csr.mtvec = stimulus >> 64;
  assign exu_csr.mepc = stimulus >> 128;
  assign exu_csr.sepc = stimulus >> 192;
  assign csr_bcast.frm = stimulus >> 256;
  assign load_fast.valid = stimulus[300];
  assign load_fast.prd = stimulus >> 301;
  assign load_fast.rebusy = stimulus[320];

  assign disp_alq.accept_a = stimulus[330];
  assign disp_alq.accept_b = stimulus[331];
  assign disp_alq.b_rs_idx = stimulus >> 332;
  assign disp_alq.iss_b_block_a = stimulus[340];
  assign disp_alq.iss_b_block_b = stimulus[341];
  assign disp_brq.accept_a = stimulus[342];
  assign disp_brq.accept_b = stimulus[343];
  assign disp_brq.b_rs_idx = stimulus >> 344;
  assign disp_brq.iss_b_block_a = stimulus[350];
  assign disp_brq.iss_b_block_b = stimulus[351];
  assign disp_mdq.accept_a = stimulus[352];
  assign disp_mdq.accept_b = stimulus[353];
  assign disp_mdq.b_rs_idx = stimulus >> 354;
  assign disp_mdq.iss_b_block_a = stimulus[360];
  assign disp_mdq.iss_b_block_b = stimulus[361];

  `define DRIVE_WB(IFACE, BASE) \
  assign {IFACE.pc, IFACE.npc, IFACE.btaken, IFACE.mispredict, IFACE.dest, \
          IFACE.result, IFACE.prd, IFACE.rd, IFACE.csr_wen, IFACE.csr_wdata, \
          IFACE.fp_flags_valid, IFACE.fp_flags, IFACE.wen, IFACE.alu, \
          IFACE.sq_waddr, IFACE.sq_wdata, IFACE.sq_wdata64, IFACE.sq_fp64, \
          IFACE.trap, IFACE.tval, IFACE.cause, IFACE.difftest_skip, IFACE.valid} = \
      stimulus >> BASE

  `DRIVE_WB(wb_alu_csr, 384);
  `DRIVE_WB(exu_ioq_bcast, 896);
  `undef DRIVE_WB

  for (genvar index = 0; index < ROB_SIZE; index++) begin : gen_uop_payload
    assign uop_pl[index] = rapt_pkg::uop_payload_t'(stimulus >> (index % 16));
  end

  assign response = ^{
    disp_alq.free_found_a, disp_alq.free_found_b,
    disp_brq.free_found_a, disp_brq.free_found_b,
    disp_mdq.free_found_a, disp_mdq.free_found_b,
    wb_alu_csr_raw.result, wb_alu_csr_raw.valid,
    wb_alu.result, wb_alu.valid, wb_branch.btaken, wb_branch.valid,
    exu_wb_mul.result, exu_wb_mul.valid,
    exu_csr.raddr, pmu_ooo_valid, pmu_ooo_valid_found, pmu_ooo_full
  };

  rapt_ieu dut (
      .clock,
      .reset,
      .cmu_bcast,
      .csr_bcast,
      .rou_exu,
      .disp_alq,
      .disp_brq,
      .disp_mdq,
      .exu_ioq_bcast,
      .load_fast,
      .alu_csr_issue_enable(stimulus[321]),
      .exu_csr,
      .wb_alu_csr_raw,
      .wb_alu_csr,
      .wb_alu,
      .wb_branch,
      .exu_wb_mul,
      .pmu_ooo_valid,
      .pmu_ooo_valid_found,
      .pmu_ooo_full,
      .uop_pl
  );
endmodule
