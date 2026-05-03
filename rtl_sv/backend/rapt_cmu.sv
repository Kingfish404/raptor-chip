`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_dpi_c.svh"

module rapt_cmu #(
    parameter unsigned XLEN = `RAPT_XLEN
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
`ifdef VERILATOR
  // Simulation-only commit-slot snapshot for NSIM reverse flow checking.
  // Keep it out of FPGA/ASIC synthesis so verification hooks do not add
  // architectural flops or timing load.
  logic [XLEN-1:0] rpc_a, rpc_b, npc_a, npc_b;
`endif
  /* verilator lint_on UNUSEDSIGNAL */

  logic ben, jen, jren;
  logic [XLEN-1:0] pmu_inst_retire;

  // Call/return detection from committed instruction word
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] bcast_inst;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [4:0] bcast_rd, bcast_rs1;
  logic is_link_rd, is_link_rs1;

  // PMU: registered branch/flush signals aligned with 'valid'
  /* verilator lint_off UNUSEDSIGNAL */
  logic ben_r, jen_r, jren_r, flush_pipe_r;
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
  assign cmu_bcast.call = prev_valid && (jen || jren) && is_link_rd;
  assign cmu_bcast.ret = prev_valid && jren && is_link_rs1 && !is_link_rd;
  assign cmu_bcast.rvc = prev_valid && (bcast_inst[1:0] != 2'b11);
  assign cmu_bcast.time_trap = rou_cmu.time_trap;

  assign cmu_bcast.fence_time = rou_cmu.fence_time;
  assign cmu_bcast.fence_i = rou_cmu.fence_i;
  assign cmu_bcast.flush_pipe = rou_cmu.flush_pipe;
  assign cmu_bcast.sys_resume = rou_cmu.sys_resume;

  assign cmu_bcast.rob_head = rou_cmu.rob_head;

  // Second commit slot info for freelist flush recovery
  assign cmu_bcast.rd_b = rou_cmu.rd_b;
  assign cmu_bcast.valid_b = rou_cmu.valid_b;

  assign bcast_inst = use_slot1 ? rou_cmu.inst_b : rou_cmu.inst_a;
  assign bcast_rd = bcast_inst[11:7];
  assign bcast_rs1 = bcast_inst[19:15];
  assign is_link_rd = (bcast_rd == 5'd1) || (bcast_rd == 5'd5);
  assign is_link_rs1 = (bcast_rs1 == 5'd1) || (bcast_rs1 == 5'd5);

  always_ff @(posedge clock) begin
    if (reset) begin
      valid   <= 0;
      valid_b <= 0;
`ifdef VERILATOR
      rpc_a <= '0;
      rpc_b <= '0;
      npc_a <= '0;
      npc_b <= '0;
`endif
      pmu_inst_retire <= 0;
      ben_r <= 0;
      jen_r <= 0;
      jren_r <= 0;
      flush_pipe_r <= 0;
      `RAPT_DPI_C_NPC_DIFFTEST_SKIP_REF
    end else begin
      ben_r <= ben;
      jen_r <= jen;
      jren_r <= jren;
      flush_pipe_r <= rou_cmu.flush_pipe;
      if (rou_cmu.valid_a) begin
        // Debug & Difftest: slot 0
        valid <= 1;
        valid_b <= rou_cmu.valid_b;
        pmu_inst_retire <= pmu_inst_retire + 1 + (rou_cmu.valid_b ? 1 : 0);
        if (rou_cmu.ebreak_a) begin
          `RAPT_DPI_C_NPC_EXU_EBREAK
        end
        if (rou_cmu.difftest_skip_a) begin
          `RAPT_DPI_C_NPC_DIFFTEST_SKIP_REF
        end
        // Slot 1 difftest
        if (rou_cmu.valid_b) begin
          if (rou_cmu.ebreak_b) begin
            `RAPT_DPI_C_NPC_EXU_EBREAK
          end
          if (rou_cmu.difftest_skip_b) begin
            `RAPT_DPI_C_NPC_DIFFTEST_SKIP_REF
          end
        end
        rpc  <= rou_cmu.valid_b ? rou_cmu.pc_b : rou_cmu.pc_a;
        npc  <= rou_cmu.valid_b ? rou_cmu.npc_b : rou_cmu.npc_a;
        inst <= rou_cmu.valid_b ? rou_cmu.inst_b : rou_cmu.inst_a;
`ifdef VERILATOR
        rpc_a <= rou_cmu.pc_a;
        rpc_b <= rou_cmu.pc_b;
        npc_a <= rou_cmu.npc_a;
        npc_b <= rou_cmu.npc_b;
`endif
      end else begin
        valid   <= 0;
        valid_b <= 0;
      end
    end
  end

endmodule
