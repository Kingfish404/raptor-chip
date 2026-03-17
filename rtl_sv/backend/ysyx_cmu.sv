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
  logic valid_b;
  logic prev_valid;
  logic [31:0] inst;
  logic [XLEN-1:0] rpc, npc;
  /* verilator lint_on UNUSEDSIGNAL */

  logic ben, jen, jren;
  logic [XLEN-1:0] pmu_inst_retire;

  // PMU — registered branch/flush signals aligned with 'valid'
  /* verilator lint_off UNUSEDSIGNAL */
  logic ben_r, jen_r, flush_pipe_r;
  /* verilator lint_on UNUSEDSIGNAL */

  assign prev_valid = rou_cmu.valid_a;
  assign ben = rou_cmu.ben;
  assign jen = rou_cmu.jen;
  assign jren = rou_cmu.jren;

  // When dual committing, broadcast slot 1's branch/redirect info.
  // Slot 0's branch was correctly predicted (no flush), so training loss is minimal.
  logic use_slot1;
  assign use_slot1 = rou_cmu.valid_b;

  assign cmu_bcast.rpc = use_slot1 ? rou_cmu.pc_b : rou_cmu.pc_a;
  assign cmu_bcast.cpc = use_slot1 ? rou_cmu.npc_b : rou_cmu.npc_a;
  assign cmu_bcast.rd_a = rou_cmu.rd_a;

  assign cmu_bcast.ben = prev_valid && ben;
  assign cmu_bcast.jen = prev_valid && jen;
  assign cmu_bcast.jren = prev_valid && jren;
  assign cmu_bcast.btaken = prev_valid && rou_cmu.btaken;
  assign cmu_bcast.time_trap = rou_cmu.time_trap;

  assign cmu_bcast.fence_time = rou_cmu.fence_time;
  assign cmu_bcast.fence_i = rou_cmu.fence_i;
  assign cmu_bcast.flush_pipe = rou_cmu.flush_pipe;

  // Second commit slot info for freelist flush recovery
  assign cmu_bcast.rd_b = rou_cmu.rd_b;
  assign cmu_bcast.valid_b = rou_cmu.valid_b;

  always @(posedge clock) begin
    if (reset) begin
      valid <= 0;
      valid_b <= 0;
      pmu_inst_retire <= 0;
      ben_r <= 0;
      jen_r <= 0;
      flush_pipe_r <= 0;
      `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
    end else begin
      ben_r <= ben;
      jen_r <= jen;
      flush_pipe_r <= rou_cmu.flush_pipe;
      if (rou_cmu.valid_a) begin
        // Debug & Difftest — slot 0
        valid <= 1;
        valid_b <= rou_cmu.valid_b;
        pmu_inst_retire <= pmu_inst_retire + 1 + (rou_cmu.valid_b ? 1 : 0);
        if (rou_cmu.ebreak_a) begin
          `YSYX_DPI_C_NPC_EXU_EBREAK
        end
        if (rou_cmu.difftest_skip_a) begin
          `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
        end
        // Slot 1 difftest
        if (rou_cmu.valid_b) begin
          if (rou_cmu.ebreak_b) begin
            `YSYX_DPI_C_NPC_EXU_EBREAK
          end
          if (rou_cmu.difftest_skip_b) begin
            `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
          end
        end
        rpc  <= rou_cmu.valid_b ? rou_cmu.pc_b : rou_cmu.pc_a;
        npc  <= rou_cmu.valid_b ? rou_cmu.npc_b : rou_cmu.npc_a;
        inst <= rou_cmu.valid_b ? rou_cmu.inst_b : rou_cmu.inst_a;
      end else begin
        valid   <= 0;
        valid_b <= 0;
      end
    end
  end

endmodule
