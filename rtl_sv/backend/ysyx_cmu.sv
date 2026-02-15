`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_dpi_c.svh"

module ysyx_cmu #(
    parameter unsigned XLEN = `YSYX_XLEN
) (
    input clock,

    rou_cmu_if.in rou_cmu,
    cmu_bcast_if.out cmu_bcast,

    input reset
);
  /* verilator lint_off UNUSEDSIGNAL */
  logic valid;
  logic prev_valid;
  logic [31:0] inst;
  logic [XLEN-1:0] rpc, npc;
  /* verilator lint_on UNUSEDSIGNAL */

  logic ben, jen, jren;
  logic [XLEN-1:0] pmu_inst_retire;

  assign prev_valid = rou_cmu.valid;
  assign ben = rou_cmu.ben;
  assign jen = rou_cmu.jen;
  assign jren = rou_cmu.jren;

  assign cmu_bcast.rpc = rou_cmu.pc;  // retire pc
  assign cmu_bcast.cpc = rou_cmu.npc;  // correct pc
  assign cmu_bcast.rd = rou_cmu.rd;

  assign cmu_bcast.ben = prev_valid && ben;
  assign cmu_bcast.jen = prev_valid && jen;
  assign cmu_bcast.jren = prev_valid && jren;
  assign cmu_bcast.btaken = prev_valid && rou_cmu.btaken;
  assign cmu_bcast.time_trap = rou_cmu.time_trap;

  assign cmu_bcast.fence_time = rou_cmu.fence_time;
  assign cmu_bcast.fence_i = rou_cmu.fence_i;
  assign cmu_bcast.flush_pipe = rou_cmu.flush_pipe;

  always @(posedge clock) begin
    if (reset) begin
      valid <= 0;
      pmu_inst_retire <= 0;
      `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
    end else begin
      if (rou_cmu.valid) begin
        // Debug & Difftest
        valid <= 1;
        pmu_inst_retire <= pmu_inst_retire + 1;
        if (rou_cmu.ebreak) begin
          `YSYX_DPI_C_NPC_EXU_EBREAK
        end
        rpc  <= rou_cmu.pc;
        npc  <= rou_cmu.npc;
        inst <= rou_cmu.inst;
      end else begin
        valid <= 0;
      end
    end
  end

endmodule
