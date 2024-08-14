`include "ysyx_macro.vh"
`include "ysyx_macro_soc.vh"
`include "ysyx_macro_dpi_c.vh"

module ysyx_pc (
    input clk,
    input rst,
    input prev_valid,
    input use_exu_npc,
    input branch_retire,
    input [DATA_W-1:0] npc_wdata,
    output wire [DATA_W-1:0] npc_o,
    output reg valid_o,
    skip_o
);
  parameter bit[7:0] DATA_W = `YSYX_W_WIDTH;
  // wire [DATA_W-1:0] npc = pc + 4;
  reg [DATA_W-1:0] pc, lpc;
  reg valid = 0, skip = 0;
  assign valid_o = valid | (use_exu_npc);
  assign skip_o  = skip;
  assign npc_o   = use_exu_npc ? npc_wdata : pc;

  always @(posedge clk) begin
    if (rst) begin
      pc <= `YSYX_PC_INIT;
      `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
    end else if (prev_valid) begin
      lpc <= pc;
      pc  <= pc + 4;
      if (use_exu_npc) begin
        pc <= npc_wdata;
        valid <= 1;
        skip <= 0;
      end else if (branch_retire) begin
        valid <= 0;
        skip  <= 1;
      end
    end else begin
      valid <= 0;
      skip  <= 0;
    end
  end
endmodule  //ysyx_PC
