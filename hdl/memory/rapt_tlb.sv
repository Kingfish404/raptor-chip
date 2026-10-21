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
    output logic [      1:0] pbmt,

    // Fill (sequential, latched on posedge clock)
    input logic             fill_valid,
    input logic [XLEN-1:10] fill_ptag,
    input logic [XLEN-1:12] fill_vtag,
    input logic [      8:0] fill_asid,
    input logic [      6:0] fill_pte,
    input logic [      1:0] fill_pbmt
);

  // Store translation-format bits, not the XLEN-wide transport padding.
  // Sv39: VA[38:12], 44-bit PPN. Sv32: VA[31:12], 22-bit PPN.
  // Retain the full architectural PPN even on a narrower physical platform:
  // unsupported PA bits must reach the access checker, not alias low memory.
  localparam int VAddrBits  = XLEN == 64 ? 39 : 32;
  localparam int PtePpnBits = XLEN == 64 ? 44 : 22;
  logic [        ENTRIES-1:0] valid;
  logic [     VAddrBits-1:12] vtags     [ENTRIES];
  logic [      PtePpnBits-1:0] ptags    [ENTRIES];
  logic [                8:0] asids     [ENTRIES];
  logic [                6:0] ptes      [ENTRIES];
  logic [                1:0] pbmts     [ENTRIES];

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
  logic [        EntryIdxW-1:0] fill_idx;
  logic                         has_invalid;
  logic lookup_canonical, fill_canonical, fill_encodable;
  // A non-canonical lookup must miss so the PTW reports the original VA's
  // page fault. Comparing only the compact VPN would otherwise create aliases.
  assign lookup_canonical = lookup_vtag
      == (XLEN-12)'($signed(lookup_vtag[VAddrBits-1:12]));
  assign fill_canonical = fill_vtag
      == (XLEN-12)'($signed(fill_vtag[VAddrBits-1:12]));
  assign fill_encodable = fill_canonical
      && fill_ptag == (XLEN-10)'(PtePpnBits'(fill_ptag));

  generate
    for (genvar i = 0; i < ENTRIES; i++) begin : gen_tlb_match
      // A global mapping is shared by every ASID. Local mappings retain the
      // normal ASID tag comparison.
      assign match_vec[i] = valid[i] && lookup_canonical
                          && (vtags[i] == lookup_vtag[VAddrBits-1:12])
                          && (ptes[i][4] || (asids[i] == lookup_asid));
      assign match_ptag[i] = match_vec[i] ? (XLEN-10)'(ptags[i]) : '0;
      assign match_pte[i]  = match_vec[i] ? ptes[i]  : '0;

      // Fill duplicate detection must use the fill address, not the unrelated
      // live lookup port. This matters when replicated DTLBs cross-fill.
      assign fill_match_vec[i] = valid[i] && fill_encodable
                               && (vtags[i] == fill_vtag[VAddrBits-1:12])
                               && ((ptes[i][4] && fill_pte[4])
                                   || (!ptes[i][4] && !fill_pte[4]
                                       && (asids[i] == fill_asid)));
    end
  endgenerate

  always_comb begin
    hit       = |match_vec;
    ptag      = '0;
    pte_flags = '0;
    pbmt      = '0;
    for (int i = 0; i < ENTRIES; i++) begin
      ptag |= match_ptag[i];
      pte_flags |= match_pte[i];
      pbmt |= {2{match_vec[i]}} & pbmts[i];
    end
  end

  assign fill_idx = fill_hit ? fill_match_idx : has_invalid ? first_invalid_idx : rr_ptr;

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
    end else if (fill_valid && fill_encodable) begin
      // A match refreshes its payload; otherwise fill the first invalid
      // entry before selecting a round-robin victim.
      valid[fill_idx] <= 1'b1;
      vtags[fill_idx] <= fill_vtag[VAddrBits-1:12];
      ptags[fill_idx] <= PtePpnBits'(fill_ptag);
      asids[fill_idx] <= fill_asid;
      ptes[fill_idx]  <= fill_pte;
      pbmts[fill_idx] <= fill_pbmt;
      if (!fill_hit && !has_invalid) begin
        rr_ptr <= (rr_ptr == EntryIdxW'(ENTRIES - 1)) ? '0 : rr_ptr + 1'b1;
      end
    end
  end

  `RAPT_SVA_NEXT(clock, reset, TLB_FLUSH_CLEARS_ENTRIES, flush, valid == '0)

endmodule

// Data-only table. WAYS=0 retains the CAM for small presets and PMP-cache trials.
// Superpage walk results are cached as their resolved 4 KiB portion, as in L1 ITLB.
// Replicated instances share one fill; payload is unreset, validity is resettable.
/* verilator lint_off DECLFILENAME */
module rapt_data_tlb #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int unsigned ENTRIES = 64,
    parameter int unsigned WAYS = 1
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
    output logic [      1:0] pbmt,
    output logic [9:0] verdict,

    // Fill (sequential, latched on posedge clock)
    input logic             fill_valid,
    input logic [XLEN-1:10] fill_ptag,
    input logic [XLEN-1:12] fill_vtag,
    input logic [      8:0] fill_asid,
    input logic [      6:0] fill_pte,
    input logic [9:0] fill_verdict,
    input logic [      1:0] fill_pbmt
);

  // Store translation-format bits, not the XLEN-wide transport padding.
  // Sv39: VA[38:12], 44-bit PPN. Sv32: VA[31:12], 22-bit PPN.
  // Retain the full architectural PPN even on a narrower physical platform:
  // unsupported PA bits must reach the access checker, not alias low memory.
  localparam int VAddrBits  = XLEN == 64 ? 39 : 32;
  localparam int PtePpnBits = XLEN == 64 ? 44 : 22;
  logic [        ENTRIES-1:0] valid;
  (* ram_style = "distributed" *) logic [     VAddrBits-1:12] vtags     [ENTRIES];
  (* ram_style = "distributed" *) logic [      PtePpnBits-1:0] ptags    [ENTRIES];
  (* ram_style = "distributed" *) logic [                8:0] asids     [ENTRIES];
  (* ram_style = "distributed" *) logic [                6:0] ptes      [ENTRIES];
  (* ram_style = "distributed" *) logic [                1:0] pbmts     [ENTRIES];

  (* ram_style = "distributed" *) logic [9:0] verdicts[ENTRIES];

  localparam int unsigned EntryIdxW = (ENTRIES <= 1) ? 1 : $clog2(ENTRIES);

  // Round-robin replacement pointer. Invalid entries are populated before it
  // is used as a victim, so a partially-filled TLB never evicts useful state.
  logic [EntryIdxW-1:0] rr_ptr;

  // Combinational fully-associative lookup
  logic                         fill_hit;
  logic [        EntryIdxW-1:0] fill_idx;
  logic                         has_invalid;
  logic lookup_canonical, fill_canonical, fill_encodable;
  // A non-canonical lookup must miss so the PTW reports the original VA's
  // page fault. Comparing only the compact VPN would otherwise create aliases.
  assign lookup_canonical = lookup_vtag
      == (XLEN-12)'($signed(lookup_vtag[VAddrBits-1:12]));
  assign fill_canonical = fill_vtag
      == (XLEN-12)'($signed(fill_vtag[VAddrBits-1:12]));
  assign fill_encodable = fill_canonical
      && fill_ptag == (XLEN-10)'(PtePpnBits'(fill_ptag));

  if (WAYS == 0) begin : g_cam
    logic [        ENTRIES-1:0] match_vec;
    logic [          XLEN-1:10] match_ptag [ENTRIES];
    logic [                6:0] match_pte  [ENTRIES];
    logic [        ENTRIES-1:0] fill_match_vec;
    logic [        EntryIdxW-1:0] fill_match_idx;
    logic [        EntryIdxW-1:0] first_invalid_idx;
    assign hit = |match_vec;
    assign fill_hit = |fill_match_vec;
    for (genvar i = 0; i < ENTRIES; i++) begin : gen_tlb_match
      // A global mapping is shared by every ASID. Local mappings retain the
      // normal ASID tag comparison.
      assign match_vec[i] = valid[i] && lookup_canonical
                          && (vtags[i] == lookup_vtag[VAddrBits-1:12])
                          && (ptes[i][4] || (asids[i] == lookup_asid));
      assign match_ptag[i] = match_vec[i] ? (XLEN-10)'(ptags[i]) : '0;
      assign match_pte[i]  = match_vec[i] ? ptes[i]  : '0;

      // Fill duplicate detection must use the fill address, not the unrelated
      // live lookup port. This matters when replicated DTLBs cross-fill.
      assign fill_match_vec[i] = valid[i] && fill_encodable
                               && (vtags[i] == fill_vtag[VAddrBits-1:12])
                               && ((ptes[i][4] && fill_pte[4])
                                   || (!ptes[i][4] && !fill_pte[4]
                                       && (asids[i] == fill_asid)));
    end

    always_comb begin
      ptag      = '0;
      pte_flags = '0;
      pbmt      = '0;
      verdict   = '0;
      for (int i = 0; i < ENTRIES; i++) begin
        ptag |= match_ptag[i];
        pte_flags |= match_pte[i];
        pbmt |= {2{match_vec[i]}} & pbmts[i];
        verdict |= {10{match_vec[i]}} & verdicts[i];
      end
    end

    assign fill_idx = fill_hit ? fill_match_idx : has_invalid ? first_invalid_idx : rr_ptr;

    always_comb begin
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

  end else begin : g_table
    localparam int Sets = ENTRIES / WAYS;
    localparam int SetBits = $clog2(Sets);
    logic [SetBits-1:0] lookup_set, fill_set;
    logic [Sets-1:0] victim;
    logic [WAYS-1:0] fill_matches, lookup_matches;
    logic [EntryIdxW-1:0] write_idx;
    // VPN-only indexing keeps global translations reachable across ASIDs.
    assign lookup_set = lookup_vtag[12+:SetBits];
    assign fill_set = fill_vtag[12+:SetBits];
    always_comb begin
      hit = 1'b0;
      ptag = '0;
      pte_flags = '0;
      pbmt = '0;
      verdict = '0;
      fill_matches = '0;
      lookup_matches = '0;
      write_idx = EntryIdxW'(fill_set);
      if (WAYS == 2 && victim[fill_set]) write_idx = EntryIdxW'(fill_set) + EntryIdxW'(Sets);
      for (int w = 0; w < WAYS; w++) begin
        lookup_matches[w] = valid[int'(lookup_set) + w * Sets] && lookup_canonical
            && vtags[int'(lookup_set) + w * Sets] == lookup_vtag[VAddrBits-1:12]
            && (ptes[int'(lookup_set) + w * Sets][4]
                || asids[int'(lookup_set) + w * Sets] == lookup_asid);
        if (lookup_matches[w]) begin
          hit = 1'b1;
          ptag = (XLEN-10)'(ptags[int'(lookup_set) + w * Sets]);
          pte_flags = ptes[int'(lookup_set) + w * Sets];
          pbmt = pbmts[int'(lookup_set) + w * Sets];
          verdict = verdicts[int'(lookup_set) + w * Sets];
        end
        fill_matches[w] = valid[int'(fill_set) + w * Sets]
            && vtags[int'(fill_set) + w * Sets] == fill_vtag[VAddrBits-1:12]
            && ((ptes[int'(fill_set) + w * Sets][4] && fill_pte[4])
                || (!ptes[int'(fill_set) + w * Sets][4] && !fill_pte[4]
                    && asids[int'(fill_set) + w * Sets] == fill_asid));
      end
      for (int w = WAYS - 1; w >= 0; w--) begin
        if (!valid[int'(fill_set)+w*Sets]) write_idx = EntryIdxW'(int'(fill_set) + w * Sets);
      end
      for (int w = 0; w < WAYS; w++) begin
        if (fill_matches[w]) write_idx = EntryIdxW'(int'(fill_set) + w * Sets);
      end
    end
    assign fill_idx = write_idx;
    assign fill_hit = |fill_matches;
    assign has_invalid = 1'b0;
    always_ff @(posedge clock) begin
      if (reset || flush) victim <= '0;
      else if (fill_valid && fill_encodable && WAYS == 2)
        victim[fill_set] <= !write_idx[EntryIdxW-1];
    end
  end

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      valid  <= '0;
      rr_ptr <= '0;
    end else if (fill_valid && fill_encodable) begin
      // A match refreshes its payload; otherwise fill the first invalid
      // entry before selecting a round-robin victim.
      valid[fill_idx] <= 1'b1;
      if (!fill_hit && !has_invalid) begin
        rr_ptr <= (rr_ptr == EntryIdxW'(ENTRIES - 1)) ? '0 : rr_ptr + 1'b1;
      end
    end
  end

  always_ff @(posedge clock) begin
    if (fill_valid && fill_encodable && !reset && !flush) begin
      vtags[fill_idx] <= fill_vtag[VAddrBits-1:12];
      ptags[fill_idx] <= PtePpnBits'(fill_ptag);
      asids[fill_idx] <= fill_asid;
      ptes[fill_idx]  <= fill_pte;
      pbmts[fill_idx] <= fill_pbmt;
      verdicts[fill_idx] <= fill_verdict;
    end
  end

  `RAPT_SVA_NEXT(clock, reset, TLB_FLUSH_CLEARS_ENTRIES, flush, valid == '0)

endmodule
/* verilator lint_on DECLFILENAME */
