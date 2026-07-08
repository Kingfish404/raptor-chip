`include "rapt.svh"

// L1I tag + valid memory with dual-mirror register arrays.
//
// One cache line stores a single tag per way. Two mirrored copies provide
// two independent combinational read addresses each cycle:
//   - raddr_curr  : current fetch line
//   - raddr_next4 : line containing pc+4
//
// This removes the old per-word tag duplication while preserving the
// parallel hit checks needed by the fetch path.
//
// Tags use (* ram_style = "block" *) to guide FPGA synthesis toward BRAM
// inference, reducing LUT-mux depth on the read path.  Valid bits remain
// distributed flops for fast bulk invalidation.
(* keep_hierarchy *)
module rapt_l1i_tagmem #(
    parameter int L1I_LEN  = `RAPT_L1I_LEN,
    parameter int TAG_W    = 22,
    parameter int L1I_SIZE = 2 ** L1I_LEN
) (
    input logic clock,
    input logic reset,

    input  logic [L1I_LEN-1:0] raddr_curr,
    output logic [  TAG_W-1:0] rtag_curr,
    output logic               rvalid_curr,

    input  logic [L1I_LEN-1:0] raddr_next4,
    output logic [  TAG_W-1:0] rtag_next4,
    output logic               rvalid_next4,

    input  logic               wen,
    input  logic [L1I_LEN-1:0] waddr_idx,
    input  logic [  TAG_W-1:0] wtag,
    output logic               wtag_match,

    input logic               valid_set,
    input logic [L1I_LEN-1:0] valid_set_idx,

    input logic inv
);
  // Register arrays with block-RAM hint for FPGA synthesis.
  // On FPGA this infers BRAM with registered output (pipelined naturally).
  // On ASIC this stays as flops; 32 entries x ~22 bits is a shallow mux.
  (* ram_style = "block" *) logic [TAG_W-1:0] tags_curr[L1I_SIZE];
  (* ram_style = "block" *) logic [TAG_W-1:0] tags_next4[L1I_SIZE];
  logic [L1I_SIZE-1:0] valid;

  assign rtag_curr = tags_curr[raddr_curr];
  assign rvalid_curr = valid[raddr_curr];
  assign rtag_next4 = tags_next4[raddr_next4];
  assign rvalid_next4 = valid[raddr_next4];
  assign wtag_match = valid[waddr_idx] && (tags_curr[waddr_idx] == wtag);

  always_ff @(posedge clock) begin
    if (reset) begin
      valid <= '0;
    end else begin
      if (wen) begin
        tags_curr[waddr_idx] <= wtag;
        tags_next4[waddr_idx] <= wtag;
        valid[waddr_idx] <= 1'b1;
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
