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
  localparam int PcW = `RAPT_PC_BITS_OF(XLEN);
  logic [PcW-1:1] pc_ifu_q;
  wire [PcW-1:0] pc_ifu = {pc_ifu_q, 1'b0};
  logic [PcW-1:0] nextpc, redirect_pc;
  logic prediction_ready, prediction_taken;
  logic [PcW-1:0] prediction_npc;
  rapt_pkg::fetch_slot_t held[Width], fetched[Width];
`ifdef RAPT_FETCH_WIDE
  localparam int WindowHalfwords = 8;
`else
  localparam int WindowHalfwords = 6;
`endif
  localparam int OffsetBits = $clog2(WindowHalfwords + 1);
  localparam int WindowIndexBits = $clog2(WindowHalfwords);
  logic [15:0] halfword[WindowHalfwords];
  logic half_valid[WindowHalfwords];
  localparam int CountBits = (Width > 0) ? $clog2(Width + 1) : 1;
  logic [CountBits-1:0] held_count;
  // Keep combinational indexing/arithmetic wide; narrow only bounded state.
  int unsigned consumed, fetched_count;
  logic redirect_event, recv_ready, stopped;
  logic [31:0] raw[Width], expanded[Width];
  logic [PcW-1:0] candidate_pc[Width];
  int offset[Width+1];
  logic available[Width], is_control[Width], is_serial[Width], is_cond[Width];
  logic [PcW-1:0] sequential[Width];
  logic [PcW-1:0] cond_target[Width];
  logic secondary_query;
  localparam int SlotBits = Width > 1 ? $clog2(Width) : 1;
  logic [SlotBits-1:0] secondary_index;
  logic blocked;
  typedef struct packed {
    logic [PcW-1:0] pc;
    logic [31:0] inst_n0, inst_n1, inst_n2;
    logic inst_n1_valid, inst_n2_valid;
`ifdef RAPT_FETCH_WIDE
    logic [31:0] inst_n3, inst_n4;
    logic inst_n3_valid, inst_n4_valid;
`endif
    logic trap;
    logic [XLEN-1:0] cause, tval;
    logic predicted_taken;
    logic [PcW-1:0] predicted_npc;
    logic [PcW-1:0] request_npc;
`ifdef RAPT_FETCH_LOOKAHEAD
    logic [PcW-1:0] aux_pc;
`endif
  } fetch_response_t;
  fetch_response_t live_response, response, response_q;
  fetch_response_t response_fifo[2];
  logic response_read_q, response_write_q;
  logic [1:0] response_count_q;
  logic response_valid, response_valid_q;
  logic capture_response, pop_response, response_redirect, response_stop;
  logic response_kill_younger;
  logic [PcW-1:0] request_nextpc;
  always_comb begin
    live_response = '0;
    live_response.pc = pc_ifu;
    live_response.inst_n0 = ifu_l1i.inst_n0;
`ifdef RAPT_FETCH_LOOKAHEAD
    live_response.inst_n1 = ifu_l1i.inst_n1;
    live_response.inst_n2 = ifu_l1i.inst_n2;
    live_response.inst_n1_valid = ifu_l1i.inst_n1_valid;
    live_response.inst_n2_valid = ifu_l1i.inst_n2_valid;
`ifdef RAPT_FETCH_WIDE
    live_response.inst_n3 = ifu_l1i.inst_n3;
    live_response.inst_n4 = ifu_l1i.inst_n4;
    live_response.inst_n3_valid = ifu_l1i.inst_n3_valid;
    live_response.inst_n4_valid = ifu_l1i.inst_n4_valid;
`endif
`endif
    live_response.trap = ifu_l1i.trap;
    live_response.cause = ifu_l1i.cause;
    live_response.tval = ifu_l1i.tval;
    live_response.predicted_taken = prediction_taken;
    live_response.predicted_npc = prediction_npc;
  end
  assign response_q = response_fifo[response_read_q];
  assign response_valid_q = response_count_q != 0;
  assign response = ResponseStage ? response_q : live_response;
  assign response_valid = ResponseStage ? response_valid_q : ifu_l1i.valid && prediction_ready;
  assign response_pending_o = ResponseStage && response_valid_q;

  logic response_primary_taken;
  logic [PcW-1:0] response_primary_npc;
`ifdef RAPT_BPU_DIRP_TAGE
`ifdef RAPT_FETCH_LOOKAHEAD
  // Request-side primary prediction can precede the previous packet's history
  // update. At the FIFO head the history belongs to this packet. Reuse the
  // otherwise idle auxiliary port for a first conditional, with the PC already
  // captured in aux_pc_q. Its immediate supplies the target without another BTB
  // lookup. This adds no raw-cache-data -> predictor-address path.
  wire refresh_primary = ResponseStage && response_valid && is_cond[0] && !response.trap;
  assign response_primary_taken = refresh_primary ? ifu_bpu.aux_taken : response.predicted_taken;
  assign response_primary_npc = refresh_primary ? cond_target[0] : response.predicted_npc;
`else
  assign response_primary_taken = response.predicted_taken;
  assign response_primary_npc = response.predicted_npc;
`endif
`else
  assign response_primary_taken = response.predicted_taken;
  assign response_primary_npc = response.predicted_npc;
`endif

  // Predict only the packet boundary here. In particular, lookahead permission
  // and auxiliary direction must NOT feed this request-address calculation.
  // Recognize control-flow boundaries directly from the first halfword, without
  // decompressing an instruction or computing its target. A not-taken branch
  // can therefore continue without a correction bubble. Unavailable words and
  // taken auxiliary branches are resolved by the registered response stage
  // before any younger response is packed into the instruction stream.
  function automatic logic request_control(input logic [15:0] first);
    case (first[1:0])
      2'b11: return first[6:0] inside {`RAPT_OP_B_TYPE_, `RAPT_OP_JAL___, `RAPT_OP_JALR__};
      2'b01: return first[15:13] inside {3'b101, 3'b110, 3'b111}
          || (XLEN == 32 && first[15:13] == 3'b001);
      2'b10: return first[15:13] == 3'b100 && first[6:2] == 0;
      default: return 1'b0;
    endcase
  endfunction
  function automatic logic request_conditional(input logic [15:0] first);
    case (first[1:0])
      2'b11: return first[6:0] == `RAPT_OP_B_TYPE_;
      2'b01: return first[15:13] inside {3'b110, 3'b111};
      default: return 1'b0;
    endcase
  endfunction
  // A synchronous BTB prediction only belongs to the packet's first PC.
  // Conditional branches have the auxiliary direction predictor and direct
  // jumps derive their target from the immediate, but a later JALR has neither.
  // End the packet before it so the next request can query the BTB at its PC.
  function automatic logic request_indirect(input logic [15:0] first);
    case (first[1:0])
      2'b11: return first[6:0] == `RAPT_OP_JALR__;
      2'b10: return first[15:13] == 3'b100 && first[6:2] == 0;
      default: return 1'b0;
    endcase
  endfunction
  logic [15:0] request_halfword[WindowHalfwords];
  logic [OffsetBits-1:0] request_offset[Width+1];
  logic request_stopped[Width+1];
  logic request_control_seen[Width+1];
  assign request_halfword[0] = live_response.inst_n0[15:0];
  assign request_halfword[1] = live_response.inst_n0[31:16];
  assign request_halfword[2] = pc_ifu[1] ? live_response.inst_n1[31:16]
      : live_response.inst_n1[15:0];
  assign request_halfword[3] = pc_ifu[1] ? live_response.inst_n2[15:0]
      : live_response.inst_n1[31:16];
  assign request_halfword[4] = pc_ifu[1] ? live_response.inst_n2[31:16]
      : live_response.inst_n2[15:0];
`ifdef RAPT_FETCH_WIDE
  assign request_halfword[5] = pc_ifu[1] ? live_response.inst_n3[15:0]
      : live_response.inst_n2[31:16];
  assign request_halfword[6] = pc_ifu[1] ? live_response.inst_n3[31:16]
      : live_response.inst_n3[15:0];
  assign request_halfword[7] = pc_ifu[1] ? live_response.inst_n4[15:0]
      : live_response.inst_n3[31:16];
`else
  assign request_halfword[5] = live_response.inst_n2[31:16];
`endif
`ifdef RAPT_FETCH_LOOKAHEAD
  localparam int RequestHalfwords = WindowHalfwords;
`else
  localparam int RequestHalfwords = 2;
`endif
  assign request_offset[0] = 0;
  assign request_stopped[0] = 1'b0;
  assign request_control_seen[0] = 1'b0;
  for (genvar s = 0; s < Width; s++) begin : g_request_boundary
    wire [OffsetBits-1:0] step = request_offset[s] < OffsetBits'(RequestHalfwords)
        && request_halfword[WindowIndexBits'(request_offset[s])][1:0] != 2'b11
        ? OffsetBits'(1) : OffsetBits'(2);
    wire request_is_control = request_offset[s] < OffsetBits'(RequestHalfwords)
        && request_control(request_halfword[WindowIndexBits'(request_offset[s])]);
    wire request_is_conditional = request_offset[s] < OffsetBits'(RequestHalfwords)
        && request_conditional(request_halfword[WindowIndexBits'(request_offset[s])]);
    // Predict the not-taken prefix through its first conditional, matching the
    // packing stage's single-control budget. The auxiliary predictor resolves
    // a taken non-first branch after the registered response boundary.
    wire split_before_control = request_offset[s] != 0
        && request_offset[s] < OffsetBits'(RequestHalfwords)
        && (request_indirect(request_halfword[WindowIndexBits'(request_offset[s])])
            || (request_control_seen[s] && request_is_control));
    assign request_offset[s+1] = !request_stopped[s]
        && request_offset[s] < OffsetBits'(RequestHalfwords)
        && !split_before_control
        && {1'b0, request_offset[s]} + {1'b0, step} <= (OffsetBits+1)'(RequestHalfwords)
        ? request_offset[s] + step : request_offset[s];
    assign request_stopped[s+1] = request_stopped[s]
        || split_before_control || (request_is_control && !request_is_conditional);
    assign request_control_seen[s+1] = request_control_seen[s] || request_is_control;
  end
`ifdef RAPT_FETCH_LOOKAHEAD
  logic [PcW-1:0] aux_pc_live, aux_pc_q;
  // A queried non-first conditional is the first control instruction in the
  // response. Capture its PC alongside the response so the auxiliary table
  // read cannot feed back into its own address through packet packing.
  always_comb begin
    aux_pc_live = pc_ifu;
    for (int s = 1; s < Width; s++) begin
      if (!request_stopped[s] && !request_control_seen[s]
          && request_offset[s] < OffsetBits'(RequestHalfwords)
          && request_conditional(
              request_halfword[WindowIndexBits'(request_offset[s])]
          ))
        aux_pc_live = pc_ifu + PcW'({request_offset[s], 1'b0});
    end
  end
  assign aux_pc_q = response_q.aux_pc;
`endif
  logic successor_hit;
  logic [PcW-1:0] packet_successor;
  if (ResponseStage) begin : g_successor
    // The table reads only the registered request PC. Training starts from a
    // registered response, so no raw cache-data or reverse-ready path feeds
    // the request prediction. A stale hint is corrected by the existing FIFO
    // head check before any younger packet becomes visible.
    rapt_fetch_successor #(
        .XLEN(XLEN)
    ) predictor (
        .clock,
        .reset,
        .invalidate(cmu_bcast.fence_i),
        .query_pc(pc_ifu),
        .hit(successor_hit),
        .successor(packet_successor),
        .train(recv_ready && !response_stop),
        .train_pc(response.pc),
        .train_successor(nextpc)
    );
  end else begin : g_no_successor
    assign successor_hit = 1'b0;
    assign packet_successor = '0;
  end
  assign request_nextpc = prediction_taken ? prediction_npc
      : successor_hit ? packet_successor
      : pc_ifu + PcW'({request_offset[Width], 1'b0});
  // Each packet owns the successor used when it was captured. The live request
  // PC may already be two packets ahead and cannot identify a correction.
  // Detect correction independently of downstream readiness so a stalled head
  // can cancel speculation without creating a ready -> cache-consumed path.
  assign response_kill_younger = ResponseStage && response_valid_q
      && (response_stop || nextpc != response_q.request_npc);
  assign response_redirect = recv_ready && response_kill_younger;
  assign capture_response = ResponseStage && response_count_q < 2
      && !response_kill_younger && !blocked && !redirect_event
      && !reset && ifu_l1i.valid && prediction_ready;
  assign pop_response = ResponseStage && recv_ready;
  always_ff @(posedge clock) begin
    if (reset || redirect_event || response_redirect) begin
      response_count_q <= 0;
      response_read_q <= 0;
      response_write_q <= 0;
    end else begin
      case ({
        capture_response, pop_response
      })
        2'b10: response_count_q <= response_count_q + 1'b1;
        2'b01: response_count_q <= response_count_q - 1'b1;
        default: ;
      endcase
      if (pop_response) response_read_q <= !response_read_q;
      if (capture_response) begin
        response_write_q <= !response_write_q;
        response_fifo[response_write_q] <= live_response;
        response_fifo[response_write_q].request_npc <= request_nextpc;
`ifdef RAPT_FETCH_LOOKAHEAD
        response_fifo[response_write_q].aux_pc <= aux_pc_live;
`endif
      end
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
`ifdef RAPT_FETCH_WIDE
  assign halfword[5]   = response.pc[1] ? response.inst_n3[15:0] : response.inst_n2[31:16];
  assign halfword[6]   = response.pc[1] ? response.inst_n3[31:16] : response.inst_n3[15:0];
  assign halfword[7]   = response.pc[1] ? response.inst_n4[15:0] : response.inst_n3[31:16];
`else
  assign halfword[5] = response.inst_n2[31:16];
`endif
  assign half_valid[1] = response_valid && (!response.pc[1] || response.inst_n1_valid);
  assign half_valid[2] = response.inst_n1_valid;
  assign half_valid[3] = response.pc[1] ? response.inst_n2_valid : response.inst_n1_valid;
  assign half_valid[4] = response.inst_n2_valid;
`ifdef RAPT_FETCH_WIDE
  assign half_valid[5] = response.pc[1] ? response.inst_n3_valid : response.inst_n2_valid;
  assign half_valid[6] = response.inst_n3_valid;
  assign half_valid[7] = response.pc[1] ? response.inst_n4_valid : response.inst_n3_valid;
`else
  assign half_valid[5] = !response.pc[1] && response.inst_n2_valid;
`endif
`else
  // L1I.valid covers only the first instruction: a compressed first halfword at
  // pc[1]=1 does not wait for the following word that supplies halfword 1.
  assign half_valid[1] = response_valid && !response.pc[1];
  for (genvar h = 2; h < WindowHalfwords; h++) begin : g_halfword_fill
    assign halfword[h]   = '0;
    assign half_valid[h] = 1'b0;
  end
`endif
  assign offset[0] = 0;
  for (genvar s = 0; s < Width; s++) begin : g_boundary
    logic compressed;
    assign compressed = offset[s] < WindowHalfwords && halfword[offset[s]][1:0] != 2'b11;
    assign offset[s+1] = offset[s] + (compressed ? 1 : 2);
    assign raw[s] = offset[s] >= WindowHalfwords ? '0
        : compressed ? {16'b0,halfword[offset[s]]}
        : offset[s]+1 < WindowHalfwords ? {halfword[offset[s]+1],halfword[offset[s]]} : '0;
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
        : offset[s+1] <= WindowHalfwords && half_valid[offset[s]]
          && (compressed || half_valid[offset[s]+1]);
    assign candidate_pc[s] = response.pc + PcW'(2 * offset[s]);
    assign sequential[s] = response.pc + PcW'(2 * offset[s+1]);
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
    assign cond_target[s] = candidate_pc[s] + {{(PcW - 13) {branch_imm[12]}}, branch_imm};
  end
  // Existing predictor provides a primary query and one auxiliary conditional
  // query. It is sufficient because the fetched group ends at its first CFU.
  always_comb begin
    secondary_query = 1'b0;
    secondary_index = 0;
    for (int s = 1; s < Width; s++) begin
      automatic logic before_control;
      // Choose the address from instruction boundaries alone. Availability,
      // cancellation and prediction validity gate its use, not the TAGE read
      // address; otherwise a late cancel traverses the entire auxiliary table.
      before_control = 1'b1;
      for (int older = 0; older < s; older++)
      before_control &= !is_control[older] && !is_serial[older];
      if (before_control && is_cond[s]) begin
        secondary_index = SlotBits'(s);
        secondary_query = available[s] && !response.predicted_taken && !response.trap;
        for (int older = 0; older < s; older++) secondary_query &= available[older];
      end
    end
  end
`ifdef RAPT_FETCH_LOOKAHEAD
`ifdef RAPT_BPU_DIRP_TAGE
  // The auxiliary tables are already read continuously. Gate their response
  // only with registered FIFO occupancy, not combinational packet decisions.
  // Otherwise synthesis can share mutually masked decode/cancel terms through
  // the returned direction and form a combinational loop across IFU and BPU.
  // Packing still selects at most one conditional and gates history on accept.
  assign ifu_bpu.aux_query = ResponseStage ? response_valid_q : 1'b1;
`else
  assign ifu_bpu.aux_query = secondary_query;
`endif
  // Without a response register, the auxiliary branch can only sit at
  // halfword 1..2*(Width-1) of the fetch block. Send the registered block PC
  // and the decoded position; the predictor looks up every position and the
  // position selects the direction, so L1I data never reaches an address.
  if (!ResponseStage && Width > 1) begin : g_positional_aux
    assign ifu_bpu.aux_pc = response.pc;
    assign ifu_bpu.aux_position = 4'(offset[CountBits'(secondary_index)] - 1);
  end else begin : g_exact_aux
    assign ifu_bpu.aux_pc = ResponseStage ? aux_pc_q : candidate_pc[secondary_index];
    assign ifu_bpu.aux_position = '0;
  end
`endif
  always_comb begin
    automatic logic control_seen;
    control_seen = 1'b0;
    stopped = 1'b0;
    response_stop = 1'b0;
    fetched_count = 0;
    nextpc = response.pc;
    for (int s = 0; s < Width; s++) begin
      automatic logic split_before_indirect;
      split_before_indirect = s != 0 && expanded[s][6:0] == `RAPT_OP_JALR__;
      fetched[s] = '0;
      fetched[s].inst = raw[s];
      fetched[s].pc = candidate_pc[s];
      fetched[s].pnpc = sequential[s];
      fetched[s].predicted_taken = is_cond[s] && s == 0 && response_primary_taken;
      if (s == 0 && response_primary_taken) fetched[s].pnpc = response_primary_npc;
`ifdef RAPT_FETCH_LOOKAHEAD
      if (s != 0 && is_cond[s]) begin
        if (ifu_bpu.aux_taken) fetched[s].pnpc = cond_target[s];
        fetched[s].predicted_taken = ifu_bpu.aux_taken;
        fetched[s].auxiliary = 1'b1;
        fetched[s].auxiliary_index = ifu_bpu.aux_index;
      end
`endif
      if (s != 0 && expanded[s][6:0] == `RAPT_OP_JAL___) begin
        automatic logic [20:0] immediate;
        immediate = {
          expanded[s][31], expanded[s][19:12], expanded[s][20], expanded[s][30:21], 1'b0
        };
        fetched[s].pnpc = candidate_pc[s] + {{(PcW - 21) {immediate[20]}}, immediate};
      end
      fetched[s].trap  = s == 0 && response.trap;
      fetched[s].fetch_tval_plus2 = response.tval == `RAPT_PC_SEXT(XLEN, candidate_pc[s]) + XLEN'(2);
      fetched[s].cause = 6'(response.cause);
      if (!stopped && available[s] && !split_before_indirect
          && !(is_control[s] && control_seen)) begin
        fetched_count++;
        nextpc = fetched[s].pnpc;
        response_stop |= is_serial[s] || fetched[s].trap;
      end
      stopped |= !available[s] || split_before_indirect || is_serial[s]
          || (is_control[s] && control_seen)
          || (is_control[s] && (!is_cond[s] || fetched[s].predicted_taken))
          || (s == 0 && (response_primary_taken || response.trap));
      control_seen |= is_control[s];
    end
  end
  // Clean retirement of an announced recovery owner keeps its target stream.
  // Other flushes retain the immediate prefetch and post-context redirect.
  assign redirect_event = (cmu_bcast.flush_pipe && !recovery.preserve_fetch)
      || (cmu_bcast.flush_redirect && !cmu_bcast.fetch_context_stable)
      || recovery.redirect_valid || ifu_idu.resteer;
  assign redirect_pc = cmu_bcast.flush_redirect ? cmu_bcast.redirect_pc
      : cmu_bcast.flush_pipe ? cmu_bcast.cpc
      : recovery.redirect_valid ? recovery.target : ifu_idu.resteer_pc;
  always_comb begin
    consumed = 0;
    for (int s = 0; s < Width; s++) begin
      ifu_idu.slot[s]  = held[s];
      ifu_idu.valid[s] = s < 32'(held_count) && !redirect_event && !reset;
      if (s == consumed && ifu_idu.valid[s] && ifu_idu.ready[s]) consumed++;
    end
  end
  // Checkpoint history is installed on the redirect edge. Fetch may then
  // fill IFU/FQU while decode waits for precise backend cleanup.
  assign recv_ready = 32'(held_count) == consumed && !blocked && !redirect_event
      && !reset && response_valid;
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
  // Read the predictor continuously. The query is selected only from the
  // registered fetch PC, predictor response, and packet-successor response.
  // Acceptance and instruction boundaries validate/select the result after
  // the edge; they never gate a predictor RAM read.
  localparam int HintBits = 11;
  localparam int HintTagBits = 8;
  localparam int HintEntries = 1 << HintBits;
  typedef struct packed {
    logic [HintTagBits-1:0] tag;
    logic signed [15:0] delta;
    logic [OffsetBits-1:0] length;
    logic [3:0] position;
    logic conditional, direct;
  } hint_t;
  (* ram_style = "block" *) hint_t hints[HintEntries];
  hint_t hint_q, hint_train, hint_write_q;
  logic hint_write_valid_q;
  logic [HintBits-1:0] hint_write_index_q;
  logic hint_valid_read[1];
  logic hint_valid_q, query_valid_q, saved_valid_q;
  logic [PcW-1:0] query_pc_q;
  logic saved_taken_q;
  logic [OffsetBits-1:0] stride_q;
  logic hint_match;
  logic [PcW-1:0] predicted_successor;
  wire [HintBits-1:0] hint_read_index = ifu_bpu.nextpc[HintBits:1]
      ^ ifu_bpu.nextpc[2*HintBits:HintBits+1];
  wire [HintBits-1:0] hint_write_index = response.pc[HintBits:1]
      ^ response.pc[2*HintBits:HintBits+1];
  wire query_match = query_valid_q && query_pc_q == pc_ifu;
  wire request_advance = ResponseStage ? capture_response || response_redirect : recv_ready;
  // Hints may alias or truncate a distant successor. The query-PC check below
  // repairs either case before the corresponding prediction is consumed.
  rapt_bulk_clear_bits #(
      .Entries(HintEntries),
      .GroupBits(5)
  ) hint_valids (
      .clock,
      .clear(reset || cmu_bcast.fence_i),
      .read_index('{hint_read_index}),
      .read_bit(hint_valid_read),
      .write_valid(hint_write_valid_q),
      .write_index(hint_write_index_q),
      .write_bit(1'b1)
  );
  assign hint_match = hint_valid_q && hint_q.tag == pc_ifu[HintBits+HintTagBits:HintBits+1];
  assign prediction_ready = saved_valid_q || query_match;
  assign prediction_taken = saved_valid_q ? saved_taken_q : ifu_bpu.taken;
  assign prediction_npc = saved_valid_q ? query_pc_q : ifu_bpu.npc;
  logic request_aux_taken;
`ifdef RAPT_FETCH_LOOKAHEAD
  assign ifu_bpu.request_aux_position = hint_q.position;
  assign request_aux_taken = ifu_bpu.request_aux_taken;
`else
  assign request_aux_taken = 1'b0;
`endif
  always_comb begin
    automatic logic prefix, control_seen;
    prefix = 1'b1;
    control_seen = 1'b0;
    hint_train = '0;
    hint_train.tag = response.pc[HintBits+HintTagBits:HintBits+1];
    // Record the available fallthrough prefix even when the current branch
    // is taken. A cache-line edge may permanently expose fewer than Width
    // instructions; using the maximum window there causes repeated retries.
    for (int s = 0; s < Width; s++) begin
      if (s != 0 && expanded[s][6:0] == `RAPT_OP_JALR__) prefix = 1'b0;
      if (is_control[s] && control_seen) prefix = 1'b0;
      if (prefix && available[s]) hint_train.length = OffsetBits'(offset[s+1]);
      prefix &= available[s] && !is_serial[s] && !fetched[s].trap && (!is_control[s] || is_cond[s]);
      control_seen |= is_control[s];
    end
    hint_train.conditional = secondary_query;
    hint_train.position = 4'(offset[CountBits'(secondary_index)] - 1);
    hint_train.delta = 16'(cond_target[secondary_index] - response.pc);
    for (int s = 1; s < Width; s++) begin
      if (s < fetched_count && expanded[s][6:0] == `RAPT_OP_JAL___) begin
        hint_train.direct = 1'b1;
        hint_train.delta = 16'(fetched[s].pnpc - response.pc);
      end
    end
    if (ResponseStage) begin
      hint_train.conditional = 1'b0;
      hint_train.direct = 1'b1;
      hint_train.delta = 16'(nextpc - response.pc);
    end
  end
  assign predicted_successor = ifu_bpu.taken ? ifu_bpu.npc
      : hint_match && (hint_q.direct || (hint_q.conditional && request_aux_taken))
      ? pc_ifu + PcW'($signed(hint_q.delta))
      : pc_ifu + (hint_match ? PcW'({hint_q.length, 1'b0}) : PcW'({stride_q, 1'b0}));
  assign ifu_bpu.nextpc = redirect_event ? redirect_pc
      : !prediction_ready ? pc_ifu : saved_valid_q ? query_pc_q : predicted_successor;
  assign ifu_bpu.pc_update = 1'b1;
  always_ff @(posedge clock) begin
    query_pc_q <= ifu_bpu.nextpc;
    query_valid_q <= 1'b1;
    hint_q <= hints[hint_read_index];
    hint_valid_q <= hint_valid_read[0];
    // Training payload and address cross the same edge; late fetch validity
    // only sets the pending bit. Invalidation cancels both pending generations.
    hint_write_q <= hint_train;
    hint_write_index_q <= hint_write_index;
    hint_write_valid_q <= recv_ready && !response_stop && !reset && !cmu_bcast.fence_i;
    if (hint_write_valid_q && !reset && !cmu_bcast.fence_i)
      hints[hint_write_index_q] <= hint_write_q;
    if (recv_ready && !response_stop) begin
      stride_q <= OffsetBits'(offset[fetched_count]);
    end
    if (query_match && !saved_valid_q) begin
      saved_valid_q <= 1'b1;
      // This edge also captures predicted_successor in query_pc_q. Hold that
      // query while stalled, sharing its register with the saved target.
      saved_taken_q <= ifu_bpu.taken;
    end
    if (request_advance || redirect_event) saved_valid_q <= 1'b0;
    if (reset) begin
      query_valid_q <= 1'b0;
      saved_valid_q <= 1'b0;
      stride_q <= OffsetBits'(2 * Width);
    end
  end
  assign ifu_l1i.consumed = ResponseStage ? capture_response : recv_ready;
  assign ifu_l1i.cancel = redirect_event || response_kill_younger;
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
      pc_ifu_q <= (PcW-1)'(PcW'(`RAPT_PC_INIT) >> 1);
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
        if (response_redirect) pc_ifu_q <= nextpc[PcW-1:1];
        else if (capture_response) pc_ifu_q <= request_nextpc[PcW-1:1];
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
      pmu_fetch_bpu_taken <= recv_ready && response_primary_taken;
      pmu_fetch_target_steer <= recv_ready
          && nextpc != response.pc + PcW'(2 * offset[fetched_count]);
`endif
      if (redirect_event) begin
        pc_ifu_q <= redirect_pc[PcW-1:1];
        held_count <= 0;
        blocked <= 1'b0;
      end else if (recv_ready) begin
        if (!ResponseStage) pc_ifu_q <= nextpc[PcW-1:1];
        held_count <= CountBits'(fetched_count);
        for (int s = 0; s < Width; s++) begin
          if (s < fetched_count && (is_serial[s] || fetched[s].trap)) blocked <= 1'b1;
        end
      end else begin
        held_count <= CountBits'(32'(held_count) - consumed);
      end
    end
  end
  // A free payload bank can sample even a missing/faulted fetch. Only the
  // count above publishes it. Translation/hit/prediction validity therefore
  // cannot fan out to the wide packet register's capture enable.
  always_ff @(posedge clock) begin
    for (int s = 0; s < Width; s++) begin
      if (32'(held_count) == consumed) held[s] <= fetched[s];
      else if (s + consumed < 32'(held_count)) held[s] <= held[s+consumed];
    end
  end
  if ((Width & (Width + 1)) != 0) begin : g_count_range
    `RAPT_SVA(clock, reset, IFU_RESIDENT_COUNT_BOUND, 32'(held_count) <= Width)
  end
  `RAPT_SVA(clock, reset, IFU_COUNT_BOUNDS, consumed <= 32'(held_count) && fetched_count <= Width)
  `RAPT_SVA_IMPLY(clock, reset, IFU_SAVED_QUERY_CAPTURE, saved_valid_q && !$past(saved_valid_q),
                  query_pc_q == $past(predicted_successor))
  `RAPT_SVA_IMPLY(clock, reset, IFU_SAVED_QUERY_HOLD, saved_valid_q && $past(saved_valid_q),
                  $stable(query_pc_q))
  `RAPT_SVA_IMPLY(clock, reset, IFU_RECOVERY_NO_RESPONSE_ACCEPT, recovery.redirect_valid,
                  !recv_ready && !ifu_bpu.history_valid)
  `RAPT_SVA_IMPLY(clock, reset, IFU_STABLE_REDIRECT_KEEPS_PC,
                  cmu_bcast.flush_redirect && cmu_bcast.fetch_context_stable && !$past
                  (recovery.preserve_fetch), cmu_bcast.redirect_pc == $past(cmu_bcast.cpc)
                  && pc_ifu == cmu_bcast.redirect_pc && !redirect_event)
  `RAPT_SVA_IMPLY(clock, reset, IFU_RECOVERY_NO_STREAM_OUTPUT, recovery.redirect_valid,
                  !ifu_idu.valid[0])
  `RAPT_SVA_IMPLY(clock, reset, IFU_RESPONSE_NO_WRONG_PACKET, response_redirect,
                  !capture_response && ifu_l1i.cancel)
  `RAPT_SVA_IMPLY(clock, reset, IFU_RESPONSE_NO_OVERWRITE, capture_response, response_count_q < 2)
  `RAPT_SVA(clock, reset, IFU_RESPONSE_COUNT_BOUND, response_count_q <= 2)
  `RAPT_SVA_IMPLY(clock, reset, IFU_RESPONSE_NO_UNDERFLOW, pop_response, response_valid_q)
  `RAPT_SVA_IMPLY(clock, reset, IFU_RESPONSE_FULL_STOPS_CAPTURE, response_count_q == 2,
                  !capture_response)
endmodule
