`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_dpi_c.svh"

module ysyx_wbu #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    rou_wbu_if.in   rou_wbu,
    wbu_pipe_if.out wbu_bcast,

    input  prev_valid,
    output out_valid,

    input reset
);
  logic valid;
  logic [31:0] inst_wbu;
  logic [XLEN-1:0] pc_wbu, npc_wbu;

  logic sys_retire;
  logic jen_wbu, ben_wbu;
  logic fence_time, fence_i;
  logic flush_pipe;

  assign out_valid = valid;

  assign wbu_bcast.pc = pc_wbu;
  assign wbu_bcast.npc = npc_wbu;

  assign wbu_bcast.sys_retire = sys_retire;
  assign wbu_bcast.jen = jen_wbu;
  assign wbu_bcast.ben = ben_wbu;

  assign wbu_bcast.fence_time = fence_time;
  assign wbu_bcast.fence_i = fence_i;

  assign wbu_bcast.flush_pipe = flush_pipe;

  always @(posedge clock) begin
    if (reset) begin
      valid <= 0;
      `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
    end else begin
      if (prev_valid) begin
        valid <= 1;

        if (rou_wbu.ebreak) begin
          `YSYX_DPI_C_NPC_EXU_EBREAK
        end
        pc_wbu <= rou_wbu.pc;
        npc_wbu <= rou_wbu.npc;

        sys_retire <= rou_wbu.sys_retire;
        jen_wbu <= rou_wbu.jen;
        ben_wbu <= rou_wbu.ben;

        fence_time <= rou_wbu.fence_time;
        fence_i <= rou_wbu.fence_i;

        flush_pipe <= rou_wbu.flush_pipe;

        inst_wbu <= rou_wbu.inst;
      end else begin
        valid <= 0;

        sys_retire <= 0;
        jen_wbu <= 0;
        ben_wbu <= 0;

        fence_time <= 0;
        fence_i <= 0;

        flush_pipe <= 0;
      end
    end
  end

endmodule
