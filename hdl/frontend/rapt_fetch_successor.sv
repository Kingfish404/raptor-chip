`include "rapt.svh"

// Predict only where to request the next packet. The response stage validates
// every hint against freshly decoded instructions and the direction predictor
// before a younger packet can enter the visible stream.
module rapt_fetch_successor #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int IndexBits = 7
) (
    input logic clock,
    input logic reset,
    input logic invalidate,
    input logic [XLEN-1:0] query_pc,
    output logic hit,
    output logic [XLEN-1:0] successor,
    input logic train,
    input logic [XLEN-1:0] train_pc,
    input logic [XLEN-1:0] train_successor
);
  localparam int Entries = 1 << IndexBits;
  typedef struct packed {
    logic [XLEN-1:1] tag;
    logic [XLEN-1:1] target;
  } entry_t;
  (* ram_style = "distributed" *) entry_t entries[Entries];
  logic [Entries-1:0] valid_q;
  wire [IndexBits-1:0] read_index = query_pc[IndexBits:1]
      ^ query_pc[2*IndexBits:IndexBits+1];
  wire [IndexBits-1:0] write_index = train_pc[IndexBits:1]
      ^ train_pc[2*IndexBits:IndexBits+1];
  entry_t entry;
  assign entry = entries[read_index];
  assign hit = valid_q[read_index] && entry.tag == query_pc[XLEN-1:1];
  assign successor = {entry.target, 1'b0};
  always_ff @(posedge clock) begin
    if (reset || invalidate) valid_q <= '0;
    else if (train) valid_q[write_index] <= 1'b1;
    if (train && !reset && !invalidate)
      entries[write_index] <= {train_pc[XLEN-1:1], train_successor[XLEN-1:1]};
  end
endmodule
