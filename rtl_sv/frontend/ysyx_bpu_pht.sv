`include "ysyx.svh"

// PHT (Pattern History Table) with synchronous read for BPU prediction.
// Uses (* keep_hierarchy *) to prevent Yosys from flattening this module
// into the parent, which preserves the internal registered read address
// and avoids the massive fan-out of pc_ifu driving the MUX tree directly.
(* keep_hierarchy *)
module ysyx_bpu_pht #(
    parameter int DEPTH = `YSYX_PHT_SIZE,
    parameter int ADDR_LEN = $clog2(DEPTH)
) (
    input logic clock,
    input logic reset,

    // Synchronous read port: address registered at posedge, data combinational
    input  logic                ren,
    input  logic [ADDR_LEN-1:0] raddr,
    output logic [         1:0] rdata,

    // Update port (saturating 2-bit counter)
    input logic                update_en,
    input logic                update_taken,
    input logic [ADDR_LEN-1:0] update_addr,

    // Bulk init (fence_time)
    input logic init
);
  logic [1:0] mem[DEPTH];
  logic [ADDR_LEN-1:0] r_raddr;

  assign rdata = mem[r_raddr];

  always @(posedge clock) begin
    if (reset || init) begin
      for (int i = 0; i < DEPTH; i++) mem[i] <= 2'b00;
      r_raddr <= '0;
    end else begin
      if (ren) r_raddr <= raddr;
      if (update_en) begin
        if (update_taken) begin
          if (mem[update_addr] != 2'b11) mem[update_addr] <= mem[update_addr] + 1;
        end else begin
          if (mem[update_addr] != 2'b00) mem[update_addr] <= mem[update_addr] - 1;
        end
      end
    end
  end
endmodule
