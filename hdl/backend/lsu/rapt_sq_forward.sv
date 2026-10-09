`include "rapt.svh"

// Read-only view of the ordered SQ. All load ports use identical alias and
// youngest-store rules; a younger partial match must block an older full one.
module rapt_sq_forward #(
    parameter int Xlen = `RAPT_XLEN,
    parameter int Entries = `RAPT_SQ_SIZE,
    parameter int ReadPorts = 2,
    parameter bit NarrowForward = 1'b1,
    parameter int IndexBits = $clog2(Entries),
    // Use registered neighbour block numbers of each resident store instead
    // of incrementing addresses inside every CAM lane.
    parameter bit PrecomputedBlocks = 1'b0
) (
    input logic [IndexBits-1:0] head,
    input logic [Entries-1:0] valid,
    input logic [Entries-1:0] stale_context,
    input logic [Xlen-1:0] store_addr[Entries],
    input logic [Xlen-$clog2(Xlen/8)-3:0] store_next_block[Entries] = '{default: '0},
    input logic [Xlen-$clog2(Xlen/8)-3:0] store_prev_block[Entries] = '{default: '0},
    input logic [Xlen-1:0] store_data[Entries],
    input logic [4:0] store_alu[Entries],
    input logic store_fp64[Entries],
    input logic [7:0] full_store_mask,
    input logic mmu_enabled,
    input logic [ReadPorts-1:0] narrow_allowed = '1,
    input logic alloc_valid,
    input logic [4:0] alloc_alu,
    input logic [Xlen-1:0] load_addr[ReadPorts],
    input logic [3:0] load_size_m1[ReadPorts],
    output logic [ReadPorts-1:0] conflict,
    output logic [ReadPorts-1:0] forward_valid,
    output logic [Xlen-1:0] forward_data[ReadPorts]
);
  localparam int OffsetBits = $clog2(Xlen / 8);
  // Number of additional machine words touched, including RV32 FSD's
  // possible third word. Keep the original VA across split-store drain.
  function automatic logic [1:0] store_span(input logic [OffsetBits-1:0] offset,
                                            input logic [4:0] alu, input logic fp64);
    logic [3:0] size_m1;
    case (alu)
      `RAPT_SB_WSTRB: size_m1 = 0;
      `RAPT_SH_WSTRB: size_m1 = 1;
      `RAPT_SD_WSTRB: size_m1 = 7;
      default: size_m1 = 3;
    endcase
    if (fp64) size_m1 = 7;
    return 2'((4'(offset) + size_m1) >> OffsetBits);
  endfunction
  function automatic logic word_in_store(input logic [Xlen-1:0] store_va,
                                         input logic [Xlen-1:0] load_va, input logic [1:0] span,
                                         input logic [1:0] load_span, input logic page_only);
    logic [1:0] delta, reverse_delta;
    logic borrow_word, reverse_borrow, same_block, next_block, previous_block;
    // Both spans are at most three words. Split the modular difference into
    // two low bits and a block relation: no borrow needs equal high bits;
    // a borrow needs the next block (including page/XLEN wrap). This avoids
    // a full-width subtract/compare chain for every store/load CAM pair.
    delta = load_va[OffsetBits+:2] - store_va[OffsetBits+:2];
    reverse_delta = store_va[OffsetBits+:2] - load_va[OffsetBits+:2];
    borrow_word = load_va[OffsetBits+:2] < store_va[OffsetBits+:2];
    reverse_borrow = store_va[OffsetBits+:2] < load_va[OffsetBits+:2];
    if (page_only) begin
      same_block = load_va[11:OffsetBits+2] == store_va[11:OffsetBits+2];
      next_block = load_va[11:OffsetBits+2]
          == (10-OffsetBits)'(store_va[11:OffsetBits+2] + 1'b1);
      previous_block = store_va[11:OffsetBits+2]
          == (10-OffsetBits)'(load_va[11:OffsetBits+2] + 1'b1);
    end else begin
      same_block = load_va[Xlen-1:OffsetBits+2] == store_va[Xlen-1:OffsetBits+2];
      next_block = load_va[Xlen-1:OffsetBits+2]
          == (Xlen-OffsetBits-2)'(store_va[Xlen-1:OffsetBits+2] + 1'b1);
      previous_block = store_va[Xlen-1:OffsetBits+2]
          == (Xlen-OffsetBits-2)'(load_va[Xlen-1:OffsetBits+2] + 1'b1);
    end
    return ((borrow_word ? next_block : same_block) && delta <= span)
        || ((reverse_borrow ? previous_block : same_block) && reverse_delta <= load_span);
  endfunction
  // Same relation as word_in_store with store block + 1 / - 1 supplied.
  // load == store + 1 and store == load + 1 hold modulo every low slice.
  function automatic logic word_in_store_pre(
      input logic [Xlen-1:0] store_va, input logic [Xlen-OffsetBits-3:0] store_next,
      input logic [Xlen-OffsetBits-3:0] store_prev, input logic [Xlen-1:0] load_va,
      input logic [1:0] span, input logic [1:0] load_span, input logic page_only);
    logic [1:0] delta, reverse_delta;
    logic borrow_word, reverse_borrow, same_block, next_block, previous_block;
    delta = load_va[OffsetBits+:2] - store_va[OffsetBits+:2];
    reverse_delta = store_va[OffsetBits+:2] - load_va[OffsetBits+:2];
    borrow_word = load_va[OffsetBits+:2] < store_va[OffsetBits+:2];
    reverse_borrow = store_va[OffsetBits+:2] < load_va[OffsetBits+:2];
    if (page_only) begin
      same_block = load_va[11:OffsetBits+2] == store_va[11:OffsetBits+2];
      next_block = load_va[11:OffsetBits+2] == store_next[9-OffsetBits:0];
      previous_block = load_va[11:OffsetBits+2] == store_prev[9-OffsetBits:0];
    end else begin
      same_block = load_va[Xlen-1:OffsetBits+2] == store_va[Xlen-1:OffsetBits+2];
      next_block = load_va[Xlen-1:OffsetBits+2] == store_next;
      previous_block = load_va[Xlen-1:OffsetBits+2] == store_prev;
    end
    return ((borrow_word ? next_block : same_block) && delta <= span)
        || ((reverse_borrow ? previous_block : same_block) && reverse_delta <= load_span);
  endfunction
  function automatic logic [3:0] store_size_m1(input logic [4:0] alu);
    case (alu)
      `RAPT_SB_WSTRB: return 0;
      `RAPT_SH_WSTRB: return 1;
      `RAPT_SW_WSTRB: return 3;
      `RAPT_SD_WSTRB: return 7;
      default: return 0;
    endcase
  endfunction
  logic [1:0] store_words[Entries];
  for (genvar entry_idx = 0; entry_idx < Entries; entry_idx++) begin : g_span
    assign store_words[entry_idx] = store_span(
        store_addr[entry_idx][OffsetBits-1:0], store_alu[entry_idx], store_fp64[entry_idx]
    );
  end
  logic zero_pending;
  if (!(Entries > 1 && (Entries & (Entries - 1)) == 0 && IndexBits == $clog2(
          Entries
      ) && ReadPorts > 0)) begin : g_invalid_config
    $error("Invalid rapt_sq_forward configuration");
  end
  always_comb begin
    zero_pending = alloc_valid && alloc_alu == `RAPT_CBO_ZERO_WALU;
    for (int entry_idx = 0; entry_idx < Entries; entry_idx++)
    zero_pending |= valid[entry_idx] && store_alu[entry_idx] == `RAPT_CBO_ZERO_WALU;
  end
  for (genvar port_idx = 0; port_idx < ReadPorts; port_idx++) begin : g_read
    logic [1:0] load_words;
    logic [Entries-1:0] slot_match, before_head, candidates, winner, eligible;
    logic alloc_match;
    assign load_words = 2'((4'(load_addr[port_idx][OffsetBits-1:0])
                            + load_size_m1[port_idx]) >> OffsetBits);
    // Compare physical slots before selecting by age. Rotating wide address
    // and data arrays by head would replicate a mux in front of every CAM lane.
    for (genvar entry_idx = 0; entry_idx < Entries; entry_idx++) begin : g_match
      // A retained store can belong to a previous translation context, even
      // when the current load is Bare. Stale VA equality cannot forward data.
      if (PrecomputedBlocks) begin : g_pre
        assign slot_match[entry_idx] = valid[entry_idx] && word_in_store_pre(
            store_addr[entry_idx],
            store_next_block[entry_idx],
            store_prev_block[entry_idx],
            load_addr[port_idx],
            store_words[entry_idx],
            load_words,
            mmu_enabled || stale_context[entry_idx]
        );
      end else begin : g_live
        assign slot_match[entry_idx] = valid[entry_idx] && word_in_store(
            store_addr[entry_idx],
            load_addr[port_idx],
            store_words[entry_idx],
            load_words,
            mmu_enabled || stale_context[entry_idx]
        );
      end
      assign eligible[entry_idx] = !stale_context[entry_idx]
          && load_words == 0
          && store_addr[entry_idx][Xlen-1:OffsetBits] == load_addr[port_idx][Xlen-1:OffsetBits]
          && ((store_addr[entry_idx][OffsetBits-1:0] == '0
                  && 8'(store_alu[entry_idx]) == full_store_mask)
              || (NarrowForward && !mmu_enabled && narrow_allowed[port_idx] && !store_fp64[entry_idx]
                  && store_words[entry_idx] == 0
                  && (store_alu[entry_idx] inside {`RAPT_SB_WSTRB, `RAPT_SH_WSTRB,
                                                  `RAPT_SW_WSTRB, `RAPT_SD_WSTRB})
                  && store_addr[entry_idx][OffsetBits-1:0]
                      <= load_addr[port_idx][OffsetBits-1:0]
                  && (5'(load_addr[port_idx][OffsetBits-1:0])
                        + 5'(load_size_m1[port_idx]))
                      <= (5'(store_addr[entry_idx][OffsetBits-1:0])
                            + 5'(store_size_m1(
          store_alu[entry_idx]
      )))));
      if (entry_idx == Entries - 1) begin : g_last
        assign before_head[entry_idx] = 1'b0;
        assign winner[entry_idx] = candidates[entry_idx];
      end else begin : g_not_last
        assign before_head[entry_idx] = slot_match[entry_idx] && IndexBits'(entry_idx) < head;
        assign winner[entry_idx] = candidates[entry_idx]
            && !(|candidates[Entries-1:entry_idx+1]);
      end
    end
    // Ring order is head..Entries-1, then 0..head-1. The highest matching
    // index in the second segment wins, or the highest overall if it is empty.
    // Choose among ALL aliases: a younger partial/stale store blocks an older
    // full store, so eligibility must not participate in priority selection.
    assign candidates = (|before_head) ? before_head : slot_match;
    // The impending allocation only blocks; it never supplies data. Blocking
    // every port while a store is handed off keeps the store's address
    // arithmetic off the same-cycle load forwarding and L1D request path.
    assign alloc_match = alloc_valid;
    assign conflict[port_idx] = zero_pending || alloc_match || (|slot_match);
    // An accepted allocation is younger than every resident store, but cannot
    // provide data yet. CBO.ZERO likewise blocks forwarding on every port.
    assign forward_valid[port_idx] = !zero_pending && !alloc_match && (|(winner & eligible));
    always_comb begin
      forward_data[port_idx] = '0;
      for (int entry_idx = 0; entry_idx < Entries; entry_idx++) begin
        forward_data[port_idx] |= (NarrowForward
            ? store_data[entry_idx] << (store_addr[entry_idx][OffsetBits-1:0] * 8)
            : store_data[entry_idx]) & {Xlen{winner[entry_idx]}};
      end
    end
  end
endmodule
