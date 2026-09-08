`include "rapt.svh"
`include "rapt_if.svh"

module rapt_idu #(
    parameter int XLEN  = `RAPT_XLEN,
    parameter int RLEN  = `RAPT_REG_LEN,
    parameter int Width = rapt_pkg::DecodeWidth
) (
    input logic clock,
    cmu_bcast_if.in cmu_bcast,
    rapt_recovery_if.sink recovery,
    csr_bcast_if.in csr_bcast,
    ifu_idu_if.slave ifu_idu,
    idu_rnu_if.master idu_rnu,
    idu_bpu_if.out idu_bpu,
    input logic reset
);
  rapt_pkg::fetch_slot_t slots[Width], next_slots[Width];
  rapt_pkg::decoded_slot_t decoded[Width];
  int unsigned count, next_count, consumed, incoming;
  logic accept[Width];
  logic redirect, prefix;
  logic [XLEN-1:0] redirect_pc;
  int redirect_slot, ras_slot;
  rapt_pkg::ras_action_t ras_actions[Width];
  logic pmu_early_resteer;
  for (genvar s = 0; s < Width; s++) begin : g_decode
    rapt_decode_slot #(
        .XLEN(XLEN),
        .RLEN(RLEN)
    ) decoder (
        .fetched(slots[s]),
        .csr_bcast(csr_bcast),
        .decoded(decoded[s])
    );
  end
  // Resolve only accepted instructions. The redirect is generated from this
  // registered stage, so flushing FQU cannot form a valid->redirect loop.
  always_comb begin
    prefix = !reset && !cmu_bcast.flush_pipe && !cmu_bcast.sys_resume
        && !recovery.pending;
    consumed = 0;
    redirect = 1'b0;
    redirect_pc = '0;
    redirect_slot = 0;
    ras_slot = -1;
    idu_bpu.history_valid = 0;
    idu_bpu.history_taken = 0;
    idu_bpu.history_pc_bit = 0;
    for (int s = 0; s < Width; s++) begin
      automatic logic is_control;
      automatic logic direct_jump;
      automatic logic [XLEN-1:0] sequential, corrected;
      is_control = decoded[s].uop.execute.branch.conditional
          || decoded[s].uop.execute.branch.jump || decoded[s].uop.execute.branch.indirect;
      direct_jump = decoded[s].uop.execute.branch.jump && !decoded[s].uop.execute.branch.indirect;
      ras_actions[s] = rapt_pkg::ras_action(decoded[s].uop.inst);
      sequential = slots[s].pc + (decoded[s].uop.c ? XLEN'(2) : XLEN'(4));
      corrected = direct_jump ? slots[s].pc + decoded[s].uop.imm : slots[s].pnpc;
      if (decoded[s].uop.execute.branch.conditional && slots[s].pnpc != sequential)
        corrected = slots[s].pc + decoded[s].uop.imm;
      if (!is_control) corrected = sequential;
      if (decoded[s].uop.execute.branch.indirect && ras_actions[s].pop && idu_bpu.ras_valid)
        corrected = (idu_bpu.ras_addr + decoded[s].uop.imm) & ~XLEN'(1);
      idu_rnu.slot[s] = decoded[s];
      idu_rnu.slot[s].uop.pnpc = corrected;
      idu_rnu.valid[s] = prefix && s < count;
      accept[s] = idu_rnu.valid[s] && idu_rnu.ready[s];
      if (accept[s]) begin
        consumed++;
        if (!decoded[s].uop.trap && decoded[s].uop.execute.branch.conditional) begin
          idu_bpu.history_valid = 1;
          idu_bpu.history_taken = decoded[s].uop.execute.branch.predicted_taken;
          idu_bpu.history_pc_bit = slots[s].pc[1];
        end
        if (!decoded[s].uop.trap && (ras_actions[s].push || ras_actions[s].pop)) ras_slot = s;
        if (!decoded[s].uop.trap && corrected != slots[s].pnpc) begin
          redirect = 1'b1;
          redirect_pc = corrected;
          redirect_slot = s;
        end
      end
      prefix = prefix && accept[s] && !redirect && !is_control && !decoded[s].uop.trap;
    end
  end
  always_comb begin
    incoming = 0;
    for (int s = 0; s < Width; s++) begin
      ifu_idu.ready[s] = !reset && !cmu_bcast.flush_pipe && !cmu_bcast.sys_resume
          && !recovery.pending
          && !redirect && s < Width - count + consumed;
      if (s == incoming && ifu_idu.valid[s] && ifu_idu.ready[s]) incoming++;
    end
    next_count = count - consumed + incoming;
    for (int s = 0; s < Width; s++) begin
      next_slots[s] = '0;
      if (s < count - consumed) next_slots[s] = slots[s+consumed];
      for (int i = 0; i < Width; i++)
      if (i < incoming && s == count - consumed + i) next_slots[s] = ifu_idu.slot[i];
    end
    if (redirect) next_count = 0;
  end
  assign ifu_idu.resteer = redirect;
  assign idu_bpu.history_recover = redirect;
  assign ifu_idu.resteer_pc = redirect_pc;
  assign idu_bpu.train_en = redirect && (decoded[redirect_slot].uop.execute.branch.conditional
      || (decoded[redirect_slot].uop.execute.branch.jump
          && !decoded[redirect_slot].uop.execute.branch.indirect)
      || (ras_actions[redirect_slot].pop && idu_bpu.ras_valid));
  assign idu_bpu.train_pc = slots[redirect_slot].pc;
  assign idu_bpu.train_target = redirect_pc;
  assign idu_bpu.train_type = ras_actions[redirect_slot].pop ? 2'b11
      : decoded[redirect_slot].uop.execute.branch.conditional ? 2'b00 : 2'b01;
  assign idu_bpu.push_en = ras_slot >= 0 && ras_actions[ras_slot].push;
  assign idu_bpu.pop_en = ras_slot >= 0 && ras_actions[ras_slot].pop;
  assign idu_bpu.push_addr = ras_slot < 0 ? '0 : slots[ras_slot].pc
      + (decoded[ras_slot].uop.c ? XLEN'(2) : XLEN'(4));
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe || cmu_bcast.sys_resume || recovery.pending) begin
      count <= 0;
      pmu_early_resteer <= 1'b0;
    end else begin
      count <= next_count;
      pmu_early_resteer <= redirect;
      for (int s = 0; s < Width; s++) slots[s] <= next_slots[s];
    end
  end
  `RAPT_SVA_IMPLY(
      clock, reset, IDU_RECOVERY_NO_ACCEPT_OR_OUTPUT, recovery.pending,
      !ifu_idu.ready[0] && !idu_rnu.valid[0] && !idu_bpu.history_valid && !idu_bpu.train_en)
endmodule
