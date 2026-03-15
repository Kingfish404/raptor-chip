`include "ysyx.svh"

// Fully-associative TLB for Sv32 page translation with ASID support.
// Combinational lookup, sequential fill, FIFO replacement.
module ysyx_tlb #(
    parameter bit [7:0] XLEN = `YSYX_XLEN,
    parameter int unsigned ENTRIES = 4
) (
    input clock,
    input reset,
    input flush,

    // Lookup (combinational)
    input  logic [XLEN-1:12] lookup_vtag,
    input  logic [      8:0] lookup_asid,
    output logic             hit,
    output logic [XLEN-1:10] ptag,

    // Fill (sequential, latched on posedge clock)
    input logic             fill_valid,
    input logic [XLEN-1:10] fill_ptag,
    input logic [XLEN-1:12] fill_vtag,
    input logic [      8:0] fill_asid
);

  logic [        ENTRIES-1:0] valid;
  logic [          XLEN-1:12] vtags     [ENTRIES];
  logic [          XLEN-1:10] ptags     [ENTRIES];
  logic [                8:0] asids     [ENTRIES];

  // Round-robin replacement pointer
  logic [$clog2(ENTRIES)-1:0] rr_ptr;

  // Combinational fully-associative lookup
  logic [        ENTRIES-1:0] match_vec;
  always_comb begin
    hit  = 1'b0;
    ptag = '0;
    for (int i = 0; i < ENTRIES; i++) begin
      match_vec[i] = valid[i] && (vtags[i] == lookup_vtag) && (asids[i] == lookup_asid);
      if (match_vec[i]) begin
        hit  = 1'b1;
        ptag = ptags[i];
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      valid  <= '0;
      rr_ptr <= '0;
    end else if (fill_valid && !hit) begin
      valid[rr_ptr] <= 1'b1;
      vtags[rr_ptr] <= fill_vtag;
      ptags[rr_ptr] <= fill_ptag;
      asids[rr_ptr] <= fill_asid;
      rr_ptr <= rr_ptr + 1;
    end
  end

endmodule
