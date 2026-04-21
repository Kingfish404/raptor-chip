`include "rapt.svh"

// 2-way set-associative BTB (Branch Target Buffer) with synchronous read.
// Uses (* keep_hierarchy *) to prevent Yosys from flattening this module,
// keeping the internal registered read address separate from pc_ifu and
// avoiding massive fan-out on the MUX tree address inputs.
// DEPTH = number of sets; total entries = DEPTH * WAYS.
(* keep_hierarchy *)
module rapt_bpu_btb #(
    parameter int DEPTH    = `RAPT_BTB_SIZE / 2,
    parameter int WAYS     = 2,
    parameter int TAG_LEN  = 7,
    parameter int XLEN     = `RAPT_XLEN,
    parameter int ADDR_LEN = $clog2(DEPTH)
) (
    input logic clock,
    input logic reset,

    // Synchronous read port: address+tag registered at posedge, data combinational
    input  logic                ren,
    input  logic [ADDR_LEN-1:0] raddr,
    input  logic [ TAG_LEN-1:0] rtag,
    output logic [    XLEN-1:1] rd_target,
    output logic [         1:0] rd_type,
    output logic                rd_tag_match,

    // Write entry (target + tag + valid)
    input logic                wen_entry,
    input logic [ADDR_LEN-1:0] waddr,
    input logic [    XLEN-1:1] wd_target,
    input logic [ TAG_LEN-1:0] wd_tag,

    // Write type (separate enable)
    input logic       wen_type,
    input logic [1:0] wd_type,

    // Bulk init (fence_time)
    input logic init
);
  // Storage arrays: [way][set]
  logic [    XLEN-1:1] target        [WAYS] [DEPTH];
  logic [ TAG_LEN-1:0] tag           [WAYS] [DEPTH];
  logic [         1:0] itype         [WAYS] [DEPTH];
  logic [   DEPTH-1:0] valid         [WAYS];

  // LRU tracking: lru[set] = next victim way for replacement
  logic [   DEPTH-1:0] lru;

  // Registered read address and tag.
  //
  // The raw r_raddr drives a ~1500-input mux cone (2 ways × 64 sets × 31-bit
  // target + 7-bit tag + 2-bit itype + valid). Previous STA showed this flop
  // output + a single BUF_X1 spending >10 ns on fanout alone, and ending up
  // as the chip's global critical path terminating at ifu.seq4.
  //
  // Phase A': replicate the raddr register per consumer so each copy drives
  // only its local mux tree. (* keep = "true" *) + (* no_rw_check *) stop
  // yosys from folding them back together. There are five consumers per way:
  // target, tag, itype, valid, and the lru write port.
  (* keep = "true" *)logic [ADDR_LEN-1:0] r_raddr_tag   [WAYS];
  (* keep = "true" *)logic [ADDR_LEN-1:0] r_raddr_target[WAYS];
  (* keep = "true" *)logic [ADDR_LEN-1:0] r_raddr_itype [WAYS];
  (* keep = "true" *)logic [ADDR_LEN-1:0] r_raddr_valid [WAYS];
  (* keep = "true" *)logic [ADDR_LEN-1:0] r_raddr_lru;
  (* keep = "true" *)logic [ TAG_LEN-1:0] r_rtag_cmp    [WAYS];

  // --- Read path: per-way tag match (each way uses its private raddr/rtag copy) ---
  logic [    WAYS-1:0] way_hit;
  logic                hit_way;

  for (genvar w = 0; w < WAYS; w++) begin : g_way_hit
    assign way_hit[w] = valid[w][r_raddr_valid[w]] && (r_rtag_cmp[w] == tag[w][r_raddr_tag[w]]);
  end

  assign hit_way      = way_hit[1];
  assign rd_tag_match = |way_hit;
  assign rd_target    = target[hit_way][r_raddr_target[hit_way]];
  assign rd_type      = itype[hit_way][r_raddr_itype[hit_way]];

  // --- Write path: update matching way, or replace LRU victim ---
  logic [WAYS-1:0] w_way_match;
  logic w_sel;

  for (genvar w = 0; w < WAYS; w++) begin : g_w_match
    assign w_way_match[w] = valid[w][waddr] && (wd_tag == tag[w][waddr]);
  end

  assign w_sel = |w_way_match ? w_way_match[1] : lru[waddr];

  always @(posedge clock) begin
    if (reset || init) begin
      for (int i = 0; i < DEPTH; i++) begin
        for (int w = 0; w < WAYS; w++) itype[w][i] <= 2'b00;
      end
      for (int w = 0; w < WAYS; w++) valid[w] <= '0;
      lru <= '0;
      for (int w = 0; w < WAYS; w++) begin
        r_raddr_tag[w]    <= '0;
        r_raddr_target[w] <= '0;
        r_raddr_itype[w]  <= '0;
        r_raddr_valid[w]  <= '0;
        r_rtag_cmp[w]     <= '0;
      end
      r_raddr_lru <= '0;
    end else begin
      if (ren) begin
        for (int w = 0; w < WAYS; w++) begin
          r_raddr_tag[w]    <= raddr;
          r_raddr_target[w] <= raddr;
          r_raddr_itype[w]  <= raddr;
          r_raddr_valid[w]  <= raddr;
          r_rtag_cmp[w]     <= rtag;
        end
        r_raddr_lru <= raddr;
      end
      // Update LRU on read hit: mark other way as next victim
      if (rd_tag_match) lru[r_raddr_lru] <= ~hit_way;
      // Write entry: allocate/update target + tag + valid, update LRU
      if (wen_entry) begin
        valid[w_sel][waddr]  <= 1'b1;
        tag[w_sel][waddr]    <= wd_tag;
        target[w_sel][waddr] <= wd_target;
        lru[waddr] <= ~w_sel;
      end
      // Write type: only if entry exists (matching tag) or new entry being created.
      // Prevents type corruption of unrelated entries via non-flushing wen_type writes.
      if (wen_type && (wen_entry || |w_way_match)) itype[w_sel][waddr] <= wd_type;
    end
  end
endmodule
