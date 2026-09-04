`include "rapt.svh"

// Fully-associative TLB for Sv32/Sv39 page translation with ASID support.
// Both configurations implement ASIDLEN=9; the RV64 satp WARL logic clears
// the seven unimplemented high ASID bits on write.
// Combinational lookup, sequential fill, invalid-first round-robin replacement.
module rapt_tlb #(
    parameter int XLEN = `RAPT_XLEN,
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
    output logic [      6:0] pte_flags,  // {D,A,G,U,X,W,R}

    // Fill (sequential, latched on posedge clock)
    input logic             fill_valid,
    input logic [XLEN-1:10] fill_ptag,
    input logic [XLEN-1:12] fill_vtag,
    input logic [      8:0] fill_asid,
    input logic [      6:0] fill_pte
);

  logic [        ENTRIES-1:0] valid;
  logic [          XLEN-1:12] vtags     [ENTRIES];
  logic [          XLEN-1:10] ptags     [ENTRIES];
  logic [                8:0] asids     [ENTRIES];
  logic [                6:0] ptes      [ENTRIES];

  localparam int unsigned EntryIdxW = (ENTRIES <= 1) ? 1 : $clog2(ENTRIES);

  // Round-robin replacement pointer. Invalid entries are populated before it
  // is used as a victim, so a partially-filled TLB never evicts useful state.
  logic [EntryIdxW-1:0] rr_ptr;

  // Combinational fully-associative lookup
  logic [        ENTRIES-1:0] match_vec;
  logic [          XLEN-1:10] match_ptag [ENTRIES];
  logic [                6:0] match_pte  [ENTRIES];
  logic [        ENTRIES-1:0] fill_match_vec;
  logic                         fill_hit;
  logic [        EntryIdxW-1:0] fill_match_idx;
  logic [        EntryIdxW-1:0] first_invalid_idx;
  logic                         has_invalid;

  generate
    for (genvar i = 0; i < ENTRIES; i++) begin : gen_tlb_match
      // A global mapping is shared by every ASID. Local mappings retain the
      // normal ASID tag comparison.
      assign match_vec[i] = valid[i] && (vtags[i] == lookup_vtag)
                          && (ptes[i][4] || (asids[i] == lookup_asid));
      assign match_ptag[i] = match_vec[i] ? ptags[i] : '0;
      assign match_pte[i]  = match_vec[i] ? ptes[i]  : '0;

      // Fill duplicate detection must use the fill address, not the unrelated
      // live lookup port. This matters when replicated DTLBs cross-fill.
      assign fill_match_vec[i] = valid[i] && (vtags[i] == fill_vtag)
                               && ((ptes[i][4] && fill_pte[4])
                                   || (!ptes[i][4] && !fill_pte[4]
                                       && (asids[i] == fill_asid)));
    end
  endgenerate

  always_comb begin
    hit       = |match_vec;
    ptag      = '0;
    pte_flags = '0;
    for (int i = 0; i < ENTRIES; i++) begin
      ptag      |= match_ptag[i];
      pte_flags |= match_pte[i];
    end
  end

  always_comb begin
    fill_hit         = |fill_match_vec;
    fill_match_idx   = '0;
    first_invalid_idx = '0;
    has_invalid      = 1'b0;
    for (int i = 0; i < ENTRIES; i++) begin
      if (fill_match_vec[i]) fill_match_idx = EntryIdxW'(i);
      if (!valid[i] && !has_invalid) begin
        first_invalid_idx = EntryIdxW'(i);
        has_invalid = 1'b1;
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      valid  <= '0;
      rr_ptr <= '0;
    end else if (fill_valid) begin
      if (fill_hit) begin
        // Refresh the payload as well as the global/ASID attributes. Software
        // normally fences after changing a PTE, but making refill idempotent
        // also prevents duplicate entries after cross-filling replicas.
        valid[fill_match_idx] <= 1'b1;
        vtags[fill_match_idx] <= fill_vtag;
        ptags[fill_match_idx] <= fill_ptag;
        asids[fill_match_idx] <= fill_asid;
        ptes[fill_match_idx]  <= fill_pte;
      end else if (has_invalid) begin
        valid[first_invalid_idx] <= 1'b1;
        vtags[first_invalid_idx] <= fill_vtag;
        ptags[first_invalid_idx] <= fill_ptag;
        asids[first_invalid_idx] <= fill_asid;
        ptes[first_invalid_idx]  <= fill_pte;
      end else begin
        valid[rr_ptr] <= 1'b1;
        vtags[rr_ptr] <= fill_vtag;
        ptags[rr_ptr] <= fill_ptag;
        asids[rr_ptr] <= fill_asid;
        ptes[rr_ptr]  <= fill_pte;
        rr_ptr <= (rr_ptr == EntryIdxW'(ENTRIES - 1)) ? '0 : rr_ptr + 1'b1;
      end
    end
  end

  `RAPT_SVA_NEXT(clock, reset, TLB_FLUSH_CLEARS_ENTRIES, flush, valid == '0)

endmodule
