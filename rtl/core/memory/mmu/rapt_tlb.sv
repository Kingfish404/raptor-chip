`include "rapt.svh"

// Fully-associative TLB for Sv32/Sv39 page translation with ASID support.
// Both configurations implement ASIDLEN=9; the RV64 satp WARL logic clears
// the seven unimplemented high ASID bits on write.
// Combinational lookup, sequential fill, invalid-first round-robin replacement.
module rapt_tlb #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int unsigned ENTRIES = 4,
    // True LRU over all entries instead of round-robin (2-32 entries).
    parameter bit TlbLru = `RAPT_TLB_LRU != 0,
    // Tree PLRU reduces CAM replacement state; takes priority over true LRU.
    parameter bit TlbPlru = `RAPT_TLB_PLRU != 0
) (
    input clock,
    input reset,
    input flush,
    // Flush remains unconditional (for example PMP changes); SFENCE is selective.
    input logic sfence_valid,
    input logic [26:0] sfence_vpn,
    input logic [8:0] sfence_asid,
    input logic sfence_all_vpn,
    input logic sfence_all_asid,

    // Lookup (combinational). Only a consumed translation updates replacement state.
    // Unused when access-based replacement is disabled.
    /* verilator lint_off UNUSEDSIGNAL */
    input logic lookup_valid,
    /* verilator lint_on UNUSEDSIGNAL */
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
    input logic [      1:0] fill_pbmt,
    input logic [      1:0] fill_level
);

  // Cache only the implemented PA bits. The full walk result is checked
  // before installation, so an unsupported PPN cannot alias low memory.
  localparam int VAddrBits  = XLEN == 64 ? 39 : 32;
  localparam int PtePpnBits = `RAPT_PADDR_BITS - 12;
  logic [        ENTRIES-1:0] valid;
  logic [   ENTRIES-1:0] sfence_matches;
  logic [           1:0] levels         [ENTRIES];
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
  logic [        ENTRIES-1:0] fill_match_vec;
  logic                         fill_hit;
  logic [        EntryIdxW-1:0] fill_match_idx;
  logic [        EntryIdxW-1:0] first_invalid_idx;
  logic [        EntryIdxW-1:0] fill_idx;
  logic                         has_invalid;
  logic lookup_canonical, fill_canonical, fill_encodable;
  // A non-canonical lookup must miss so the PTW reports the original VA's
  // page fault. Comparing only the compact VPN would otherwise create aliases.
  assign lookup_canonical = lookup_vtag == (XLEN - 12)'($signed(lookup_vtag[VAddrBits-1:12]));
  assign fill_canonical   = fill_vtag == (XLEN - 12)'($signed(fill_vtag[VAddrBits-1:12]));
  assign fill_encodable   = fill_canonical && fill_ptag == (XLEN - 10)'(PtePpnBits'(fill_ptag));

  generate
    for (genvar i = 0; i < ENTRIES; i++) begin : gen_tlb_match
      assign sfence_matches[i] = rapt_pkg::tlb_sfence_match(
          27'(vtags[i]),
          levels[i],
          asids[i],
          ptes[i][4],
          sfence_vpn,
          sfence_asid,
          sfence_all_vpn,
          sfence_all_asid,
          XLEN == 64
      );
      // A global mapping is shared by every ASID. Local mappings retain the
      // normal ASID tag comparison.
      assign match_vec[i] = valid[i] && lookup_canonical
                          && (vtags[i] == lookup_vtag[VAddrBits-1:12])
                          && (ptes[i][4] || (asids[i] == lookup_asid));
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
      // Local and global entries may overlap. Select one complete payload;
      // the highest matching index also owns the replacement-policy touch.
      if (match_vec[i]) begin
        ptag = (XLEN-10)'(ptags[i]);
        pte_flags = ptes[i];
        pbmt = pbmts[i];
      end
    end
  end

  logic [EntryIdxW-1:0] victim_idx;
  if ((TlbLru || TlbPlru) && ENTRIES >= 2 && ENTRIES <= 32) begin : g_lru
    rapt_tlb_lru #(
        .Entries(ENTRIES),
        .Plru(TlbPlru)
    ) u_lru (
        .clock,
        .reset,
        .flush,
        .match_vec,
        .lookup_valid(lookup_valid && !sfence_valid),
        .fill_valid(fill_valid && fill_encodable && !sfence_valid),
        .fill_idx,
        .victim(victim_idx)
    );
  end else begin : g_round_robin
    assign victim_idx = rr_ptr;
  end
  assign fill_idx = fill_hit ? fill_match_idx : has_invalid ? first_invalid_idx : victim_idx;

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
    end else if (sfence_valid) begin
      // Discard even an unrelated concurrent fill: its walk predates the fence.
      valid <= valid & ~sfence_matches;
    end else if (fill_valid && fill_encodable) begin
      // A match refreshes its payload; otherwise fill the first invalid
      // entry before selecting a round-robin victim.
      valid[fill_idx] <= 1'b1;
      vtags[fill_idx] <= fill_vtag[VAddrBits-1:12];
      ptags[fill_idx] <= PtePpnBits'(fill_ptag);
      asids[fill_idx] <= fill_asid;
      ptes[fill_idx]  <= fill_pte;
      pbmts[fill_idx] <= fill_pbmt;
      levels[fill_idx] <= fill_level;
      if (!fill_hit && !has_invalid) begin
        rr_ptr <= (rr_ptr == EntryIdxW'(ENTRIES - 1)) ? '0 : rr_ptr + 1'b1;
      end
    end
  end

  `RAPT_SVA_NEXT(clock, reset, TLB_FLUSH_CLEARS_ENTRIES, flush, valid == '0)
  `RAPT_SVA_NEXT(clock, reset, TLB_SFENCE_MATCHED_ENTRIES, sfence_valid && !flush, valid == ($past
                 (valid) & ~$past(sfence_matches)))

endmodule

// Data translations share one payload array and fill port. Two asynchronous
// lookup ports preserve load/store timing without duplicating storage on ASIC.
// WAYS=0 retains a small CAM; indexed tables use the same neutral RAM ports.
/* verilator lint_off DECLFILENAME */
module rapt_data_tlb #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int unsigned ENTRIES = 64,
    parameter int unsigned WAYS = 1,
    parameter bit TlbLru = `RAPT_TLB_LRU != 0,
    parameter bit TlbPlru = `RAPT_TLB_PLRU != 0,
    parameter bit SecondPort = 0,
    parameter bit TlbLruB = TlbLru,
    parameter bit TlbPlruB = TlbPlru
) (
    input clock,
    input reset,
    input flush,
    input logic sfence_valid,
    // Over-invalidation avoids a broadcast read of RAM tags for SFENCE.
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [26:0] sfence_vpn,
    input logic [8:0] sfence_asid,
    input logic sfence_all_vpn,
    input logic sfence_all_asid,
    /* verilator lint_on UNUSEDSIGNAL */

    input logic lookup_valid,
    input logic [XLEN-1:12] lookup_vtag,
    input logic [8:0] lookup_asid,
    output logic hit,
    output logic [XLEN-1:10] ptag,
    output logic [6:0] pte_flags,
    output logic [1:0] pbmt,
    output logic [9:0] verdict,

    input logic lookup_b_valid,
    input logic [XLEN-1:12] lookup_b_vtag,
    input logic [8:0] lookup_b_asid,
    output logic hit_b,
    output logic [XLEN-1:10] ptag_b,
    output logic [6:0] pte_flags_b,
    output logic [1:0] pbmt_b,
    output logic [9:0] verdict_b,

    input logic fill_valid,
    input logic [XLEN-1:10] fill_ptag,
    input logic [XLEN-1:12] fill_vtag,
    input logic [8:0] fill_asid,
    input logic [6:0] fill_pte,
    input logic [9:0] fill_verdict,
    input logic [1:0] fill_pbmt,
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [1:0] fill_level
    /* verilator lint_on UNUSEDSIGNAL */
);
  localparam int VAddrBits  = XLEN == 64 ? 39 : 32;
  localparam int PtePpnBits = `RAPT_PADDR_BITS - 12;
  localparam int EntryIdxW  = ENTRIES <= 1 ? 1 : $clog2(ENTRIES);
  logic [ENTRIES-1:0] valid;
  logic [VAddrBits-1:12] vtags[ENTRIES];
  logic [PtePpnBits-1:0] ptags[ENTRIES];
  logic [8:0] asids[ENTRIES];
  logic [6:0] ptes[ENTRIES];
  logic [1:0] pbmts[ENTRIES];
  logic [9:0] verdicts[ENTRIES];
  logic [EntryIdxW-1:0] rr_ptr, fill_idx;
  logic fill_hit, has_invalid, fill_canonical, fill_encodable;
  logic [1:0] lookup_canonical;
  logic [XLEN-1:12] lookup_tags[2];
  logic [8:0] lookup_asids[2];
  logic [1:0] port_hit;
  logic [XLEN-1:10] port_ptag[2];
  logic [6:0] port_pte[2];
  logic [1:0] port_pbmt[2];
  logic [9:0] port_verdict[2];
  logic [1:0] touch_valid;
  assign lookup_tags[0] = lookup_vtag;
  assign lookup_tags[1] = lookup_b_vtag;
  assign lookup_asids[0] = lookup_asid;
  assign lookup_asids[1] = lookup_b_asid;
  assign hit = port_hit[0];
  assign ptag = port_ptag[0];
  assign pte_flags = port_pte[0];
  assign pbmt = port_pbmt[0];
  assign verdict = port_verdict[0];
  assign hit_b = port_hit[1];
  assign ptag_b = port_ptag[1];
  assign pte_flags_b = port_pte[1];
  assign pbmt_b = port_pbmt[1];
  assign verdict_b = port_verdict[1];
  assign touch_valid[0] = lookup_valid && (TlbLru || TlbPlru);
  assign touch_valid[1] = SecondPort && lookup_b_valid && (TlbLruB || TlbPlruB);
  for (genvar p = 0; p < 2; p++) begin : g_canonical
    assign lookup_canonical[p] = lookup_tags[p] == (XLEN - 12)'($signed(
        lookup_tags[p][VAddrBits-1:12]
    ));
  end
  assign fill_canonical = fill_vtag == (XLEN-12)'($signed(fill_vtag[VAddrBits-1:12]));
  assign fill_encodable = fill_canonical && fill_ptag == (XLEN-10)'(PtePpnBits'(fill_ptag));

  if (WAYS == 0) begin : g_cam
    logic [ENTRIES-1:0] match_vec[2], fill_match_vec;
    logic [ENTRIES-1:0] policy_match;
    logic [EntryIdxW-1:0] fill_match_idx, first_invalid_idx, victim_idx;
    for (genvar p = 0; p < 2; p++) begin : g_port
      for (genvar i = 0; i < ENTRIES; i++) begin : g_match
        assign match_vec[p][i] = (p == 0 || SecondPort) && valid[i] && lookup_canonical[p]
            && vtags[i] == lookup_tags[p][VAddrBits-1:12]
            && (ptes[i][4] || asids[i] == lookup_asids[p]);
      end
      always_comb begin
        port_hit[p] = |match_vec[p];
        port_ptag[p] = '0;
        port_pte[p] = '0;
        port_pbmt[p] = '0;
        port_verdict[p] = '0;
        for (int i = 0; i < ENTRIES; i++) begin
          if (match_vec[p][i]) begin
            port_ptag[p] = (XLEN - 10)'(ptags[i]);
            port_pte[p] = ptes[i];
            port_pbmt[p] = pbmts[i];
            port_verdict[p] = verdicts[i];
          end
        end
      end
    end
    for (genvar i = 0; i < ENTRIES; i++) begin : g_fill_match
      assign fill_match_vec[i] = valid[i]
          && vtags[i] == fill_vtag[VAddrBits-1:12]
          && ((ptes[i][4] && fill_pte[4])
              || (!ptes[i][4] && !fill_pte[4] && asids[i] == fill_asid));
    end
    assign fill_hit = |fill_match_vec;
    // A consumed load wins a simultaneous store touch. L1D consumes at most
    // one port per cycle; this priority also defines standalone dual access.
    assign policy_match = touch_valid[0] ? match_vec[0] : match_vec[1];
    if ((TlbLru || TlbPlru || TlbLruB || TlbPlruB) && ENTRIES >= 2 && ENTRIES <= 32) begin : g_lru
      rapt_tlb_lru #(
          .Entries(ENTRIES),
          .Plru(TlbPlru || (SecondPort && TlbPlruB))
      ) u_lru (
          .clock,
          .reset,
          .flush(flush || sfence_valid),
          .match_vec(policy_match),
          .lookup_valid((|touch_valid) && !sfence_valid),
          .fill_valid(fill_valid && fill_encodable && !sfence_valid),
          .fill_idx,
          .victim(victim_idx)
      );
    end else begin : g_round_robin
      assign victim_idx = rr_ptr;
    end
    assign fill_idx = fill_hit ? fill_match_idx : has_invalid ? first_invalid_idx : victim_idx;
    always_comb begin
      fill_match_idx = '0;
      first_invalid_idx = '0;
      has_invalid = 0;
      for (int i = 0; i < ENTRIES; i++) begin
        if (fill_match_vec[i]) fill_match_idx = EntryIdxW'(i);
        if (!valid[i] && !has_invalid) begin
          first_invalid_idx = EntryIdxW'(i);
          has_invalid = 1;
        end
      end
    end
  end else begin : g_table
    localparam int Sets = ENTRIES / WAYS;
    localparam int SetBits = Sets <= 1 ? 1 : $clog2(Sets);
    logic [SetBits-1:0] lookup_set[2], fill_set;
    logic [Sets-1:0] victim;
    logic [WAYS-1:0] fill_matches, lookup_matches[2];
    logic [EntryIdxW-1:0] write_idx;
    if ((WAYS != 1 && WAYS != 2) || ENTRIES % WAYS != 0
        || (Sets & (Sets - 1)) != 0) begin : g_bad_geometry
      $error("Data TLB requires power-of-two sets and one or two ways");
    end
    assign fill_set = Sets == 1 ? '0 : fill_vtag[12+:SetBits];
    for (genvar p = 0; p < 2; p++) begin : g_port
      assign lookup_set[p] = Sets == 1 ? '0 : lookup_tags[p][12+:SetBits];
      always_comb begin
        port_hit[p] = 0;
        port_ptag[p] = '0;
        port_pte[p] = '0;
        port_pbmt[p] = '0;
        port_verdict[p] = '0;
        lookup_matches[p] = '0;
        for (int w = 0; w < WAYS; w++) begin
          lookup_matches[p][w] = (p == 0 || SecondPort)
              && valid[int'(lookup_set[p]) + w * Sets] && lookup_canonical[p]
              && vtags[int'(lookup_set[p]) + w * Sets] == lookup_tags[p][VAddrBits-1:12]
              && (ptes[int'(lookup_set[p]) + w * Sets][4]
                  || asids[int'(lookup_set[p]) + w * Sets] == lookup_asids[p]);
          if (lookup_matches[p][w]) begin
            port_hit[p] = 1;
            port_ptag[p] = (XLEN-10)'(ptags[int'(lookup_set[p]) + w * Sets]);
            port_pte[p] = ptes[int'(lookup_set[p]) + w * Sets];
            port_pbmt[p] = pbmts[int'(lookup_set[p]) + w * Sets];
            port_verdict[p] = verdicts[int'(lookup_set[p]) + w * Sets];
          end
        end
      end
    end
    always_comb begin
      fill_matches = '0;
      write_idx = EntryIdxW'(fill_set);
      if (WAYS == 2 && victim[fill_set]) write_idx += EntryIdxW'(Sets);
      for (int w = 0; w < WAYS; w++) begin
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
    assign has_invalid = 0;
    logic touch_q, touch_way_q;
    logic [SetBits-1:0] touch_set_q;
    wire touch_port = !touch_valid[0];
    always_ff @(posedge clock) begin
      touch_q <= WAYS == 2 && (|touch_valid) && port_hit[touch_port]
          && !reset && !flush && !sfence_valid;
      touch_set_q <= lookup_set[touch_port];
      touch_way_q <= WAYS == 2 && lookup_matches[touch_port][WAYS-1];
    end
    always_ff @(posedge clock) begin
      if (reset || flush || sfence_valid) victim <= '0;
      else begin
        if (touch_q) victim[touch_set_q] <= !touch_way_q;
        if (fill_valid && fill_encodable && WAYS == 2) victim[fill_set] <= !write_idx[EntryIdxW-1];
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset || flush || sfence_valid) begin
      valid <= '0;
      rr_ptr <= '0;
    end else if (fill_valid && fill_encodable) begin
      valid[fill_idx] <= 1;
      if (!fill_hit && !has_invalid)
        rr_ptr <= rr_ptr == EntryIdxW'(ENTRIES - 1) ? '0 : rr_ptr + 1'b1;
    end
  end
  // One indexed write; both lookup ports and the duplicate-fill probe read
  // this storage. Reset and SFENCE touch only the small validity vector.
  always_ff @(posedge clock) begin
    if (fill_valid && fill_encodable && !reset && !flush && !sfence_valid) begin
      vtags[fill_idx] <= fill_vtag[VAddrBits-1:12];
      ptags[fill_idx] <= PtePpnBits'(fill_ptag);
      asids[fill_idx] <= fill_asid;
      ptes[fill_idx] <= fill_pte;
      pbmts[fill_idx] <= fill_pbmt;
      verdicts[fill_idx] <= fill_verdict;
    end
  end
  `RAPT_SVA_NEXT(clock, reset, TLB_FLUSH_CLEARS_ENTRIES, flush, valid == '0)
  `RAPT_SVA_NEXT(clock, reset, TLB_SFENCE_CLEARS_ENTRIES, sfence_valid, valid == '0)
endmodule

// True LRU over a fully associative TLB. A lookup hit is registered and
// recorded one cycle later; a fill is recorded on its write edge and wins.
module rapt_tlb_lru #(
    parameter int unsigned Entries = 16,
    parameter bit Plru = 0,
    parameter int unsigned EntryIdxW = $clog2(Entries)
) (
    input logic clock,
    input logic reset,
    input logic flush,
    input logic [Entries-1:0] match_vec,
    input logic lookup_valid,
    input logic fill_valid,
    input logic [EntryIdxW-1:0] fill_idx,
    output logic [EntryIdxW-1:0] victim
);
  logic touch_q;
  logic [EntryIdxW-1:0] touch_idx_q;
  logic [EntryIdxW-1:0] match_idx;
  logic [1:0] update_valid;
  logic [EntryIdxW-1:0] update_way[2];
  logic read_set[1], update_set[2];
  logic [EntryIdxW-1:0] victims[1];
  always_comb begin
    match_idx = '0;
    for (int i = 0; i < Entries; i++) if (match_vec[i]) match_idx = EntryIdxW'(i);
  end
  always_ff @(posedge clock) begin
    touch_q <= lookup_valid && |match_vec && !reset && !flush;
    touch_idx_q <= match_idx;
  end
  assign update_valid = {fill_valid, touch_q};
  assign update_way[0] = touch_idx_q;
  assign update_way[1] = fill_idx;
  assign read_set[0] = 1'b0;
  assign update_set[0] = 1'b0;
  assign update_set[1] = 1'b0;
  if (Plru && (Entries & (Entries - 1)) == 0) begin : g_plru
    rapt_cache_plru #(
        .Ways(Entries),
        .SetBits(1),
        .ReadPorts(1)
    ) u_policy (
        .clock,
        .reset,
        .invalidate(flush),
        .read_set,
        .victim(victims),
        .update_valid,
        .update_set,
        .update_way
    );
  end else begin : g_lru
    rapt_cache_lru #(
        .Ways(Entries),
        .SetBits(1),
        .ReadPorts(1)
    ) u_policy (
        .clock,
        .reset,
        .invalidate(flush),
        .read_set,
        .victim(victims),
        .update_valid,
        .update_set,
        .update_way
    );
  end
  assign victim = victims[0];
endmodule
/* verilator lint_on DECLFILENAME */
