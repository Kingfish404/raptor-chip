`timescale 1ns / 1ps

module tb_rapt_sram_2rw;
  rapt_pkg::sram_ctrl_t sram_ctrl = rapt_pkg::SramCtrlReset;
  logic clock = 0;
  logic a_en = 0, a_wen = 0, b_en = 0, b_wen = 0;
  logic [4:0] a_addr = 0, b_addr = 0;
  logic [63:0] a_wdata = 0, b_wdata = 0, a_rdata, b_rdata;
  always #5 clock = ~clock;

  rapt_sram_2rw dut (
      .sram_ctrl_i(sram_ctrl),
      .clock,
      .a_en,
      .a_wen,
      .a_addr,
      .a_wdata,
      .a_rdata,
      .b_en,
      .b_wen,
      .b_addr,
      .b_wdata,
      .b_rdata
  );

  task automatic cycle;
    @(posedge clock);
    #1;
  endtask

  initial begin
    if ($bits(sram_ctrl) != rapt_pkg::SramCtrlWidth || rapt_pkg::SramCtrlWidth != 16)
      $fatal(1, "SRAM control width mismatch");
    a_en = 1;
    b_en = 1;
    a_wen = 1;
    b_wen = 1;
    a_addr = 1;
    b_addr = 2;
    a_wdata = 64'h0123_4567_89ab_cdef;
    b_wdata = 64'hfedc_ba98_7654_3210;
    cycle();
    a_wen  = 0;
    b_wen  = 0;
    a_addr = 2;
    b_addr = 1;
    cycle();
    if (a_rdata !== b_wdata || b_rdata !== a_wdata) $fatal(1, "2RW shared storage read");
    a_en = 0;
    b_en = 0;
    // Arbitrary settings are safe only in these ideal functional models.
    sram_ctrl = 16'h4567;
    #1;
`ifdef RAPT_USE_SRAM_MACRO
    if (dut.g_32x64.u_sram.ctrl !== sram_ctrl) $fatal(1, "2RW macro ctrl is disconnected");
`endif
    cycle();
    if (a_rdata !== b_wdata || b_rdata !== a_wdata) $fatal(1, "2RW idle/control output hold");
    a_en = 1;
    a_wen = 1;
    a_addr = 3;
    a_wdata = 64'h0000_1111_2222_3333;
    cycle();
    if (a_rdata !== b_wdata) $fatal(1, "2RW write output hold");
    a_wen  = 0;
    b_en   = 1;
    b_addr = 2;
    cycle();
    if (a_rdata !== a_wdata || b_rdata !== b_wdata) $fatal(1, "2RW independent ports");
    $display("PASS: 2RW control forwarding, shared storage, independent ports and output hold");
    $finish;
  end
endmodule
