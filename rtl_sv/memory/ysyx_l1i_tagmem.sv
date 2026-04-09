`include "ysyx.svh"

// L1I tag + valid memory behind (* keep_hierarchy *).
// Combinational read — functionally identical to inline register arrays.
// The module boundary prevents Yosys from merging these arrays into the
// parent's fan-out tree, forcing separate buffer insertion for addr_idx
// and reducing the root pc_ifu BUF delay on the critical path.
(* keep_hierarchy *)
module ysyx_l1i_tagmem #(
    parameter int L1I_LEN       = 32'(`YSYX_L1I_LEN),
    parameter int L1I_LINE_LEN  = 32'(`YSYX_L1I_LINE_LEN),
    parameter int TAG_W         = 22,
    parameter int L1I_SIZE      = 2 ** L1I_LEN,
    parameter int L1I_LINE_SIZE = 2 ** L1I_LINE_LEN
) (
    input logic clock,
    input logic reset,

    // Combinational read — hit outputs available same cycle
    input  logic [     L1I_LEN-1:0] addr_idx,
    input  logic [L1I_LINE_LEN-1:0] addr_offset,
    input  logic [       TAG_W-1:0] addr_tag,
    input  logic [     L1I_LEN-1:0] addr_idx_next,
    input  logic [L1I_LINE_LEN-1:0] addr_offset_next,
    input  logic [       TAG_W-1:0] addr_tag_next,
    output logic                    hit,
    output logic                    hit_next,

    // Write port: tag fill from bus
    input logic                    wen,
    input logic [     L1I_LEN-1:0] waddr_idx,
    input logic [L1I_LINE_LEN-1:0] waddr_offset,
    input logic [       TAG_W-1:0] wtag,

    // Valid set (one-hot per fill when IFQ drains)
    input logic               valid_set,
    input logic [L1I_LEN-1:0] valid_set_idx,

    // Bulk invalidate
    input logic inv
);
  logic [TAG_W-1:0] tags[L1I_SIZE][L1I_LINE_SIZE];
  logic [L1I_SIZE-1:0] valid;

  // Combinational hit — same semantics as inline arrays
  assign hit = (valid[addr_idx] && (tags[addr_idx][addr_offset] == addr_tag));
  assign hit_next = (valid[addr_idx_next]
    && (tags[addr_idx_next][addr_offset_next] == addr_tag_next));

  always @(posedge clock) begin
    if (reset) begin
      valid <= '0;
    end else begin
      if (wen) begin
        tags[waddr_idx][waddr_offset] <= wtag;
      end
      if (valid_set) begin
        valid[valid_set_idx] <= 1'b1;
      end
      if (inv) begin
        valid <= '0;
      end
    end
  end
endmodule
