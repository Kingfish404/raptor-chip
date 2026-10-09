`include "rapt.svh"

// 2-way set-associative BTB (Branch Target Buffer). Each target way has one
// clocked read and one write port, suitable for a fixed FPGA RAM bank.
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

    // Synchronous lookup: address and target data register at the rising edge.
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
  // Replacement is a single LRU bit per set, which is only correct for two
  // ways. Reject other associativities instead of silently never replacing
  // ways beyond the first two.
  if (WAYS != 2) begin : g_invalid_ways
    $error("rapt_bpu_btb replacement policy supports exactly 2 ways");
  end
  logic [   DEPTH-1:0] valid        [WAYS];
  logic [    XLEN-1:1] way_target   [WAYS];
  logic [         1:0] way_type     [WAYS];

  // LRU tracking: lru[set] = next victim way for replacement
  logic [   DEPTH-1:0] lru;

  // Registered read address and tag.
  //
  // Keep local copies for the metadata lookup and replacement path.
  //
  // The target payload is read at the same edge as these registers, so its
  // output no longer has an address mux on the prediction path.
  (* keep = "true" *)logic [ADDR_LEN-1:0] r_raddr_tag  [WAYS];
  (* keep = "true" *)logic [ADDR_LEN-1:0] r_raddr_itype[WAYS];
  (* keep = "true" *)logic [ADDR_LEN-1:0] r_raddr_valid[WAYS];
  (* keep = "true" *)logic [ADDR_LEN-1:0] r_raddr_lru;
  (* keep = "true" *)logic [ TAG_LEN-1:0] r_rtag_cmp   [WAYS];

  // --- Read path: per-way tag match (each way uses its private raddr/rtag copy) ---
  logic [    WAYS-1:0] way_hit;
  logic                hit_way;
  logic [ADDR_LEN-1:0] held_raddr;

  assign hit_way      = way_hit[1];
  assign rd_tag_match = |way_hit;
  assign rd_target    = hit_way ? way_target[1] : way_target[0];
  assign rd_type      = hit_way ? way_type[1] : way_type[0];

  // --- Write path: update matching way, or replace LRU victim ---
  logic [WAYS-1:0] w_way_match;
  logic w_sel;

  // A fixed way owns each target bank. A write to the currently observed set
  // must appear at the output after the edge, including when ren is low. The
  // explicit forwarding register makes that behavior independent of the RAM's
  // read-during-write mode and keeps its read port on a simple clocked template.
  for (genvar w = 0; w < WAYS; w++) begin : g_way_storage
    (* ram_style = "block" *) logic [XLEN-1:1] target[DEPTH];
    logic [XLEN-1:1] target_q;
    logic [XLEN-1:1] target_forward_q;
    logic target_forward_valid_q;
    logic target_write;
    logic target_write_observed;
    logic [TAG_LEN-1:0] tag[DEPTH];
    logic [1:0] itype[DEPTH];
    assign target_write = wen_entry && (w_sel == 1'(w)) && !reset && !init;
    assign target_write_observed = target_write && (waddr == (ren ? raddr : held_raddr));
    assign way_target[w] = target_forward_valid_q ? target_forward_q : target_q;
    assign way_type[w] = itype[r_raddr_itype[w]];
    assign way_hit[w] = valid[w][r_raddr_valid[w]] && (r_rtag_cmp[w] == tag[r_raddr_tag[w]]);
    assign w_way_match[w] = valid[w][waddr] && (wd_tag == tag[waddr]);
    always_ff @(posedge clock) begin
      if (ren && !(target_write && waddr == raddr)) target_q <= target[raddr];
      if (target_write) target[waddr] <= wd_target;
    end
    always_ff @(posedge clock) begin
      if (reset || init) target_forward_valid_q <= 1'b0;
      else begin
        if (ren) target_forward_valid_q <= target_write_observed;
        if (target_write_observed) begin
          target_forward_q <= wd_target;
          target_forward_valid_q <= 1'b1;
        end
      end
    end
    always_ff @(posedge clock) begin
      if (!reset && !init) begin
        if (wen_entry && w_sel == 1'(w)) begin
          tag[waddr] <= wd_tag;
        end
        if (wen_type && (wen_entry || |w_way_match) && w_sel == 1'(w)) itype[waddr] <= wd_type;
      end
    end
  end

  assign w_sel = |w_way_match ? w_way_match[1] : lru[waddr];

  always_ff @(posedge clock) begin
    if (reset || init) begin
      for (int w = 0; w < WAYS; w++) valid[w] <= '0;
      lru <= '0;
      // itype/tag/target payload and the replicated r_raddr_* address
      // registers are intentionally NOT reset: way_hit ANDs every payload
      // read with valid[w][r_raddr_valid[w]], and the valid array is
      // cleared here, so no stale entry can raise rd_tag_match (the only
      // gate through which rd_target/rd_type are consumed in rapt_bpu).
      // target was already unreset; itype now follows the same rule.
    end else begin
      if (ren) begin
        for (int w = 0; w < WAYS; w++) begin
          r_raddr_tag[w]   <= raddr;
          r_raddr_itype[w] <= raddr;
          r_raddr_valid[w] <= raddr;
          r_rtag_cmp[w]    <= rtag;
        end
        r_raddr_lru <= raddr;
        held_raddr  <= raddr;
      end
      // Update LRU on read hit: mark other way as next victim.
      // Write-entry LRU takes priority when both fire (same-set R/W).
      if (wen_entry) begin
        valid[w_sel][waddr] <= 1'b1;
        lru[waddr] <= ~w_sel;
      end else if (rd_tag_match) begin
        lru[r_raddr_lru] <= ~hit_way;
      end
    end
  end
endmodule
