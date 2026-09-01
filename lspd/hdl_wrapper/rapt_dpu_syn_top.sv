`include "rapt.svh"
`include "rapt_if.svh"

module rapt_dpu_syn_top (
    input  logic          clock,
    input  logic          reset,
    input  logic [1023:0] stimulus,
    output logic          response
);
  rou_exu_if rou_exu ();
  dpu_iq_if disp_alq ();
  dpu_iq_if #(.RS_SIZE(4)) disp_brq ();
  dpu_iq_if #(.RS_SIZE(4)) disp_mdq ();
  dpu_iq_if #(.RS_SIZE(4)) disp_fpq ();
  dpu_ioq_if disp_ioq ();

  assign rou_exu.uop   = rapt_pkg::uop_t'(stimulus);
  assign rou_exu.valid = stimulus[255];
`ifdef RAPT_DUAL_ISSUE
  assign rou_exu.uop_b   = rapt_pkg::uop_t'(stimulus >> 256);
  assign rou_exu.valid_b = stimulus[511];
`endif

  assign disp_alq.free_found_a = stimulus[512];
  assign disp_alq.free_found_b = stimulus[513];
  assign disp_alq.free_idx_a = stimulus >> 514;
  assign disp_alq.free_idx_b = stimulus >> 522;
  assign disp_brq.free_found_a = stimulus[530];
  assign disp_brq.free_found_b = stimulus[531];
  assign disp_brq.free_idx_a = stimulus >> 532;
  assign disp_brq.free_idx_b = stimulus >> 536;
  assign disp_mdq.free_found_a = stimulus[540];
  assign disp_mdq.free_found_b = stimulus[541];
  assign disp_mdq.free_idx_a = stimulus >> 542;
  assign disp_mdq.free_idx_b = stimulus >> 546;
  assign disp_fpq.free_found_a = stimulus[550];
  assign disp_fpq.free_found_b = stimulus[551];
  assign disp_fpq.free_idx_a = stimulus >> 552;
  assign disp_fpq.free_idx_b = stimulus >> 556;
  assign disp_ioq.ready = stimulus[560];
  assign disp_ioq.ready_b = stimulus[561];

  logic ready_b;
`ifdef RAPT_DUAL_ISSUE
  assign ready_b = rou_exu.ready_b;
`else
  assign ready_b = 1'b0;
`endif

  assign response = ^{
    rou_exu.ready, ready_b,
    disp_alq.accept_a, disp_alq.accept_b, disp_alq.b_rs_idx,
    disp_brq.accept_a, disp_brq.accept_b, disp_brq.b_rs_idx,
    disp_mdq.accept_a, disp_mdq.accept_b, disp_mdq.b_rs_idx,
    disp_fpq.accept_a, disp_fpq.accept_b, disp_fpq.b_rs_idx,
    disp_ioq.accept_a, disp_ioq.accept_b_paired, disp_ioq.accept_b_alone
  };

  rapt_dpu dut (
      .clock,
      .reset,
      .rou_exu,
      .disp_alq,
      .disp_brq,
      .disp_mdq,
      .disp_fpq,
      .disp_ioq
  );
endmodule
