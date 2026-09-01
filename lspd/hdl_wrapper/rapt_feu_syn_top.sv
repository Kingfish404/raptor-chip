`include "rapt.svh"
`include "rapt_if.svh"

module rapt_feu_syn_top #(
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
  dpu_iq_if #(.RS_SIZE(4)) disp_fpq ();
  cdb_if wb_alu_csr ();
  cdb_if wb_alu ();
  cdb_if exu_ioq_bcast ();
  cdb_if exu_wb_mul ();
  load_fast_if load_fast ();
  fpr_if fpr ();
  cdb_if wb_fpu ();
  logic issue_enable;
  rapt_pkg::uop_payload_t uop_pl[ROB_SIZE];

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
  assign csr_bcast.frm = stimulus >> 701;
  assign fpr.alu_rdata_a = stimulus;
  assign fpr.alu_rdata_b = stimulus >> 64;
  assign fpr.alu_rdata_c = stimulus >> 128;
  assign load_fast.valid = stimulus[900];
  assign load_fast.prd = stimulus >> 901;
  assign load_fast.rebusy = stimulus[920];

  assign disp_fpq.accept_a = stimulus[930];
  assign disp_fpq.accept_b = stimulus[931];
  assign disp_fpq.b_rs_idx = stimulus >> 932;
  assign disp_fpq.iss_b_block_a = stimulus[940];
  assign disp_fpq.iss_b_block_b = stimulus[941];

  `define DRIVE_WB(IFACE, BASE) \
  assign {IFACE.pc, IFACE.npc, IFACE.btaken, IFACE.mispredict, IFACE.dest, \
          IFACE.result, IFACE.prd, IFACE.rd, IFACE.csr_wen, IFACE.csr_wdata, \
          IFACE.fp_flags_valid, IFACE.fp_flags, IFACE.wen, IFACE.alu, \
          IFACE.sq_waddr, IFACE.sq_wdata, IFACE.sq_wdata64, IFACE.sq_fp64, \
          IFACE.trap, IFACE.tval, IFACE.cause, IFACE.difftest_skip, IFACE.valid} = \
      stimulus >> BASE

  `DRIVE_WB(wb_alu_csr, 960);
  `DRIVE_WB(wb_alu, 1216);
  `DRIVE_WB(exu_ioq_bcast, 1472);
  `DRIVE_WB(exu_wb_mul, 1728);
  `undef DRIVE_WB

  for (genvar index = 0; index < ROB_SIZE; index++) begin : gen_uop_payload
    assign uop_pl[index] = rapt_pkg::uop_payload_t'(stimulus >> (index % 16));
  end

  assign response = ^{
    disp_fpq.free_found_a, disp_fpq.free_found_b,
    wb_fpu.result, wb_fpu.fp_flags, wb_fpu.valid,
    fpr.alu_raddr_a, fpr.alu_raddr_b, fpr.alu_raddr_c,
    fpr.alu_wvalid, fpr.alu_waddr, fpr.alu_wdata, issue_enable
  };

  rapt_feu dut (
      .clock,
      .reset,
      .cmu_bcast,
      .csr_bcast,
      .rou_exu,
      .disp_fpq,
      .wb_alu_csr,
      .wb_alu,
      .exu_ioq_bcast,
      .exu_wb_mul,
      .load_fast,
      .fpr,
      .wb_fpu,
      .issue_enable,
      .uop_pl
  );
endmodule
