`include "rapt.svh"
`include "rapt_soc_if.svh"

// Independent accepted-beat history for the cluster's optional AXI R buffer.
// Inputs are unrestricted; only the proof command requests a first-edge reset.
module formal_axi_r_buffer #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int ID_W = 4,
    parameter bit Enable = 1'b1
) (
    input logic clock,
    input logic reset,
    axi4_if.slave upstream,
    axi4_if.master downstream,
    output logic correct,
    output logic [11:0] activated
);
  rapt_axi_r_buffer #(
      .XLEN(XLEN),
      .ID_W(ID_W),
      .Enable(Enable)
  ) dut (
      .*
  );
  typedef struct packed {
    logic [ID_W-1:0] id;
    logic [XLEN-1:0] data;
    logic [1:0] resp;
    logic last;
  } beat_t;
  beat_t incoming, outgoing, first, second, held, source_held;
  assign incoming = {downstream.rid, downstream.rdata, downstream.rresp, downstream.rlast};
  assign outgoing = {upstream.rid, upstream.rdata, upstream.rresp, upstream.rlast};
  logic past_valid = 1'b0;
  logic [1:0] count;
  logic stalled, source_stalled, popped;
  wire push = Enable && downstream.rvalid && !reset && count < 2;
  wire pop = Enable && count != 0 && upstream.rready;
  always_ff @(posedge clock) begin
    past_valid <= 1'b1;
    if (reset) begin
      count <= '0;
      stalled <= 1'b0;
      source_stalled <= 1'b0;
      popped <= 1'b0;
    end else begin
      stalled <= upstream.rvalid && !upstream.rready;
      source_stalled <= downstream.rvalid && !downstream.rready;
      if (upstream.rvalid && !upstream.rready) held <= outgoing;
      if (downstream.rvalid && !downstream.rready) source_held <= incoming;
      if (pop) popped <= 1'b1;
      if (pop) first <= second;
      if (push) begin
        if (count == 0 || (count == 1 && pop)) first <= incoming;
        else second <= incoming;
      end
      case ({
        push, pop
      })
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: ;
      endcase
    end
  end

  wire requests_match =
      {downstream.araddr, downstream.arid, downstream.arlen, downstream.arsize,
       downstream.arburst, downstream.arcache, downstream.arvalid}
      == {upstream.araddr, upstream.arid, upstream.arlen, upstream.arsize,
          upstream.arburst, upstream.arcache, upstream.arvalid}
      && upstream.arready == downstream.arready
      && {downstream.awaddr, downstream.awid, downstream.awlen, downstream.awsize,
          downstream.awburst, downstream.awcache, downstream.awvalid}
      == {upstream.awaddr, upstream.awid, upstream.awlen, upstream.awsize,
          upstream.awburst, upstream.awcache, upstream.awvalid}
      && upstream.awready == downstream.awready
      && {downstream.wdata, downstream.wstrb, downstream.wlast, downstream.wvalid}
      == {upstream.wdata, upstream.wstrb, upstream.wlast, upstream.wvalid}
      && upstream.wready == downstream.wready
      && {upstream.bid, upstream.bresp, upstream.bvalid}
      == {downstream.bid, downstream.bresp, downstream.bvalid}
      && downstream.bready == upstream.bready;
  if (Enable) begin : g_buffered
    // The hidden second beat is an asserted induction invariant derived from
    // the independent shift history; no DUT state is assumed or replaced.
    wire resident_order = count != 2 || beat_t'(dut.g_buffered.beat[!dut.g_buffered.head])
        == second;
    wire queue_matches = count <= 2 && dut.g_buffered.count == count
        && (dut.g_buffered.head ^ dut.g_buffered.tail) == count[0]
        && upstream.rvalid == (count != 0)
        && downstream.rready == (!reset && count < 2)
        && (count == 0 || outgoing == first) && resident_order;
    wire held_stable = reset || !stalled || (upstream.rvalid && outgoing == held);
    assign correct = requests_match && (!past_valid || (queue_matches && held_stable));
  end else begin : g_bypass
    wire source_preserved = !source_stalled || (downstream.rvalid && incoming == source_held);
    wire held_preserved = !stalled || (upstream.rvalid && outgoing == held);
    assign correct = requests_match && upstream.rvalid == downstream.rvalid
        && downstream.rready == upstream.rready && outgoing == incoming
        && (!past_valid || reset || !source_preserved || held_preserved);
  end
  always_comb begin
    activated = '0;
    if (past_valid && !reset) begin
      activated[0] = upstream.arvalid && upstream.arready && upstream.araddr != '0;
      activated[1] = upstream.awvalid && upstream.awready && upstream.awaddr != '0;
      activated[2] = upstream.wvalid && upstream.wready && upstream.wstrb != '0;
      activated[3] = upstream.bvalid && upstream.bready && upstream.bresp != '0;
      if (Enable) begin
        activated[4] = push && count == 0;
        activated[5] = count == 2 && downstream.rvalid;
        activated[6] = push && pop;
        activated[7] = stalled && upstream.rvalid;
        activated[9] = pop && count == 2;
        activated[10] = upstream.rvalid && upstream.rdata != '0 && upstream.rid != '0;
        activated[11] = popped && count == 0;
      end else begin
        activated[4] = upstream.rvalid && upstream.rready && upstream.rdata != '0;
        activated[5] = source_stalled && downstream.rvalid && incoming == source_held
            && !upstream.rready;
      end
    end
    if (Enable) activated[8] = past_valid && reset && count != 0;
  end
endmodule
