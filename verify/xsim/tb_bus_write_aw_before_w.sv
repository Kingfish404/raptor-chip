`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"

module tb_bus_write_aw_before_w;
  localparam int XLEN = 32;
  localparam int IdW = 4;

  logic clock = 1'b0;
  logic reset = 1'b1;

  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) axi ();

  l1i_bus_if #(.XLEN(XLEN)) l1i_bus ();
  l1d_bus_if #(.XLEN(XLEN)) l1d_bus ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  cmu_bcast_if #(.XLEN(XLEN)) cmu_bcast ();

  rapt_bus #(.XLEN(XLEN)) dut (
      .clock(clock),
      .axi(axi),
      .l1i_bus(l1i_bus),
      .l1d_bus(l1d_bus),
      .csr_bcast(csr_bcast),
      .cmu_bcast(cmu_bcast),
      .reset(reset)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_bus_defaults.svh"

  initial begin
    init_bus_inputs();
    tick(4);
    reset = 1'b0;
    tick(1);

    l1d_bus.awaddr = 32'h8000_2000;
    l1d_bus.wdata = 32'h1122_3344;
    l1d_bus.wstrb = 8'h0f;
    l1d_bus.awvalid = 1'b1;
    l1d_bus.wvalid = 1'b1;

    axi.awready = 1'b0;
    axi.wready = 1'b1;
    repeat (3) begin
      #1;
      check(axi.awvalid, "AXI AW should remain valid while AWREADY is low");
      check(!axi.wvalid, "AXI W must not be emitted before AW is accepted");
      check(!l1d_bus.wready, "L1D write must not complete before B response");
      tick(1);
    end

    axi.awready = 1'b1;
    #1;
    check(axi.awvalid, "AXI AW disappeared before handshake");
    check(!axi.wvalid, "AXI W should start after the AW handshake cycle");
    tick(1);

    axi.awready = 1'b0;
    #1;
    check(axi.wvalid, "AXI W was not presented after AW handshake");
    check(axi.wdata == 32'h1122_3344, "AXI W data mismatch");
    check(axi.wstrb == 4'hf, "AXI W strobe mismatch");
    check(axi.wlast, "AXI WLAST must be asserted for the single-beat write");
    tick(1);

    axi.wready = 1'b0;
    #1;
    check(!axi.wvalid, "AXI W should drop after W handshake");
    check(axi.bready, "AXI BREADY should assert after W handshake");
    check(!l1d_bus.wready, "L1D write completed before BVALID");

    axi.bvalid = 1'b1;
    axi.bid = 4'd2;
    axi.bresp = 2'b00;
    #1;
    check(l1d_bus.wready, "L1D write did not complete on B response");
    check(!l1d_bus.werr, "L1D write unexpectedly flagged an error");
    tick(1);

    l1d_bus.awvalid = 1'b0;
    l1d_bus.wvalid = 1'b0;
    axi.bvalid = 1'b0;
    #1;
    check(!axi.bready, "AXI BREADY did not drop after B response");

    $display("PASS: rapt_bus write AW-before-W xsim checks passed");
    $finish;
  end
endmodule
