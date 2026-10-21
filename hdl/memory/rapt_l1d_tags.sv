`include "rapt.svh"

// L1D tag/valid ownership and replacement lookup. Reads are combinational;
// updates and fence invalidation occur on the same edge as the data write.
// The controller retains transaction sequencing and the two-way toggle.
module rapt_l1d_tags #(
    parameter int L1D_LEN = `RAPT_L1D_LEN,
    parameter int L1D_LINE_LEN = `RAPT_L1D_LINE_LEN,
    parameter int L1D_SIZE = 2 ** L1D_LEN,
    parameter int L1D_LINE_SIZE = 2 ** L1D_LINE_LEN,
    parameter int L1D_N_WAYS = `RAPT_L1D_N_WAYS,
    parameter int L1dTagW = `RAPT_PADDR_BITS - L1D_LEN - L1D_LINE_LEN - $clog2(`RAPT_XLEN / 8),
    parameter int L1dWayW = L1D_N_WAYS > 1 ? $clog2(L1D_N_WAYS) : 1,
    parameter bit WriteBack = 1'b0
) (
    input logic clock,
    input logic reset,
    input logic fence_time,
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
    output logic inspect_dirty_any,
    output logic update_blocked
);
  // Per-line live/dirty flags stay in flops: fence clears and the global
  // summaries need every line at once. Word masks have one writer per way,
  // so they map to distributed RAM with replicated asynchronous reads.
  logic line_live[L1D_N_WAYS][L1D_SIZE];
  logic line_dirty_q[L1D_N_WAYS][L1D_SIZE];
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
  // Retain the generic flop layout and its stable verification view.
  logic [L1dTagW-1:0] l1d_tag[L1D_N_WAYS][L1D_SIZE];
  logic [L1dTagW-1:0] tag_addr_data[L1D_N_WAYS];
  logic [L1dTagW-1:0] tag_waddr_data[L1D_N_WAYS];
  logic [L1dTagW-1:0] tag_probe_data[L1D_N_WAYS];
  logic [L1dTagW-1:0] tag_update_data[L1D_N_WAYS];
  logic [L1dTagW-1:0] tag_clear_data[L1D_N_WAYS];
  logic [L1dTagW-1:0] tag_inspect_data[L1D_N_WAYS];
  logic [L1D_N_WAYS-1:0] tag_write, clear_tag_match;
  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_tag_storage
    assign tag_write[way] = !reset && !clear_any && !clear_line_valid
        && l1d_update && l1d_valid_u && update_allowed && l1d_way == L1dWayW'(way);
    assign clear_tag_match[way] = tag_clear_data[way] == clear_line_tag;
    if (`RAPT_FPGA_LUTRAM) begin : g_lutram
      // One write per way, replicated for each independent asynchronous read.
      (* ram_style = "distributed" *) logic [L1dTagW-1:0] addr_words[L1D_SIZE];
      (* ram_style = "distributed" *) logic [L1dTagW-1:0] waddr_words[L1D_SIZE];
      (* ram_style = "distributed" *) logic [L1dTagW-1:0] probe_words[L1D_SIZE];
      (* ram_style = "distributed" *) logic [L1dTagW-1:0] update_words[L1D_SIZE];
      (* ram_style = "distributed" *) logic [L1dTagW-1:0] clear_words[L1D_SIZE];
      (* ram_style = "distributed" *) logic [L1dTagW-1:0] inspect_words[L1D_SIZE];
      always_ff @(posedge clock)
        if (tag_write[way]) begin
          addr_words[l1d_idx] <= l1d_tag_u;
          waddr_words[l1d_idx] <= l1d_tag_u;
          probe_words[l1d_idx] <= l1d_tag_u;
          update_words[l1d_idx] <= l1d_tag_u;
          clear_words[l1d_idx] <= l1d_tag_u;
          inspect_words[l1d_idx] <= l1d_tag_u;
        end
      assign tag_addr_data[way] = addr_words[addr_idx];
      assign tag_waddr_data[way] = waddr_words[waddr_idx];
      assign tag_probe_data[way] = probe_words[probe_idx];
      assign tag_update_data[way] = update_words[l1d_idx];
      assign tag_clear_data[way] = clear_words[clear_line_idx];
      assign tag_inspect_data[way] = inspect_words[inspect_set];
    end else begin : g_flops
      for (genvar set_idx = 0; set_idx < L1D_SIZE; set_idx++) begin : g_set
        always_ff @(posedge clock)
          if (tag_write[way] && l1d_idx == L1D_LEN'(set_idx))
            l1d_tag[way][set_idx] <= l1d_tag_u;
      end
      assign tag_addr_data[way] = l1d_tag[way][addr_idx];
      assign tag_waddr_data[way] = l1d_tag[way][waddr_idx];
      assign tag_probe_data[way] = l1d_tag[way][probe_idx];
      assign tag_update_data[way] = l1d_tag[way][l1d_idx];
      assign tag_clear_data[way] = l1d_tag[way][clear_line_idx];
      assign tag_inspect_data[way] = l1d_tag[way][inspect_set];
    end
  end
  logic [L1D_N_WAYS-1:0] dirty_conflict;
  logic [L1D_N_WAYS-1:0] update_tag_match;
  logic clear_blocked;

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

  always_comb begin
    dirty_any = 1'b0;
    clear_blocked = 1'b0;
    for (int way = 0; way < L1D_N_WAYS; way++) begin
      for (int set_idx = 0; set_idx < L1D_SIZE; set_idx++) begin
        dirty_any |= line_dirty_q[way][set_idx];
        clear_blocked |= clear_set[set_idx] && line_dirty_q[way][set_idx];
      end
    end
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
  if (L1D_N_WAYS > 2) begin : g_replacement
    logic [L1D_LEN-1:0] read_set[2], update_set[2];
    logic [L1dWayW-1:0] update_way[2];
    logic [1:0] update_valid;
    assign read_set[0] = addr_idx;
    assign read_set[1] = waddr_idx;
    assign update_set[0] = addr_idx;
    assign update_set[1] = l1d_idx;
    assign update_valid = {l1d_update && l1d_valid_u && !clear_any
                           && !clear_line_valid && update_allowed, load_hit};
    assign update_way[1] = l1d_way;
    always_comb begin
      update_way[0] = '0;
      for (int way = L1D_N_WAYS - 1; way >= 0; way--)
      if (load_way_hit[way]) update_way[0] = L1dWayW'(way);
    end
    rapt_cache_plru #(
        .Ways(L1D_N_WAYS),
        .SetBits(L1D_LEN)
    ) u_policy (
        .clock(clock),
        .reset(reset),
        .invalidate(fence_time),
        .read_set(read_set),
        .victim(victims),
        .update_valid(update_valid),
        .update_set(update_set),
        .update_way(update_way)
    );
  end else begin : g_toggle
    assign victims[0] = L1dWayW'(L1D_N_WAYS == 2 && load_replace);
    assign victims[1] = L1dWayW'(L1D_N_WAYS == 2 && store_replace);
  end


  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_probe
    assign probe_way_hit[way] = (tag_probe_data[way] == probe_tag)
                               & valid_probe[way][probe_offset];
    assign clear_line_dirty_way[way] = clear_tag_match[way]
                                    && line_dirty_q[way][clear_line_idx];
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
    (* ram_style = "distributed" *) logic [L1D_LINE_SIZE-1:0] valid_words[L1D_SIZE];
    logic [L1D_LINE_SIZE-1:0] raw_addr, raw_waddr, raw_probe, raw_inspect;
    logic [L1D_LINE_SIZE-1:0] raw_dirty_update, raw_dirty_inspect;
    always_ff @(posedge clock) if (word_write[way]) valid_words[l1d_idx] <= valid_write_data[way];
    // Dirty masks exist only for write-back caches; write-through reads zero.
    if (WriteBack) begin : g_dirty_words
      (* ram_style = "distributed" *) logic [L1D_LINE_SIZE-1:0] dirty_words[L1D_SIZE];
      always_ff @(posedge clock) if (word_write[way]) dirty_words[l1d_idx] <= dirty_write_data[way];
      assign raw_dirty_update = dirty_words[l1d_idx];
      if (`RAPT_FPGA_LUTRAM) begin : g_inspect_copy
        (* ram_style = "distributed" *) logic [L1D_LINE_SIZE-1:0] inspect_dirty_words[L1D_SIZE];
        always_ff @(posedge clock)
          if (word_write[way])
            inspect_dirty_words[l1d_idx] <= dirty_write_data[way];
        assign raw_dirty_inspect = inspect_dirty_words[inspect_set];
      end else begin : g_inspect_shared
        assign raw_dirty_inspect = dirty_words[inspect_set];
      end
    end else begin : g_no_dirty_words
      assign raw_dirty_update = '0;
      assign raw_dirty_inspect = '0;
    end
    if (`RAPT_FPGA_LUTRAM) begin : g_lutram
      // Same write as valid_words, one copy per asynchronous read.
      (* ram_style = "distributed" *) logic [L1D_LINE_SIZE-1:0] addr_words[L1D_SIZE];
      (* ram_style = "distributed" *) logic [L1D_LINE_SIZE-1:0] waddr_words[L1D_SIZE];
      (* ram_style = "distributed" *) logic [L1D_LINE_SIZE-1:0] probe_words[L1D_SIZE];
      (* ram_style = "distributed" *) logic [L1D_LINE_SIZE-1:0] inspect_words[L1D_SIZE];
      always_ff @(posedge clock)
        if (word_write[way]) begin
          addr_words[l1d_idx] <= valid_write_data[way];
          waddr_words[l1d_idx] <= valid_write_data[way];
          probe_words[l1d_idx] <= valid_write_data[way];
          inspect_words[l1d_idx] <= valid_write_data[way];
        end
      assign raw_addr = addr_words[addr_idx];
      assign raw_waddr = waddr_words[waddr_idx];
      assign raw_probe = probe_words[probe_idx];
      assign raw_inspect = inspect_words[inspect_set];
    end else begin : g_shared
      assign raw_addr = valid_words[addr_idx];
      assign raw_waddr = valid_words[waddr_idx];
      assign raw_probe = valid_words[probe_idx];
      assign raw_inspect = valid_words[inspect_set];
    end
    assign valid_addr[way] = line_live[way][addr_idx] ? raw_addr : '0;
    assign valid_waddr[way] = line_live[way][waddr_idx] ? raw_waddr : '0;
    assign valid_probe[way] = line_live[way][probe_idx] ? raw_probe : '0;
    assign valid_inspect[way] = line_live[way][inspect_set] ? raw_inspect : '0;
    assign valid_update[way] = line_live[way][l1d_idx] ? valid_words[l1d_idx] : '0;
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
        always_ff @(posedge clock) begin
          if (reset || line_clear) line_dirty_q[way][set_idx] <= 1'b0;
          else if (word_write[way] && l1d_idx == L1D_LEN'(set_idx))
            line_dirty_q[way][set_idx] <= |dirty_write_data[way];
          else if (clean_valid && inspect_set == L1D_LEN'(set_idx) && inspect_way == L1dWayW'(way))
            line_dirty_q[way][set_idx] <= 1'b0;
        end
      end else begin : g_no_dirty
        assign line_dirty_q[way][set_idx] = 1'b0;
      end
    end
  end
`ifndef SYNTHESIS
  // Effective per-word state for testbench observation.
  logic [L1D_LINE_SIZE-1:0] l1d_valid[L1D_N_WAYS][L1D_SIZE];
  logic [L1D_LINE_SIZE-1:0] dirty[L1D_N_WAYS][L1D_SIZE];
  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_view
    for (genvar set_idx = 0; set_idx < L1D_SIZE; set_idx++) begin : g_set
      assign l1d_valid[way][set_idx] = line_live[way][set_idx]
          ? g_word_state[way].valid_words[set_idx] : '0;
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
