`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

module tb_clint;
  localparam int XLEN = 32;
  localparam logic [XLEN-1:0] Msip = 32'h0200_0000;
  localparam logic [XLEN-1:0] Mtimecmp = 32'h0200_4000;
  localparam logic [XLEN-1:0] Mtime = 32'h0200_bff8;

  logic clock = 1'b0;
  logic reset = 1'b1;
  clint_bus_if #(.XLEN(XLEN)) clint_bus();

  rapt_clint #(
      .XLEN(XLEN),
      .MTIME_DIV(3)
  ) dut (
      .clock(clock),
      .reset(reset),
      .clint_bus(clint_bus)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"

  task automatic write_reg(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] data);
    begin
      clint_bus.awaddr = addr;
      clint_bus.wdata = data;
      clint_bus.wvalid = 1'b1;
      tick(1);
      clint_bus.wvalid = 1'b0;
    end
  endtask

  task automatic read_reg(input logic [XLEN-1:0] addr, output logic [XLEN-1:0] data);
    begin
      clint_bus.araddr = addr;
      #1;
      data = clint_bus.rdata;
    end
  endtask

  initial begin
    logic [XLEN-1:0] data;
    logic [63:0] deadline;

    clint_bus.araddr = '0;
    clint_bus.awaddr = '0;
    clint_bus.wdata = '0;
    clint_bus.wvalid = 1'b0;

    tick(2);
    reset = 1'b0;
    read_reg(Mtime, data);
    check(data == 32'd0, "mtime was not zero after reset");
    tick(2);
    read_reg(Mtime, data);
    check(data == 32'd0, "mtime advanced before MTIME_DIV cycles");
    tick(1);
    read_reg(Mtime, data);
    check(data == 32'd1, "mtime did not advance on MTIME_DIV boundary");

    write_reg(Mtimecmp + 32'd4, 32'h1234_5678);
    write_reg(Mtimecmp, 32'h9abc_def0);
    read_reg(Mtimecmp, data);
    check(data == 32'h9abc_def0, "mtimecmp low-half readback mismatch");
    read_reg(Mtimecmp + 32'd4, data);
    check(data == 32'h1234_5678, "mtimecmp high-half readback mismatch");
    check(!clint_bus.timer_int, "future mtimecmp asserted timer interrupt");

    deadline = dut.mtime + 64'd3;
    write_reg(Mtimecmp + 32'd4, 32'hffff_ffff);
    write_reg(Mtimecmp, deadline[31:0]);
    write_reg(Mtimecmp + 32'd4, deadline[63:32]);
    while (dut.mtime < deadline) begin
      check(!clint_bus.timer_int, "timer interrupt asserted before mtimecmp");
      tick(1);
    end
    check(clint_bus.timer_int, "timer interrupt did not assert at mtimecmp");

    write_reg(Mtimecmp + 32'd4, 32'hffff_ffff);
    check(!clint_bus.timer_int, "moving mtimecmp forward did not clear timer interrupt");

    write_reg(Msip, 32'd1);
    check(clint_bus.sw_int, "MSIP write did not assert software interrupt");
    read_reg(Msip, data);
    check(data == 32'd1, "MSIP readback mismatch");
    write_reg(Msip, 32'd0);
    check(!clint_bus.sw_int, "clearing MSIP did not clear software interrupt");

    $display("PASS: CLINT divider, mtimecmp, timer boundary, and MSIP semantics");
    $finish;
  end
endmodule
