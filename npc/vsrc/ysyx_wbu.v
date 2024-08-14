`include "ysyx_macro.vh"
`include "ysyx_macro_dpi_c.vh"

module ysyx_wbu (
    input clk,
    input rst,

    input [31:0] pc,
    input [31:0] inst,
    input [BIT_W-1:0] reg_wdata,
    input [3:0] rd,
    input [BIT_W-1:0] npc_wdata,
    input use_exu_npc,
    input ebreak,

    output reg [BIT_W-1:0] reg_wdata_o,
    output reg [3:0] rd_o,
    output reg [BIT_W-1:0] npc_wdata_o,
    output reg use_exu_npc_o,

    input prev_valid,
    input next_ready,
    output reg valid_o,
    output ready_o
);
  parameter bit[7:0] BIT_W = `YSYX_W_WIDTH;

  reg state;
  reg [31:0] inst_wbu, pc_wbu;
  `YSYX_BUS_FSM()
  always @(posedge clk) begin
    if (rst) begin
      valid_o <= 0;
      ready_o <= 1;
    end else begin
      if (prev_valid & ready_o) begin
        reg_wdata_o <= reg_wdata;
        rd_o <= rd;
        npc_wdata_o <= npc_wdata;
        use_exu_npc_o <= use_exu_npc;
        pc_wbu <= pc;
        inst_wbu <= inst;
        if (ebreak) begin
          `YSYX_DPI_C_NPC_EXU_EBREAK
        end
      end
      if (state == `YSYX_IDLE) begin
        if (prev_valid == 1) begin
          valid_o <= 1;
          // ready_o <= 0;
        end
      end else if (state == `YSYX_WAIT_READY) begin
        // if (next_ready == 1) begin
        ready_o <= 1;
        if (prev_valid == 0) begin
          valid_o <= 0;
        end
        // end
      end
    end
  end

endmodule  // ysyx_WBU
