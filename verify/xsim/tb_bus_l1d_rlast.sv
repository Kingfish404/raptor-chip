`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"

module tb_bus_l1d_rlast;
  localparam int XLEN = 32;
  localparam int IdW = 4;

  logic clock = 1'b0;
  logic reset = 1'b1;

  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) axi ();
  mem_link_if #(.XLEN(XLEN), .ID_W(IdW)) mem ();

  l1i_bus_if #(.XLEN(XLEN)) l1i_bus ();
  l1d_bus_if #(.XLEN(XLEN)) l1d_bus ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  cmu_bcast_if #(.XLEN(XLEN)) cmu_bcast ();

  rapt_bus #(.XLEN(XLEN)) dut (
      .clock(clock),
      .mem(mem),
      .l1i_bus(l1i_bus),
      .l1d_bus(l1d_bus),
      .csr_bcast(csr_bcast),
      .cmu_bcast(cmu_bcast),
      .reset(reset)
  );

      rapt_axi_master #(.XLEN(XLEN), .ID_W(IdW)) adapter (
        .clock(clock),
        .reset(reset),
        .mem(mem),
        .axi(axi)
      );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_bus_defaults.svh"
  `include "tb_bus_write_scenario.svh"

  task automatic wait_for_ar;
    bit found;
    begin
      found = 1'b0;
      for (int wait_cycle = 0; wait_cycle < 16; wait_cycle++) begin
        if (axi.arvalid && axi.arid == 4'd2 && axi.araddr == 32'h8000_1000) begin
          found = 1'b1;
          wait_cycle = 16;
        end else begin
          tick(1);
        end
      end
      if (!found) fail("L1D read did not reach AXI AR channel");
    end
  endtask

  initial begin
    init_bus_inputs();
    tick(4);
    reset = 1'b0;
    tick(1);

    l1d_bus.araddr = 32'h8000_1000;
    l1d_bus.rstrb = 8'h0f;
    l1d_bus.arvalid = 1'b1;
    #1;
    check(l1d_bus.rready, "L1D request was not captured");
    tick(1);
    l1d_bus.arvalid = 1'b0;

    wait_for_ar();
    axi.arready = 1'b1;
    tick(1);
    axi.arready = 1'b0;

    axi.rid = 4'd2;
    axi.rdata = 32'hcafe_babe;
    axi.rresp = 2'b00;
    axi.rlast = 1'b1;
    axi.rvalid = 1'b1;
    #1;

    check(l1d_bus.rvalid, "L1D response valid was not forwarded");
    check(l1d_bus.rlast, "L1D response last was not forwarded");
    check(l1d_bus.rdata == 32'hcafe_babe, "L1D response data mismatch");
    check(!l1d_bus.rerr, "L1D response unexpectedly flagged error");
    tick(1);
    $display("PASS: rapt_bus L1D rlast xsim checks passed");

    reset = 1'b1;
    init_bus_inputs();
    tick(2);
    reset = 1'b0;
    tick(1);

    run_bus_write_scenario();

    $display("PASS: rapt_bus independent AW/W and back-to-back write checks passed");
    $finish;
  end
endmodule
