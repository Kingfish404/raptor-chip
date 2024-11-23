`include "ysyx.svh"
`include "ysyx_dpi_c.svh"

module ysyx_wbu (
    input clock,

    input [31:0] inst,
    input [31:0] pc,
    input ebreak,

    input [XLEN-1:0] npc_wdata,
    input branch_change,
    input branch_retire,

    output [XLEN-1:0] out_npc,
    output out_change,
    output out_retire,

    input  prev_valid,
    input  next_ready,
    output out_valid,
    output out_ready,

    input reset
);
  parameter bit [7:0] XLEN = `YSYX_XLEN;

  reg [31:0] inst_wbu, pc_wbu, npc_wbu;

  reg change, retire, valid, ready;

  assign out_valid = valid;
  assign out_ready = ready;
  assign ready = 1;

  assign out_npc = npc_wbu;
  assign out_change = change;
  assign out_retire = retire;

  always @(posedge clock) begin
    if (reset) begin
      valid <= 0;
      `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
    end else begin
      if (prev_valid) begin
        pc_wbu <= pc;
        inst_wbu <= inst;
        valid <= 1;
        change <= branch_change;
        retire <= branch_retire;
        npc_wbu <= npc_wdata;
        if (ebreak) begin
          `YSYX_DPI_C_NPC_EXU_EBREAK
        end
      end else begin
        valid  <= 0;
        change <= 0;
        retire <= 0;
      end
    end
  end

endmodule  // ysyx_wbu
