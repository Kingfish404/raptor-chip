`include "rapt.svh"

// 2- or 4-way set-associative BTB (Branch Target Buffer). Each target way has
// one clocked read and one write port, suitable for a synchronous RAM bank.
// DEPTH = number of sets; total entries = DEPTH * WAYS.
module rapt_bpu_btb #(
    parameter int DEPTH    = `RAPT_BTB_SIZE / 2,
    parameter int WAYS     = 2,
    parameter int TAG_LEN  = 7,
    parameter int XLEN     = `RAPT_XLEN,
    parameter int ADDR_LEN = $clog2(DEPTH)
) (
    input logic clock,
    input logic reset,

    // Synchronous lookup: address and target data register at the rising edge.
    input  logic                ren,
    input  logic [ADDR_LEN-1:0] raddr,
    input  logic [ TAG_LEN-1:0] rtag,
    output logic [    `RAPT_PC_BITS_OF(XLEN)-1:1] rd_target,
    output logic [         1:0] rd_type,
    output logic                rd_tag_match,

    // Write entry (target + tag + valid)
    input logic                wen_entry,
    input logic                inv_entry,
    input logic [ADDR_LEN-1:0] waddr,
    input logic [    `RAPT_PC_BITS_OF(XLEN)-1:1] wd_target,
    input logic [ TAG_LEN-1:0] wd_tag,

    // Write type (separate enable)
    input logic       wen_type,
    input logic [1:0] wd_type,

    // Bulk init (fence_time)
    input logic init
);
  localparam int PcW = `RAPT_PC_BITS_OF(XLEN);
  localparam int WayBits = $clog2(WAYS);
  localparam int PlruBits = WAYS - 1;
  if (WAYS != 2 && WAYS != 4) begin : g_invalid_ways
    $error("rapt_bpu_btb replacement policy supports 2 or 4 ways");
  end
  logic [   DEPTH-1:0] valid        [WAYS];
  logic [    PcW-1:1] way_target   [WAYS];
  logic [         1:0] way_type     [WAYS];

  // Tree-PLRU tracking (1 bit per set for 2-way, 3 bits per set for 4-way).
  // Expose packed lru[DEPTH-1:0] (root PLRU bit) for 2-way testbench visibility.
  logic [PlruBits-1:0] plru         [DEPTH];
  logic [   DEPTH-1:0] lru;
  for (genvar s = 0; s < DEPTH; s++) begin : g_lru_view
    assign lru[s] = plru[s][0];
  end

  function automatic logic [WayBits-1:0] plru_victim(input logic [2:0] bits);
    if (WAYS == 2) return WayBits'(bits[0]);
    else return WayBits'({bits[0], bits[0] ? bits[2] : bits[1]});
  endfunction

  function automatic logic [PlruBits-1:0] plru_update(input logic [2:0] bits,
                                                      input logic [1:0] accessed_way);
    logic [2:0] next_bits;
    next_bits = bits;
    if (WAYS == 2) begin
      next_bits[0] = ~accessed_way[0];
    end else begin
      next_bits[0] = ~accessed_way[1];
      if (accessed_way[1]) next_bits[2] = ~accessed_way[0];
      else next_bits[1] = ~accessed_way[0];
    end
    return PlruBits'(next_bits);
  endfunction

  // Registered read address and tag.
  // The target payload is read at the same edge as these registers, so its
  // output has no address mux on the prediction path.
  logic [    WAYS-1:0] way_hit;
  logic [ WayBits-1:0] hit_way;
  logic [ADDR_LEN-1:0] held_raddr;
  logic [ TAG_LEN-1:0] rtag_q;
  logic                lookup_valid_q;

  always_comb begin
    hit_way = '0;
    for (int w = WAYS - 1; w >= 0; w--) begin
      if (way_hit[w]) hit_way = WayBits'(w);
    end
  end
  assign rd_tag_match = |way_hit;
  assign rd_target    = way_target[hit_way];
  assign rd_type      = way_type[hit_way];

  // --- Write path: update matching way, fill invalid way, or replace PLRU victim ---
  logic [   WAYS-1:0] w_way_match;
  logic [WayBits-1:0] w_match_way;
  logic [WayBits-1:0] w_invalid_way;
  logic               w_has_invalid;
  logic [WayBits-1:0] w_sel;

  always_comb begin
    w_match_way = '0;
    w_invalid_way = '0;
    w_has_invalid = 1'b0;
    for (int w = WAYS - 1; w >= 0; w--) begin
      if (w_way_match[w]) w_match_way = WayBits'(w);
      if (!valid[w][waddr]) begin
        w_has_invalid = 1'b1;
        w_invalid_way = WayBits'(w);
      end
    end
    if (|w_way_match) w_sel = w_match_way;
    else if (w_has_invalid) w_sel = w_invalid_way;
    else w_sel = plru_victim(3'(plru[waddr]));
  end

  // A fixed way owns each target bank. A write to the currently observed set
  // must appear at the output after the edge, including when ren is low. The
  // explicit forwarding register makes that behavior independent of the RAM's
  // read-during-write mode and keeps its read port on a simple clocked template.
  for (genvar w = 0; w < WAYS; w++) begin : g_way_storage
    logic [PcW-1:1] target[DEPTH];
    logic [PcW-1:1] target_q;
    logic [PcW-1:1] target_forward_q;
    logic target_forward_valid_q;
    logic target_write;
    logic target_write_observed;
    logic [TAG_LEN-1:0] tag[DEPTH];
    logic [1:0] itype[DEPTH];
    assign target_write = wen_entry && (w_sel == WayBits'(w)) && !reset && !init;
    assign target_write_observed = target_write && (ren || lookup_valid_q)
        && (waddr == (ren ? raddr : held_raddr));
    assign way_target[w] = target_forward_valid_q ? target_forward_q : target_q;
    assign way_type[w] = itype[held_raddr];
    assign way_hit[w] = lookup_valid_q && valid[w][held_raddr]
        && (rtag_q == tag[held_raddr]);
    assign w_way_match[w] = valid[w][waddr] && (wd_tag == tag[waddr]);
    always_ff @(posedge clock) begin
      // Forward collisions after the edge; keep the address comparison off
      // the RAM read enable, including reads whose result will be discarded.
      if (ren) target_q <= target[raddr];
      if (target_write) target[waddr] <= wd_target;
    end
    // During an enabled lookup, capture any target write speculatively.
    // The unchanged valid bit exposes this value only on an address match.
    // When the lookup is held, writes to other sets must preserve the value
    // already being forwarded. That comparison uses the registered address,
    // keeping the current lookup address off the wide data write enable.
    always_ff @(posedge clock) begin
      if (target_write && (ren || (lookup_valid_q && waddr == held_raddr)))
        target_forward_q <= wd_target;
    end
    always_ff @(posedge clock) begin
      if (reset || init) target_forward_valid_q <= 1'b0;
      else begin
        if (ren) target_forward_valid_q <= target_write_observed;
        if (target_write_observed) target_forward_valid_q <= 1'b1;
      end
    end
    always_ff @(posedge clock) begin
      if (!reset && !init) begin
        if (wen_entry && w_sel == WayBits'(w)) begin
          tag[waddr] <= wd_tag;
        end
        if (wen_type && (wen_entry || |w_way_match) && w_sel == WayBits'(w))
          itype[waddr] <= wd_type;
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset || init) begin
      for (int w = 0; w < WAYS; w++) valid[w] <= '0;
      for (int s = 0; s < DEPTH; s++) plru[s] <= '0;
      // Payload RAMs and tag/type lookup metadata remain unreset. Reset the
      // held selector so an empty table has a known read gate before the first
      // lookup, while bulk init preserves an already captured lookup.
      if (reset) begin
        lookup_valid_q <= 1'b0;
        held_raddr     <= '0;
        rtag_q         <= '0;
      end
    end else begin
      if (ren) begin
        lookup_valid_q <= 1'b1;
        held_raddr     <= raddr;
        rtag_q         <= rtag;
      end
      // Update PLRU on write or read hit (write takes priority on same set).
      if (wen_entry) begin
        valid[w_sel][waddr] <= 1'b1;
        plru[waddr] <= plru_update(3'(plru[waddr]), 2'(w_sel));
      end else if (inv_entry) begin
        if (|w_way_match) begin
          valid[w_match_way][waddr] <= 1'b0;
          if (WAYS == 2) plru[waddr] <= PlruBits'(w_match_way);
        end
      end else if (rd_tag_match) begin
        plru[held_raddr] <= plru_update(3'(plru[held_raddr]), 2'(hit_way));
      end
    end
  end
endmodule
