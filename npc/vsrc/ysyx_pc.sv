`include "ysyx.svh"
`include "ysyx_soc.svh"
`include "ysyx_dpi_c.svh"

module ysyx_pc (
    input clock,
    input reset,

    input bad_speculation,

    input branch_change,
    input branch_retire,
    input [XLEN-1:0] npc_wdata,
    output [XLEN-1:0] out_npc,
    output out_change,
    output out_retire,

    input prev_valid
);
  parameter bit [7:0] XLEN = `YSYX_XLEN;
  reg [XLEN-1:0] pc;
  reg change, retire;
  assign out_npc = pc;
  assign out_change = change;
  assign out_retire = retire;

  always @(posedge clock) begin
    if (reset) begin
    end else begin
      if (prev_valid & !bad_speculation) begin
        change <= branch_change;
        retire <= branch_retire;
        pc <= npc_wdata;
      end else begin
        change <= 0;
        retire <= 0;
      end
    end
  end
endmodule  //ysyx_PC
