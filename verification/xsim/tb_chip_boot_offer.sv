`include "rapt_soc_if.svh"
`timescale 1ns / 1ps

module tb_chip_boot_offer;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1, core_reset = 0;
  always #5 clock = !clock;
  axi4_if #(.XLEN(XLEN)) bus ();
  axi4_if #(.XLEN(XLEN)) backend ();
  wire flash_mode, enable;
  rapt_chip_boot #(
      .XLEN(XLEN)
  ) dut (
      .clock,
      .reset,
      .core_reset_i(core_reset),
      .backend_idle_i(1'b1),
      .flash_mode_o(flash_mode),
      .enable_o(enable),
      .axi(bus),
      .backend
  );

  task automatic tick;
    @(posedge clock);
    #1;
  endtask

  task automatic chip_reset;
    @(negedge clock);
    reset = 1;
    core_reset = 0;
    bus.arvalid = 0;
    bus.awvalid = 0;
    bus.wvalid = 0;
    bus.rready = 1;
    bus.bready = 1;
    backend.arready = 0;
    backend.awready = 0;
    backend.wready = 0;
    backend.rvalid = 0;
    backend.bvalid = 0;
    repeat (3) tick();
    @(negedge clock);
    reset = 0;
  endtask

  task automatic finish_control_write(input logic [1:0] expected_response);
    do @(posedge clock); while (!bus.awready);
    @(negedge clock);
    bus.awvalid = 0;
    bus.wvalid = 1;
    do @(posedge clock); while (!bus.wready);
    @(negedge clock);
    bus.wvalid = 0;
    do @(posedge clock); while (!bus.bvalid);
    if (bus.bresp != expected_response) $fatal(1, "Control response %h", bus.bresp);
    @(negedge clock);
  endtask

  task automatic request_bridge;
    @(negedge clock);
    bus.awaddr = XLEN'(32'h00100808);
    bus.awvalid = 1;
    bus.wdata = 0;
    finish_control_write(0);
    if (dut.requested_q != 0 || !flash_mode) $fatal(1, "Selection applied before reset");
  endtask

  task automatic await_bridge;
    while (flash_mode || !enable) tick();
    if (dut.active_q != 0) $fatal(1, "Reset snapshot lost");
  endtask

  initial begin
    bus.araddr = XLEN'(32'h30000000);
    bus.arid = 1;
    bus.arlen = 0;
    bus.arsize = 2;
    bus.arburst = 1;
    bus.arcache = 0;
    bus.awaddr = XLEN'(32'h00100808);
    bus.awid = 2;
    bus.awlen = 0;
    bus.awsize = 2;
    bus.awburst = 1;
    bus.awcache = 0;
    bus.wdata = 0;
    bus.wstrb = (XLEN / 8)'(15);
    bus.wlast = 1;
    backend.rid = 1;
    backend.rdata = XLEN'(32'h12345678);
    backend.rresp = 0;
    backend.rlast = 1;
    backend.bid = 2;
    backend.bresp = 0;

    chip_reset();
    request_bridge();
    // A local read leaves write preferred, so a late AW would otherwise
    // displace the following stalled external AR even without a reset.
    @(negedge clock);
    bus.araddr = XLEN'(32'h00100808);
    bus.arvalid = 1;
    do @(posedge clock); while (!bus.arready);
    @(negedge clock);
    bus.arvalid = 0;
    do @(posedge clock); while (!bus.rvalid);
    if (bus.rdata != XLEN'(32'h00030000)) $fatal(1, "Pending control lost");
    @(negedge clock);
    bus.araddr = XLEN'(32'h30000000);
    bus.arvalid = 1;
    tick();
    if (!backend.arvalid) $fatal(1, "Read not offered");
    @(negedge clock);
    bus.awvalid = 1;
    repeat (2) begin
      tick();
      if (!backend.arvalid || bus.awready) $fatal(1, "Late AW displaced stalled AR");
    end
    @(negedge clock);
    core_reset = 1;
    repeat (4) begin
      tick();
      if (!backend.arvalid || backend.araddr != XLEN'(32'h30000000)
          || backend.arid != 1 || bus.awready || !flash_mode || !enable)
        $fatal(1, "Stalled AR changed under competing AW/reset");
    end
    @(negedge clock);
    backend.arready = 1;
    @(posedge clock);
    if (!bus.arready) $fatal(1, "Read not accepted");
    @(negedge clock);
    bus.arvalid = 0;
    backend.arready = 0;
    backend.rvalid = 1;
    bus.rready = 0;
    repeat (3) begin
      tick();
      if (!flash_mode || !enable || !bus.rvalid || bus.awready)
        $fatal(1, "Backend switched before stalled R completed");
    end
    @(negedge clock);
    bus.rready = 1;
    @(posedge clock);
    if (bus.rdata != XLEN'(32'h12345678)) $fatal(1, "Read data lost");
    @(negedge clock);
    backend.rvalid = 0;
    // The competing local AW stays valid through the switch and is rejected
    // while reset is held; it must not steal or cancel the earlier AR offer.
    finish_control_write(2);
    await_bridge();

    chip_reset();
    request_bridge();
    @(negedge clock);
    bus.awaddr = XLEN'(32'h30001000);
    bus.awvalid = 1;
    bus.wdata = XLEN'(32'h87654321);
    bus.wvalid = 1;
    tick();
    if (!backend.awvalid) $fatal(1, "Write not offered");
    @(negedge clock);
    bus.araddr = XLEN'(32'h00100808);
    bus.arvalid = 1;
    repeat (2) begin
      tick();
      if (!backend.awvalid || bus.arready) $fatal(1, "Late AR displaced stalled AW");
    end
    @(negedge clock);
    core_reset = 1;
    repeat (4) begin
      tick();
      if (!backend.awvalid || backend.awaddr != XLEN'(32'h30001000)
          || backend.awid != 2 || bus.arready || !flash_mode || !enable)
        $fatal(1, "Stalled AW changed under competing AR/reset");
    end
    @(negedge clock);
    backend.awready = 1;
    @(posedge clock);
    if (!bus.awready) $fatal(1, "Write not accepted");
    @(negedge clock);
    bus.awvalid = 0;
    backend.awready = 0;
    backend.wready = 1;
    @(posedge clock);
    if (!backend.wvalid || backend.wdata != XLEN'(32'h87654321)) $fatal(1, "Write data lost");
    @(negedge clock);
    bus.wvalid = 0;
    backend.wready = 0;
    backend.bvalid = 1;
    bus.bready = 0;
    repeat (3) begin
      tick();
      if (!flash_mode || !enable || !bus.bvalid || bus.arready)
        $fatal(1, "Backend switched before stalled B completed");
    end
    @(negedge clock);
    bus.bready = 1;
    @(posedge clock);
    @(negedge clock);
    backend.bvalid = 0;
    do @(posedge clock); while (!bus.arready);
    @(negedge clock);
    bus.arvalid = 0;
    do @(posedge clock); while (!bus.rvalid);
    if (bus.rresp != 0 || bus.rdata != 0) $fatal(1, "Queued local read lost active control");
    await_bridge();
    $display("PASS: boot router holds stalled AR/AW through arbitration/reset XLEN=%0d", XLEN);
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "Boot offer test timeout");
  end
endmodule
