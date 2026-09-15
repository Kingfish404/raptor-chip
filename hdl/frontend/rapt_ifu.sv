`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"

// The cache owns cross-word/page assembly of the first instruction. Its fixed
// lookahead window is an input bandwidth limit, NOT a decode/rename slot count.
// This stage walks complete 16/32-bit instructions and holds any unconsumed
// suffix. A control instruction terminates the fetched prefix.
module rapt_ifu #(
    parameter int XLEN  = `RAPT_XLEN,
    parameter int Width = rapt_pkg::DecodeWidth,
    parameter bit ResponseStage = `RAPT_FETCH_RESPONSE_STAGE
) (
    input logic clock,
    cmu_bcast_if.in cmu_bcast,
    rapt_recovery_if.sink recovery,
    ifu_bpu_if.out ifu_bpu,
    ifu_l1i_if.master ifu_l1i,
    ifu_idu_if.master ifu_idu,
    output logic ifu_hazard,
    output logic response_pending_o,
    input logic reset
);
  logic [XLEN-1:0] pc_ifu, nextpc, redirect_pc;
  rapt_pkg::fetch_slot_t held[Width], fetched[Width];
  logic [15:0] halfword[6];
  logic half_valid[6];
  localparam int CountBits = (Width > 0) ? $clog2(Width + 1) : 1;
  logic [CountBits-1:0] held_count;
  // Keep combinational indexing/arithmetic wide; narrow only bounded state.
  int unsigned consumed, fetched_count;
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
  typedef struct packed {
    logic [XLEN-1:0] pc;
    logic [31:0] inst_n0, inst_n1, inst_n2;
    logic inst_n1_valid, inst_n2_valid;
    logic trap;
    logic [XLEN-1:0] cause, tval;
    logic predicted_taken;
    logic [XLEN-1:0] predicted_npc;
  } fetch_response_t;
  fetch_response_t live_response, response, response_q;
  logic response_valid, response_valid_q;
  logic capture_response, response_redirect, response_stop;
  logic [XLEN-1:0] request_nextpc;
  always_comb begin
    live_response = '0;
    live_response.pc = pc_ifu;
    live_response.inst_n0 = ifu_l1i.inst_n0;
`ifdef RAPT_FETCH_LOOKAHEAD
    live_response.inst_n1 = ifu_l1i.inst_n1;
    live_response.inst_n2 = ifu_l1i.inst_n2;
    live_response.inst_n1_valid = ifu_l1i.inst_n1_valid;
    live_response.inst_n2_valid = ifu_l1i.inst_n2_valid;
`endif
    live_response.trap = ifu_l1i.trap;
    live_response.cause = ifu_l1i.cause;
    live_response.tval = ifu_l1i.tval;
    live_response.predicted_taken = ifu_bpu.taken;
    live_response.predicted_npc = ifu_bpu.npc;
  end
  assign response = ResponseStage ? response_q : live_response;
  assign response_valid = ResponseStage ? response_valid_q : ifu_l1i.valid;
  assign response_pending_o = ResponseStage && response_valid_q;

  // Predict only the packet boundary here. In particular, lookahead permission
  // and auxiliary direction must NOT feed this request-address calculation.
  // Recognize control-flow boundaries directly from the first halfword, without
  // decompressing an instruction or computing its target. A not-taken branch
  // can therefore continue without a correction bubble. Unavailable words and
  // taken auxiliary branches are resolved by the registered response stage
  // before any younger response is accepted.
  function automatic logic request_control(input logic [15:0] first);
    case (first[1:0])
      2'b11: return first[6:0] inside {`RAPT_OP_B_TYPE_, `RAPT_OP_JAL___, `RAPT_OP_JALR__};
      2'b01: return first[15:13] inside {3'b101, 3'b110, 3'b111}
          || (XLEN == 32 && first[15:13] == 3'b001);
      2'b10: return first[15:13] == 3'b100 && first[6:2] == 0;
      default: return 1'b0;
    endcase
  endfunction
  logic [15:0] request_halfword[6];
  logic [2:0] request_offset[Width+1];
  logic request_stopped[Width+1];
  assign request_halfword[0] = live_response.inst_n0[15:0];
  assign request_halfword[1] = live_response.inst_n0[31:16];
  assign request_halfword[2] = pc_ifu[1] ? live_response.inst_n1[31:16]
      : live_response.inst_n1[15:0];
  assign request_halfword[3] = pc_ifu[1] ? live_response.inst_n2[15:0]
      : live_response.inst_n1[31:16];
  assign request_halfword[4] = pc_ifu[1] ? live_response.inst_n2[31:16]
      : live_response.inst_n2[15:0];
  assign request_halfword[5] = live_response.inst_n2[31:16];
`ifdef RAPT_FETCH_LOOKAHEAD
  localparam int RequestHalfwords = 6;
`else
  localparam int RequestHalfwords = 2;
`endif
  assign request_offset[0] = 0;
  assign request_stopped[0] = 1'b0;
  for (genvar s = 0; s < Width; s++) begin : g_request_boundary
    wire [2:0] step = request_offset[s] < 3'(RequestHalfwords)
        && request_halfword[request_offset[s]][1:0] != 2'b11 ? 3'd1 : 3'd2;
    assign request_offset[s+1] = !request_stopped[s] && request_offset[s] < 3'(RequestHalfwords)
        && {1'b0, request_offset[s]} + {1'b0, step} <= 4'(RequestHalfwords)
        ? request_offset[s] + step : request_offset[s];
    assign request_stopped[s+1] = request_stopped[s]
        || (request_offset[s] < 3'(RequestHalfwords)
            && request_control(request_halfword[request_offset[s]]));
  end
  assign request_nextpc = ifu_bpu.taken ? ifu_bpu.npc
      : pc_ifu + XLEN'({request_offset[Width], 1'b0});
  assign response_redirect = ResponseStage && recv_ready
      && (response_stop || nextpc != pc_ifu);
  assign capture_response = ResponseStage && (!response_valid_q || recv_ready)
      && !response_redirect && !blocked && !redirect_event && !recovery.pending
      && !reset && ifu_l1i.valid;
  always_ff @(posedge clock) begin
    if (reset || redirect_event || recovery.pending) begin
      response_valid_q <= 1'b0;
    end else if (capture_response) begin
      response_q <= live_response;
      response_valid_q <= 1'b1;
    end else if (recv_ready) begin
      response_valid_q <= 1'b0;
    end
  end
  function automatic logic is_zimop(input logic [31:0] inst);
    return inst[6:0] == `RAPT_OP_SYSTEM && inst[14:12] == 3'b100 && inst[31]
        && inst[29:28] == 2'b00 && (inst[25] || inst[24:22] == 3'b111);
  endfunction
  function automatic logic is_inval_order(input logic [31:0] inst);
    // SINVAL.VMA performs a complete translation fence. Its two ordering
    // companions retire as ordinary no-ops and produce no system resume.
    return inst == 32'h18000073 || inst == 32'h18100073;
  endfunction
  assign halfword[0]   = response.inst_n0[15:0];
  assign halfword[1]   = response.inst_n0[31:16];
  assign half_valid[0] = response_valid;
`ifdef RAPT_FETCH_LOOKAHEAD
  assign halfword[2]   = response.pc[1] ? response.inst_n1[31:16] : response.inst_n1[15:0];
  assign halfword[3]   = response.pc[1] ? response.inst_n2[15:0] : response.inst_n1[31:16];
  assign halfword[4]   = response.pc[1] ? response.inst_n2[31:16] : response.inst_n2[15:0];
  assign halfword[5]   = response.inst_n2[31:16];
  assign half_valid[1] = response_valid && (!response.pc[1] || response.inst_n1_valid);
  assign half_valid[2] = response.inst_n1_valid;
  assign half_valid[3] = response.pc[1] ? response.inst_n2_valid : response.inst_n1_valid;
  assign half_valid[4] = response.inst_n2_valid;
  assign half_valid[5] = !response.pc[1] && response.inst_n2_valid;
`else
  assign half_valid[1] = response_valid;
  for (genvar h = 2; h < 6; h++) begin : g_halfword_fill
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
    assign available[s] = s == 0 ? response_valid
        : offset[s+1] <= 6 && half_valid[offset[s]]
          && (compressed || half_valid[offset[s]+1]);
    assign candidate_pc[s] = response.pc + XLEN'(2 * offset[s]);
    assign sequential[s] = response.pc + XLEN'(2 * offset[s+1]);
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
      before_control = available[s] && !response.predicted_taken && !response.trap;
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
    response_stop = 1'b0;
    fetched_count = 0;
    nextpc = response.pc;
    for (int s = 0; s < Width; s++) begin
      fetched[s] = '0;
      fetched[s].inst = raw[s];
      fetched[s].pc = candidate_pc[s];
      fetched[s].pnpc = sequential[s];
      fetched[s].predicted_taken = is_cond[s] && s == 0 && response.predicted_taken;
      if (s == 0 && response.predicted_taken) fetched[s].pnpc = response.predicted_npc;
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
      fetched[s].trap  = s == 0 && response.trap;
      fetched[s].tval  = response.tval;
      fetched[s].cause = response.cause;
      if (!stopped && available[s]) begin
        fetched_count++;
        nextpc = fetched[s].pnpc;
        response_stop |= is_serial[s] || fetched[s].trap;
      end
      stopped |= !available[s] || is_control[s] || is_serial[s]
          || (s == 0 && (response.predicted_taken || response.trap));
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
      ifu_idu.valid[s] = s < 32'(held_count) && !redirect_event && !recovery.pending && !reset;
      if (s == consumed && ifu_idu.valid[s] && ifu_idu.ready[s]) consumed++;
    end
  end
  // The completion-time redirect is allowed to launch a read-ahead, but the
  // returned line must not repopulate fetch state until precise backend
  // cleanup releases the recovery fence.  This also prevents speculative
  // history updates from the recovery target while retirement is pending.
  assign recv_ready = 32'(held_count) == consumed && !blocked && !redirect_event
      && !recovery.pending && !reset && response_valid;
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
  assign ifu_bpu.nextpc = redirect_event ? redirect_pc
      : !ResponseStage || response_redirect ? nextpc : request_nextpc;
  assign ifu_bpu.pc_update = redirect_event
      || (ResponseStage ? capture_response || response_redirect : recv_ready);
  assign ifu_l1i.consumed = ResponseStage ? capture_response : recv_ready;
  assign ifu_l1i.cancel = redirect_event || recovery.pending || response_redirect;
  assign ifu_l1i.pc = pc_ifu;
  assign ifu_l1i.invalid = cmu_bcast.fence_i;
  // Ordinary reads use pc_ifu's registered address. L1I already reads the
  // current and following words in parallel; feeding the just-decoded nextpc
  // back to its SRAM ports adds a cache-data -> decode -> address path.
  // Keep immediate read-ahead for recovery/redirect targets.
  assign ifu_l1i.prefetch_valid = redirect_event;
  assign ifu_l1i.prefetch_pc = redirect_pc;
`ifndef SYNTHESIS
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
`endif
  always_ff @(posedge clock) begin
    if (reset) begin
      pc_ifu <= XLEN'(`RAPT_PC_INIT);
      held_count <= 0;
      blocked <= 1'b0;
`ifndef SYNTHESIS
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
`endif
    end else begin
      // Address generation runs ahead of the response/packing stage. A
      // correction has priority over a speculative next-packet request.
      if (ResponseStage) begin
        if (response_redirect) pc_ifu <= nextpc;
        else if (capture_response) pc_ifu <= request_nextpc;
      end
`ifndef SYNTHESIS
      pmu_fetch_multi_fire <= consumed > 1;
      pmu_fetch_first_control <= recv_ready && is_control[0];
      pmu_fetch_aux_conditional <= recv_ready && secondary_query;
      pmu_fetch_nonfirst_jal_pack <= recv_ready && fetched_count > 1
      && expanded[fetched_count-1][6:0] == `RAPT_OP_JAL___;
      pmu_fetch_nonfirst_cond_pack <= recv_ready && secondary_query;
      pmu_fetch_n1_unavailable <= response_valid && !half_valid[2];
      pmu_fetch_n1_unavailable_unaligned <= response_valid && !half_valid[2] && response.pc[1];
      pmu_fetch_n1_unavailable_l1i <= response_valid && !half_valid[2];
      pmu_fetch_downstream_blocked <= held_count != 0 && consumed == 0;
      pmu_ifu_flush_stall <= redirect_event;
      pmu_ifu_response_after_redirect <= redirect_event && ifu_l1i.valid;
      pmu_ifu_response_after_l1i_gap <= recv_ready && held_count == 0;
      pmu_ifu_response_bypass_candidate <= recv_ready && held_count == 0 && !is_control[0];
      pmu_fetch_fire <= consumed != 0;
      pmu_fetch_slots <= consumed;
      pmu_ifu_stall <= held_count == 0 && ifu_idu.ready[0];
      pmu_ifu_icache_stall <= held_count == 0 && !blocked && !response_valid && !ifu_l1i.valid;
      pmu_ifu_empty_stall <= blocked;
      pmu_fetch_response_consume <= recv_ready;
      pmu_fetch_bpu_taken <= recv_ready && response.predicted_taken;
      pmu_fetch_target_steer <= recv_ready
          && nextpc != response.pc + XLEN'(2 * offset[fetched_count]);
`endif
      if (redirect_event) begin
        pc_ifu <= redirect_pc;
        held_count <= 0;
        blocked <= 1'b0;
      end else if (recv_ready) begin
        if (!ResponseStage) pc_ifu <= nextpc;
        held_count <= CountBits'(fetched_count);
        for (int s = 0; s < Width; s++) begin
          held[s] <= fetched[s];
          if (s < fetched_count && (is_serial[s] || fetched[s].trap)) blocked <= 1'b1;
        end
      end else begin
        held_count <= CountBits'(32'(held_count) - consumed);
        for (int s = 0; s < Width; s++)
        if (s + consumed < 32'(held_count)) held[s] <= held[s+consumed];
      end
    end
  end
  if ((Width & (Width + 1)) != 0) begin : g_count_range
    `RAPT_SVA(clock, reset, IFU_RESIDENT_COUNT_BOUND, 32'(held_count) <= Width)
  end
  `RAPT_SVA(clock, reset, IFU_COUNT_BOUNDS, consumed <= 32'(held_count) && fetched_count <= Width)
  `RAPT_SVA_IMPLY(clock, reset, IFU_RECOVERY_NO_RESPONSE_ACCEPT, recovery.pending,
                  !recv_ready && !ifu_bpu.history_valid)
  `RAPT_SVA_IMPLY(clock, reset, IFU_RECOVERY_NO_STREAM_OUTPUT, recovery.pending, !ifu_idu.valid[0])
  `RAPT_SVA_IMPLY(clock, reset, IFU_RESPONSE_NO_WRONG_PACKET, response_redirect,
                  !capture_response && ifu_l1i.cancel)
  `RAPT_SVA_IMPLY(clock, reset, IFU_RESPONSE_NO_OVERWRITE, capture_response,
                  !response_valid_q || recv_ready)
endmodule
