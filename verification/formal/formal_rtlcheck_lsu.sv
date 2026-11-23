`include "rapt.svh"

// RTLCheck-style microarchitectural RVWMO ordering & forwarding proof for
// `rapt_sq_forward` (store-to-load forwarding, youngest-store dominance,
// younger partial/stale blocking, CBO.ZERO/alloc barriers, and precomputed
// block-number equivalence).
module formal_rtlcheck_lsu #(
    parameter int Xlen = `RAPT_XLEN,
    parameter int Entries = 4,
    parameter int ReadPorts = 1,
    parameter bit NarrowForward = 1'b1
) (
    input logic [$clog2(Entries)-1:0] head,
    input logic [Entries-1:0] valid,
    input logic [Entries-1:0] stale_context,
    input logic [Xlen-1:0] store_addr[Entries],
    input logic [Xlen-1:0] store_data[Entries],
    input logic [4:0] store_alu[Entries],
    input logic store_fp64[Entries],
    input logic mmu_enabled,
    input logic [ReadPorts-1:0] narrow_allowed,
    input logic alloc_valid,
    input logic [4:0] alloc_alu,
    input logic [Xlen-1:0] load_addr[ReadPorts],
    input logic [3:0] load_size_m1[ReadPorts]
);
  localparam int OffsetBits = $clog2(Xlen / 8);
  localparam int BlockBits = Xlen - OffsetBits - 2;
  localparam int IndexBits = $clog2(Entries);
  localparam logic [7:0] FullStoreMask = (Xlen == 64) ? `RAPT_SD_WSTRB : `RAPT_SW_WSTRB;

  logic [BlockBits-1:0] store_next_block[Entries];
  logic [BlockBits-1:0] store_prev_block[Entries];
  for (genvar i = 0; i < Entries; i++) begin : g_blocks
    assign store_next_block[i] = store_addr[i][Xlen-1:OffsetBits+2] + BlockBits'(1);
    assign store_prev_block[i] = store_addr[i][Xlen-1:OffsetBits+2] - BlockBits'(1);
  end

  logic [ReadPorts-1:0] conflict_live, forward_valid_live;
  logic [Xlen-1:0] forward_data_live[ReadPorts];
  logic [ReadPorts-1:0] conflict_pre, forward_valid_pre;
  logic [Xlen-1:0] forward_data_pre[ReadPorts];

  rapt_sq_forward #(
      .Xlen(Xlen),
      .Entries(Entries),
      .ReadPorts(ReadPorts),
      .NarrowForward(NarrowForward),
      .PrecomputedBlocks(1'b0)
  ) dut_live (
      .head(head),
      .valid(valid),
      .stale_context(stale_context),
      .store_addr(store_addr),
      .store_next_block(store_next_block),
      .store_prev_block(store_prev_block),
      .store_data(store_data),
      .store_alu(store_alu),
      .store_fp64(store_fp64),
      .full_store_mask(FullStoreMask),
      .mmu_enabled(mmu_enabled),
      .narrow_allowed(narrow_allowed),
      .alloc_valid(alloc_valid),
      .alloc_alu(alloc_alu),
      .load_addr(load_addr),
      .load_size_m1(load_size_m1),
      .conflict(conflict_live),
      .forward_valid(forward_valid_live),
      .forward_data(forward_data_live)
  );

  rapt_sq_forward #(
      .Xlen(Xlen),
      .Entries(Entries),
      .ReadPorts(ReadPorts),
      .NarrowForward(NarrowForward),
      .PrecomputedBlocks(1'b1)
  ) dut_pre (
      .head(head),
      .valid(valid),
      .stale_context(stale_context),
      .store_addr(store_addr),
      .store_next_block(store_next_block),
      .store_prev_block(store_prev_block),
      .store_data(store_data),
      .store_alu(store_alu),
      .store_fp64(store_fp64),
      .full_store_mask(FullStoreMask),
      .mmu_enabled(mmu_enabled),
      .narrow_allowed(narrow_allowed),
      .alloc_valid(alloc_valid),
      .alloc_alu(alloc_alu),
      .load_addr(load_addr),
      .load_size_m1(load_size_m1),
      .conflict(conflict_pre),
      .forward_valid(forward_valid_pre),
      .forward_data(forward_data_pre)
  );

  // Independent RVWMO reference model walking entries strictly in program order:
  // oldest = head, youngest = (head + Entries - 1) mod Entries.
  function automatic logic [3:0] ref_store_size_m1(input logic [4:0] alu, input logic fp64);
    if (fp64) return 4'd7;
    if (alu == `RAPT_SB_WSTRB) return 4'd0;
    if (alu == `RAPT_SH_WSTRB) return 4'd1;
    if (alu == `RAPT_SW_WSTRB) return 4'd3;
    if (alu == `RAPT_SD_WSTRB) return 4'd7;
    return 4'd3;
  endfunction

  function automatic logic ref_words_overlap(input logic [Xlen-1:0] sva, input logic [1:0] sspan,
                                             input logic [Xlen-1:0] lva, input logic [1:0] lspan,
                                             input logic page_only);
    logic hit;
    hit = 1'b0;
    for (int sw = 0; sw < 4; sw++) begin
      for (int lw = 0; lw < 4; lw++) begin
        if (sw <= int'(sspan) && lw <= int'(lspan)) begin
          if (page_only) begin
            logic [11-OffsetBits:0] s_w, l_w;
            s_w = sva[11:OffsetBits] + (12-OffsetBits)'(sw);
            l_w = lva[11:OffsetBits] + (12-OffsetBits)'(lw);
            if (s_w == l_w) hit = 1'b1;
          end else begin
            logic [Xlen-1-OffsetBits:0] s_w, l_w;
            s_w = sva[Xlen-1:OffsetBits] + (Xlen-OffsetBits)'(sw);
            l_w = lva[Xlen-1:OffsetBits] + (Xlen-OffsetBits)'(lw);
            if (s_w == l_w) hit = 1'b1;
          end
        end
      end
    end
    return hit;
  endfunction

  logic ref_zero_pending;
  always_comb begin
    ref_zero_pending = alloc_valid && (alloc_alu == `RAPT_CBO_ZERO_WALU);
    for (int i = 0; i < Entries; i++) begin
      if (valid[i] && store_alu[i] == `RAPT_CBO_ZERO_WALU) ref_zero_pending = 1'b1;
    end
  end

  for (genvar p = 0; p < ReadPorts; p++) begin : g_check
    logic [1:0] ref_lspan;
    logic ref_any_match;
    logic ref_youngest_elig;
    logic [Xlen-1:0] ref_fwd_data;
    logic ref_conflict, ref_forward_valid;

    always_comb begin
      // Constrain load_size_m1 to architectural scalar/FP sizes (1, 2, 4, 8 bytes).
      assume (load_size_m1[p] == 4'd0 || load_size_m1[p] == 4'd1
              || load_size_m1[p] == 4'd3 || (Xlen == 64 && load_size_m1[p] == 4'd7));

      ref_lspan = 2'((4'(load_addr[p][OffsetBits-1:0]) + load_size_m1[p]) >> OffsetBits);
      ref_any_match = 1'b0;
      ref_youngest_elig = 1'b0;
      ref_fwd_data = '0;

      // Walk strictly from oldest (age=0 -> head) to youngest (age=Entries-1).
      // Any younger alias overwrites ref_youngest_elig, enforcing youngest dominance!
      for (int age = 0; age < Entries; age++) begin
        logic [IndexBits-1:0] slot;
        logic [3:0] s_sm1;
        logic [1:0] s_span;
        logic ov, byte_ov;
        logic full_match, narrow_match;
        slot = head + IndexBits'(age);
        s_sm1 = ref_store_size_m1(store_alu[slot], store_fp64[slot]);
        s_span = 2'((4'(store_addr[slot][OffsetBits-1:0]) + s_sm1) >> OffsetBits);
        byte_ov = !NarrowForward || (s_span != 2'd0) || (ref_lspan != 2'd0)
            || ((5'(store_addr[slot][OffsetBits-1:0])
                 <= 5'(load_addr[p][OffsetBits-1:0]) + 5'(load_size_m1[p]))
                && (5'(load_addr[p][OffsetBits-1:0])
                    <= 5'(store_addr[slot][OffsetBits-1:0]) + 5'(s_sm1)));
        ov = valid[slot] && byte_ov && ref_words_overlap(
            store_addr[slot], s_span, load_addr[p], ref_lspan, mmu_enabled || stale_context[slot]
        );
        if (ov) begin
          ref_any_match = 1'b1;
          full_match = (store_addr[slot][OffsetBits-1:0] == '0)
              && (8'(store_alu[slot]) == FullStoreMask);
          narrow_match = NarrowForward && !mmu_enabled && narrow_allowed[p]
              && !store_fp64[slot] && (s_span == 2'd0)
              && (store_alu[slot] == `RAPT_SB_WSTRB || store_alu[slot] == `RAPT_SH_WSTRB
                  || store_alu[slot] == `RAPT_SW_WSTRB || store_alu[slot] == `RAPT_SD_WSTRB)
              && (store_addr[slot][OffsetBits-1:0] <= load_addr[p][OffsetBits-1:0])
              && ((5'(load_addr[p][OffsetBits-1:0]) + 5'(load_size_m1[p]))
                  <= (5'(store_addr[slot][OffsetBits-1:0]) + 5'(s_sm1)));
          if (!stale_context[slot] && (ref_lspan == 2'd0)
              && (store_addr[slot][Xlen-1:OffsetBits] == load_addr[p][Xlen-1:OffsetBits])
              && (full_match || narrow_match)) begin
            ref_youngest_elig = 1'b1;
            ref_fwd_data = NarrowForward
                ? (store_data[slot] << (store_addr[slot][OffsetBits-1:0] * 8))
                : store_data[slot];
          end else begin
            // Younger partial/stale/cross-word alias MUST block older full store!
            ref_youngest_elig = 1'b0;
            ref_fwd_data = '0;
          end
        end
      end

      ref_conflict = ref_zero_pending || alloc_valid || ref_any_match;
      ref_forward_valid = !ref_zero_pending && !alloc_valid && ref_youngest_elig;

      // Axiom 1: CoWR soundness (exact conflict match)
      axiom_conflict : assert (conflict_live[p] == ref_conflict);
      // Axiom 2: Youngest-store dominance & forwarding validity
      axiom_forward_valid : assert (forward_valid_live[p] == ref_forward_valid);
      // Axiom 3: Forwarded data matches exact youngest eligible store bytes
      if (ref_forward_valid) begin
        axiom_forward_data : assert (forward_data_live[p] == ref_fwd_data);
      end
      // Axiom 4: Forwarding implies conflict and no CBO.ZERO/alloc barrier
      axiom_barrier :
      assert (!forward_valid_live[p] || (conflict_live[p] && !ref_zero_pending && !alloc_valid));
      // Axiom 5: Precomputed block-number variant is bit-identical
      axiom_pre_equiv :
      assert (conflict_pre[p] == conflict_live[p]
                               && forward_valid_pre[p] == forward_valid_live[p]
                               && (!forward_valid_live[p]
                                   || forward_data_pre[p] == forward_data_live[p]));
    end
  end
endmodule
