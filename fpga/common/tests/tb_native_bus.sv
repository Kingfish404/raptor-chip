`timescale 1ns / 1ps
`include "native_ddr_model.svh"

module tb_native_bus;
  localparam int X = `RAPT_XLEN;
  localparam int Bytes = X / 8;
  localparam int Size = $clog2(Bytes);
  logic clk = 0, reset = 1;
  always #5 clk = ~clk;
  axi4_if #(.XLEN(X)) cpu ();
  axi4_if #(.XLEN(X)) ddr ();
  rapt_native_bus #(
      .XLEN(X),
      .WithDdr(`NATIVE_DDR),
      .RomFile("")
  ) dut (
      .clk,
      .reset,
      .uart_rx(1'b1),
      .uart_tx(),
      .uart_irq(),
      .cpu,
      .ddr
  );
  native_ddr_model #(
      .XLEN(X),
      .InjectErrors(1)
  ) memory (
      .clk,
      .reset,
      .axi(ddr)
  );

  task automatic aw(input logic [X-1:0] addr, input int len, input int size = Size,
                    input int burst = 1);
    @(negedge clk);
    cpu.awaddr = addr;
    cpu.awlen = 8'(len);
    cpu.awsize = 3'(size);
    cpu.awburst = 2'(burst);
    cpu.awid = 9;
    cpu.awvalid = 1;
    do @(posedge clk); while (!cpu.awready);
    @(negedge clk);
    cpu.awvalid = 0;
  endtask

  task automatic w(input logic [X-1:0] data, input logic last, input logic [Bytes-1:0] mask = '1);
    @(negedge clk);
    cpu.wdata = data;
    cpu.wstrb = mask;
    cpu.wlast = last;
    cpu.wvalid = 1;
    do @(posedge clk); while (!cpu.wready);
    @(negedge clk);
    cpu.wvalid = 0;
  endtask

  task automatic b(input logic [1:0] response = 0);
    wait (cpu.bvalid);
    repeat (4) begin
      @(negedge clk);
      if (!cpu.bvalid || cpu.bid != 9 || cpu.bresp != response)
        $fatal(
            1, "B response/stall mismatch: id=%h resp=%h expected=%h", cpu.bid, cpu.bresp, response
        );
    end
    cpu.bready = 1;
    @(negedge clk);
    cpu.bready = 0;
  endtask

  task automatic ar(input logic [X-1:0] addr, input int len, input int size = Size,
                    input int burst = 1);
    @(negedge clk);
    cpu.araddr = addr;
    cpu.arlen = 8'(len);
    cpu.arsize = 3'(size);
    cpu.arburst = 2'(burst);
    cpu.arid = 6;
    cpu.arvalid = 1;
    do @(posedge clk); while (!cpu.arready);
    @(negedge clk);
    cpu.arvalid = 0;
  endtask

  task automatic r(input logic [X-1:0] expected, input logic last, input logic [1:0] response = 0,
                   input logic [X-1:0] mask = '1);
    wait (cpu.rvalid);
    repeat (3) begin
      @(negedge clk);
      if (!cpu.rvalid || cpu.rid != 6 || cpu.rlast != last || cpu.rresp != response ||
          (cpu.rdata & mask) != (expected & mask))
        $fatal(
            1,
            "R response/stall mismatch: data=%h expected=%h id=%h last=%b resp=%h",
            cpu.rdata,
            expected,
            cpu.rid,
            cpu.rlast,
            cpu.rresp
        );
    end
    cpu.rready = 1;
    @(negedge clk);
    cpu.rready = 0;
  endtask

  initial begin
    cpu.awvalid = 0;
    cpu.wvalid = 0;
    cpu.bready = 0;
    cpu.arvalid = 0;
    cpu.rready = 0;
    cpu.awcache = 0;
    cpu.arcache = 0;
    repeat (5) @(negedge clk);
    reset = 0;
    // W can precede AW; the slave must backpressure without losing it.
    cpu.wvalid = 1;
    cpu.wdata = X'('h12345678);
    cpu.wstrb = '1;
    cpu.wlast = 1;
    repeat (3) begin
      @(negedge clk);
      if (cpu.wready) $fatal(1, "accepted W before AW");
    end
    aw('h80000000, 0);
    do @(posedge clk); while (!cpu.wready);
    @(negedge clk);
    cpu.wvalid = 0;
    b();
    ar('h80000000, 0);
    r(X'('h12345678), 1);

    aw('h80000100, 3);
    for (int i = 0; i < 4; i++) w(X'(64'h1234567887650000 + i), i == 3);
    b();
    ar('h80000100, 3);
    for (int i = 0; i < 4; i++) r(X'(64'h1234567887650000 + i), i == 3);
    // Byte stores in every lane must preserve neighboring bytes.
    aw('h80000200, 0);
    w(0, 1);
    b();
    for (int i = 0; i < Bytes; i++) begin
      aw(X'('h80000200 + i), 0, 0);
      w(X'(8'h80 + i) << (i * 8), 1, Bytes'(1) << i);
      b();
      ar(X'('h80000200 + i), 0, 0);
      r(X'(8'h80 + i) << (i * 8), 1, 0, X'(255) << (i * 8));
    end
    // Read and write channels progress independently.
    fork
      begin
        aw('h0f000000, 0);
        w(X'('hfeedcafe), 1);
        b();
      end
      begin
        ar('h80000100, 3);
        for (int i = 0; i < 4; i++) r(X'(64'h1234567887650000 + i), i == 3);
      end
    join
    ar('h0f000000, 0);
    r(X'('hfeedcafe), 1);
    aw('h20000000, 0);
    w('1, 1);
    b(2);
    ar('h20000000, 0);
    r(0, 1);
    aw('h40000000, 2);
    for (int i = 0; i < 3; i++) w('1, i == 2);
    b(3);
    ar('h40000000, 2);
    for (int i = 0; i < 3; i++) r(0, i == 2, 3);
    ar('h80000ffc, 1, 2);
    r(0, 0, 3);
    r(0, 1, 3);
    ar('h80000001, 0);
    r(X'('h12345678), 1, 0, ~X'(255));
    ar('h80000101, 3);
    for (int i = 0; i < 4; i++) r(X'(64'h1234567887650000 + i), i == 3);
    aw('h80000201, 1);
    w('1, 0, ~Bytes'(1));
    w(X'('habcd), 1);
    b();
    ar('h80000200, 1);
    r((~X'(255)) | X'('h80), 0);
    r(X'('habcd), 1);
    aw('h0f000100, 1, Size, 0);
    w(X'('habcd), 0);
    w(X'('h1234), 1);
    b();
    ar('h0f000100, 1, Size, 0);
    r(X'('h1234), 0);
    r(X'('h1234), 1);
    ar('h80000000, 0, Size + 1);
    r(0, 1, 3);
    ar('h80000000, 0, Size, 2);
    r(0, 1, 3);
    if (X == 64) begin
      ar(X'(64'h180000000), 0);
      r(0, 1, 3);
    end
    // UART scratch register occupies its correct AXI byte lane.
    aw('h10000007, 0, 0);
    w(X'(8'h5a) << (8 * (7 % Bytes)), 1, Bytes'(1) << (7 % Bytes));
    b();
    ar('h10000007, 0, 0);
    r(X'(8'h5a) << (8 * (7 % Bytes)), 1);
    if (`NATIVE_DDR) begin
      aw('h80010000, 0);
      w('1, 1);
      b(2);
      ar('h80010000, 0);
      r('1, 1, 2);
    end
    // Reset abandons local in-flight replies, and a new request can complete.
    ar('h0f000000, 0);
    wait (cpu.rvalid);
    @(negedge clk);
    reset = 1;
    repeat (3) @(negedge clk);
    reset = 0;
    ar('h0f000000, 0);
    r(X'('hfeedcafe), 1);
    $display("PASS native bus RV%0d DDR=%0d", X, `NATIVE_DDR);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "native bus watchdog");
  end
endmodule
