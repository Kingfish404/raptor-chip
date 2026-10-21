`include "rapt.svh"
`include "rapt_if.svh"
module tb_registered_store_drain;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = 4;
  localparam logic [XLEN-1:0] Base = XLEN'('h80001000);
  `include "tb_lsu_harness.svh"
  integer cycles = 0;
  always @(posedge clock) if (!reset) cycles <= cycles + 1;

  task automatic allocate(input int n, input bit split = 0);
    exu_ioq_bcast = '0;
    exu_ioq_bcast.valid = 1;
    exu_ioq_bcast.wen = 1;
    exu_ioq_bcast.dest = rapt_pkg::rob_index_t'(n);
    exu_ioq_bcast.tval = Base + XLEN'(n * 64 + int'(split));
    exu_ioq_bcast.sq_waddr = exu_ioq_bcast.tval;
    exu_ioq_bcast.sq_wdata = split ? XLEN'(64'h0123456789abcdef) : XLEN'(n + 1);
    exu_ioq_bcast.sq_wdata64 = 64'h0123456789abcdef;
    exu_ioq_bcast.sq_fp64 = split;
    exu_ioq_bcast.alu = split ? {1'b0, `RAPT_SD_WSTRB}
        : XLEN == 64 ? {1'b0, `RAPT_SD_WSTRB} : {1'b0, `RAPT_SW_WSTRB};
    sq_waddr_hi = (exu_ioq_bcast.tval & ~XLEN'(XLEN / 8 - 1)) + XLEN'(XLEN / 8);
    sq_waddr_third = sq_waddr_hi + XLEN'(XLEN / 8);
    tick(1);
    exu_ioq_bcast = '0;
  endtask

  task automatic commit_store(input int n, input bit split = 0);
    rou_lsu.dest = rapt_pkg::rob_index_t'(n);
    rou_lsu.sq_vaddr = Base + XLEN'(n * 64 + int'(split));
    rou_lsu.valid = 1;
    rou_lsu.store = 1;
    tick(1);
    rou_lsu.valid = 0;
    rou_lsu.store = 0;
  endtask

  initial begin
    automatic int begin_cycle;
    init_lsu_inputs(1, 0, 0);
    tick(3);
    reset = 0;
    tick(1);
    for (int n = 0; n < 4; n++) allocate(n);
    for (int n = 0; n < 4; n++) commit_store(n);
    begin_cycle = cycles;
    lsu_l1d.wready = 1;
    for (int n = 0; n < 4; n++) begin
      #1;
      check(
          lsu_l1d.wvalid && lsu_l1d.waddr == Base + XLEN'(n * 64) && lsu_l1d.wdata == XLEN'(n + 1),
          "back-to-back drain inserted a bubble or wrong owner");
      check(lsu_l1d.wmore == (n < 3), "registered wmore lost the following owner");
      tick(1);
    end
    check(rou_lsu.sq_empty && cycles - begin_cycle == 4,
          "four stores did not drain in four cycles");
    lsu_l1d.wready = 0;
    allocate(4, 1);
    commit_store(4, 1);
    begin_cycle = cycles;
    lsu_l1d.wready = 1;
    for (int beat = 0; beat < (XLEN == 32 ? 3 : 2); beat++) begin
      #1;
      check(lsu_l1d.wvalid && !rou_lsu.sq_empty,
            "split beat inserted a bubble or released ownership");
      tick(1);
    end
    check(rou_lsu.sq_empty, "split owner survived its final response");
    $display("PASS: registered drain XLEN=%0d single=4/4 cycles split=%0d cycles", XLEN,
             cycles - begin_cycle);
    $finish;
  end
endmodule
