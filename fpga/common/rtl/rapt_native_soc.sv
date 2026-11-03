// axi4_if is supplied by the shared Raptor RTL compilation unit.

module rapt_native_soc #(
    parameter int XLEN = `RAPT_XLEN,
    parameter bit WithDdr = 0,
    parameter bit WithPeripheral = 0,
    parameter int RamBytes = 131072,
    parameter int ClockHz = 50_000_000,
    parameter string RomFile = "boot.hex"
) (
    input logic clk,
    input logic reset,
    input logic uart_rx,
    output logic uart_tx,
    output logic writeback_error,
    output logic peripheral_rd,
    peripheral_wr,
    output logic [15:0] peripheral_raddr,
    peripheral_waddr,
    output logic [31:0] peripheral_wdata,
    output logic [3:0] peripheral_wstrb,
    input logic [31:0] peripheral_rdata,
    input logic peripheral_irq,
`ifdef RAPT_SAMPLING
    axi4_if.slave replay,
`endif
    axi4_if.master ddr
);
  axi4_if #(.XLEN(XLEN)) cpu ();
  logic uart_irq;
  logic bus_idle;
  logic core_reset;
  logic [31:1] core_irq;
`ifdef RAPT_SAMPLING
  axi4_if #(.XLEN(XLEN)) memory_bus ();
  logic replay_reset;
  rapt_sample_if #(.XLEN(XLEN)) sample ();
  rapt_sample_bridge #(
      .XLEN(XLEN),
      .BuildId(`NATIVE_SOURCE_ID)
  ) sampling (
      .clk,
      .reset,
      .bus_idle,
      .writeback_error,
      .cpu_reset(replay_reset),
      .host(replay),
      .cpu,
      .mem(memory_bus),
      .sample
  );
  assign core_reset = reset || replay_reset;
  // Native captures use the virt UART's PLIC source 10.
  assign core_irq = {21'b0, uart_irq, 9'b0};
`else
  assign core_reset = reset;
  assign core_irq = {29'b0, WithPeripheral && peripheral_irq, uart_irq};
`endif
  rapt #(
      .XLEN(XLEN)
  ) core (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .clock(clk),
      .reset(core_reset),
`ifdef RAPT_SAMPLING
      .sample,
`endif
      .writeback_error_o(writeback_error),
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .io_interrupt(1'b0),
      .ext_irq_i(core_irq),
      .jtag_trst_n(1'b0),
      .jtag_tms(1'b1),
      .jtag_tdi(1'b0),
      .jtag_tdo(),
      .io_master_arcache(cpu.arcache),
      .io_master_arburst(cpu.arburst),
      .io_master_arsize(cpu.arsize),
      .io_master_arlen(cpu.arlen),
      .io_master_arid(cpu.arid),
      .io_master_araddr(cpu.araddr),
      .io_master_arvalid(cpu.arvalid),
      .io_master_arready(cpu.arready),
      .io_master_rid(cpu.rid),
      .io_master_rlast(cpu.rlast),
      .io_master_rdata(cpu.rdata),
      .io_master_rresp(cpu.rresp),
      .io_master_rvalid(cpu.rvalid),
      .io_master_rready(cpu.rready),
      .io_master_awcache(cpu.awcache),
      .io_master_awburst(cpu.awburst),
      .io_master_awsize(cpu.awsize),
      .io_master_awlen(cpu.awlen),
      .io_master_awid(cpu.awid),
      .io_master_awaddr(cpu.awaddr),
      .io_master_awvalid(cpu.awvalid),
      .io_master_awready(cpu.awready),
      .io_master_wlast(cpu.wlast),
      .io_master_wdata(cpu.wdata),
      .io_master_wstrb(cpu.wstrb),
      .io_master_wvalid(cpu.wvalid),
      .io_master_wready(cpu.wready),
      .io_master_bid(cpu.bid),
      .io_master_bresp(cpu.bresp),
      .io_master_bvalid(cpu.bvalid),
      .io_master_bready(cpu.bready)
  ,
      .jtag_tck_en(1'b1)
  );
  rapt_native_bus #(
      .XLEN(XLEN),
      .WithDdr(WithDdr),
      .WithPeripheral(WithPeripheral),
      .RamBytes(RamBytes),
      .ClockHz(ClockHz),
      .RomFile(RomFile)
  ) bus (
      .clk,
      .reset,
`ifdef RAPT_SAMPLING
      .uart_rx(1'b1),
`else
      .uart_rx,
`endif
      .uart_tx,
      .uart_irq,
      .peripheral_rd,
      .peripheral_wr,
      .peripheral_raddr,
      .peripheral_waddr,
      .peripheral_wdata,
      .peripheral_wstrb,
      .peripheral_rdata,
`ifdef RAPT_SAMPLING
      .cpu(memory_bus),
`else
      .cpu(cpu),
`endif
      .idle_o(bus_idle),
      .ddr
  );
endmodule
