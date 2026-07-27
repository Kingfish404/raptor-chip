`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

module tb_plic_gateway;
  localparam int XLEN = 32;
  localparam logic [XLEN-1:0] PlicBase = 32'h0c00_0000;
  localparam logic [XLEN-1:0] Pending = PlicBase + 32'h0000_1000;
  localparam logic [XLEN-1:0] EnableM = PlicBase + 32'h0000_2000;
  localparam logic [XLEN-1:0] ThresholdM = PlicBase + 32'h0020_0000;
  localparam logic [XLEN-1:0] ClaimM = ThresholdM + 32'h4;

  logic clock = 1'b0;
  logic reset = 1'b1;
  plic_bus_if #(.XLEN(XLEN)) plic_bus();

  rapt_plic #(.XLEN(XLEN)) dut (
      .clock(clock),
      .reset(reset),
      .plic_bus(plic_bus)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"

  task automatic write_reg(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] data);
    begin
      plic_bus.awaddr = addr;
      plic_bus.wdata = data;
      plic_bus.wvalid = 1'b1;
      tick(1);
      plic_bus.wvalid = 1'b0;
    end
  endtask

  task automatic claim(output logic [XLEN-1:0] id);
    begin
      plic_bus.araddr = ClaimM;
      #1;
      id = plic_bus.rdata;
      plic_bus.ar_commit = 1'b1;
      tick(1);
      plic_bus.ar_commit = 1'b0;
    end
  endtask

  initial begin
    logic [XLEN-1:0] id;

    plic_bus.ext_irq = '0;
    plic_bus.araddr = '0;
    plic_bus.ar_commit = 1'b0;
    plic_bus.awaddr = '0;
    plic_bus.wdata = '0;
    plic_bus.wvalid = 1'b0;

    tick(2);
    reset = 1'b0;
    tick(1);

    write_reg(PlicBase + 32'h4, 32'd3);
    write_reg(PlicBase + 32'h8, 32'd3);
    write_reg(EnableM, 32'h0000_0006);
    write_reg(ThresholdM, 32'd0);

    // Equal-priority pending sources must claim the lowest source ID first.
    write_reg(Pending, 32'h0000_0006);
    claim(id);
    check(id == 32'd1, "equal-priority tie did not select the lowest source ID");
    write_reg(ClaimM, id);
    claim(id);
    check(id == 32'd2, "second pending source was not claimable");
    write_reg(ClaimM, id);

    // A level request is consumed once and cannot pass its gateway again
    // until software completes the claimed ID.
    plic_bus.ext_irq[1] = 1'b1;
    tick(2);
    claim(id);
    check(id == 32'd1, "level request did not become claimable");
    tick(3);
    plic_bus.araddr = Pending;
    #1;
    check(!plic_bus.rdata[1], "level request re-pended before completion");

    // Completing another ID must not reopen source 1's gateway.
    write_reg(ClaimM, 32'd2);
    tick(2);
    check(!plic_bus.rdata[1], "wrong completion ID reopened the gateway");

    // Completing source 1 reopens its gateway. Because the input remains
    // asserted, a fresh request must become pending.
    write_reg(ClaimM, 32'd1);
    tick(2);
    check(plic_bus.rdata[1], "held level request did not re-pend after completion");

    // Once the device deasserts, claim+complete must leave the source idle.
    plic_bus.ext_irq[1] = 1'b0;
    claim(id);
    check(id == 32'd1, "re-pended level request returned the wrong ID");
    write_reg(ClaimM, id);
    tick(3);
    plic_bus.araddr = Pending;
    #1;
    check(!plic_bus.rdata[1], "deasserted source remained pending after completion");

    // Priority equal to threshold is not deliverable; strictly greater is.
    write_reg(Pending, 32'h0000_0002);
    write_reg(ThresholdM, 32'd3);
    tick(2);
    check(!plic_bus.meip[0], "priority equal to threshold asserted MEIP");
    write_reg(ThresholdM, 32'd2);
    tick(2);
    check(plic_bus.meip[0], "priority above threshold did not assert MEIP");

    $display("PASS: PLIC gateway, claim/complete, priority, and threshold semantics");
    $finish;
  end
endmodule
