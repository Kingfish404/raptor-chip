`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_axi_r_buffer;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0;
  logic reset = 1;
  axi4_if #(.XLEN(XLEN)) upstream ();
  axi4_if #(.XLEN(XLEN)) downstream ();
  rapt_axi_r_buffer #(
      .XLEN(XLEN)
  ) dut (
      .clock,
      .reset,
      .upstream,
      .downstream
  );
  always #5 clock = ~clock;

  task automatic check_beat(input logic [3:0] id, input logic [XLEN-1:0] data,
                            input logic [1:0] resp, input logic last);
    if (!upstream.rvalid || upstream.rid != id || upstream.rdata != data
        || upstream.rresp != resp || upstream.rlast != last)
      $fatal(1, "buffered R beat changed or arrived out of order");
  endtask

  initial begin
    upstream.rready = 0;
    downstream.rvalid = 0;
    downstream.rid = '0;
    downstream.rdata = '0;
    downstream.rresp = '0;
    downstream.rlast = 0;
    upstream.araddr = XLEN'('h80000100);
    upstream.arid = 4'h7;
    upstream.arlen = 8'h3;
    upstream.arsize = 3'd2;
    upstream.arburst = 2'b01;
    upstream.arcache = 4'hf;
    upstream.arvalid = 1;
    downstream.arready = 1;
    upstream.awaddr = XLEN'('h80000200);
    upstream.awid = 4'h8;
    upstream.awlen = 0;
    upstream.awsize = 3'd2;
    upstream.awburst = 2'b01;
    upstream.awcache = 4'hf;
    upstream.awvalid = 1;
    downstream.awready = 1;
    upstream.wdata = XLEN'('h12345678);
    upstream.wstrb = '1;
    upstream.wlast = 1;
    upstream.wvalid = 1;
    downstream.wready = 1;
    downstream.bid = 4'h8;
    downstream.bresp = 2'b10;
    downstream.bvalid = 1;
    upstream.bready = 1;

    repeat (2) @(negedge clock);
    reset = 0;
    #1;
    if (!downstream.rready || upstream.rvalid) $fatal(1, "empty R buffer state");
    if (!upstream.arready || downstream.araddr != upstream.araddr
        || downstream.arid != upstream.arid || downstream.arlen != upstream.arlen
        || downstream.arsize != upstream.arsize || downstream.arburst != upstream.arburst
        || downstream.arcache != upstream.arcache || !downstream.arvalid)
      $fatal(1, "AR channel did not pass through");
    if (!upstream.awready || downstream.awaddr != upstream.awaddr
        || downstream.awid != upstream.awid || downstream.awcache != upstream.awcache
        || !downstream.awvalid || !upstream.wready || downstream.wdata != upstream.wdata
        || downstream.wstrb != upstream.wstrb || !downstream.wlast || !downstream.wvalid
        || !upstream.bvalid || upstream.bid != downstream.bid
        || upstream.bresp != downstream.bresp || !downstream.bready)
      $fatal(1, "AW/W/B channels did not pass through");

    downstream.rvalid = 1;
    downstream.rid = 4'h1;
    downstream.rdata = XLEN'('h11);
    downstream.rresp = 2'b00;
    downstream.rlast = 0;
    @(negedge clock);
    check_beat(4'h1, XLEN'('h11), 2'b00, 0);
    downstream.rid = 4'h2;
    downstream.rdata = XLEN'('h22);
    downstream.rresp = 2'b10;
    downstream.rlast = 1;
    @(negedge clock);
    check_beat(4'h1, XLEN'('h11), 2'b00, 0);
    if (downstream.rready) $fatal(1, "full R buffer did not backpressure memory");
    downstream.rid = 4'h3;
    downstream.rdata = XLEN'('h33);
    downstream.rresp = 2'b01;
    downstream.rlast = 1;
    @(negedge clock);
    check_beat(4'h1, XLEN'('h11), 2'b00, 0);
    upstream.rready = 1;
    @(negedge clock);
    check_beat(4'h2, XLEN'('h22), 2'b10, 1);
    if (!downstream.rready) $fatal(1, "R buffer did not reopen after pop");
    @(negedge clock);
    check_beat(4'h3, XLEN'('h33), 2'b01, 1);
    downstream.rvalid = 0;
    @(negedge clock);
    if (upstream.rvalid || !downstream.rready) $fatal(1, "R buffer did not drain");

    // After the first registered beat, a ready consumer receives one beat
    // per clock, including alternating AXI IDs and a final error response.
    for (int beat = 0; beat < 8; beat++) begin
      downstream.rvalid = 1;
      downstream.rid = 4'(beat & 1);
      downstream.rdata = XLEN'('h100 + beat);
      downstream.rresp = beat == 7 ? 2'b10 : 2'b00;
      downstream.rlast = beat == 7;
      if (!downstream.rready) $fatal(1, "streaming R buffer lost capacity");
      @(negedge clock);
      check_beat(4'(beat & 1), XLEN'('h100 + beat), beat == 7 ? 2'b10 : 2'b00, beat == 7);
    end
    downstream.rvalid = 0;
    @(negedge clock);
    if (upstream.rvalid) $fatal(1, "streaming R buffer left an extra beat");
    $display("PASS: two-entry AXI R buffer RV%0d", XLEN);
    $finish;
  end
endmodule
