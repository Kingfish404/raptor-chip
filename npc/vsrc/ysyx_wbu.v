`include "ysyx_macro.v"
`include "ysyx_macro_dpi_c.v"

module ysyx_wbu (
    input clk,
    input rst,

    input [BIT_W-1:0] reg_wdata,
    input [4:0] rd,
    input [BIT_W-1:0] npc_wdata,
    input use_exu_npc,
    input ebreak,

    output reg [BIT_W-1:0] reg_wdata_o,
    output reg [4:0] rd_o,
    output reg [BIT_W-1:0] npc_wdata_o,
    output reg use_exu_npc_o,

    input prev_valid,
    input next_ready,
    output reg valid_o,
    output ready_o
);
  parameter integer BIT_W = `ysyx_W_WIDTH;

  reg state;
  `ysyx_BUS_FSM()
  always @(posedge clk) begin
    if (rst) begin
      valid_o <= 0;
      ready_o <= 1;
    end else begin
      if (prev_valid) begin
        reg_wdata_o <= reg_wdata;
        rd_o <= rd;
        npc_wdata_o <= npc_wdata;
        use_exu_npc_o <= use_exu_npc;
        if (ebreak) begin
          `ysyx_DPI_C_npc_exu_ebreak
        end
      end
      if (state == `ysyx_IDLE) begin
        if (prev_valid == 1) begin
          valid_o <= 1;
          ready_o <= 0;
        end
      end else if (state == `ysyx_WAIT_READY) begin
        if (next_ready == 1) begin
          ready_o <= 1;
          valid_o <= 0;
        end
      end
    end
  end

endmodule  // ysyx_WBU
