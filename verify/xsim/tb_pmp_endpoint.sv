`include "rapt.svh"
`include "rapt_if.svh"

module tb_pmp_endpoint;
  localparam int XLEN = `RAPT_XLEN;

  logic clock = 1'b0;
  logic [XLEN-1:0] addr;
  logic [3:0] size_m1;
  logic fault;
  logic fault_lo;
  logic op_r;
  logic op_x;
  pmp_state_if #(.XLEN(XLEN)) pmp_state ();

  rapt_pmp #(
      .XLEN(XLEN)
  ) dut (
      .addr,
      .size_m1,
      .priv(`RAPT_PRIV_U),
      .op_r,
      .op_w(1'b0),
      .op_x,
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

    pmp_state.pmp_raw_addr[0] = $bits(pmp_state.pmp_raw_addr[0])'(32'h0000_0400);
    pmp_state.pmp_cfg_r[0] = 1'b1;
    pmp_state.pmp_cfg_x[0] = 1'b1;
    pmp_state.pmp_mode_off[0] = 1'b0;
    pmp_state.pmp_mode_tor[0] = 1'b1;

    pmp_state.pmp_raw_addr[1] = $bits(pmp_state.pmp_raw_addr[1])'(32'h0000_0800);
    pmp_state.pmp_cfg_r[1] = 1'b1;
    pmp_state.pmp_mode_off[1] = 1'b0;
    pmp_state.pmp_mode_tor[1] = 1'b1;

    op_r = 1'b0;
    op_x = 1'b1;
    addr = XLEN'(32'h0000_0ffe);
    size_m1 = 4'd1;
    #1;
    check(!fault, "two-byte fetch was denied before the TOR boundary");

    size_m1 = 4'd3;
    #1;
    check(fault, "four-byte fetch crossing the TOR boundary was allowed");
    check(!fault_lo, "cross-boundary fault was incorrectly attributed to the low endpoint");

    op_r = 1'b1;
    op_x = 1'b0;
    addr = XLEN'(32'h0000_0ffc);
    size_m1 = 4'd3;
    #1;
    check(!fault, "four-byte load within the first TOR entry was denied");

    addr = XLEN'(32'h0000_0ffe);
    #1;
    check(fault, "load spanning two readable TOR entries was allowed");
    check(!fault_lo, "partial-entry data fault was incorrectly attributed to the low endpoint");

    // Readable higher-priority NA4 only covers the high half.
    pmp_state.pmp_mode_tor='0;
    pmp_state.pmp_mode_na4[0]=1;
    pmp_state.pmp_raw_addr[0]='h400;
    pmp_state.pmp_mode_napot[1]=1;
    pmp_state.pmp_raw_addr[1]='1;
    pmp_state.pmp_napot_mask[1]='1;
    op_r=1;
    op_x=0;
    addr='hffc;
    size_m1=7;
    #1;
    check(fault, "higher-priority high-half partial match was ignored");
    // Entry entirely inside a request: neither endpoint belongs to it.
    addr='hffd;
    size_m1=7;
    #1;
    check(fault, "interior NA4 entry was ignored");
    pmp_state.pmp_mode_na4[0]=0;
    pmp_state.pmp_mode_tor[0]=1;
    // TOR entry zero starts at zero. Use entry 1 with entry 0 OFF as base.
    pmp_state.pmp_mode_tor[0]=0;
    pmp_state.pmp_mode_off[0]=1;
    pmp_state.pmp_mode_napot[1]=0;
    pmp_state.pmp_mode_tor[1]=1;
    pmp_state.pmp_raw_addr[1]='h401;
    pmp_state.pmp_mode_off[2]=0;
    pmp_state.pmp_mode_napot[2]=1;
    pmp_state.pmp_raw_addr[2]='1;
    pmp_state.pmp_napot_mask[2]='1;
    pmp_state.pmp_cfg_r[2]=1;
    #1;
    check(fault, "interior TOR entry was ignored");
    // Empty/reversed TOR must not claim overlapping bytes.
    pmp_state.pmp_raw_addr[1] = 'h3ff;
    #1;
    check(!fault, "empty TOR incorrectly matched an access");
    // NAPOT region [0x1000,0x1007] inside a sixteen-byte request.
    pmp_state.pmp_mode_tor[1]=0;
    pmp_state.pmp_mode_napot[1]=1;
    pmp_state.pmp_raw_addr[1]='h401;
    pmp_state.pmp_napot_mask[1]=1;
    addr='hffd;
    size_m1=15;
    #1;
    check(fault, "interior NAPOT entry was ignored");
    // A wrapping request can have both endpoints in TOR while crossing
    // its uncovered top-of-address-space gap.
    pmp_state.pmp_mode_off[0]=0;
    pmp_state.pmp_mode_tor[0]=1;
    pmp_state.pmp_raw_addr[0]='1;
    pmp_state.pmp_mode_tor[1]=0;
    pmp_state.pmp_mode_napot[1]=1;
    pmp_state.pmp_raw_addr[1]='1;
    pmp_state.pmp_napot_mask[1]='1;
    addr=(XLEN'(1)<<`RAPT_PADDR_BITS)-XLEN'(9);
    size_m1=15;
    #1;
    check(fault, "wrapping partial TOR match was allowed");
    pmp_state.pmp_mode_tor[0]=0;
    pmp_state.pmp_mode_off[0]=1;
    #1;
    check(!fault, "full-space NAPOT failed wrapped byte coverage");
    $display("PASS: PMP endpoint-size boundary checks passed");
    $finish;
  end
endmodule
