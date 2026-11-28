`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

module tb_clint_multihart;
  localparam int XLEN = `RAPT_XLEN;
  localparam int NHARTS = 4;
  localparam logic [XLEN-1:0] MsipBase = `RAPT_CLINT_MSIP;
  localparam logic [XLEN-1:0] MtimecmpBase = `RAPT_CLINT_MTIMECMP;
  localparam logic [XLEN-1:0] MtimeAddr = `RAPT_BUS_RTC_ADDR;

  logic clock = 1'b0;
  logic reset = 1'b1;

  clint_bus_if #(
      .XLEN  (XLEN),
      .NHARTS(NHARTS)
  ) clint_bus ();

  rapt_clint #(
      .XLEN     (XLEN),
      .MTIME_DIV(1),
      .NHARTS   (NHARTS)
  ) dut (
      .clock    (clock),
      .reset    (reset),
      .clint_bus(clint_bus)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"

  task automatic write_reg(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] data,
                           input logic [XLEN/8-1:0] wstrb);
    begin
      clint_bus.awaddr = addr;
      clint_bus.wdata  = data;
      clint_bus.wstrb  = wstrb;
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

  task automatic write64(input logic [XLEN-1:0] addr, input logic [63:0] data);
    begin
      if (XLEN == 64) begin
        write_reg(addr, data, 8'hff);
      end else begin
        write_reg(addr + XLEN'(4), data[63:32], 4'hf);
        write_reg(addr, data[31:0], 4'hf);
      end
    end
  endtask

  initial begin
    logic [XLEN-1:0] rdata;
    logic [63:0] base_mtime;

    clint_bus.araddr = '0;
    clint_bus.awaddr = '0;
    clint_bus.wdata  = '0;
    clint_bus.wstrb  = '0;
    clint_bus.wvalid = 1'b0;

    tick(2);
    reset = 1'b0;
    tick(1);

    check(clint_bus.sw_int == 4'b0000, "sw_int non-zero after reset");
    check(clint_bus.timer_int == 4'b0000, "timer_int non-zero after reset");

    // 1. Per-hart 32-bit MSIP writes & readbacks
    for (int h = 0; h < NHARTS; h++) begin
      write_reg(MsipBase + XLEN'(h * 4), XLEN'(1), {{(XLEN / 8 - 4) {1'b0}}, 4'hf});
      check(clint_bus.sw_int[h] == 1'b1, "msip[h] did not assert sw_int[h]");
      for (int o = 0; o < NHARTS; o++) begin
        if (o != h) check(clint_bus.sw_int[o] == 1'b0, "msip[h] aliased to another hart");
      end
      read_reg(MsipBase + XLEN'(h * 4), rdata);
      check(rdata[31:0] == 32'd1, "msip[h] readback mismatch");
      write_reg(MsipBase + XLEN'(h * 4), XLEN'(0), {{(XLEN / 8 - 4) {1'b0}}, 4'hf});
      check(clint_bus.sw_int == 4'b0000, "msip[h] clear failed");
    end

    // 2. RV64 paired 64-bit write to msip[0] and msip[1] simultaneously
    if (XLEN == 64) begin
      write_reg(MsipBase, 64'h0000_0001_0000_0001, 8'hff);
      check(clint_bus.sw_int == 4'b0011, "64-bit paired msip[0..1] write failed");
      read_reg(MsipBase, rdata);
      check(rdata == 64'h0000_0001_0000_0001, "64-bit paired msip[0..1] readback failed");
      write_reg(MsipBase, 64'h0, 8'hff);
      check(clint_bus.sw_int == 4'b0000, "64-bit paired msip[0..1] clear failed");
    end

    // 3. Per-hart mtimecmp deadlines against shared mtime
    base_mtime = clint_bus.mtime_value;
    write64(MtimecmpBase + XLEN'(0 * 8), base_mtime + 64'd20);
    write64(MtimecmpBase + XLEN'(1 * 8), base_mtime + 64'd30);
    write64(MtimecmpBase + XLEN'(2 * 8), base_mtime + 64'd40);
    write64(MtimecmpBase + XLEN'(3 * 8), base_mtime + 64'd50);

    while (clint_bus.mtime_value < base_mtime + 64'd20) tick(1);
    check(clint_bus.timer_int == 4'b0001, "hart 0 timer did not fire first");
    while (clint_bus.mtime_value < base_mtime + 64'd30) tick(1);
    check(clint_bus.timer_int == 4'b0011, "hart 1 timer did not fire second");
    while (clint_bus.mtime_value < base_mtime + 64'd40) tick(1);
    check(clint_bus.timer_int == 4'b0111, "hart 2 timer did not fire third");
    while (clint_bus.mtime_value < base_mtime + 64'd50) tick(1);
    check(clint_bus.timer_int == 4'b1111, "hart 3 timer did not fire fourth");

    // 4. Shared mtime write clears all timers when moved backwards
    write64(MtimeAddr, base_mtime);
    check(clint_bus.timer_int == 4'b0000, "moving shared mtime backwards did not clear timers");

    $display("PASS: multi-hart CLINT (NHARTS=%0d, XLEN=%0d)", NHARTS, XLEN);
    $finish;
  end
endmodule
