`timescale 1ns / 1ps
`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"
module tb_sample_bridge;
  logic clk = 0, reset = 1;
  always #5 clk = ~clk;
  axi4_if host ();
  axi4_if cpu ();
  axi4_if mem ();
  axi4_if ddr ();
  rapt_sample_if sample ();
  logic cpu_reset, bus_idle;
  assign sample.quiescent = sample.halt_req;
  assign sample.restore_fire = 0;
  assign sample.gpr_data = 64'hf00d;
  rapt_sample_bridge #(
      .RamBytes(262144),
      .BuildId(128'h123456789abcdef0)
  ) dut (
      .clk,
      .reset,
      .bus_idle,
      .writeback_error(1'b0),
      .cpu_reset,
      .host,
      .cpu,
      .mem,
      .sample
  );
  rapt_native_bus #(
      .RamBytes(262144),
      .RomFile("")
  ) bus (
      .clk,
      .reset,
      .uart_rx(1'b1),
      .uart_tx(),
      .uart_irq(),
      .peripheral_rd(),
      .peripheral_wr(),
      .peripheral_raddr(),
      .peripheral_waddr(),
      .peripheral_wdata(),
      .peripheral_wstrb(),
      .peripheral_rdata(32'b0),
      .idle_o(bus_idle),
      .cpu(mem),
      .ddr
  );
  assign ddr.awready = '0;
  assign ddr.wready = '0;
  assign ddr.bid = '0;
  assign ddr.bresp = '0;
  assign ddr.bvalid = '0;
  assign ddr.arready = '0;
  assign ddr.rid = '0;
  assign ddr.rdata = '0;
  assign ddr.rresp = '0;
  assign ddr.rlast = '0;
  assign ddr.rvalid = '0;

  task automatic write_word(input bit h, input logic [63:0] addr, data,
                            input logic [1:0] expected = 0);
    @(negedge clk);
    if (h) begin
      host.awaddr = addr;
      host.awvalid = 1;
    end else begin
      cpu.awaddr = addr;
      cpu.awvalid = 1;
    end
    do @(posedge clk); while (!(h ? host.awready : cpu.awready));
    @(negedge clk);
    if (h) begin
      host.awvalid = 0;
      host.wdata = data;
      host.wvalid = 1;
    end else begin
      cpu.awvalid = 0;
      cpu.wdata = data;
      cpu.wvalid = 1;
    end
    do @(posedge clk); while (!(h ? host.wready : cpu.wready));
    @(negedge clk);
    if (h) host.wvalid = 0;
    else cpu.wvalid = 0;
    wait (h ? host.bvalid : cpu.bvalid);
    repeat (3) @(negedge clk);
    if ((h ? host.bresp : cpu.bresp) != expected) $fatal(1, "Wrong B response");
    if (h) host.bready = 1;
    else cpu.bready = 1;
    @(negedge clk);
    if (h) host.bready = 0;
    else cpu.bready = 0;
  endtask

  task automatic read_word(input logic [63:0] addr, output logic [63:0] data,
                           input logic [1:0] expected = 0, input bit h = 1);
    @(negedge clk);
    if (h) begin
      host.araddr = addr;
      host.arvalid = 1;
    end else begin
      cpu.araddr = addr;
      cpu.arvalid = 1;
    end
    do @(posedge clk); while (!(h ? host.arready : cpu.arready));
    @(negedge clk);
    if (h) host.arvalid = 0;
    else cpu.arvalid = 0;
    wait (h ? host.rvalid : cpu.rvalid);
    data = h ? host.rdata : cpu.rdata;
    repeat (3) @(negedge clk);
    if (!(h ? host.rvalid : cpu.rvalid) || (h ? host.rdata : cpu.rdata) != data ||
        (h ? host.rresp : cpu.rresp) != expected || !(h ? host.rlast : cpu.rlast))
      $fatal(1, "Read response was not held under backpressure");
    if (h) host.rready = 1;
    else cpu.rready = 1;
    @(negedge clk);
    if (h) host.rready = 0;
    else cpu.rready = 0;
  endtask

  initial begin
    logic [63:0] value;
    host.awvalid = 0;
    host.awaddr = 0;
    host.awid = 0;
    host.awlen = 0;
    host.awsize = 3;
    host.awburst = 1;
    host.awcache = 0;
    host.wvalid = 0;
    host.wdata = 0;
    host.wstrb = '1;
    host.wlast = 1;
    host.bready = 0;
    host.arvalid = 0;
    host.araddr = 0;
    host.arid = 0;
    host.arlen = 0;
    host.arsize = 3;
    host.arburst = 1;
    host.arcache = 0;
    host.rready = 0;
    cpu.awvalid = 0;
    cpu.awaddr = 0;
    cpu.awid = 0;
    cpu.awlen = 0;
    cpu.awsize = 3;
    cpu.awburst = 1;
    cpu.awcache = 0;
    cpu.wvalid = 0;
    cpu.wdata = 0;
    cpu.wstrb = '1;
    cpu.wlast = 1;
    cpu.bready = 0;
    cpu.arvalid = 0;
    cpu.araddr = 0;
    cpu.arid = 0;
    cpu.arlen = 0;
    cpu.arsize = 3;
    cpu.arburst = 1;
    cpu.arcache = 0;
    cpu.rready = 0;
    sample.count = 0;
    sample.mret = 0;
    for (int c = 0; c < rapt_pkg::CommitWidth; c++) sample.pc[c] = 0;
    repeat (4) @(negedge clk);
    reset = 0;
    repeat (8) @(negedge clk);
    read_word(64'h1f000000, value);
    if (value != 64'h5250545300010001) $fatal(1, "Bad replay ABI");
    read_word(64'h1f0000b0, value);
    if (value != 64'h123456789abcdef0) $fatal(1, "Bad build identity");
    write_word(1, 64'h80000000, 64'h123456789abcdef0);
    read_word(64'h80000000, value);
    if (value != 64'h123456789abcdef0) $fatal(1, "Host RAM load/readback failed");
    write_word(1, 64'h1f0000a0, 1);
    do read_word(64'h1f0000a0, value); while (value[1]);
    if (!value[2] || value[3]) $fatal(1, "Zero DMA did not finish correctly");
    read_word(64'h80000000, value);
    if (value != 0) $fatal(1, "DMA did not clear first word");
    read_word(64'h8003fff8, value);
    if (value != 0) $fatal(1, "DMA did not clear last word");
    write_word(1, 64'h1f000010, 0);
    write_word(1, 64'h1f000018, 128);
    write_word(1, 64'h1f000020, 64'h80001000);
    write_word(1, 64'h1f000028, 64'h0f000244);
    write_word(1, 64'h1f000008, 1);
    if (cpu_reset) $fatal(1, "Hart did not start");
    read_word(64'h80000000, value, 2'b11);
    write_word(1, 64'h80000000, 0, 2'b10);
    write_word(0, 64'h80001000, 64'habcdef);
    write_word(0, 64'h80002000, 64'h987654);
    write_word(0, 64'h8003f000, 64'h112233);
    write_word(1, 64'h1f000008, 2);
    repeat (10) @(negedge clk);
    read_word(64'h1f000080, value);
    if (value != 64'hf00d) $fatal(1, "Halted GPR read failed");
    write_word(1, 64'h1f000008, 3);
    repeat (10) @(negedge clk);
    if (!cpu_reset) $fatal(1, "Drain/reset did not complete");
    read_word(64'h80001000, value);
    if (value != 64'habcdef) $fatal(1, "CPU memory owner lost data");
    read_word(64'h1f010000, value);
    if (value != ((64'b1 << 1) | (64'b1 << 2) | (64'b1 << 63)))
      $fatal(1, "Dirty bitmap missed pages or counted host writes: %h", value);
    write_word(1, 64'h1f0000a0, 2);
    repeat (10) @(negedge clk);
    read_word(64'h1f010000, value);
    if (value != 0) $fatal(1, "Dirty bitmap clear failed");
    // A restored Linux 8250 timer may access quiet control/status registers.
    // Neither RBR/THR traffic nor NIC activity is admitted by this scope.
    for (int kind = 0; kind < 2; kind++) begin
      write_word(1, 64'h1f000008, 1);
      @(negedge clk);
      sample.pc[0] = 64'h0f000244;
      sample.count = 1;
      sample.mret = 1;
      @(negedge clk);
      sample.pc[0] = 64'h80001000;
      sample.mret = 0;
      @(negedge clk);
      sample.count = 0;
      cpu.arsize = 0;
      cpu.awsize = 0;
      read_word(64'h10000001, value, 0, 0);
      write_word(0, 64'h10000001, 0);
      read_word(64'h10000002, value, 0, 0);
      read_word(64'h10000005, value, 0, 0);
      read_word(64'h1f000090, value);
      if (value != 0) $fatal(1, "Quiet UART timer access was rejected");
      read_word(kind == 0 ? 64'h10000000 : 64'h18000000, value, kind == 0 ? 2'b00 : 2'b11, 0);
      repeat (10) @(negedge clk);
      read_word(64'h1f000090, value);
      if (value != 7) $fatal(1, "External data activity was not rejected");
      write_word(1, 64'h1f000008, 3);
      repeat (10) @(negedge clk);
      if (!cpu_reset) $fatal(1, "Device-scope error did not reset cleanly");
    end
    $display("PASS: host memory, zero DMA, ownership, backpressure, halt/reset, dirty pages");
    $finish;
  end
  initial begin
    #3000000;
    $fatal(1, "Sampling bridge timeout");
  end
endmodule
