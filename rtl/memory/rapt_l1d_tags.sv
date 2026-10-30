`include "rapt.svh"

// L1D tag/valid ownership and replacement lookup. Reads are combinational;
// updates and fence invalidation occur on the same edge as the data write.
// The controller retains transaction sequencing and the two-way toggle.
module rapt_l1d_tags #(
    parameter int L1D_LEN = `RAPT_L1D_LEN,
    parameter int L1D_LINE_LEN = `RAPT_L1D_LINE_LEN,
    parameter int L1D_SIZE = 2 ** L1D_LEN,
    parameter int L1D_LINE_SIZE = 2 ** L1D_LINE_LEN,
    parameter int L1D_N_WAYS = `RAPT_L1D_WAYS,
    parameter int L1dTagW = `RAPT_PADDR_BITS - L1D_LEN - L1D_LINE_LEN - $clog2(`RAPT_XLEN / 8),
    parameter int L1dWayW = L1D_N_WAYS > 1 ? $clog2(L1D_N_WAYS) : 1,
    parameter bit WriteBack = 1'b0,
    parameter bit DirtySkip = 1'b0,
    // True LRU for 2-16 ways instead of the 2-way fill toggle / tree PLRU.
    parameter bit CacheLru = `RAPT_CACHE_LRU != 0,
    // Controller phases share A/B lookup and store/writeback inspection.
    parameter bit SharedReadPorts = 1'b0,
    parameter bit CacheNru = `RAPT_L1D_NRU != 0
) (
    input logic clock,
    input logic reset,
    input logic fence_time,
    input logic probe_read = 1'b0,
    input logic inspect_read = 1'b0,
    // 0: load/probe, 1: store/inspect, 2: physical clear, 3: update.
    input logic [1:0] inspect_source = 2'b0,
    input logic [L1D_SIZE-1:0] clear_set,
    input logic clear_enable = 1'b1,
    input logic clear_line_valid = 1'b0,
    input logic [L1D_LEN-1:0] clear_line_idx = '0,
    input logic [L1dTagW-1:0] clear_line_tag = '0,
    output logic [L1D_N_WAYS-1:0] clear_line_dirty_way,
    input logic [L1D_LEN-1:0] addr_idx,
    input logic [L1D_LINE_LEN-1:0] addr_offset,
    input logic [L1dTagW-1:0] addr_tag,
    input logic [L1D_LEN-1:0] waddr_idx,
    input logic [L1D_LINE_LEN-1:0] waddr_offset,
    input logic [L1dTagW-1:0] waddr_tag,
    input logic [L1D_LEN-1:0] probe_idx,
    input logic [L1D_LINE_LEN-1:0] probe_offset,
    input logic [L1dTagW-1:0] probe_tag,
    input logic load_hit,
    input logic load_replace,
    input logic store_replace,
    output logic [L1D_N_WAYS-1:0] load_way_hit,
    output logic [L1D_N_WAYS-1:0] probe_way_hit,
    output logic hit_w,
    output logic [L1dWayW-1:0] store_hit_way,
    output logic [L1dWayW-1:0] store_fill_way,
    output logic [L1dWayW-1:0] ld_fill_way,
    output logic [L1dTagW-1:0] load_victim_tag,
    output logic load_victim_valid,
    output logic load_victim_dirty,
    input logic l1d_update,
    input logic l1d_valid_u,
    input logic line_update = 1'b0,
    input logic [L1D_LINE_SIZE-1:0] line_mask = '0,
    input logic l1d_inv_all_ways,
    input logic [L1dTagW-1:0] l1d_tag_u,
    input logic [L1D_LEN-1:0] l1d_idx,
    input logic [L1D_LINE_LEN-1:0] l1d_off,
    input logic [L1dWayW-1:0] l1d_way,
    input logic update_dirty = 1'b0,
    input logic [L1D_LEN-1:0] inspect_set = '0,
    input logic [L1dWayW-1:0] inspect_way = '0,
    // Cleaning retires the whole line's dirty state (clean_mask must be '1).
    input logic clean_valid = 1'b0,
    input logic [L1D_LINE_SIZE-1:0] clean_mask = '0,
    output logic [L1dTagW-1:0] inspect_tag,
    output logic [L1D_LINE_SIZE-1:0] inspect_valid,
    output logic [L1D_LINE_SIZE-1:0] inspect_dirty,
    output logic dirty_any,
    output logic [L1D_LEN-1:0] first_dirty_set,
    output logic [L1dWayW-1:0] first_dirty_way,
    output logic inspect_dirty_any,
    output logic update_blocked
);
  // Bulk set invalidation still needs one live bit per line. Tags and word
  // validity share one entry, with one indexed writer per way. Independent
  // asynchronous reads are replicated by synthesis only where needed.
  localparam int EntryBits = L1dTagW + L1D_LINE_SIZE;
  logic line_live[L1D_N_WAYS][L1D_SIZE];
  logic line_dirty_q[L1D_N_WAYS][L1D_SIZE];
  logic [L1D_N_WAYS-1:0] dirty_next[L1D_SIZE];
  logic [L1D_SIZE-1:0] dirty_set_q, dirty_set_next;
  logic [L1D_LINE_SIZE-1:0] valid_addr[L1D_N_WAYS], valid_waddr[L1D_N_WAYS];
  logic [L1D_LINE_SIZE-1:0] valid_probe[L1D_N_WAYS], valid_inspect[L1D_N_WAYS];
  logic [L1D_LINE_SIZE-1:0] valid_update[L1D_N_WAYS];
  logic [L1D_LINE_SIZE-1:0] dirty_inspect[L1D_N_WAYS], dirty_update[L1D_N_WAYS];
  logic [L1D_N_WAYS-1:0] word_write;
  logic [L1D_LINE_SIZE-1:0] valid_write_data[L1D_N_WAYS], dirty_write_data[L1D_N_WAYS];
  logic update_enable;
  logic update_allowed;
  logic clear_any;
  assign clear_any = clear_enable && |clear_set;
  logic [L1D_LEN-1:0] load_read_idx, store_read_idx;
  assign load_read_idx = SharedReadPorts && probe_read ? probe_idx : addr_idx;
  assign store_read_idx = SharedReadPorts && inspect_read ? inspect_set : waddr_idx;
  logic [L1dTagW-1:0] tag_addr_data[L1D_N_WAYS];
  logic [L1dTagW-1:0] tag_waddr_data[L1D_N_WAYS];
  logic [L1dTagW-1:0] tag_probe_data[L1D_N_WAYS];
  logic [L1dTagW-1:0] tag_update_data[L1D_N_WAYS];
  logic [L1dTagW-1:0] tag_clear_data[L1D_N_WAYS];
  logic [L1dTagW-1:0] tag_inspect_data[L1D_N_WAYS];
  logic [EntryBits-1:0] entry_addr[L1D_N_WAYS], entry_waddr[L1D_N_WAYS];
  logic [EntryBits-1:0] entry_probe[L1D_N_WAYS], entry_update[L1D_N_WAYS];
  logic [EntryBits-1:0] entry_clear[L1D_N_WAYS], entry_inspect[L1D_N_WAYS];
  logic [L1D_N_WAYS-1:0] clear_tag_match;
  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_tag_storage
    logic [EntryBits-1:0] entries[L1D_SIZE];
    wire [L1dTagW-1:0] write_tag = l1d_valid_u ? l1d_tag_u : tag_update_data[way];
    always_ff @(posedge clock)
      if (word_write[way])
        entries[l1d_idx] <= {write_tag, valid_write_data[way]};
    assign entry_addr[way] = entries[load_read_idx];
    assign entry_waddr[way] = entries[store_read_idx];
    assign entry_update[way] = entries[l1d_idx];
    assign entry_clear[way] = entries[clear_line_idx];
    if (SharedReadPorts) begin : g_shared
      assign entry_probe[way] = entry_addr[way];
      always_comb begin
        case (inspect_source)
          2'd0: entry_inspect[way] = entry_addr[way];
          2'd1: entry_inspect[way] = entry_waddr[way];
          2'd2: entry_inspect[way] = entry_clear[way];
          default: entry_inspect[way] = entry_update[way];
        endcase
      end
    end else begin : g_independent
      assign entry_probe[way] = entries[probe_idx];
      assign entry_inspect[way] = entries[inspect_set];
    end
    assign tag_addr_data[way] = entry_addr[way][L1D_LINE_SIZE+:L1dTagW];
    assign tag_waddr_data[way] = entry_waddr[way][L1D_LINE_SIZE+:L1dTagW];
    assign tag_update_data[way] = entry_update[way][L1D_LINE_SIZE+:L1dTagW];
    assign tag_clear_data[way] = entry_clear[way][L1D_LINE_SIZE+:L1dTagW];
    assign tag_probe_data[way] = entry_probe[way][L1D_LINE_SIZE+:L1dTagW];
    assign tag_inspect_data[way] = entry_inspect[way][L1D_LINE_SIZE+:L1dTagW];
    assign clear_tag_match[way] = tag_clear_data[way] == clear_line_tag;
  end
  logic [L1D_N_WAYS-1:0] dirty_conflict;
  logic [L1D_N_WAYS-1:0] update_tag_match;
  logic clear_blocked;

  // The accepted load owns this read independently of store/refill probes.
  assign load_victim_tag = tag_addr_data[ld_fill_way];
  assign load_victim_valid = |valid_addr[ld_fill_way];
  assign load_victim_dirty = line_dirty_q[ld_fill_way][addr_idx];
  assign inspect_tag = tag_inspect_data[inspect_way];
  assign inspect_valid = valid_inspect[inspect_way];
  assign inspect_dirty = dirty_inspect[inspect_way];
  // The line summary is maintained with the word mask. Arbitration needs
  // only this bit; keep the full mask selection off its combinational path.
  assign inspect_dirty_any = line_dirty_q[inspect_way][inspect_set];
  assign update_allowed = !update_blocked;
  // Reduce the registered clear-set/dirty state before the common enable.
  // Writeback arbitration may arrive late; it must not traverse every line's
  // clear test and the cache-wide reduction before reaching update_allowed.
  assign update_blocked = WriteBack && ((clear_enable && clear_blocked) || |dirty_conflict);

  // Summaries describe the same edge as the per-line flags. Computing
  // them from next state moves the cache-wide reduction off arbitration.
  for (genvar set_idx = 0; set_idx < L1D_SIZE; set_idx++) begin : g_dirty_summary
    assign dirty_set_next[set_idx] = |dirty_next[set_idx];
  end
  always_ff @(posedge clock) begin
    dirty_set_q <= dirty_set_next;
    dirty_any <= |dirty_set_next;
  end
  assign clear_blocked = |(clear_set & dirty_set_q);

  if (WriteBack && DirtySkip) begin : g_dirty_select
    always_comb begin
      first_dirty_set = '0;
      for (int set_idx = L1D_SIZE - 1; set_idx >= 0; set_idx--)
      if (dirty_set_q[set_idx]) first_dirty_set = L1D_LEN'(set_idx);
      first_dirty_way = '0;
      for (int way = L1D_N_WAYS - 1; way >= 0; way--)
      if (line_dirty_q[way][first_dirty_set]) first_dirty_way = L1dWayW'(way);
    end
  end else begin : g_no_dirty_select
    assign first_dirty_set = '0;
    assign first_dirty_way = '0;
  end

  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_dirty_conflict
    always_comb begin
      dirty_conflict[way] = 1'b0;
      if (l1d_update && line_dirty_q[way][l1d_idx]) begin
        if (l1d_valid_u) begin
          if (l1d_way == L1dWayW'(way))
            dirty_conflict[way] = !update_tag_match[way]
              || line_update
                || (!line_update && !update_dirty && dirty_update[way][l1d_off]);
          else dirty_conflict[way] = update_tag_match[way];
        end else
          dirty_conflict[way] = (l1d_inv_all_ways || l1d_way == L1dWayW'(way))
              && update_tag_match[way]
              && dirty_update[way][l1d_off];
      end
    end
  end

  if (!(L1D_LEN > 0 && L1D_LINE_LEN > 0 && L1dTagW > 0
        && L1D_SIZE == 2 ** L1D_LEN && L1D_LINE_SIZE == 2 ** L1D_LINE_LEN
        && L1D_N_WAYS > 0 && (L1D_N_WAYS & (L1D_N_WAYS - 1)) == 0
        && L1dWayW == (L1D_N_WAYS > 1 ? $clog2(
          L1D_N_WAYS
      ) : 1))) begin : g_invalid_config
    $error("Invalid rapt_l1d_tags configuration");
  end

  // Compare each line tag once, then select only the requested word's valid bit.
  logic [L1D_N_WAYS-1:0] way_tag_match;
  generate
    for (genvar w = 0; w < L1D_N_WAYS; w++) begin : gen_line_tag_cmp
      assign way_tag_match[w] = (tag_addr_data[w] == addr_tag);
      assign load_way_hit[w] = valid_addr[w][addr_offset] & way_tag_match[w];
    end
  endgenerate
  logic [L1D_N_WAYS-1:0] way_wtag_match;
  logic [L1D_N_WAYS-1:0] load_live_match, store_live_match;
  logic [L1D_N_WAYS-1:0] load_line_valid, store_line_valid;
  logic [L1dWayW-1:0] victims[2];
  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_candidates
    assign load_live_match[way] = way_tag_match[way] && |valid_addr[way];
    assign store_live_match[way] = way_wtag_match[way] && |valid_waddr[way];
    assign load_line_valid[way] = |valid_addr[way];
    assign store_line_valid[way] = |valid_waddr[way];
  end
  if (L1D_N_WAYS > 2 || ((CacheLru || CacheNru) && L1D_N_WAYS == 2)) begin : g_replacement
    logic [L1D_LEN-1:0] read_set[2], update_set[2];
    logic [L1dWayW-1:0] update_way[2];
    logic [1:0] update_valid;
    assign read_set[0] = addr_idx;
    assign read_set[1] = waddr_idx;
    assign update_set[0] = addr_idx;
    assign update_set[1] = l1d_idx;
    assign update_valid = {
      l1d_update && l1d_valid_u && !clear_any && !clear_line_valid && update_allowed, load_hit
    };
    assign update_way[1] = l1d_way;
    always_comb begin
      update_way[0] = '0;
      for (int way = L1D_N_WAYS - 1; way >= 0; way--)
      if (load_way_hit[way]) update_way[0] = L1dWayW'(way);
    end
    if (CacheNru) begin : g_nru
      // A cache hit excludes every pending array update in the controller.
      // Reserve the row from registered metadata; late conflict checks only
      // gate the write enable, never the RAM address.
      rapt_cache_nru #(
          .Ways(L1D_N_WAYS),
          .SetBits(L1D_LEN)
      ) u_policy (
          .clock(clock),
          .reset(reset),
          .invalidate(`RAPT_SFENCE_KEEP_STATE < 1 && fence_time),
          .read_set(read_set),
          .victim(victims),
          .update_valid(|update_valid),
          .update_set(l1d_update ? update_set[1] : update_set[0]),
          .update_way(l1d_update ? update_way[1] : update_way[0])
      );
      `RAPT_SVA(clock, reset, L1D_NRU_EXCLUSIVE_UPDATES, !(&update_valid))
      `RAPT_SVA_IMPLY(clock, reset, L1D_NRU_REGISTERED_ADDRESS, load_hit, !l1d_update)
    end else if (CacheLru && L1D_N_WAYS <= 16) begin : g_lru
      rapt_cache_lru #(
          .Ways(L1D_N_WAYS),
          .SetBits(L1D_LEN)
      ) u_policy (
          .clock(clock),
          .reset(reset),
          .invalidate(`RAPT_SFENCE_KEEP_STATE < 1 && fence_time),
          .read_set(read_set),
          .victim(victims),
          .update_valid(update_valid),
          .update_set(update_set),
          .update_way(update_way)
      );
    end else begin : g_plru
      rapt_cache_plru #(
          .Ways(L1D_N_WAYS),
          .SetBits(L1D_LEN)
      ) u_policy (
          .clock(clock),
          .reset(reset),
          .invalidate(`RAPT_SFENCE_KEEP_STATE < 1 && fence_time),
          .read_set(read_set),
          .victim(victims),
          .update_valid(update_valid),
          .update_set(update_set),
          .update_way(update_way)
      );
    end
  end else begin : g_toggle
    assign victims[0] = L1dWayW'(L1D_N_WAYS == 2 && load_replace);
    assign victims[1] = L1dWayW'(L1D_N_WAYS == 2 && store_replace);
  end


  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_probe
    assign probe_way_hit[way] = (tag_probe_data[way] == probe_tag) & valid_probe[way][probe_offset];
    assign clear_line_dirty_way[way] = clear_tag_match[way] && line_dirty_q[way][clear_line_idx];
  end

  // Parallel write-side tag comparison (per-line tag)
  logic [L1D_N_WAYS-1:0] way_whit;
  generate
    for (genvar w = 0; w < L1D_N_WAYS; w++) begin : gen_line_wtag_cmp
      assign way_wtag_match[w] = (tag_waddr_data[w] == waddr_tag);
      assign way_whit[w] = valid_waddr[w][waddr_offset] & way_wtag_match[w];
    end
  endgenerate
  assign hit_w = |way_whit;
  always_comb begin
    store_hit_way = '0;
    for (int w = int'(L1D_N_WAYS) - 1; w >= 0; w--) if (way_whit[w]) store_hit_way = L1dWayW'(w);
  end
  rapt_cache_fill_select #(
      .Ways(L1D_N_WAYS)
  ) u_load_fill (
      .match_way(load_live_match),
      .valid_way(load_line_valid),
      .victim(victims[0]),
      .selected(ld_fill_way)
  );
  rapt_cache_fill_select #(
      .Ways(L1D_N_WAYS)
  ) u_store_fill (
      .match_way(store_live_match),
      .valid_way(store_line_valid),
      .victim(victims[1]),
      .selected(store_fill_way)
  );


  // Only one set can be updated per cycle. Select its tags before comparing,
  // rather than broadcasting the incoming tag into one comparator per set.
  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_update_match
    assign update_tag_match[way] = tag_update_data[way] == l1d_tag_u;
  end

  // Each line has one state writer. Clear dominates install/invalidate;
  // installing a different tag clears the other words in the target line.
  // Whole-line clears and duplicate scrubs only drop the live flag; word
  // masks are rewritten from the effective view on the next install.
  assign update_enable = !reset && !clear_any && !clear_line_valid && l1d_update && update_allowed;
  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_word_update
    logic [L1D_LINE_SIZE-1:0] word_bit, dirty_base;
    logic clean_hit;
    assign word_bit = L1D_LINE_SIZE'(1) << l1d_off;
    assign clean_hit = clean_valid && inspect_set == l1d_idx && inspect_way == L1dWayW'(way);
    assign dirty_base = clean_hit ? '0 : dirty_update[way];
    assign word_write[way] = update_enable && (l1d_valid_u ? l1d_way == L1dWayW'(way)
        : (l1d_inv_all_ways || l1d_way == L1dWayW'(way))
          && (!WriteBack || update_tag_match[way]));
    always_comb begin
      if (!l1d_valid_u) valid_write_data[way] = valid_update[way] & ~word_bit;
      else if (line_update) valid_write_data[way] = line_mask;
      else if (update_tag_match[way]) valid_write_data[way] = valid_update[way] | word_bit;
      else valid_write_data[way] = word_bit;
      if (!WriteBack) dirty_write_data[way] = '0;
      else if (!l1d_valid_u) dirty_write_data[way] = dirty_base;
      else if (line_update) dirty_write_data[way] = update_dirty ? line_mask : '0;
      else if (!update_tag_match[way]) dirty_write_data[way] = update_dirty ? word_bit : '0;
      else dirty_write_data[way] = dirty_base | (update_dirty ? word_bit : '0);
    end
  end

  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_word_state
    logic [L1D_LINE_SIZE-1:0] raw_dirty_update, raw_dirty_inspect;
    if (WriteBack) begin : g_dirty_words
      logic [L1D_LINE_SIZE-1:0] dirty_words[L1D_SIZE];
      always_ff @(posedge clock) if (word_write[way]) dirty_words[l1d_idx] <= dirty_write_data[way];
      assign raw_dirty_update = dirty_words[l1d_idx];
      assign raw_dirty_inspect = dirty_words[inspect_set];
    end else begin : g_no_dirty_words
      assign raw_dirty_update = '0;
      assign raw_dirty_inspect = '0;
    end
    assign valid_addr[way] = line_live[way][load_read_idx]
        ? entry_addr[way][L1D_LINE_SIZE-1:0] : '0;
    assign valid_waddr[way] = line_live[way][store_read_idx]
        ? entry_waddr[way][L1D_LINE_SIZE-1:0] : '0;
    assign valid_probe[way] = line_live[way][probe_idx]
        ? entry_probe[way][L1D_LINE_SIZE-1:0] : '0;
    assign valid_inspect[way] = line_live[way][inspect_set]
        ? entry_inspect[way][L1D_LINE_SIZE-1:0] : '0;
    assign valid_update[way] = line_live[way][l1d_idx]
        ? entry_update[way][L1D_LINE_SIZE-1:0] : '0;
    assign dirty_inspect[way] = line_dirty_q[way][inspect_set] ? raw_dirty_inspect : '0;
    assign dirty_update[way] = line_dirty_q[way][l1d_idx] ? raw_dirty_update : '0;
`ifndef SYNTHESIS
    assert property (@(posedge clock) disable iff (reset)
      (dirty_update[way] & ~valid_update[way]) == '0
        && (dirty_inspect[way] & ~valid_inspect[way]) == '0);
    assert property (@(posedge clock) disable iff (reset) clean_valid |-> clean_mask == '1);
    assert property (@(posedge clock) disable iff (reset)
      line_dirty_q[way][inspect_set] == (|dirty_inspect[way]));
`endif

    for (genvar set_idx = 0; set_idx < L1D_SIZE; set_idx++) begin : g_set_state
      logic line_clear;
      assign line_clear = (clear_enable && clear_set[set_idx] && update_allowed)
          || (clear_line_valid && clear_line_idx == L1D_LEN'(set_idx) && clear_tag_match[way]
              && (!WriteBack || !line_dirty_q[way][set_idx]));
      always_ff @(posedge clock) begin
        if (reset || line_clear) line_live[way][set_idx] <= 1'b0;
        else if (update_enable && l1d_valid_u && l1d_idx == L1D_LEN'(set_idx)) begin
          if (l1d_way == L1dWayW'(way)) line_live[way][set_idx] <= 1'b1;
          // Scrub the entire duplicate line, including other offsets.
          else if (update_tag_match[way]) line_live[way][set_idx] <= 1'b0;
        end
      end
      if (WriteBack) begin : g_dirty_state
        always_comb begin
          dirty_next[set_idx][way] = line_dirty_q[way][set_idx];
          if (reset || line_clear) dirty_next[set_idx][way] = 1'b0;
          else if (word_write[way] && l1d_idx == L1D_LEN'(set_idx))
            dirty_next[set_idx][way] = |dirty_write_data[way];
          else if (clean_valid && inspect_set == L1D_LEN'(set_idx) && inspect_way == L1dWayW'(way))
            dirty_next[set_idx][way] = 1'b0;
        end
        always_ff @(posedge clock) line_dirty_q[way][set_idx] <= dirty_next[set_idx][way];
      end else begin : g_no_dirty
        assign line_dirty_q[way][set_idx] = 1'b0;
        assign dirty_next[set_idx][way] = 1'b0;
      end
    end
  end
`ifdef RAPT_SVA_ACTIVE
  logic [L1D_SIZE-1:0] observed_dirty_set;
  for (genvar set_idx = 0; set_idx < L1D_SIZE; set_idx++) begin : g_summary_check
    always_comb begin
      observed_dirty_set[set_idx] = 1'b0;
      for (int way = 0; way < L1D_N_WAYS; way++)
      observed_dirty_set[set_idx] |= line_dirty_q[way][set_idx];
    end
  end
  `RAPT_SVA(clock, reset, L1D_DIRTY_SET_SUMMARY, observed_dirty_set == dirty_set_q)
  `RAPT_SVA(clock, reset, L1D_DIRTY_ANY_SUMMARY, dirty_any == (|observed_dirty_set))
`endif
`ifndef SYNTHESIS
  // Effective per-word state for testbench observation.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [L1dTagW-1:0] l1d_tag[L1D_N_WAYS][L1D_SIZE];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [L1D_LINE_SIZE-1:0] l1d_valid[L1D_N_WAYS][L1D_SIZE];
  logic [L1D_LINE_SIZE-1:0] dirty[L1D_N_WAYS][L1D_SIZE];
  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_view
    for (genvar set_idx = 0; set_idx < L1D_SIZE; set_idx++) begin : g_set
      assign l1d_tag[way][set_idx] = g_tag_storage[way].entries[set_idx][L1D_LINE_SIZE+:L1dTagW];
      assign l1d_valid[way][set_idx] = line_live[way][set_idx]
          ? g_tag_storage[way].entries[set_idx][L1D_LINE_SIZE-1:0] : '0;
      if (WriteBack) begin : g_dirty_view
        assign dirty[way][set_idx] = line_dirty_q[way][set_idx]
            ? g_word_state[way].g_dirty_words.dirty_words[set_idx] : '0;
      end else begin : g_no_dirty_view
        assign dirty[way][set_idx] = '0;
      end
    end
  end
`endif
endmodule
