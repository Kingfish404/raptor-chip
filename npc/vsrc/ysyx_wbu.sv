`include "ysyx_macro.svh"
`include "ysyx_macro_dpi_c.svh"

module ysyx_wbu (
    input clk,
    input rst,

    input [31:0] pc,
    input [31:0] inst,

    input ebreak,
    output [31:0] pc_o,

    input prev_valid,
    input next_ready,
    output reg valid_o,
    output ready_o
);
  parameter bit [7:0] BIT_W = `YSYX_W_WIDTH;

  reg state;
  reg [31:0] inst_wbu, pc_wbu;

  assign pc_o = pc_wbu;

  `YSYX_BUS_FSM()
  always @(posedge clk) begin
    if (rst) begin
      valid_o <= 0;
      ready_o <= 1;
    end else begin
      if (prev_valid & ready_o) begin
        pc_wbu   <= pc;
        inst_wbu <= inst;
        if (ebreak) begin
          `YSYX_DPI_C_NPC_EXU_EBREAK
        end
      end
      if (state == `YSYX_IDLE) begin
        if (prev_valid == 1) begin
          valid_o <= 1;
        end
      end else if (state == `YSYX_WAIT_READY) begin
        ready_o <= 1;
        if (prev_valid == 0) begin
          valid_o <= 0;
        end
      end
    end
  end

endmodule  // ysyx_WBU
