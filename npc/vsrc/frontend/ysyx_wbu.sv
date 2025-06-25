`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_dpi_c.svh"

module ysyx_wbu #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    input [31:0] inst,
    input [31:0] pc,
    input ebreak,

    input [XLEN-1:0] npc_wdata,
    input jen,
    input ben,
    input sys_retire,

    wbu_pipe_if.out wbu_if,

    input  prev_valid,
    output out_valid,

    input reset
);
  logic [31:0] inst_wbu, pc_wbu, npc_wbu;

  logic jen_wbu, ben_wbu;
  logic retire, valid, ready;

  assign out_valid = valid;
  assign ready = 1;

  assign wbu_if.npc = npc_wbu;
  assign wbu_if.rpc = pc_wbu;
  assign wbu_if.jen = jen_wbu;
  assign wbu_if.ben = ben_wbu;
  assign wbu_if.sys_retire = retire;

  always @(posedge clock) begin
    if (reset) begin
      valid <= 0;
      `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
    end else begin
      if (prev_valid) begin
        pc_wbu <= pc;
        inst_wbu <= inst;
        valid <= 1;
        jen_wbu <= jen;
        ben_wbu <= ben;
        retire <= sys_retire;
        npc_wbu <= npc_wdata;
        if (ebreak) begin
          `YSYX_DPI_C_NPC_EXU_EBREAK
        end
      end else begin
        valid   <= 0;
        retire  <= 0;
        jen_wbu <= 0;
        ben_wbu <= 0;
      end
    end
  end

endmodule
