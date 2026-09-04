`include "rapt.svh"
`include "rapt_if.svh"

module tb_lsu_cbo_zero;
  localparam int XLEN = 64;
  localparam int LsuTbSqSize = `RAPT_SQ_SIZE;
  localparam logic [63:0] TestAddr = 64'h0000_0000_8000_103d;
  localparam logic [63:0] BlockBase = 64'h0000_0000_8000_1000;

  `include "tb_lsu_harness.svh"

  initial begin
    init_lsu_inputs(1'b1, '0, '0);
    tick(4);
    reset = 1'b0;
    tick(1);

    // Allocate one unaligned-address CBO.ZERO.  The architectural operation
    // selects the containing cache block, not merely the addressed dword.
    exu_ioq_bcast.valid = 1'b1;
    exu_ioq_bcast.wen = 1'b1;
    exu_ioq_bcast.alu = {1'b0, `RAPT_CBO_ZERO_WALU};
    exu_ioq_bcast.dest = 6'd9;
    exu_ioq_bcast.tval = TestAddr;
    exu_ioq_bcast.sq_waddr = TestAddr;
    exu_ioq_bcast.sq_wdata = 64'hdead_beef_cafe_f00d;
    tick(1);
    exu_ioq_bcast.valid = 1'b0;
    exu_ioq_bcast.wen = 1'b0;

    rou_lsu.valid = 1'b1;
    rou_lsu.store = 1'b1;
    rou_lsu.alu = {1'b0, `RAPT_CBO_ZERO_WALU};
    rou_lsu.dest = 6'd9;
    rou_lsu.sq_waddr = TestAddr;
    rou_lsu.sq_vaddr = TestAddr;
    tick(1);
    rou_lsu.valid = 1'b0;
    rou_lsu.store = 1'b0;

    lsu_l1d.wready = 1'b1;
    for (int beat = 0; beat < 8; beat++) begin
      #1;
      check(lsu_l1d.wvalid, "CBO.ZERO omitted a cache-block write beat");
      check(lsu_l1d.waddr == BlockBase + 64'(beat * 8),
            "CBO.ZERO emitted an incorrect aligned beat address");
      check(lsu_l1d.walu == 8'hff, "CBO.ZERO beat was not a full dword store");
      check(lsu_l1d.wdata == 64'b0, "CBO.ZERO emitted nonzero data");
      tick(1);
    end

    #1;
    check(!lsu_l1d.wvalid, "CBO.ZERO emitted more than one 64-byte block");
    tick(2);
    check(dut.sq_all_empty, "CBO.ZERO did not release its SQ entry");

    $display("PASS: Zicboz clears exactly one 64-byte cache block");
    $finish;
  end
endmodule
