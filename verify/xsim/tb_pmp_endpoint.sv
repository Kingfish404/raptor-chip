`include "rapt.svh"
`include "rapt_if.svh"

module tb_pmp_endpoint;
  localparam int XLEN = 32;

  logic clock = 1'b0;
  logic [XLEN-1:0] addr;
  logic [3:0] size_m1;
  logic fault;
  logic fault_lo;
  pmp_state_if #(.XLEN(XLEN)) pmp_state();

  rapt_pmp #(.XLEN(XLEN)) dut (
      .addr,
      .size_m1,
      .priv(`RAPT_PRIV_U),
      .op_r(1'b0),
      .op_w(1'b0),
      .op_x(1'b1),
      .pmp_raw_addr(pmp_state.pmp_raw_addr),
      .pmp_napot_mask(pmp_state.pmp_napot_mask),
      .pmp_cfg_r(pmp_state.pmp_cfg_r),
      .pmp_cfg_w(pmp_state.pmp_cfg_w),
      .pmp_cfg_x(pmp_state.pmp_cfg_x),
      .pmp_cfg_l(pmp_state.pmp_cfg_l),
      .pmp_mode_off(pmp_state.pmp_mode_off),
      .pmp_mode_tor(pmp_state.pmp_mode_tor),
      .pmp_mode_na4(pmp_state.pmp_mode_na4),
      .pmp_mode_napot(pmp_state.pmp_mode_napot),
      .fault,
      .fault_lo_o(fault_lo)
  );

  `include "tb_common.svh"

  initial begin
    pmp_state.pmp_raw_addr = '{default: '0};
    pmp_state.pmp_napot_mask = '{default: '0};
    pmp_state.pmp_cfg_r = '0;
    pmp_state.pmp_cfg_w = '0;
    pmp_state.pmp_cfg_x = '0;
    pmp_state.pmp_cfg_l = '0;
    pmp_state.pmp_mode_off = '1;
    pmp_state.pmp_mode_tor = '0;
    pmp_state.pmp_mode_na4 = '0;
    pmp_state.pmp_mode_napot = '0;

    pmp_state.pmp_raw_addr[0] = 32'h0000_0400;
    pmp_state.pmp_cfg_x[0] = 1'b1;
    pmp_state.pmp_mode_off[0] = 1'b0;
    pmp_state.pmp_mode_tor[0] = 1'b1;

    pmp_state.pmp_raw_addr[1] = 32'h0000_0800;
    pmp_state.pmp_mode_off[1] = 1'b0;
    pmp_state.pmp_mode_tor[1] = 1'b1;

    addr = 32'h0000_0ffe;
    size_m1 = 4'd1;
    #1;
    check(!fault, "two-byte fetch was denied before the TOR boundary");

    size_m1 = 4'd3;
    #1;
    check(fault, "four-byte fetch crossing the TOR boundary was allowed");
    check(!fault_lo, "cross-boundary fault was incorrectly attributed to the low endpoint");

    $display("PASS: PMP endpoint-size boundary checks passed");
    $finish;
  end
endmodule
