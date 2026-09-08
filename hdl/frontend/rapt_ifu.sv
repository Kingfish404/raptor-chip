`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"

// The cache owns cross-word/page assembly of the first instruction. Its fixed
// lookahead window is an input bandwidth limit, NOT a decode/rename slot count.
// This stage walks complete 16/32-bit instructions and holds any unconsumed
// suffix. A control instruction terminates the fetched prefix.
module rapt_ifu #(
    parameter int XLEN  = `RAPT_XLEN,
    parameter int Width = rapt_pkg::DecodeWidth
) (
    input logic clock,
    cmu_bcast_if.in cmu_bcast,
    rapt_recovery_if.sink recovery,
    ifu_bpu_if.out ifu_bpu,
    ifu_l1i_if.master ifu_l1i,
    ifu_idu_if.master ifu_idu,
    output logic ifu_hazard,
    input logic reset
);
  logic [XLEN-1:0] pc_ifu, nextpc, redirect_pc;
  rapt_pkg::fetch_slot_t held[Width], fetched[Width];
  logic [15:0] halfword[6];
  logic half_valid[6];
  int unsigned held_count, consumed, fetched_count;
  logic redirect_event, recv_ready, stopped;
  logic [31:0] raw[Width], expanded[Width];
  logic [XLEN-1:0] candidate_pc[Width];
  int offset[Width+1];
  logic available[Width], is_control[Width], is_serial[Width], is_cond[Width];
  logic [XLEN-1:0] sequential[Width];
  logic [XLEN-1:0] cond_target[Width];
  logic secondary_query;
  int secondary_index;
  logic blocked;
  function automatic logic is_zimop(input logic [31:0] inst);
    return inst[6:0] == `RAPT_OP_SYSTEM && inst[14:12] == 3'b100 && inst[31]
        && inst[29:28] == 2'b00 && (inst[25] || inst[24:22] == 3'b111);
  endfunction
  function automatic logic is_inval_order(input logic [31:0] inst);
    // SINVAL.VMA performs a complete translation fence. Its two ordering
    // companions retire as ordinary no-ops and produce no system resume.
    return inst == 32'h18000073 || inst == 32'h18100073;
  endfunction
  assign halfword[0]   = ifu_l1i.inst_n0[15:0];
  assign halfword[1]   = ifu_l1i.inst_n0[31:16];
  assign half_valid[0] = ifu_l1i.valid;
`ifdef RAPT_FETCH_LOOKAHEAD
  assign halfword[2]   = pc_ifu[1] ? ifu_l1i.inst_n1[31:16] : ifu_l1i.inst_n1[15:0];
  assign halfword[3]   = pc_ifu[1] ? ifu_l1i.inst_n2[15:0] : ifu_l1i.inst_n1[31:16];
  assign halfword[4]   = pc_ifu[1] ? ifu_l1i.inst_n2[31:16] : ifu_l1i.inst_n2[15:0];
  assign halfword[5]   = ifu_l1i.inst_n2[31:16];
  assign half_valid[1] = ifu_l1i.valid && (!pc_ifu[1] || ifu_l1i.inst_n1_valid);
  assign half_valid[2] = ifu_l1i.inst_n1_valid;
  assign half_valid[3] = pc_ifu[1] ? ifu_l1i.inst_n2_valid : ifu_l1i.inst_n1_valid;
  assign half_valid[4] = ifu_l1i.inst_n2_valid;
  assign half_valid[5] = !pc_ifu[1] && ifu_l1i.inst_n2_valid;
`else
  assign half_valid[1] = ifu_l1i.valid;
  for (genvar h = 2; h < 6; h++) begin
    assign halfword[h]   = '0;
    assign half_valid[h] = 1'b0;
  end
`endif
  assign offset[0] = 0;
  for (genvar s = 0; s < Width; s++) begin : g_boundary
    logic compressed;
    assign compressed = offset[s] < 6 && halfword[offset[s]][1:0] != 2'b11;
    assign offset[s+1] = offset[s] + (compressed ? 1 : 2);
    assign raw[s] = offset[s] >= 6 ? '0 : compressed ? {16'b0,halfword[offset[s]]}
        : offset[s]+1 < 6 ? {halfword[offset[s]+1],halfword[offset[s]]} : '0;
    logic [31:0] decompressed;
    rapt_idu_decoder_c decompressor (
        .io_cinst(raw[s][15:0]),
        .io_is_rv64(XLEN == 64),
        .io_inst(decompressed)
    );
    assign expanded[s] = compressed ? decompressed : raw[s];
    // L1I.valid guarantees a complete first instruction even on a straddle;
    // later lookahead instructions require every contributing word's validity.
    assign available[s] = s == 0 ? ifu_l1i.valid
        : offset[s+1] <= 6 && half_valid[offset[s]]
          && (compressed || half_valid[offset[s]+1]);
    assign candidate_pc[s] = pc_ifu + XLEN'(2 * offset[s]);
    assign sequential[s] = pc_ifu + XLEN'(2 * offset[s+1]);
    assign is_cond[s] = expanded[s][6:0] == `RAPT_OP_B_TYPE_;
    assign is_control[s] = is_cond[s] || expanded[s][6:0] ==
        `RAPT_OP_JAL___
        || expanded[s][6:0] == `RAPT_OP_JALR__;
    assign is_serial[s] = (expanded[s][6:0] == `RAPT_OP_SYSTEM && !is_zimop(
        expanded[s]
    ) && !is_inval_order(expanded[s]))
        || expanded[s][6:0] == `RAPT_OP_FENCE_ || expanded[s][6:0] == `RAPT_OP_AMO___;
    wire [12:0] branch_imm = {
      expanded[s][31], expanded[s][7], expanded[s][30:25], expanded[s][11:8], 1'b0
    };
    assign cond_target[s] = candidate_pc[s] + {{(XLEN - 13) {branch_imm[12]}}, branch_imm};
  end
  // Existing predictor provides a primary query and one auxiliary conditional
  // query. It is sufficient because the fetched group ends at its first CFU.
  always_comb begin
    secondary_query = 1'b0;
    secondary_index = 0;
    for (int s = 1; s < Width; s++) begin
      automatic logic before_control;
      before_control = available[s] && !ifu_bpu.taken && !ifu_l1i.trap;
      for (int older = 0; older < s; older++)
      before_control &= available[older] && !is_control[older] && !is_serial[older];
      if (before_control && is_cond[s]) begin
        secondary_query = 1'b1;
        secondary_index = s;
      end
    end
  end
`ifdef RAPT_FETCH_LOOKAHEAD
  assign ifu_bpu.aux_query = secondary_query;
  assign ifu_bpu.aux_pc = candidate_pc[secondary_index];
`endif
  always_comb begin
    stopped = 1'b0;
    fetched_count = 0;
    nextpc = pc_ifu;
    for (int s = 0; s < Width; s++) begin
      fetched[s] = '0;
      fetched[s].inst = raw[s];
      fetched[s].pc = candidate_pc[s];
      fetched[s].pnpc = sequential[s];
      fetched[s].predicted_taken = is_cond[s] && s == 0 && ifu_bpu.taken;
      if (s == 0 && ifu_bpu.taken) fetched[s].pnpc = ifu_bpu.npc;
`ifdef RAPT_FETCH_LOOKAHEAD
      if (s != 0 && is_cond[s] && ifu_bpu.aux_taken) fetched[s].pnpc = cond_target[s];
      if (s != 0 && is_cond[s]) fetched[s].predicted_taken = ifu_bpu.aux_taken;
`endif
      if (s != 0 && expanded[s][6:0] == `RAPT_OP_JAL___) begin
        automatic logic [20:0] immediate;
        immediate = {
          expanded[s][31], expanded[s][19:12], expanded[s][20], expanded[s][30:21], 1'b0
        };
        fetched[s].pnpc = candidate_pc[s] + {{(XLEN - 21) {immediate[20]}}, immediate};
      end
      fetched[s].trap  = s == 0 && ifu_l1i.trap;
      fetched[s].tval  = ifu_l1i.tval;
      fetched[s].cause = ifu_l1i.cause;
      if (!stopped && available[s]) begin
        fetched_count++;
        nextpc = fetched[s].pnpc;
      end
      stopped |= !available[s] || is_control[s] || is_serial[s]
          || (s == 0 && (ifu_bpu.taken || ifu_l1i.trap));
    end
  end
  assign redirect_event = cmu_bcast.flush_pipe || cmu_bcast.flush_redirect
      || cmu_bcast.sys_resume || recovery.redirect_valid || ifu_idu.resteer;
  assign redirect_pc = cmu_bcast.flush_redirect ? cmu_bcast.redirect_pc
      : (cmu_bcast.flush_pipe || cmu_bcast.sys_resume) ? cmu_bcast.cpc
      : recovery.redirect_valid ? recovery.target : ifu_idu.resteer_pc;
  always_comb begin
    consumed = 0;
    for (int s = 0; s < Width; s++) begin
      ifu_idu.slot[s]  = held[s];
      ifu_idu.valid[s] = s < held_count && !redirect_event && !reset;
      if (s == consumed && ifu_idu.valid[s] && ifu_idu.ready[s]) consumed++;
    end
  end
  // The completion-time redirect is allowed to launch a read-ahead, but the
  // returned line must not repopulate fetch state until precise backend
  // cleanup releases the recovery fence.  This also prevents speculative
  // history updates from the recovery target while retirement is pending.
  assign recv_ready = held_count == consumed && !blocked && !redirect_event
      && !recovery.pending && !reset && ifu_l1i.valid;
  always_comb begin
    ifu_bpu.history_valid = 0;
    ifu_bpu.history_taken = 0;
    ifu_bpu.history_pc_bit = 0;
    for (int s = 0; s < Width; s++)
    if (recv_ready && s < fetched_count && is_cond[s] && !fetched[s].trap
        && !(expanded[s][14:12] inside {3'b010, 3'b011})) begin
      ifu_bpu.history_valid = 1;
      ifu_bpu.history_taken = fetched[s].predicted_taken;
      ifu_bpu.history_pc_bit = fetched[s].pc[1];
    end
  end
  assign ifu_hazard = blocked;
  assign ifu_bpu.pc = pc_ifu;
  assign ifu_bpu.nextpc = redirect_event ? redirect_pc : nextpc;
  assign ifu_bpu.pc_update = recv_ready || redirect_event;
  assign ifu_l1i.consumed = recv_ready;
  assign ifu_l1i.cancel = redirect_event || recovery.pending;
  assign ifu_l1i.pc = pc_ifu;
  assign ifu_l1i.invalid = cmu_bcast.fence_i;
  // Ordinary reads use pc_ifu's registered address. L1I already reads the
  // current and following words in parallel; feeding the just-decoded nextpc
  // back to its SRAM ports adds a cache-data -> decode -> address path.
  // Keep immediate read-ahead for recovery/redirect targets.
  assign ifu_l1i.prefetch_valid = redirect_event;
  assign ifu_l1i.prefetch_pc = redirect_pc;
  logic pmu_fetch_fire, pmu_ifu_stall, pmu_ifu_icache_stall, pmu_ifu_empty_stall;
  logic pmu_fetch_response_consume, pmu_fetch_bpu_taken, pmu_fetch_target_steer;
  logic [31:0] pmu_fetch_slots;
  // Compatibility projections for the existing PMU report schema. They are
  // observations of the stream, never functional slot-control signals. All
  // probes sample the same pre-edge state; the simulator reads after the edge.
  logic pmu_fetch_multi_fire, pmu_fetch_first_control, pmu_fetch_aux_conditional;
  logic pmu_fetch_nonfirst_jal_pack, pmu_fetch_nonfirst_cond_pack;
  logic pmu_fetch_n1_unavailable, pmu_fetch_n1_unavailable_unaligned, pmu_fetch_n1_unavailable_l1i;
  logic pmu_fetch_downstream_blocked, pmu_ifu_flush_stall;
  logic
      pmu_ifu_response_after_redirect,
      pmu_ifu_response_after_l1i_gap,
      pmu_ifu_response_bypass_candidate;
  always_ff @(posedge clock) begin
    if (reset) begin
      pc_ifu <= XLEN'(`RAPT_PC_INIT);
      held_count <= 0;
      blocked <= 1'b0;
      pmu_fetch_fire <= 1'b0;
      pmu_fetch_slots <= 0;
      pmu_ifu_stall <= 0;
      pmu_ifu_icache_stall <= 0;
      pmu_ifu_empty_stall <= 0;
      pmu_fetch_response_consume <= 0;
      pmu_fetch_bpu_taken <= 0;
      pmu_fetch_target_steer <= 0;
      pmu_fetch_multi_fire <= '0;
      pmu_fetch_first_control <= '0;
      pmu_fetch_aux_conditional <= '0;
      pmu_fetch_nonfirst_jal_pack <= '0;
      pmu_fetch_nonfirst_cond_pack <= '0;
      pmu_fetch_n1_unavailable <= '0;
      pmu_fetch_n1_unavailable_unaligned <= '0;
      pmu_fetch_n1_unavailable_l1i <= '0;
      pmu_fetch_downstream_blocked <= '0;
      pmu_ifu_flush_stall <= '0;
      pmu_ifu_response_after_redirect <= '0;
      pmu_ifu_response_after_l1i_gap <= '0;
      pmu_ifu_response_bypass_candidate <= '0;

    end else begin
      pmu_fetch_multi_fire <= consumed > 1;
      pmu_fetch_first_control <= recv_ready && is_control[0];
      pmu_fetch_aux_conditional <= recv_ready && secondary_query;
      pmu_fetch_nonfirst_jal_pack <= recv_ready && fetched_count > 1
      && expanded[fetched_count-1][6:0] == `RAPT_OP_JAL___;
      pmu_fetch_nonfirst_cond_pack <= recv_ready && secondary_query;
      pmu_fetch_n1_unavailable <= ifu_l1i.valid && !half_valid[2];
      pmu_fetch_n1_unavailable_unaligned <= ifu_l1i.valid && !half_valid[2] && pc_ifu[1];
      pmu_fetch_n1_unavailable_l1i <= ifu_l1i.valid && !half_valid[2];
      pmu_fetch_downstream_blocked <= held_count != 0 && consumed == 0;
      pmu_ifu_flush_stall <= redirect_event;
      pmu_ifu_response_after_redirect <= redirect_event && ifu_l1i.valid;
      pmu_ifu_response_after_l1i_gap <= recv_ready && held_count == 0;
      pmu_ifu_response_bypass_candidate <= recv_ready && held_count == 0 && !is_control[0];
      pmu_fetch_fire <= consumed != 0;
      pmu_fetch_slots <= consumed;
      pmu_ifu_stall <= held_count == 0 && ifu_idu.ready[0];
      pmu_ifu_icache_stall <= held_count == 0 && !blocked && !ifu_l1i.valid;
      pmu_ifu_empty_stall <= blocked;
      pmu_fetch_response_consume <= recv_ready;
      pmu_fetch_bpu_taken <= recv_ready && ifu_bpu.taken;
      pmu_fetch_target_steer <= recv_ready && nextpc != pc_ifu + XLEN'(2 * offset[fetched_count]);
      if (redirect_event) begin
        pc_ifu <= redirect_pc;
        held_count <= 0;
        blocked <= 1'b0;
      end else if (recv_ready) begin
        pc_ifu <= nextpc;
        held_count <= fetched_count;
        for (int s = 0; s < Width; s++) begin
          held[s] <= fetched[s];
          if (s < fetched_count && (is_serial[s] || fetched[s].trap)) blocked <= 1'b1;
        end
      end else begin
        held_count <= held_count - consumed;
        for (int s = 0; s < Width; s++) if (s + consumed < held_count) held[s] <= held[s+consumed];
      end
    end
  end
  `RAPT_SVA_IMPLY(clock, reset, IFU_RECOVERY_NO_RESPONSE_ACCEPT, recovery.pending,
                  !recv_ready && !ifu_bpu.history_valid)
  `RAPT_SVA_IMPLY(clock, reset, IFU_RECOVERY_NO_STREAM_OUTPUT, recovery.pending, !ifu_idu.valid[0])
endmodule
