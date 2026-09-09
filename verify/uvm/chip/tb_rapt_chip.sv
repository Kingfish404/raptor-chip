`timescale 1ns/1ps
module tb_rapt_chip;
  import uvm_pkg::*;
  import rapt_chip_pkg::*;
  bit clock = 0;
  always #5 clock = ~clock;
  rapt_chip_if bus(clock);
  rapt dut (
    .clock(clock), .reset(bus.reset),
    .io_master_arcache(bus.arcache),
    .io_master_arburst(bus.arburst),
    .io_master_arsize(bus.arsize),
    .io_master_arlen(bus.arlen),
    .io_master_arid(bus.arid),
    .io_master_araddr(bus.araddr),
    .io_master_arvalid(bus.arvalid),
    .io_master_arready(bus.arready),
    .io_master_rid(bus.rid),
    .io_master_rlast(bus.rlast),
    .io_master_rdata(bus.rdata),
    .io_master_rresp(bus.rresp),
    .io_master_rvalid(bus.rvalid),
    .io_master_rready(bus.rready),
    .io_master_awcache(bus.awcache),
    .io_master_awburst(bus.awburst),
    .io_master_awsize(bus.awsize),
    .io_master_awlen(bus.awlen),
    .io_master_awid(bus.awid),
    .io_master_awaddr(bus.awaddr),
    .io_master_awvalid(bus.awvalid),
    .io_master_awready(bus.awready),
    .io_master_wlast(bus.wlast),
    .io_master_wdata(bus.wdata),
    .io_master_wstrb(bus.wstrb),
    .io_master_wvalid(bus.wvalid),
    .io_master_wready(bus.wready),
    .io_master_bid(bus.bid),
    .io_master_bresp(bus.bresp),
    .io_master_bvalid(bus.bvalid),
    .io_master_bready(bus.bready),
    .io_interrupt(bus.io_interrupt), .ext_irq_i(bus.ext_irq),
    .jtag_trst_n(bus.jtag_trst_n), .jtag_tms(bus.jtag_tms),
    .jtag_tdi(bus.jtag_tdi), .jtag_tdo(bus.jtag_tdo),
    .external_write_valid_i(bus.external_write_valid),
    .external_write_pending_i(bus.external_write_pending),
    .external_write_first_i(bus.external_write_first),
    .external_write_last_i(bus.external_write_last)
  );
  initial begin
    uvm_config_db#(virtual rapt_chip_if)::set(null, "*", "vif", bus);
    run_test("chip_test");
  end
endmodule
