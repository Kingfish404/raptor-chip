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
    parameter int L1dTagW = `RAPT_XLEN - L1D_LEN - L1D_LINE_LEN - $clog2(`RAPT_XLEN / 8),
    parameter int L1dWayW = L1D_N_WAYS > 1 ? $clog2(L1D_N_WAYS) : 1
) (
    input logic clock,
    input logic reset,
    input logic fence_time,
    input logic [L1D_SIZE-1:0] clear_set,
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
    input logic l1d_inv_all_ways,
    input logic [L1dTagW-1:0] l1d_tag_u,
    input logic [L1D_LEN-1:0] l1d_idx,
    input logic [L1D_LINE_LEN-1:0] l1d_off,
    input logic [L1dWayW-1:0] l1d_way
);
  logic [L1D_LINE_SIZE-1:0] l1d_valid[L1D_N_WAYS][L1D_SIZE];
  logic [L1dTagW-1:0] l1d_tag[L1D_N_WAYS][L1D_SIZE];

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
      assign way_tag_match[w] = (l1d_tag[w][addr_idx] == addr_tag);
      assign load_way_hit[w] = l1d_valid[w][addr_idx][addr_offset] & way_tag_match[w];
    end
  endgenerate
  logic [L1D_N_WAYS-1:0] way_wtag_match;
  logic [L1D_N_WAYS-1:0] load_live_match, store_live_match;
  logic [L1D_N_WAYS-1:0] load_word_valid, store_word_valid;
  logic [L1dWayW-1:0] victims[2];
  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_candidates
    assign load_live_match[way] = way_tag_match[way] && |l1d_valid[way][addr_idx];
    assign store_live_match[way] = way_wtag_match[way] && |l1d_valid[way][waddr_idx];
    assign load_word_valid[way] = l1d_valid[way][addr_idx][addr_offset];
    assign store_word_valid[way] = l1d_valid[way][waddr_idx][waddr_offset];
  end
  if (L1D_N_WAYS > 2) begin : g_replacement
    logic [L1D_LEN-1:0] read_set[2], update_set[2];
    logic [L1dWayW-1:0] update_way[2];
    logic [1:0] update_valid;
    assign read_set[0] = addr_idx;
    assign read_set[1] = waddr_idx;
    assign update_set[0] = addr_idx;
    assign update_set[1] = l1d_idx;
    assign update_valid = {l1d_update && l1d_valid_u && !(|clear_set), load_hit};
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
    assign probe_way_hit[way] = (l1d_tag[way][probe_idx] == probe_tag)
                               & l1d_valid[way][probe_idx][probe_offset];
  end

  // Parallel write-side tag comparison (per-line tag)
  logic [L1D_N_WAYS-1:0] way_whit;
  generate
    for (genvar w = 0; w < L1D_N_WAYS; w++) begin : gen_line_wtag_cmp
      assign way_wtag_match[w] = (l1d_tag[w][waddr_idx] == waddr_tag);
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
      .valid_way(load_word_valid),
      .victim(victims[0]),
      .selected(ld_fill_way)
  );
  rapt_cache_fill_select #(
      .Ways(L1D_N_WAYS)
  ) u_store_fill (
      .match_way(store_live_match),
      .valid_way(store_word_valid),
      .victim(victims[1]),
      .selected(store_fill_way)
  );


  // Each line has one state writer. Clear dominates install/invalidate;
  // installing a different tag clears the other words in the target line.
  for (genvar way = 0; way < L1D_N_WAYS; way++) begin : g_way_state
    for (genvar set_idx = 0; set_idx < L1D_SIZE; set_idx++) begin : g_set_state
      always_ff @(posedge clock) begin
        if (reset || clear_set[set_idx]) begin
          l1d_valid[way][set_idx] <= '0;
        end else if (!(|clear_set) && l1d_update && l1d_idx == L1D_LEN'(set_idx)) begin
          if (l1d_valid_u) begin
            if (l1d_way == L1dWayW'(way)) begin
              if (l1d_tag[way][set_idx] == l1d_tag_u) l1d_valid[way][set_idx][l1d_off] <= 1'b1;
              else l1d_valid[way][set_idx] <= L1D_LINE_SIZE'(1) << l1d_off;
            end else if (l1d_tag[way][set_idx] == l1d_tag_u) begin
              // Scrub the entire duplicate line, including other offsets.
              l1d_valid[way][set_idx] <= '0;
            end
          end else if (l1d_inv_all_ways || l1d_way == L1dWayW'(way)) begin
            l1d_valid[way][set_idx][l1d_off] <= 1'b0;
          end
        end
        // Tags need no reset; their corresponding valid bits gate use.
        if (!reset && !(|clear_set) && l1d_update && l1d_valid_u
            && l1d_idx == L1D_LEN'(set_idx) && l1d_way == L1dWayW'(way))
          l1d_tag[way][set_idx] <= l1d_tag_u;
      end
    end
  end
endmodule
