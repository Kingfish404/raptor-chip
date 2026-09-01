`include "rapt.svh"

// Independent PLIC state-machine model.  A three-source/two-context instance
// retains priority ties, source ordering, M/S routing, and all gateway states
// while keeping induction and lifecycle covers tractable.
module formal_plic #(
    parameter int XLEN = 32,
    parameter int NDEV = 3,
    parameter int NCTX = 2,
    parameter int NHART = (NCTX + 1) / 2
) (
    input logic clock,
    input logic reset,
    input logic [NDEV:0] ext_irq,
    input logic [XLEN-3:0] araddr_word,
    input logic ar_commit,
    input logic [XLEN-3:0] awaddr_word,
    input logic [XLEN-1:0] wdata,
    input logic wvalid
);
  localparam int IdW = (NDEV <= 1) ? 1 : $clog2(NDEV + 1);
  localparam logic [31:0] PendBase = 32'h0000_1000;
  localparam logic [31:0] EnBase = 32'h0000_2000;
  localparam logic [31:0] EnStride = 32'h0000_0080;
  localparam logic [31:0] CtxBase = 32'h0020_0000;
  localparam logic [31:0] CtxStride = 32'h0000_1000;

  // The router presents only naturally aligned 32-bit PLIC transactions.
  // Constructing byte addresses from symbolic word addresses makes that
  // interface contract structural rather than solver-assumption based.
  logic [XLEN-1:0] araddr, awaddr;
  assign araddr = {araddr_word, 2'b00};
  assign awaddr = {awaddr_word, 2'b00};

  plic_bus_if #(.XLEN(XLEN), .NDEV(NDEV), .NCTX(NCTX), .NHART(NHART)) bus();
  assign bus.ext_irq = ext_irq;
  assign bus.araddr = araddr;
  assign bus.ar_commit = ar_commit;
  assign bus.awaddr = awaddr;
  assign bus.wdata = wdata;
  assign bus.wvalid = wvalid;

  logic [2:0] dut_priority[NDEV+1];
  logic [NDEV:0] dut_pending;
  logic [NDEV:0] dut_enable[NCTX];
  logic [2:0] dut_threshold[NCTX];
  logic [NDEV:0] dut_gateway_busy;
  logic [NHART-1:0] dut_meip, dut_seip;
  rapt_plic #(.XLEN(XLEN), .NDEV(NDEV), .NCTX(NCTX), .NHART(NHART)) dut (
      .clock, .reset, .plic_bus(bus),
      .formal_priority(dut_priority),
      .formal_pending(dut_pending),
      .formal_enable(dut_enable),
      .formal_threshold(dut_threshold),
      .formal_gateway_busy(dut_gateway_busy),
      .formal_meip(dut_meip),
      .formal_seip(dut_seip)
  );

  logic [2:0] ref_priority[NDEV+1];
  logic [NDEV:0] ref_pending;
  logic [NDEV:0] ref_enable[NCTX];
  logic [2:0] ref_threshold[NCTX];
  logic [NDEV:0] ref_gateway_busy;
  logic [NHART-1:0] ref_meip, ref_seip;

  logic [31:0] r_off, w_off;
  assign r_off = {8'b0, araddr[23:0]};
  assign w_off = {8'b0, awaddr[23:0]};

  logic [IdW-1:0] ref_best_id[NCTX];
  logic [2:0] ref_best_prio[NCTX];
  logic ref_ctx_irq[NCTX];
  always_comb begin
    for (int c = 0; c < NCTX; c++) begin
      ref_best_id[c] = '0;
      ref_best_prio[c] = ref_threshold[c];
      ref_ctx_irq[c] = 1'b0;
      for (int s = 1; s <= NDEV; s++) begin
        if (ref_pending[s] && ref_enable[c][s]
            && ref_priority[s] > ref_threshold[c]) begin
          ref_ctx_irq[c] = 1'b1;
        end
        // Strict greater-than preserves the lowest source ID on ties.
        if (ref_pending[s] && ref_enable[c][s]
            && ref_priority[s] > ref_best_prio[c]) begin
          ref_best_prio[c] = ref_priority[s];
          ref_best_id[c] = IdW'(s);
        end
      end
    end
  end

  logic [NHART-1:0] ref_meip_next, ref_seip_next;
  always_comb begin
    ref_meip_next = '0;
    ref_seip_next = '0;
    for (int c = 0; c < NCTX; c++) begin
      if ((c / 2) < NHART) begin
        if ((c & 1) == 0) ref_meip_next[c/2] = ref_ctx_irq[c];
        else ref_seip_next[c/2] = ref_ctx_irq[c];
      end
    end
  end

  logic ref_claim_fire;
  logic [IdW-1:0] ref_claim_id;
  logic ref_complete_fire;
  logic [IdW-1:0] ref_complete_id;
  logic ref_sw_pending_set;
  always_comb begin
    ref_claim_fire = 1'b0;
    ref_claim_id = '0;
    for (int c = 0; c < NCTX; c++) begin
      if (ar_commit && r_off == CtxBase + CtxStride * c + 32'd4
          && ref_best_id[c] != '0) begin
        ref_claim_fire = 1'b1;
        ref_claim_id = ref_best_id[c];
      end
    end

    ref_complete_fire = 1'b0;
    ref_complete_id = wdata[IdW-1:0];
    for (int c = 0; c < NCTX; c++) begin
      for (int s = 1; s <= NDEV; s++) begin
        if (wvalid && w_off == CtxBase + CtxStride * c + 32'd4
            && ref_complete_id == IdW'(s)
            && ref_gateway_busy[s] && !ref_pending[s]) begin
          ref_complete_fire = 1'b1;
        end
      end
    end
    ref_sw_pending_set = wvalid && w_off == PendBase;
  end

  logic [NDEV:0] ref_pending_next, ref_gateway_next;
  always_comb begin
    ref_pending_next = ref_pending;
    ref_gateway_next = ref_gateway_busy;
    ref_pending_next[0] = 1'b0;
    ref_gateway_next[0] = 1'b0;
    for (int s = 1; s <= NDEV; s++) begin
      if (!ref_gateway_busy[s]
          && (ext_irq[s] || (ref_sw_pending_set && wdata[s]))) begin
        ref_pending_next[s] = 1'b1;
        ref_gateway_next[s] = 1'b1;
      end
      if (ref_claim_fire && ref_claim_id == IdW'(s))
        ref_pending_next[s] = 1'b0;
      if (ref_complete_fire && ref_complete_id == IdW'(s))
        ref_gateway_next[s] = 1'b0;
    end
  end

  logic [XLEN-1:0] ref_rdata;
  always_comb begin
    ref_rdata = '0;
    for (int s = 0; s <= NDEV; s++) begin
      if (r_off == 32'(4 * s)) ref_rdata = XLEN'(ref_priority[s]);
    end
    if (r_off == PendBase) ref_rdata = XLEN'(ref_pending);
    for (int c = 0; c < NCTX; c++) begin
      if (r_off == EnBase + EnStride * c) ref_rdata = XLEN'(ref_enable[c]);
      if (r_off == CtxBase + CtxStride * c) ref_rdata = XLEN'(ref_threshold[c]);
      if (r_off == CtxBase + CtxStride * c + 32'd4)
        ref_rdata = XLEN'(ref_best_id[c]);
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      ref_pending <= '0;
      ref_gateway_busy <= '0;
      ref_meip <= '0;
      ref_seip <= '0;
      for (int s = 0; s <= NDEV; s++) ref_priority[s] <= '0;
      for (int c = 0; c < NCTX; c++) begin
        ref_enable[c] <= '0;
        ref_threshold[c] <= '0;
      end
    end else begin
      ref_pending <= ref_pending_next;
      ref_gateway_busy <= ref_gateway_next;
      ref_meip <= ref_meip_next;
      ref_seip <= ref_seip_next;

      if (wvalid) begin
        for (int s = 1; s <= NDEV; s++) begin
          if (w_off == 32'(4 * s)) ref_priority[s] <= wdata[2:0];
        end
        for (int c = 0; c < NCTX; c++) begin
          if (w_off == EnBase + EnStride * c)
            ref_enable[c] <= {wdata[NDEV:1], 1'b0};
          if (w_off == CtxBase + CtxStride * c)
            ref_threshold[c] <= wdata[2:0];
        end
      end
    end
  end

  logic f_past_valid = 1'b0;
  always_ff @(posedge clock) f_past_valid <= 1'b1;

  always_comb begin
    assume(f_past_valid || reset);
    if (f_past_valid) begin
      assert(dut_pending == ref_pending);
      assert(dut_gateway_busy == ref_gateway_busy);
      assert(dut_meip == ref_meip);
      assert(dut_seip == ref_seip);
      assert(bus.meip == ref_meip);
      assert(bus.seip == ref_seip);
      assert(bus.rdata == ref_rdata);
      assert(ref_pending[0] == 1'b0);
      assert(ref_gateway_busy[0] == 1'b0);
      for (int s = 0; s <= NDEV; s++)
        assert(dut_priority[s] == ref_priority[s]);
      for (int c = 0; c < NCTX; c++) begin
        assert(dut_enable[c] == ref_enable[c]);
        assert(dut_threshold[c] == ref_threshold[c]);
        assert(ref_enable[c][0] == 1'b0);
      end
    end
  end

  logic saw_claim, saw_complete;
  always_ff @(posedge clock) begin
    if (reset) begin
      saw_claim <= 1'b0;
      saw_complete <= 1'b0;
    end else begin
      if (ref_claim_fire && ref_claim_id == IdW'(1)) saw_claim <= 1'b1;
      if (saw_claim && ref_complete_fire && ref_complete_id == IdW'(1))
        saw_complete <= 1'b1;
      cover(ref_pending[1] && ref_pending[2]
            && ref_enable[0][1] && ref_enable[0][2]
            && ref_priority[1] == ref_priority[2]
            && ref_priority[1] > ref_threshold[0]
            && ref_best_id[0] == IdW'(1));
      cover(ref_meip[0] && ref_seip[0]);
      cover(saw_complete && ref_pending[1]);
    end
  end
endmodule
