`timescale 1ns / 1ps

module tb_rapt_sram_1rw;
  rapt_pkg::sram_ctrl_t sram_ctrl = rapt_pkg::SramCtrlReset;
  logic clock = 1'b0;
  logic en = 1'b0;
  logic wen = 1'b0;
  logic [2:0] addr = '0;
  logic [31:0] rdata;
  logic [31:0] wdata = '0;
  logic [3:0] bwe = '0;

  always #5 clock = ~clock;

  rapt_sram_1rw #(
      .ADDR_WIDTH(3),
      .DATA_WIDTH(32),
      .USE_BWE(1)
  ) dut (
      .sram_ctrl_i(sram_ctrl),
      .clock,
      .en,
      .wen,
      .addr,
      .rdata,
      .wdata,
      .bwe
  );

  task automatic cycle;
    @(posedge clock);
    #1;
  endtask

  initial begin
    sram_ctrl = 16'h4567;
    #1;
`ifdef RAPT_USE_SRAM_MACRO
    if (dut.g_8x32.u_sram.ctrl !== sram_ctrl) $fatal(1, "1RW macro ctrl is disconnected");
`endif
    en = 1'b1;
    wen = 1'b1;
    addr = 3'd2;
    wdata = 32'h1122_3344;
    bwe = 4'b1111;
    cycle();

    wen = 1'b0;
    addr = 3'd2;
    cycle();
    assert (rdata == 32'h1122_3344)
    else $fatal(1, "synchronous read failed");

    en = 1'b0;
    addr = 3'd0;
    cycle();
    assert (rdata == 32'h1122_3344)
    else $fatal(1, "disabled read did not hold rdata");

    en = 1'b1;
    wen = 1'b1;
    addr = 3'd2;
    wdata = 32'haabb_ccdd;
    bwe = 4'b0101;
    cycle();
    assert (rdata == 32'h1122_3344)
    else $fatal(1, "write cycle did not hold rdata");

    wen = 1'b0;
    cycle();
    assert (rdata == 32'h11bb_33dd)
    else $fatal(1, "byte write enable failed");

    $display("PASS: rapt_sram_1rw synchronous-read contract");
    $finish;
  end
endmodule
