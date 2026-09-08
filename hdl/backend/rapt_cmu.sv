`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_dpi_c.svh"
module rapt_cmu #(
    parameter unsigned XLEN = `RAPT_XLEN,
    parameter int CommitWidth = rapt_pkg::CommitWidth
) (
    input logic clock,
    rou_cmu_if.in rou_cmu,
    cmu_bcast_if.out cmu_bcast,
    input logic reset
);
  // Registered simulator observation: every committed instruction is exposed.
  logic valid;
  int unsigned retire_count, count;
  logic [31:0] inst, pmu_inst_retire;
  logic [XLEN-1:0] rpc, npc;
  logic [XLEN-1:0] rpc_slots[CommitWidth], npc_slots[CommitWidth];
  logic [31:0] inst_slots[CommitWidth];
  logic
      ben_slots[CommitWidth],
      jen_slots[CommitWidth],
      jren_slots[CommitWidth],
      mispredict_slots[CommitWidth];
  logic ben_r, jen_r, jren_r, flush_pipe_r;
  int youngest, branch_index;
  logic branch_valid, atomic_valid;
  logic [31:0] bcast_inst;
  rapt_pkg::ras_action_t commit_ras_action;
  always_comb begin
    count = 0;
    youngest = 0;
    branch_index = 0;
    branch_valid = 1'b0;
    atomic_valid = 1'b0;
    for (int c = 0; c < CommitWidth; c++)
    if (rou_cmu.slot[c].valid) begin
      count++;
      atomic_valid |= rou_cmu.slot[c].atomic && !rou_cmu.slot[c].trap;
      youngest = c;
      if (rou_cmu.slot[c].ben || rou_cmu.slot[c].jen || rou_cmu.slot[c].jren) begin
        branch_index = c;
        branch_valid = 1'b1;
      end
    end
  end
  assign bcast_inst = rou_cmu.slot[branch_index].inst;
  assign cmu_bcast.rpc = rou_cmu.slot[branch_valid?branch_index : youngest].pc;
  assign cmu_bcast.cpc = rou_cmu.next_pc;
  assign cmu_bcast.ben = branch_valid && !rou_cmu.slot[branch_index].trap && rou_cmu.slot[branch_index].ben;
  assign cmu_bcast.jen = branch_valid && !rou_cmu.slot[branch_index].trap && rou_cmu.slot[branch_index].jen;
  assign cmu_bcast.jren = branch_valid && !rou_cmu.slot[branch_index].trap && rou_cmu.slot[branch_index].jren;
  // Only successful retirement preserves address identity; a trapping atomic
  // must follow normal context invalidation just like any other exception.
  assign cmu_bcast.atomic_retired = atomic_valid;
  assign cmu_bcast.btaken = rou_cmu.slot[branch_index].btaken;
  assign commit_ras_action = rapt_pkg::ras_action(bcast_inst);
  assign cmu_bcast.call = branch_valid && !rou_cmu.slot[branch_index].trap
      && commit_ras_action.push;
  assign cmu_bcast.ret = branch_valid && !rou_cmu.slot[branch_index].trap
      && commit_ras_action.pop;
  // inst is expanded by decode; its low bits cannot recover original length.
  assign cmu_bcast.rvc = rou_cmu.slot[branch_index].c;
  assign cmu_bcast.time_trap = rou_cmu.time_trap;
  assign cmu_bcast.fence_time = rou_cmu.fence_time;
  assign cmu_bcast.fence_i = rou_cmu.fence_i;
  assign cmu_bcast.flush_pipe = rou_cmu.flush_pipe;
  assign cmu_bcast.flush_redirect = rou_cmu.flush_redirect;
  assign cmu_bcast.redirect_pc = rou_cmu.redirect_pc;
  assign cmu_bcast.sys_resume = rou_cmu.sys_resume;
  assign cmu_bcast.rob_head = rou_cmu.rob_head;
  always_ff @(posedge clock) begin
    if (reset) begin
      valid <= 1'b0;
      retire_count <= 0;
      pmu_inst_retire <= 0;
      ben_r <= 0;
      jen_r <= 0;
      jren_r <= 0;
      flush_pipe_r <= 0;
      rpc <= 0;
      npc <= 0;
      inst <= 0;
      `RAPT_DPI_C_NPC_DIFFTEST_SKIP_REF
      for (int c = 0; c < CommitWidth; c++) begin
        rpc_slots[c] <= 0;
        npc_slots[c] <= 0;
        inst_slots[c] <= 0;
        ben_slots[c] <= 0;
        jen_slots[c] <= 0;
        jren_slots[c] <= 0;
        mispredict_slots[c] <= 0;
      end
    end else begin
      valid <= count != 0;
      retire_count <= count;
      pmu_inst_retire <= pmu_inst_retire + count;
      ben_r <= cmu_bcast.ben;
      jen_r <= cmu_bcast.jen;
      jren_r <= cmu_bcast.jren;
      flush_pipe_r <= rou_cmu.flush_pipe;
      if (count != 0) begin
        rpc  <= rou_cmu.slot[youngest].pc;
        npc  <= rou_cmu.next_pc;
        inst <= rou_cmu.slot[youngest].inst;
      end
      for (int c = 0; c < CommitWidth; c++) begin
        rpc_slots[c] <= rou_cmu.slot[c].pc;
        npc_slots[c] <= rou_cmu.slot[c].npc;
        inst_slots[c] <= rou_cmu.slot[c].inst;
        ben_slots[c] <= rou_cmu.slot[c].ben;
        jen_slots[c] <= rou_cmu.slot[c].jen;
        jren_slots[c] <= rou_cmu.slot[c].jren;
        mispredict_slots[c] <= rou_cmu.slot[c].branch_mispredict;
        if (rou_cmu.slot[c].valid) begin
          if (rou_cmu.slot[c].ebreak) begin
            `RAPT_DPI_C_NPC_EXU_EBREAK
          end
          if (rou_cmu.slot[c].difftest_skip) begin
            `RAPT_DPI_C_NPC_DIFFTEST_SKIP_REF
          end
        end
      end
    end
  end
endmodule
