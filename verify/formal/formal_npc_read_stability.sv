`include "rapt.svh"
// The test DPI backend returns an unconstrained complete word and delay.
// This proves the actual endpoint's R/B-channel hold contract, not host memory.
module formal_npc_read_stability (
    input logic clock,
    reset,
    input logic [1:0] arburst,
    awburst,
    input logic [2:0] arsize,
    awsize,
    input logic [7:0] arlen,
    awlen,
    input logic [3:0] arid,
    awid,
    input logic [`RAPT_XLEN-1:0] araddr,
    awaddr,
    wdata,
    memory_word,
    input logic [31:0] delay_word,
    input logic [`RAPT_XLEN/8-1:0] wstrb,
    input logic arvalid,
    rready,
    awvalid,
    wlast,
    wvalid,
    bready,
    output logic observed_rvalid,
    observed_bvalid,
    observed_arready,
    observed_awready,
    observed_wready,
    output logic [`RAPT_XLEN-1:0] observed_rdata,
    output logic [1:0] observed_bresp,
    output logic mismatch
);
  localparam int X = `RAPT_XLEN;
  logic out_arready, out_rlast, out_rvalid, out_awready, out_wready, out_bvalid;
  logic [3:0] out_rid, out_bid;
  logic [X-1:0] out_rdata;
  logic [1:0] out_rresp, out_bresp;
  logic hold, b_hold;
  logic [5:0] b_saved;
  logic [X+6:0] saved;
  rapt_npc_soc #(.XLEN(X)) dut (.*);
  always_ff @(posedge clock) begin
    if (reset) begin
      hold<=0;
      saved<=0;
      b_hold<=0;
      b_saved<=0;
    end else begin
      hold<=out_rvalid && !rready;
      b_hold<=out_bvalid && !bready;
      b_saved<={out_bid,out_bresp};
      saved<={out_rid,out_rlast,out_rresp,out_rdata};
    end
  end
  assign observed_rvalid=out_rvalid;
  assign observed_bvalid=out_bvalid;
  assign observed_arready=out_arready;
  assign observed_awready=out_awready;
  assign observed_wready=out_wready;
  assign observed_rdata=out_rdata;
  assign observed_bresp=out_bresp;
  assign mismatch=(b_hold && (!out_bvalid || {out_bid,out_bresp} != b_saved))
      || (hold && (!out_rvalid
      || {out_rid,out_rlast,out_rresp,out_rdata} != saved));
endmodule
