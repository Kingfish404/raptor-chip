`include "ysyx_macro.v"
`include "ysyx_macro_soc.v"
`include "ysyx_macro_dpi_c.v"

module ysyx_pc (
    input clk,
    input rst,
    input prev_valid,
    input use_exu_npc,
    input branch_retire,
    input [DATA_W-1:0] npc_wdata,
    output wire [DATA_W-1:0] npc_o,
    output reg valid_o, skip_o,
    output [DATA_W-1:0] pc_o
);
  parameter integer DATA_W = `ysyx_W_WIDTH;
  wire [DATA_W-1:0] npc = pc + 4;
  reg [DATA_W-1:0] pc, lpc;
  assign npc_o = pc;
  // assign pc_o  = pc;

  always @(posedge clk) begin
    if (rst) begin
      pc <= `ysyx_PC_INIT;
      `ysyx_DPI_C_npc_difftest_skip_ref
    end else if (prev_valid) begin
      lpc <= pc;
      if (use_exu_npc) begin
        pc <= npc_wdata;
        valid_o <= 1;
        skip_o <= 0;
      end else if (branch_retire) begin
        pc <= npc;
        valid_o <= 0;
        skip_o <= 1;
      end
    end
  end
endmodule  //ysyx_PC
