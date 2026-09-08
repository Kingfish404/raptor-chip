`include "rapt.svh"

// Conservative non-speculative fetch authorization. Empty includes all
// frontend queues and the ROB, so repeated PCs cannot alias older dynamic
// instructions. A frontend cancel alone never replenishes the permission.
module rapt_ifetch_io_guard #(
    parameter int XLEN = `RAPT_XLEN
) (
    input logic clock,
    reset,
    input logic [XLEN-1:0] owner_pc,
    frontier_pc,
    input logic frontier_advance,
    blocked,
    pipeline_empty,
    memory_idle,
    input logic io_start,
    output logic authorized
);
  logic issued;
  assign authorized = !reset && !blocked && !frontier_advance && !issued
      && pipeline_empty && memory_idle && owner_pc == frontier_pc;
  always_ff @(posedge clock) begin
    if (reset || frontier_advance) issued <= 0;
    else if (io_start) issued <= 1;
  end
  `RAPT_SVA_IMPLY(clock, reset, IFETCH_IO_START_AUTHORIZED, io_start, authorized)
endmodule
