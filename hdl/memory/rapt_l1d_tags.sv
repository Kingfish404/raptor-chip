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
    input logic clean_valid = 1'b0,
    input logic [L1D_LINE_SIZE-1:0] clean_mask = '0,
    output logic [L1dTagW-1:0] inspect_tag,
    output logic [L1D_LINE_SIZE-1:0] inspect_valid,
    output logic [L1D_LINE_SIZE-1:0] inspect_dirty,
    output logic dirty_any,
    output logic update_blocked
);
  logic [L1D_LINE_SIZE-1:0] l1d_valid[L1D_N_WAYS][L1D_SIZE];
  logic update_allowed;
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
    assign tag_write[way] = !reset && !(|clear_set) && !clear_line_valid
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
  logic [L1D_LINE_SIZE-1:0] dirty[L1D_N_WAYS][L1D_SIZE];
  logic line_dirty_q[L1D_N_WAYS][L1D_SIZE];
  logic [L1D_N_WAYS-1:0] dirty_conflict;
  logic [L1D_N_WAYS-1:0] update_tag_match;
  logic clear_blocked;

  assign inspect_tag = tag_inspect_data[inspect_way];
  assign inspect_valid = l1d_valid[inspect_way][inspect_set];
  assign inspect_dirty = dirty[inspect_way][inspect_set];
  assign update_allowed = !update_blocked;
  assign update_blocked = WriteBack && (clear_blocked || |dirty_conflict);

  always_comb begin
    dirty_any = 1'b0;
    clear_blocked = 1'b0;
    for (int way = 0; way < L1D_N_WAYS; way++) begin
      for (int set_idx = 0; set_idx < L1D_SIZE; set_idx++) begin
        dirty_any |= line_dirty_q[way][set_idx];
        clear_blocked |= clear_set[set_idx] && |dirty[way][set_idx];
      end
    end
  end

  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_dirty_conflict
    always_comb begin
      dirty_conflict[way] = 1'b0;
      if (l1d_update && |dirty[way][l1d_idx]) begin
        if (l1d_valid_u) begin
          if (l1d_way == L1dWayW'(way))
            dirty_conflict[way] = !update_tag_match[way]
              || line_update
                || (!line_update && !update_dirty && dirty[way][l1d_idx][l1d_off]);
          else dirty_conflict[way] = update_tag_match[way];
        end else
          dirty_conflict[way] = (l1d_inv_all_ways || l1d_way == L1dWayW'(way))
              && update_tag_match[way]
              && dirty[way][l1d_idx][l1d_off];
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
      assign load_way_hit[w] = l1d_valid[w][addr_idx][addr_offset] & way_tag_match[w];
    end
  endgenerate
  logic [L1D_N_WAYS-1:0] way_wtag_match;
  logic [L1D_N_WAYS-1:0] load_live_match, store_live_match;
  logic [L1D_N_WAYS-1:0] load_line_valid, store_line_valid;
  logic [L1dWayW-1:0] victims[2];
  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_candidates
    assign load_live_match[way] = way_tag_match[way] && |l1d_valid[way][addr_idx];
    assign store_live_match[way] = way_wtag_match[way] && |l1d_valid[way][waddr_idx];
    assign load_line_valid[way] = |l1d_valid[way][addr_idx];
    assign store_line_valid[way] = |l1d_valid[way][waddr_idx];
  end
  if (L1D_N_WAYS > 2) begin : g_replacement
    logic [L1D_LEN-1:0] read_set[2], update_set[2];
    logic [L1dWayW-1:0] update_way[2];
    logic [1:0] update_valid;
    assign read_set[0] = addr_idx;
    assign read_set[1] = waddr_idx;
    assign update_set[0] = addr_idx;
    assign update_set[1] = l1d_idx;
    assign update_valid = {l1d_update && l1d_valid_u && !(|clear_set)
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
                               & l1d_valid[way][probe_idx][probe_offset];
    assign clear_line_dirty_way[way] = clear_tag_match[way]
                                    && (|dirty[way][clear_line_idx]);
  end

  // Parallel write-side tag comparison (per-line tag)
  logic [L1D_N_WAYS-1:0] way_whit;
  generate
    for (genvar w = 0; w < L1D_N_WAYS; w++) begin : gen_line_wtag_cmp
      assign way_wtag_match[w] = (tag_waddr_data[w] == waddr_tag);
      assign way_whit[w] = l1d_valid[w][waddr_idx][waddr_offset] & way_wtag_match[w];
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
  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_way_state
    for (genvar set_idx = 0; set_idx < L1D_SIZE; set_idx++) begin : g_set_state
      always_ff @(posedge clock) begin
        if (reset || (clear_set[set_idx] && update_allowed)
            || (clear_line_valid && clear_line_idx == L1D_LEN'(set_idx)
                && clear_tag_match[way]
                && (!WriteBack || !(|dirty[way][set_idx])))) begin
          l1d_valid[way][set_idx] <= '0;
        end else if (!(|clear_set) && !clear_line_valid && l1d_update && update_allowed
                     && l1d_idx == L1D_LEN'(set_idx)) begin
          if (l1d_valid_u) begin
            if (l1d_way == L1dWayW'(way)) begin
              if (line_update) l1d_valid[way][set_idx] <= line_mask;
              else if (update_tag_match[way]) l1d_valid[way][set_idx][l1d_off] <= 1'b1;
              else l1d_valid[way][set_idx] <= L1D_LINE_SIZE'(1) << l1d_off;
            end else if (update_tag_match[way]) begin
              // Scrub the entire duplicate line, including other offsets.
              l1d_valid[way][set_idx] <= '0;
            end
          end else if ((l1d_inv_all_ways || l1d_way == L1dWayW'(way))
                       && (!WriteBack || update_tag_match[way])) begin
            l1d_valid[way][set_idx][l1d_off] <= 1'b0;
          end
        end
      end
      if (WriteBack) begin : g_dirty_state
        logic [L1D_LINE_SIZE-1:0] dirty_next;
        always_comb begin
          dirty_next = dirty[way][set_idx];
          if (reset || (clear_set[set_idx] && update_allowed)
              || (clear_line_valid && clear_line_idx == L1D_LEN'(set_idx)
                  && clear_tag_match[way]
                  && !(|dirty[way][set_idx])))
            dirty_next = '0;
          else begin
            if (clean_valid && inspect_set == L1D_LEN'(set_idx) && inspect_way == L1dWayW'(way))
              dirty_next = dirty[way][set_idx] & ~clean_mask;
            if (!(|clear_set) && !clear_line_valid
                && l1d_update && l1d_valid_u && update_allowed
                && l1d_idx == L1D_LEN'(set_idx) && l1d_way == L1dWayW'(way)) begin
              if (line_update) dirty_next = update_dirty ? line_mask : '0;
              else if (!update_tag_match[way])
                dirty_next = update_dirty ? L1D_LINE_SIZE'(1) << l1d_off : '0;
              else if (update_dirty) dirty_next[l1d_off] = 1'b1;
            end
          end
        end
        // Derive both states from the same next value, including clean/store
        // collisions. The global summary is available without another cycle.
        always_ff @(posedge clock) begin
          dirty[way][set_idx] <= dirty_next;
          line_dirty_q[way][set_idx] <= |dirty_next;
        end
`ifndef SYNTHESIS
        assert property (@(posedge clock) disable iff (reset)
          (dirty[way][set_idx] & ~l1d_valid[way][set_idx]) == '0);
`endif
      end else begin : g_no_dirty
        assign dirty[way][set_idx] = '0;
        assign line_dirty_q[way][set_idx] = 1'b0;
      end
    end
  end
endmodule
