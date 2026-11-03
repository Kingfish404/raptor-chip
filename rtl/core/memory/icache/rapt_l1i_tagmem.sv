`include "rapt.svh"

// One logical tag array, with current, pc+4 and refill comparison reads.
// The tag-valid flops own bulk invalidation for both tags and word masks.
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
  // The current, next-PC and write-tag reads are all combinational.
  logic [TAG_W-1:0] tags[L1I_SIZE];
  logic [L1I_SIZE-1:0] valid;

  assign rtag_curr = tags[raddr_curr];
  assign rvalid_curr = valid[raddr_curr];
  assign rtag_next4 = tags[raddr_next4];
  assign rvalid_next4 = valid[raddr_next4];
  assign wtag_match = valid[waddr_idx] && (tags[waddr_idx] == wtag);

  always_ff @(posedge clock) begin
    if (reset) begin
      valid <= '0;
    end else begin
      if (wen) begin
        tags[waddr_idx] <= wtag;
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
