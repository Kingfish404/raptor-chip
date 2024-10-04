
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
    output reg ready_o
);
  parameter bit [7:0] BIT_W = `YSYX_W_WIDTH;

  reg state;
  reg [31:0] inst_wbu, pc_wbu;

  assign pc_o = pc_wbu;
  assign ready_o = '1;

  assign state = valid_o;
  always @(posedge clk) begin
    if (rst) begin
      valid_o <= 0;
    end else begin
      if (prev_valid & ready_o) begin
        pc_wbu   <= pc;
        inst_wbu <= inst;
        valid_o  <= 1;
        if (ebreak) begin
          `YSYX_DPI_C_NPC_EXU_EBREAK
        end
      end else begin
        valid_o <= 0;
      end
    end
  end

endmodule  // ysyx_WBU
